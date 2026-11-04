"""Request identity, source evidence and the actual page/action operations."""
import copy
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from mail_world import BASH, MailWorld, REPO, make_project

LIB = Path(os.environ.get("JARVIS_TEST_SKILLS", str(REPO / "skills"))) / "jarvis/scripts/lib"
os.environ["JARVIS_BASH"] = BASH
sys.path.insert(0, str(LIB))
import owner_asks
from session import Session


def request_comment(key="request-1", text="Question"):
    return {"id": key, "body": text, "user_id": "requester", "user": "Original asker",
            "user_email": "asker@example.test", "created_at": "2026-11-01T03:00:00Z",
            "updated_at": "2026-11-01T03:00:00Z", "parent_id": None,
            "url": "https://linear.app/example/issue/KEN-1#comment-" + key}


def projection(home, count=1):
    comments = [request_comment("request-" + str(i), "Question " + str(i)) for i in range(count)]
    return {"home": home, "config": {"configured": True}, "mailboxes": [],
            "tracker": {"workspace": "example", "issues": [{"uuid": "issue-uuid", "comments": comments}],
                        "requests": [{"issue": "KEN-1", "issueUuid": "issue-uuid", "thread": comment["id"], "comment": comment}
                                     for comment in comments]}}


class CanonicalFixture:
    """The public source projection and append boundary, with positive/unknown receipts."""
    def __init__(self, home, count=1):
        self.data = projection(home, count)
        self.deliveries = []
        self.confirm = True
        self.land = True

    def stable(self):
        return copy.deepcopy(self.data)

    def value(self, *args):
        return {"viewer": {"id": "posting-app"}}

    def send(self, route, text, key):
        self.deliveries.append(key)
        if self.land:
            comment = dict(request_comment("reply"), body=text, user_id="posting-app", parent_id=route["thread"])
            self.data["tracker"]["issues"][0]["comments"].append(comment)
        return "reply" if self.confirm else None


class OwnerAsksContract(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(dir=REPO / "tmp")
        self.addCleanup(self.scratch.cleanup)
        self.home = Path(self.scratch.name).resolve()
        self.now = 1793494800
        self.source = CanonicalFixture(str(self.home))
        self.environment = patch.dict(os.environ, {"XDG_STATE_HOME": str(self.home / "runtime")})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.owner = self.new_owner()

    def new_owner(self):
        session = Session(str(self.home))
        session.path = session.path.with_name("owner-asks.json")
        return owner_asks.OwnerAsks(session, self.source, lambda: self.now)

    def page(self, view="active", cursor=None, owner=None):
        owner = owner or self.owner
        with owner.session.locked():
            return owner.page(owner.read(), view, cursor)

    def action(self, action, row, request_id, revision=None, owner=None, **fields):
        owner = owner or self.owner
        request = {"requestId": request_id, "expectedRevision": revision or row["revision"], **fields}
        with owner.session.locked():
            return owner.action(owner.read(), action, row["id"], request)

    def test_distinct_comments_exact_mirrors_and_original_metadata(self):
        data = projection(str(self.home), 2)
        first = data["tracker"]["requests"][0]["comment"]
        ask = {"id": "actual-mail-id", "from": "overseer:repo", "at": "2026-10-30T01:00:00Z", "text": "Mailbox original",
               "tracker_posted": True, "issue": "KEN-1", "tracker_comment": first["id"]}
        data["mailboxes"] = [{"destination": "local", "root": "/canonical/repo", "asks": [ask], "outward": {"rows": [ask]},
                              "links": {ask["id"]: {"url": first["url"]}},
                              "posted": {"KEN-1": {"workspace": "example", "uuid": "issue-uuid"}}}]
        rows, _ = owner_asks.source_rows(data)
        self.assertEqual(len(rows), 2)
        self.assertEqual({row["askedBy"]["id"] for row in rows.values()}, {"overseer:repo", "requester"})
        self.assertEqual({row["askedAt"] for row in rows.values()}, {"2026-10-30T01:00:00Z", first["created_at"]})
        for linked in (False, True):
            with self.subTest(confirmed=linked):
                ask["tracker_posted"] = linked
                ask["tracker_comment"] = "unrelated"
                rows, _ = owner_asks.source_rows(data)
                self.assertEqual(len(rows), 3)
        data["mailboxes"][0]["asks"].append(dict(ask, id="another-real-ask"))
        data["mailboxes"][0]["links"]["another-real-ask"] = {"url": first["url"]}
        self.assertEqual(len(owner_asks.source_rows(data)[0]), 4)

    def test_complete_row_and_byte_paging_and_stale_cursors(self):
        self.source.data = projection(str(self.home), 70)
        first = self.page()
        ids = []
        page = first
        while True:
            self.assertLessEqual(len(page["rows"]), owner_asks.PAGE_ROWS)
            self.assertLessEqual(len(owner_asks.encoded(page).encode()) + 1, owner_asks.PAGE_BYTES)
            self.assertEqual(page["activeCount"], 70)
            self.assertEqual(page["revision"], first["revision"])
            ids.extend(row["id"] for row in page["rows"])
            if page["complete"]:
                self.assertIsNone(page["nextCursor"])
                break
            cursor = page["nextCursor"]
            page = self.page(cursor=cursor)
            self.assertNotEqual(page["nextCursor"], cursor)
        self.assertEqual(len(set(ids)), 70)
        self.assertEqual(self.page("snoozed")["revision"], first["revision"])
        self.source.data["tracker"]["requests"][0]["comment"]["body"] += " changed"
        with self.assertRaises(owner_asks.Unavailable):
            self.page(cursor=first["nextCursor"])
        self.source.data = projection(str(self.home))
        self.source.data["tracker"]["requests"][0]["comment"]["body"] = "x" * owner_asks.PAGE_BYTES
        with self.assertRaises(owner_asks.Unavailable):
            self.page()

    def test_receipt_replay_precedes_revision(self):
        row = self.page()["rows"][0]
        first = self.action("reply", row, "same-request", text="Owner answer")
        self.assertEqual(first["kind"], "accepted")
        self.assertEqual(self.action("reply", row, "same-request", text="Owner answer"), first)
        self.assertEqual(len(self.source.deliveries), 1)
        conflict = self.action("reply", row, "same-request", text="Different answer")
        self.assertEqual(conflict["kind"], "refused")
        stale = self.action("reply", row, "other-request", text="Owner answer")
        self.assertEqual(stale["kind"], "refused")
        self.assertEqual(len(self.source.deliveries), 1)

    def test_uncertain_delivery_needs_positive_evidence_and_never_resends(self):
        for landed in (True, False):
            with self.subTest(landed=landed):
                self.source.confirm, self.source.land = False, landed
                row = self.page()["rows"][0]
                key = "uncertain-" + str(landed)
                with self.assertRaises(owner_asks.Unavailable):
                    self.action("done", row, key, text="Evidence supplied")
                deliveries = len(self.source.deliveries)
                if landed:
                    result = self.action("done", row, key, text="Evidence supplied")
                    self.assertEqual((result["kind"], result["state"]), ("accepted", "checking"))
                else:
                    with self.assertRaises(owner_asks.Unavailable):
                        self.action("done", row, key, text="Evidence supplied")
                self.assertEqual(len(self.source.deliveries), deliveries)

    def test_done_and_snooze_keep_original_request_until_delegate_evidence(self):
        row = self.page()["rows"][0]
        result = self.action("done", row, "done", text="Evidence")
        self.assertEqual(result["state"], "checking")
        checking = self.page()["rows"][0]
        for until in ("2026-11-01T10:00:00", "2020-01-01T00:00:00Z", "not-time"):
            self.assertEqual(self.action("later", checking, until, until=until)["kind"], "refused")
        later = owner_asks.iso(self.now + 3600)
        self.assertEqual(self.action("later", checking, "later", until=later)["state"], "snoozed")
        self.assertEqual(self.page()["activeCount"], 0)
        snoozed = self.page("snoozed")["rows"][0]
        self.now += 3600
        restored = self.page()["rows"][0]
        self.assertEqual(restored["state"], "checking")
        self.assertEqual((restored["id"], restored["askedAt"], restored["link"]), (snoozed["id"], row["askedAt"], row["link"]))
        self.source.data["tracker"]["requests"] = []
        with self.assertRaises(owner_asks.Unavailable):
            self.page()

    def test_overlapping_actions_have_one_winner(self):
        row = self.page()["rows"][0]
        barrier, answers = threading.Barrier(2), []
        failures = []
        def act(key):
            try:
                owner = self.new_owner()
                barrier.wait(timeout=5)
                answers.append(self.action("later", row, key, owner=owner, until=owner_asks.iso(self.now + 60)))
            except BaseException as error:
                failures.append(error)
        threads = [threading.Thread(target=act, args=(str(i),)) for i in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=20)
            self.assertFalse(thread.is_alive())
        self.assertEqual(failures, [])
        self.assertEqual(sorted(answer["kind"] for answer in answers), ["accepted", "refused"])

    def test_control_rejects_lost_receipt_replay_guard(self):
        # Keep the mutant outside the worktree and acquire only its own
        # scratch directory. The original suite supplies all test fixtures.
        directory = REPO.parent / "tmp"
        directory.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="owner-asks-control-", dir=directory) as allocation:
            skills = Path(allocation).resolve() / "skills"
            for package in ("jarvis", "orch", "mailbox"):
                shutil.copytree(REPO / "skills" / package / "scripts", skills / package / "scripts")
            path = skills / "jarvis/scripts/lib/owner_asks.py"
            original = path.read_text()
            old = 'previous = state["requests"].get(request["requestId"])'
            self.assertEqual(original.count(old), 1)
            mutant = original.replace(old, 'previous = None')
            self.assertNotEqual(mutant, original)
            path.write_text(mutant)
            env = dict(os.environ, JARVIS_TEST_SKILLS=str(skills))
            result = subprocess.run([BASH, str(REPO / "skills/jarvis/tests/owner-asks.test.sh"),
                                     "OwnerAsksContract.test_receipt_replay_precedes_revision"],
                                    env=env, capture_output=True, text=True, timeout=60)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAILED (failures=", result.stderr)


class PublicOwnerAsks(MailWorld):
    def setUp(self):
        super().setUp()
        self.home = make_project(self.root / "main")
        for package in ("jarvis", "linear", "slack"):
            directory = self.home / ".agents/skills" / package
            directory.symlink_to(REPO / "skills" / package, target_is_directory=True)
        self.registry.write_text(str(self.home) + "\n")
        self.env.update(XDG_STATE_HOME=str(self.root / "runtime"), SLACK_BOT_TOKEN="test-token")

    def run_cli(self, action="list", home=None, payload=None, *args):
        command = [BASH, LIB.parent / "jarvis-session", "owner-asks", action, "--home", home or self.home, *args]
        if action == "list":
            command += ["--view", "active"]
        result = subprocess.run(list(map(str, command)), env=self.env, text=True, input=payload,
                                capture_output=True, cwd=self.home, timeout=20)
        return result, json.loads(result.stdout)

    def test_canonical_empty_absence_and_unreadable_source(self):
        result, page = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((page["activeCount"], page["snoozedCount"], page["rows"], page["complete"]), (0, 0, [], True))
        self.executable("kendex", "#!/bin/sh\nexit 1\n")
        result, error = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(error["kind"], "unavailable")
        self.assertNotIn("activeCount", error)

    def test_real_mailbox_link_reply_checking_and_verified_close(self):
        # Exercise Slack's public mapping/permalink owner against its existing
        # API fixture; no product reader or HTTP transport is replaced.
        spec = importlib.util.spec_from_file_location("fake_slack", REPO / "skills/slack/tests/lib/fake_slack.py")
        fake = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fake)
        fake.Handler.ws = fake.Workspace("test-token", "test-app", {}, 200)
        fake.Handler.ws.channels["C1"] = {"id": "C1", "name": "owner"}
        fake.Handler.ws.messages["C1"] = [{"ts": "100.000001", "text": "Original"}]
        server = fake.Server(("127.0.0.1", 0), fake.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)
        self.env["SLACK_API_URL"] = "http://127.0.0.1:" + str(server.server_port)
        ask = self.mail(self.home, "ask", "Original owner ask", "--to", "owner", "--options", "a,b", "--reserved")
        slack = self.home / "tmp/slack"
        slack.mkdir()
        (slack / "binding.json").write_text(json.dumps({"channel": "C1", "channel_name": "owner", "bound_at": "100", "owners": [], "owner_ids": {}}))
        (slack / "journal.jsonl").write_text(json.dumps({"t": "out", "id": ask, "kind": "ask", "state": "open", "thread": "100.000001", "at": "2026-11-01T00:00:00Z"}) + "\n")
        result, page = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        row = page["rows"][0]
        self.assertEqual(row["askedAt"], self.box(self.home, "to-overseer")[0]["at"])
        self.assertTrue(row["link"]["url"].startswith("https://workspace.slack.test/"))
        # The original delivery owner runs the real send, then loses its
        # stdout once. Recovery must use canonical positive evidence without
        # resending, including a body the mailbox normalizes at its boundary.
        scripts = self.home / ".agents/skills/mailbox/scripts"
        scripts.unlink()
        scripts.mkdir()
        wrapper = scripts / "lane-mail"
        wrapper.write_text('#!' + BASH + '\nset -euo pipefail\n' +
                           'if [ ! -f "' + str(self.root / "lost") + '" ]; then\n' +
                           '  "' + str(REPO / "skills/mailbox/scripts/lane-mail") + '" "$@" >/dev/null\n' +
                           '  touch "' + str(self.root / "lost") + '"\nelse\n' +
                           '  exec "' + str(REPO / "skills/mailbox/scripts/lane-mail") + '" "$@"\nfi\n')
        wrapper.chmod(0o755)
        payload = json.dumps({"requestId": "actual-done", "expectedRevision": row["revision"], "text": "Done evidence\n"})
        result, unknown = self.run_cli("done", None, payload, "--id", row["id"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(unknown["kind"], "unavailable")
        result, receipt = self.run_cli("done", None, payload, "--id", row["id"])
        self.assertEqual(receipt["state"], "checking", result.stderr)
        self.assertEqual(self.run_cli()[1]["rows"][0]["state"], "checking")
        self.assertEqual(self.run_cli("done", None, payload, "--id", row["id"])[1], receipt)
        answers = [entry for entry in self.box(self.home, "to-lane") if entry.get("re") == ask]
        self.assertEqual(len(answers), 1)
        self.assertEqual(answers[0]["kind"], "answer")
        closed = self.command([REPO / "skills/mailbox/scripts/lane-mail", "resolve", "--item", "overseer", "--id", ask], self.home)
        self.assertEqual(closed.returncode, 0, closed.stderr)
        self.assertEqual(self.run_cli()[1]["rows"], [])

    def test_satellite_uses_the_same_main_receipt_without_local_state(self):
        satellite = make_project(self.root / "satellite", overseer=False)
        (satellite / "kendex.settings.toml").write_text('[env]\nJARVIS_MAIN_HOST="main:' + str(self.home) + '"\n')
        self.executable("ssh", '#!' + BASH + '\nset -euo pipefail\nshift 4\nshift\nexec ' + BASH + ' -c "$1"\n')
        result, main = self.run_cli()
        result, remote = self.run_cli(home=satellite)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((remote["homeId"], remote["revision"]), (main["homeId"], main["revision"]))
        self.assertEqual(len(list((self.root / "runtime").rglob("owner-asks.json"))), 1)


if __name__ == "__main__":
    unittest.main()
