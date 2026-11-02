"""A satellite's forward, outbox drain and main status against a real main mailbox over an ssh shim."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import time
import unittest
from unittest.mock import patch

from mail_world import BASH, LANE_MAIL, REPO, SCRIPTS, MailWorld, make_project

WORKFLOW_STATE = REPO / "skills/orch/scripts/workflow-state"

# Independent of the producer: the status --main shape a consumer validates.
SATELLITE_KEYS = {"v", "role", "main", "reachable", "checked_at", "cause", "last_answer", "requests"}
REQUEST_KEYS = {"request", "key", "state", "cause", "forwarded", "queued_at", "attempts"}
STATES = {"queued", "delivered", "read"}
SSH = r'''#!/bin/sh
while [ "$1" = "-o" ]; do shift 2; done
printf '%s\n' "$1" >> "$SSH_LOG"
shift
mode="$(cat "$SSH_MODE")"
case "$mode" in
  down) exit 255 ;;
  hang) exec sleep 30 ;;
  drop-receipt) case "$*" in *--delivery-id*) sh -c "$*" >/dev/null 2>&1; exit 255 ;; esac ;;
esac
exec sh -c "$*"
'''
REQUEST_AT = "2026-11-02T14:03:07.120Z"
CONFIRMED_AT = "2026-11-02T14:03:21Z"
OPERATION = "vgs-audit:2026-11-02T14:03:07.120Z#3:op-7"
DAY = 86400


def satellite_status(output):
    answer = json.loads(output)
    assert set(answer) == SATELLITE_KEYS, answer
    assert answer["v"] == 1 and answer["role"] == "satellite"
    for row in answer["requests"]:
        assert set(row) == REQUEST_KEYS and row["state"] in STATES, row
    return answer


def canonical(at):
    """The record time with its fraction padded to nine digits, as the key reads it."""
    whole, _, fraction = at[:-1].partition(".")
    return whole + "." + fraction.ljust(9, "0") + "Z"


class Forward(MailWorld):
    scripts = SCRIPTS

    def setUp(self):
        super().setUp()
        self.main = make_project(self.root / "main")
        self.satellite = make_project(self.root / "satellite")
        (self.satellite / "tmp").mkdir(exist_ok=True)
        self.mode = self.root / "ssh-mode"
        self.mode.write_text("up")
        self.ssh_log = self.root / "ssh.log"
        self.executable("ssh", SSH)
        self.env.update(SSH_LOG=str(self.ssh_log), SSH_MODE=str(self.mode),
                        JARVIS_MAIN_HOST="main.example:" + str(self.main))
        self.records = 0

    def record(self, request=None, confirmation=None, **top):
        """A distinct valid words-form record; request and confirmation replace their parts' fields."""
        self.records += 1
        confirmation = confirmation or {}
        base = {"ref": "vgs-audit:conf-%d" % self.records, "at": CONFIRMED_AT}
        if "method" not in confirmation:
            base["words"] = "Yes."
        value = {"v": 1,
                 "request": dict({"ref": "vgs-audit:req-%d" % self.records, "at": REQUEST_AT,
                                  "text": "Renew passport %d." % self.records}, **(request or {})),
                 "confirmation": dict(base, **confirmation)}
        value.update(top)
        return value

    def write(self, record):
        path = self.satellite / "tmp" / ("record-%d.json" % self.records)
        path.write_bytes(record if isinstance(record, bytes) else json.dumps(record).encode())
        return path

    def jarvis(self, *args, env=None):
        return self.command([BASH, self.scripts / "jarvis-session", *args, "--home", self.satellite],
                            self.satellite, env)

    def forward(self, record, env=None):
        return self.jarvis("forward", "--record", self.write(record), env=env)

    def status(self):
        result = self.jarvis("status", "--main")
        self.assertEqual(result.returncode, 0, result.stderr)
        return satellite_status(result.stdout)

    def ssh_calls(self):
        return self.ssh_log.read_text().splitlines() if self.ssh_log.exists() else []

    def directives(self):
        return [row for row in self.box(self.main, "to-lane") if row["kind"] == "directive"]

    def key(self, record):
        request = record["request"]
        identity = str(self.satellite) + "\n" + request["ref"] + "\n" + canonical(request["at"])
        return "forward-" + hashlib.sha256(identity.encode()).hexdigest()

    def outbox_path(self):
        return (self.root / ".local/state/kendex/jarvis" / hashlib.sha256(os.fsencode(str(self.satellite))).hexdigest()
                / "forward.json")

    def outbox(self):
        return json.loads(self.outbox_path().read_text())

    def age(self, field, days, record=None):
        """Move FIELD's time DAYS back on every entry, or on RECORD's, as if that long had passed."""
        outbox = self.outbox()
        for entry in outbox["entries"]:
            if entry.get(field) is not None and (record is None or entry["key"] == self.key(record)):
                entry[field] -= days * DAY
        self.outbox_path().write_text(json.dumps(outbox))

    def age_closed(self, days):
        self.age("closed_at", days)

    def landed(self, record):
        """The main's directive that carries RECORD's delivery key."""
        rows = [row for row in self.directives() if row.get("delivery_id") == self.key(record)]
        self.assertEqual(len(rows), 1)
        return rows[0]["id"]

    def unregister(self, root):
        """Clear ROOT's overseer record, as a main session that ended leaves it."""
        env = {k: v for k, v in self.env.items() if not k.startswith("JARVIS_")}
        result = self.command([WORKFLOW_STATE, "set", "oversee", "overseer", "null"], root, env)
        self.assertEqual(result.returncode, 0, result.stderr)

    def compact_all(self, root):
        """lane-mail compact on ROOT at a clock past every row's retention."""
        late = self.root / "late"
        late.mkdir(exist_ok=True)
        date = late / "date"
        date.write_text('#!/bin/sh\ncase "$*" in *+%s*) echo 9999999999;; *) exec '
                        + shutil.which("date") + ' "$@";; esac\n')
        date.chmod(0o755)
        result = self.command([LANE_MAIL, "compact", "--item", "overseer"], root,
                              dict(self.env, PATH=str(late) + os.pathsep + self.env["PATH"]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("to-overseer=0", result.stdout)

    def answer(self, forwarded, text, *options):
        self.mail(self.main, "notice", text, "--to", "owner", "--ref", forwarded, *options)

    def delivered(self, record):
        result = self.forward(record)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_record_delivers(self):
        # Each row: name, request fields, confirmation fields, the line's method and text values.
        rows = (("vgs-audit words", {}, {}, "words", '"Yes."'),
                ("lane-mail words", {"ref": "lane-mail:1793628728-58343-3175"},
                 {"ref": "lane-mail:1793628729-58414-2848", "words": "forward"}, "words", '"forward"'),
                ("transcript confirmation", {"ref": "lane-mail:1793628728-1-1"},
                 {"ref": "transcript:session-1#turn-9", "words": "Sure thing\nForward!"}, "words",
                 '"Sure thing\\nForward!"'),
                ("one nanosecond later", {"at": "2026-11-02T14:03:07Z"}, {"at": "2026-11-02T14:03:07.000000001Z"},
                 "words", '"Yes."'),
                ("physical, one operation row", {"ref": OPERATION},
                 {"ref": OPERATION, "at": REQUEST_AT, "method": "physical"}, "physical", "null"),
                ("voice beside a voice-request header",
                 {"text": "voice-request: caller=owner operation=op-8\nBook the flight."},
                 {"method": "voice"}, "voice", "null"))
        for name, request, confirmation, method, text in rows:
            with self.subTest(row=name):
                record = self.record(request, confirmation)
                before = len(self.directives())
                answer = self.delivered(record)
                rows_written = self.directives()[before:]
                key = self.key(record)
                line = ("forwarded-request: satellite=%s request-ref=%s request-at=%s confirmation-ref=%s "
                        "confirmed-at=%s key=%s confirmation-method=%s confirmation-text=%s" % (
                            os.uname().nodename, record["request"]["ref"], record["request"]["at"],
                            record["confirmation"]["ref"], record["confirmation"]["at"], key, method, text))
                self.assertEqual([(row["from"], row.get("delivery_id"), row["text"]) for row in rows_written],
                                 [("owner", key, record["request"]["text"] + "\n\n" + line)])
                self.assertEqual((answer["key"], answer["forwarded"], answer["request"]),
                                 (key, rows_written[0]["id"], record["request"]["ref"]))
        # forward read no satellite mailbox row: the satellite holds none.
        self.assertEqual(self.box(self.satellite, "to-lane"), [])

    def test_record_refusals(self):
        long_words = "x" * 293 + "\nforward"
        rows = (("missing file", None, "record-unreadable"),
                ("oversized", b"{" + b" " * 65535 + b"}", "record-unreadable"),
                ("invalid utf-8", b'{"v":1,"request":"\xff"}', "record-unreadable"),
                ("array", b"[]", "record-unreadable"),
                ("v 2", {"v": 2}, "record-invalid field=record"),
                ("v true", {"v": True}, "record-invalid field=record"),
                ("extra key", {"extra": "x"}, "record-invalid field=record"),
                ("request without at", ("request", "at"), "record-invalid field=request"),
                ("words and method", (None, {"method": "voice", "words": "Yes."}), "record-invalid field=confirmation"),
                ("unknown method", (None, {"method": "text"}), "record-invalid field=confirmation.method"),
                ("empty id", ({"ref": "vgs-audit:"}, None), "record-invalid field=request.ref"),
                ("unknown source", ({"ref": "audit:1"}, None), "record-invalid field=request.ref"),
                ("space in id", ({"ref": "vgs-audit:a b"}, None), "record-invalid field=request.ref"),
                ("long id", ({"ref": "vgs-audit:" + "a" * 201}, None), "record-invalid field=request.ref"),
                ("offset", (None, {"at": "2026-11-02T14:03:07+00:00"}), "record-invalid field=confirmation.at"),
                ("space time", (None, {"at": "2026-11-02 14:03:07Z"}), "record-invalid field=confirmation.at"),
                ("no such day", (None, {"at": "2026-02-30T00:00:00Z"}), "record-invalid field=confirmation.at"),
                ("ten digit fraction", (None, {"at": "2026-11-02T14:03:21.1234567890Z"}),
                 "record-invalid field=confirmation.at"),
                ("blank text", ({"text": " \n"}, None), "record-invalid field=request.text"),
                ("blank words", (None, {"words": " "}), "record-invalid field=confirmation.words"),
                ("a second before", (None, {"at": "2026-11-02T14:03:06.120Z"}), "confirmation-early"),
                ("no", (None, {"words": "no, don't"}), "confirmation-unclear"),
                ("yes please", (None, {"words": "yes please"}), "confirmation-unclear"),
                ("forward it", (None, {"words": "forward it"}), "confirmation-unclear"),
                ("301 characters", (None, {"words": long_words}), "confirmation-unclear"))
        self.assertEqual(len(long_words), 301)
        for name, change, cause in rows:
            with self.subTest(row=name):
                if change is None:
                    path = self.satellite / "tmp/absent.json"
                elif isinstance(change, bytes):
                    path = self.write(change)
                elif isinstance(change, dict):
                    path = self.write(self.record(**change))
                elif change == ("request", "at"):
                    record = self.record()
                    del record["request"]["at"]
                    path = self.write(record)
                else:
                    path = self.write(self.record(*change))
                result = self.jarvis("forward", "--record", path)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stderr.split("\n")[0], "jarvis-session: forward=refused cause=" + cause)
        self.assertEqual(self.ssh_calls(), [])
        self.assertEqual(self.directives(), [])
        self.assertFalse(self.outbox_path().exists())

    def test_same_request_keeps_one_key(self):
        self.mode.write_text("down")
        record = self.record()
        first = self.forward(record)
        later = json.loads(json.dumps(record))
        later["request"]["at"] = "2026-11-02T14:03:07.120000Z"
        later["confirmation"].update(ref="vgs-audit:conf-later", at="2026-11-02T14:05:00Z", words="forward")
        again = self.forward(later)
        self.assertEqual((first.returncode, again.returncode), (75, 75), again.stderr)
        self.assertEqual({json.loads(first.stdout)["key"], json.loads(again.stdout)["key"]}, {self.key(record)})
        entries = self.outbox()["entries"]
        self.assertEqual(len(entries), 1)
        self.assertIn(" confirmation-ref=vgs-audit:conf-1 ", entries[0]["text"])
        conflict = json.loads(json.dumps(record))
        conflict["request"]["text"] = "Renew another passport."
        moved = json.loads(json.dumps(record))
        moved["request"]["at"] = "2026-11-02T14:03:08Z"
        moved["confirmation"]["at"] = "2026-11-02T14:04:00Z"
        for name, changed in (("other text", conflict), ("other time", moved)):
            with self.subTest(row=name):
                refused = self.forward(changed)
                self.assertEqual(refused.stderr.split("\n")[0], "jarvis-session: forward=refused cause=request-conflict")
        self.mode.write_text("up")
        self.assertEqual(self.jarvis("forward-drain").returncode, 0)
        self.assertEqual([row.get("delivery_id") for row in self.directives()], [self.key(record)])

    def test_unavailable_main(self):
        rows = (("down", "down", "main-unreachable"), ("overseer absent", "unregistered", "overseer-absent"),
                ("mailbox missing", "bare", "mailbox-missing"))
        requests = []
        for name, main, cause in rows:
            with self.subTest(row=name):
                if main == "down":
                    self.mode.write_text("down")
                else:
                    self.main = make_project(self.root / main, overseer=False)
                    if main == "bare":
                        shutil.rmtree(self.main / ".agents/skills/mailbox")
                    self.env["JARVIS_MAIN_HOST"] = "main.example:" + str(self.main)
                    self.mode.write_text("up")
                record = self.record()
                requests.append(record["request"]["ref"])
                result = self.forward(record)
                self.assertEqual(result.returncode, 75, result.stderr)
                answer = json.loads(result.stdout)
                self.assertEqual((answer["state"], answer["cause"], answer["forwarded"]), ("queued", cause, None))
                self.assertEqual(self.directives(), [])
                status = self.status()
                self.assertEqual(status["reachable"], main != "down")
                self.assertEqual([(row["state"], row["cause"]) for row in status["requests"]
                                  if row["request"] == record["request"]["ref"]], [("queued", cause)])
        # No retry clears a missing mailbox: the drain reports every request
        # it now holds, each as one event block the watch loop appends.
        drained = self.jarvis("forward-drain")
        self.assertEqual((drained.returncode, drained.stdout), (0, "".join(
            "EVENT forward-failed request=%s cause=mailbox-missing detail=forward:\\u0020mailbox-missing=%s\n"
            % (request, self.main) for request in requests)), drained.stderr)

    def test_hung_main_records_its_cause_within_the_budget(self):
        self.mode.write_text("hang")
        spec = importlib.util.spec_from_file_location("jarvis_forward", self.scripts / "lib/forward.py")
        module = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, self.env, clear=True):
            spec.loader.exec_module(module)
            forwarder = module.Forwarder(BASH, str(self.satellite), self.outbox_path().parent)
            with forwarder.outbox.locked() as state:
                state["entries"].append({"key": "forward-hang", "request": "vgs-audit:r", "text": "x",
                                         "queued_at": 0, "attempts": 0, "forwarded": None})
            forwarder.deadline = time.monotonic() + 2
            started = time.monotonic()
            self.assertEqual(forwarder.drain(), "")
            self.assertLess(time.monotonic() - started, 10)
            state = forwarder.outbox.read()
        self.assertEqual((state["probe"]["reachable"], state["probe"]["cause"]), (False, "main-unreachable"))
        self.assertEqual(state["entries"][0]["cause"], "main-unreachable")

    def test_retry_recovery(self):
        with self.subTest(row="restart delivers once"):
            self.mode.write_text("down")
            record = self.record()
            self.assertEqual(self.forward(record).returncode, 75)
            frozen = self.outbox()["entries"][0]["text"]
            # An answer older than the send never counts.
            self.answer(self.mail(self.main, "send", "older owner note", "--directive"), "older reply")
            self.mode.write_text("up")
            drained = self.jarvis("forward-drain")
            self.assertEqual((drained.returncode, drained.stdout), (0, ""), drained.stderr)
            rows = self.directives()
            self.assertEqual([(row["from"], row.get("delivery_id"), row["text"]) for row in rows[1:]],
                             [("owner", self.key(record), frozen)])
            self.assertEqual(self.outbox()["entries"][0]["forwarded"], rows[1]["id"])
            self.assertIsNone(self.status()["last_answer"])
        with self.subTest(row="lost receipt lands once"):
            record = self.record()
            self.mode.write_text("drop-receipt")
            self.assertEqual(self.forward(record).returncode, 75)
            self.mode.write_text("up")
            self.assertEqual(self.jarvis("forward-drain").returncode, 0)
            landed = [row for row in self.directives() if row["text"].startswith(record["request"]["text"])]
            self.assertEqual(len(landed), 1)
            entry = next(entry for entry in self.outbox()["entries"] if entry["request"] == record["request"]["ref"])
            self.assertEqual((entry["forwarded"], landed[0].get("delivery_id")), (landed[0]["id"], entry["key"]))

    def test_lost_receipt_then_answer(self):
        # The main answers a request whose receipt the satellite lost, with no
        # other forward open; the retry that follows lands, or is refused,
        # and the answer closes it.
        for name, registered in (("lost receipt, then the answer", True),
                                 ("lost receipt, answer, then the main session ends", False)):
            with self.subTest(row=name):
                record = self.record()
                self.mode.write_text("drop-receipt")
                self.assertEqual(self.forward(record).returncode, 75)
                self.answer(self.landed(record), "Done: " + record["request"]["ref"])
                if not registered:
                    self.unregister(self.main)
                self.mode.write_text("up")
                drained = self.jarvis("forward-drain")
                self.assertEqual((drained.returncode, drained.stdout), (0, ""), drained.stderr)
                status = self.status()
                self.assertEqual(([row["request"] for row in status["requests"]
                                   if row["request"] == record["request"]["ref"]], (status["last_answer"] or {}).get("request")),
                                 ([], record["request"]["ref"]))

    def test_answer_closes_the_entry(self):
        with self.subTest(row="console request"):
            record = self.record({"ref": "lane-mail:1793628728-58343-1"},
                                 {"ref": "lane-mail:1793628729-58414-2", "words": "forward"})
            forwarded = self.delivered(record)["forwarded"]
            self.answer(forwarded, "Renewed.")
            drained = self.jarvis("forward-drain")
            self.assertEqual((drained.returncode, drained.stdout), (0, ""), drained.stderr)
            status = self.status()
            self.assertEqual((status["requests"], status["last_answer"]["request"], status["last_answer"]["forwarded"]),
                             ([], record["request"]["ref"], forwarded))
            calls = self.ssh_calls()
            self.assertEqual(self.jarvis("forward-drain").stdout, "")
            self.assertEqual(self.ssh_calls(), calls)
            again = self.forward(record)
            self.assertEqual(again.stderr.split("\n")[0], "jarvis-session: forward=refused cause=answered-already")
            self.assertEqual(self.ssh_calls(), calls)
        with self.subTest(row="progress, then the answer"):
            record = self.record()
            forwarded = self.delivered(record)["forwarded"]
            # The main reader takes the request, so its receipt reads it.
            self.assertEqual(self.command([LANE_MAIL, "inbox", "--item", "overseer"], self.main).returncode, 0)
            self.answer(forwarded, "Working on it.", "--progress")
            self.assertEqual(self.jarvis("forward-drain").stdout, "")
            self.assertEqual([row["state"] for row in self.status()["requests"]], ["read"])
            self.answer(forwarded, "Done.")
            self.assertEqual(self.jarvis("forward-drain").stdout, "")
            self.assertEqual(self.status()["requests"], [])
            # Past the closed entry's keep, the same record sends again; the main
            # lands it once, and its earlier answer closes it again.
            self.age_closed(31)
            self.assertEqual(self.delivered(record)["forwarded"], forwarded)
            self.assertEqual(len([row for row in self.directives() if row.get("delivery_id") == self.key(record)]), 1)
            self.assertEqual(self.jarvis("forward-drain").stdout, "")
            self.assertEqual(self.status()["requests"], [])
        with self.subTest(row="reused reference, later request"):
            record = self.record()
            forwarded = self.delivered(record)["forwarded"]
            self.answer(forwarded, "First done.")
            self.assertEqual(self.jarvis("forward-drain").returncode, 0)
            self.age_closed(31)
            later = json.loads(json.dumps(record))
            later["request"].update(at="2026-11-03T09:00:00Z", text="Renew it again.")
            later["confirmation"].update(at="2026-11-03T09:00:05Z")
            self.delivered(later)
            keys = {self.key(record), self.key(later)}
            self.assertEqual(len(keys), 2)
            self.assertEqual({row["delivery_id"] for row in self.directives() if row.get("delivery_id") in keys}, keys)
        # Each row: name, the order the main answers requests A and B in
        # between drains, and the request of the answer the main wrote last.
        for name, order, last in (("an answer read beside a later delivery", "A, deliver B", "A"),
                                  ("answers in request order", "AB", "B"), ("answers in reverse order", "BA", "A")):
            with self.subTest(row=name):
                first, second = self.record(), self.record()
                forwarded = {"A": self.delivered(first)["forwarded"]}
                if order == "A, deliver B":
                    self.answer(forwarded["A"], "Done: " + forwarded["A"])
                    self.delivered(second)
                else:
                    forwarded["B"] = self.delivered(second)["forwarded"]
                    for request in order:
                        self.answer(forwarded[request], "Done: " + forwarded[request])
                drained = self.jarvis("forward-drain")
                self.assertEqual((drained.returncode, drained.stdout), (0, ""), drained.stderr)
                status = self.status()
                refs = {"A": first["request"]["ref"], "B": second["request"]["ref"]}
                self.assertEqual(([row["request"] for row in status["requests"] if row["request"] in refs.values()],
                                  (status["last_answer"] or {}).get("request")),
                                 ([refs["B"]] if order == "A, deliver B" else [], refs[last]))
        # Each row: name, whether the main compacts the answer away, then the
        # drain's output and whether the forward is still open, a week after delivery.
        for name, compacted in (("an answer kept past the wait", False), ("an answer compacted unread", True)):
            with self.subTest(row=name):
                record = self.record()
                forwarded = self.delivered(record)["forwarded"]
                self.assertEqual(self.command([LANE_MAIL, "inbox", "--item", "overseer"], self.main).returncode, 0)
                self.answer(forwarded, "Done: " + forwarded)
                last = self.status()["last_answer"]
                if compacted:
                    self.compact_all(self.main)
                self.age("delivered_at", 7, record)
                drained = self.jarvis("forward-drain")
                expected = ("EVENT forward-failed request=%s cause=answer-unseen\n" % record["request"]["ref"]
                            if compacted else "")
                self.assertEqual((drained.returncode, drained.stdout), (0, expected), drained.stderr)
                status = self.status()
                self.assertEqual([row for row in status["requests"] if row["request"] == record["request"]["ref"]], [])
                self.assertEqual(status["last_answer"]["request"], last["request"] if compacted else record["request"]["ref"])
                if compacted:
                    self.assertEqual(self.jarvis("forward-drain").stdout, expected)
                    calls = self.ssh_calls()
                    again = self.forward(record)
                    self.assertEqual(again.stderr.split("\n")[0], "jarvis-session: forward=refused cause=answer-unseen")
                    self.assertEqual(self.ssh_calls(), calls)

    def test_role_refusals(self):
        record = self.write(self.record())
        main = dict(self.env, JARVIS_MAIN_HOST="")
        invalid = dict(self.env, JARVIS_MAIN_HOST="main.example")
        rows = (("main forward", ("forward", "--record", record), main, "forward", "role-main"),
                ("main drain", ("forward-drain",), main, "forward-drain", "role-main"),
                ("invalid forward", ("forward", "--record", record), invalid, "forward", "setting-invalid"))
        for name, args, env, verb, cause in rows:
            with self.subTest(row=name):
                result = self.jarvis(*args, env=env)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stderr.split("\n")[0], "jarvis-session: %s=refused cause=%s" % (verb, cause))
        self.assertEqual(self.ssh_calls(), [])
        self.assertEqual(self.directives(), [])
        status = self.jarvis("status", "--main", env=invalid)
        self.assertEqual(satellite_status(status.stdout)["cause"], "setting-invalid")
        self.assertEqual(json.loads(self.jarvis("status", "--main", env=main).stdout), {"v": 1, "role": "main"})

    def test_instrument_control(self):
        # Each planted defect, in a disposable copy, turns its row red.
        rows = (
            # A send that drops the delivery key lands a lost-receipt retry twice.
            ("test_retry_recovery", "lib/owner_note.py", ' --file "$note" ${1+"$@"}\n', ' --file "$note"\n'),
            # A key from the reference alone never lands a reused reference's later request.
            ("test_answer_closes_the_entry", "lib/forward.py",
             'canonical_at(request["at"])).encode()', '"").encode()'))
        for name, relative, old, new in rows:
            with self.subTest(row=name), tempfile.TemporaryDirectory() as folder:
                copy = Path(folder) / "jarvis/scripts"
                shutil.copytree(SCRIPTS, copy)
                for package in ("mailbox", "orch"):
                    Path(folder, package).symlink_to(REPO / "skills" / package, target_is_directory=True)
                path = copy / relative
                source = path.read_text()
                self.assertEqual(source.count(old), 1)
                path.write_text(source.replace(old, new))
                case = Forward(methodName=name)
                case.scripts = copy
                case.setUp()
                try:
                    with self.assertRaises(AssertionError):
                        getattr(case, name)()
                finally:
                    case.doCleanups()


if __name__ == "__main__":
    unittest.main()
