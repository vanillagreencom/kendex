"""owner-unanswered judges real lane-mail rows against replies, threads, closes and progress records."""
import datetime
import json
from pathlib import Path
import shutil
import tempfile
import time
import unittest

from mail_world import BASH, LANE_MAIL, REPO, SCRIPTS, MailWorld, make_project


def record(identity, operation, decision, at="2026-10-18T23:00:00Z"):
    return ("- Id and time: P-20261018T23000%sZ %s\n  - Operation: %s\n  - Observed result and source: read\n"
            "  - Decision: %s\n  - State change: none\n") % (identity, at, operation, decision)


class OwnerUnanswered(MailWorld):
    scripts = None

    def setUp(self):
        super().setUp()
        self.packages = self.root / "packages"
        for name in ("jarvis", "mailbox"):
            shutil.copytree(REPO / "skills" / name / "scripts", self.packages / name / "scripts")
        self.packages.joinpath("orch").symlink_to(REPO / "skills/orch", target_is_directory=True)
        if self.scripts is None:
            self.scripts = self.packages / "jarvis/scripts"
        self.home = make_project(self.root / "home")
        self.clock = self.root / "clock"
        self.clock.mkdir()
        real = shutil.which("date")
        self.clock.joinpath("date").write_text(
            '#!/bin/sh\ncase "$*" in *+%s*) echo "$CLOCK";; *) exec ' + real + ' "$@";; esac\n')
        self.clock.joinpath("date").chmod(0o755)
        # One now for every send and check, so a row's age is its offset and
        # the --older bounds hold however long the runner takes.
        self.base = int(time.time())

    def owner(self, text, *options):
        return self.mail(self.home, "send", text, *options)

    def clocked(self, offset):
        return dict(self.env, PATH=str(self.clock) + ":" + self.env["PATH"], CLOCK=str(self.base + offset))

    def check(self, *args, offset=0):
        result = self.command([BASH, self.scripts / "owner-unanswered", *args], self.home, self.clocked(offset))
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line)["text"] for line in result.stdout.splitlines()]

    def world(self):
        """One owner row per table case; returns the texts expected listed.

        The session reads the inbox before the -300 cases, so compaction drops
        the earlier closed and covered exchanges and keeps every later row and
        the open ask's thread.
        Rows sent under one at() share their id's epoch second, as a relay
        catch-up's do: a record naming one full id covers no sibling.
        """
        key = iter("C1:%d.0" % n for n in range(100))
        plain = self.env

        def at(offset):
            self.env = self.clocked(offset)

        def stamp(offset):
            return datetime.datetime.fromtimestamp(self.base + offset, datetime.timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ")

        at(-900)
        asks = [self.mail(self.home, "ask", "question %d" % n, "--to", "owner", "--options", "yes,no",
                          "--recommend", "yes") for n in range(4)]
        at(-800)
        replied = self.owner("answered by ref", "--directive", "--delivery-id", next(key))
        self.mail(self.home, "notice", "reply", "--to", "owner", "--ref", replied)
        at(-700)
        self.owner("yes", "--re", asks[0], "--delivery-id", next(key))
        self.owner("no, sibling", "--re", asks[0], "--delivery-id", next(key))
        at(-655)
        self.mail(self.home, "notice", "ruling reported", "--to", "owner", "--ref", asks[0])
        self.owner("same second as the reply", "--re", asks[0], "--delivery-id", next(key))
        at(-650)
        self.owner("correction after the reply", "--re", asks[0], "--delivery-id", next(key))
        at(-600)
        self.owner("closed answer", "--re", asks[1], "--delivery-id", next(key))
        result = self.command([LANE_MAIL, "resolve", "--item", "overseer", "--id", asks[1]], self.home)
        self.assertEqual(result.returncode, 0, result.stderr)
        at(-500)
        logged = self.owner("logged answer", "--re", asks[2], "--delivery-id", next(key))
        at(-400)
        archived = self.owner("archived answer", "--re", asks[3], "--delivery-id", next(key))
        read = self.command([LANE_MAIL, "inbox", "--item", "overseer"], self.home)
        self.assertEqual(read.returncode, 0, read.stderr)
        at(-300)
        quiet = self.owner("request handled with no reply", "--directive", "--delivery-id", next(key))
        self.owner("same second as a handled request", "--directive", "--delivery-id", next(key))
        at(-290)
        root = next(key)
        self.owner("thread root", "--directive", "--delivery-id", root)
        at(-280)
        followed = self.threaded("thread follow-up", root, next(key))
        at(-270)
        self.mail(self.home, "notice", "followed up", "--to", "owner", "--ref", followed)
        at(-260)
        self.threaded("thread correction", root, next(key))
        # An ask that names a thread root posts its own top-level question:
        # it answers the root alone, not the follow-up in the root's thread.
        at(-255)
        asked = self.owner("asked about root", "--directive", "--delivery-id", "C8:1.0")
        at(-254)
        self.threaded("follow-up an ask does not answer", "C8:1.0", "C8:2.0")
        at(-253)
        self.mail(self.home, "ask", "about the root", "--to", "owner", "--options", "yes,no", "--recommend", "yes",
                  "--ref", asked)
        # Each pair case has its own channel, so no other text is near. A
        # pair is judged on the Slack stamps in the delivery ids, which the
        # owner sent; at is the relay's delivery, which a catch-up bunches.
        at(-250)
        self.owner("caption", "--directive", "--delivery-id", "C2:1000.0")
        self.owner("late caption", "--directive", "--delivery-id", "C3:1000.0")
        self.threaded("thread text", "C4:1.0", "C4:1002.0")
        self.owner("text before a captioned file", "--directive", "--delivery-id", "C7:1000.0")
        at(-249)
        self.owner("file F2 not fetched: no download url", "--directive", "--delivery-id", "C3:1031.0")
        captioned_file = "and here is the log\n" + str(self.home / "tmp/slack/files/F6-log.txt")
        self.owner(captioned_file, "--directive", "--delivery-id", "C7:1010.0")
        # Pair cover: one cover at -244 names one member, by either producer,
        # a notice --ref or a no-reply record. It covers the member it names,
        # and the other member only when that one arrived before it; a relay
        # catch-up or retry delivers it later.
        at(-245)
        covered_caption = self.owner("caption a record handled", "--directive", "--delivery-id", "C6:1000.0")
        self.owner(str(self.home / "tmp/slack/files/F5-covered.png"), "--directive", "--delivery-id", "C6:1010.0")
        replied_text = self.owner("text a reply names", "--directive", "--delivery-id", "C12:1000.0")
        self.owner(str(self.home / "tmp/slack/files/F9-replied.png"), "--directive", "--delivery-id", "C12:1010.0")
        self.owner("text whose file a reply names", "--directive", "--delivery-id", "C11:1000.0")
        replied_file = self.owner(str(self.home / "tmp/slack/files/F10-replied.png"),
                                  "--directive", "--delivery-id", "C11:1010.0")
        self.owner("text whose file a record handled", "--directive", "--delivery-id", "C13:1000.0")
        recorded_file = self.owner(str(self.home / "tmp/slack/files/F11-recorded.png"),
                                   "--directive", "--delivery-id", "C13:1010.0")
        answered_text = self.owner("text answered before its file", "--directive", "--delivery-id", "C9:1000.0")
        recorded_text = self.owner("text a record handled before its file", "--directive",
                                   "--delivery-id", "C10:1000.0")
        early_file = self.owner(str(self.home / "tmp/slack/files/F12-early.png"),
                                "--directive", "--delivery-id", "C14:1010.0")
        early_recorded_file = self.owner(str(self.home / "tmp/slack/files/F13-early.png"),
                                         "--directive", "--delivery-id", "C15:1010.0")
        at(-244)
        for target in (replied_text, replied_file, answered_text, early_file):
            self.mail(self.home, "notice", "on " + target, "--to", "owner", "--ref", target)
        at(-243)
        late_file = str(self.home / "tmp/slack/files/F7-late.png")
        self.owner(late_file, "--directive", "--delivery-id", "C9:1015.0")
        late_recorded_file = str(self.home / "tmp/slack/files/F8-late.png")
        self.owner(late_recorded_file, "--directive", "--delivery-id", "C10:1015.0")
        self.owner("text after a reply named its file", "--directive", "--delivery-id", "C14:1000.0")
        self.owner("text after a record named its file", "--directive", "--delivery-id", "C15:1000.0")
        at(-240)
        other_thread = str(self.home / "tmp/slack/files/F3-other.png")
        self.threaded(other_thread, "C4:9.0", "C4:1003.0")
        at(-200)
        self.owner(str(self.home / "tmp/slack/files/F1-photo.png") + "\nfile F4 not fetched: no download url",
                   "--directive", "--delivery-id", "C2:1020.0")
        at(-199)
        legacy = self.owner("legacy archived", "--directive", "--delivery-id", next(key))
        current = self.owner("legacy in the handoff", "--directive", "--delivery-id", next(key))
        delegated = self.owner("delegate logged", "--directive", "--delivery-id", next(key))
        delegate_archived = self.owner("delegate archived", "--directive", "--delivery-id", next(key))
        at(-198)
        self.owner("no delivery id", "--directive")
        self.owner("watch-loop batch", "--directive", "--delivery-id", "jarvis-0123abcd")
        at(-100)
        self.owner("unanswered", "--directive", "--delivery-id", next(key))
        # Window pairs: test_table sends a text a day back whose file a
        # catch-up delivers here; the text of the second file arrives last,
        # too young for --older 1. A file lists when its text is outside the
        # window, and hides behind its text when both are in it.
        self.owner(str(self.home / "tmp/slack/files/F14-day.png"), "--directive", "--delivery-id", "C16:1015.0")
        self.owner(str(self.home / "tmp/slack/files/F15-old.png"), "--directive", "--delivery-id", "C17:1015.0")
        at(0)
        request = self.owner("request handled without no reply", "--directive", "--delivery-id", next(key))
        self.owner("text after its file", "--directive", "--delivery-id", "C17:1000.0")
        self.env = plain
        state = self.home / "state"
        (state / "archive/2026").mkdir(parents=True)
        (state / "delegate/archive").mkdir(parents=True)
        (state / "handoff.md").write_text("## Progress log\n\n" + record("1", "Read " + logged, "apply it") +
                                          record("2", "Handled " + request, "done") +
                                          record("3", "Handled " + quiet, "done, No reply needed") +
                                          "".join(record(n, "Handled " + target, "no reply", stamp(-244))
                                                  for n, target in (("7", covered_caption), ("8", recorded_text),
                                                                    ("9", recorded_file),
                                                                    ("0", early_recorded_file))) +
                                          "- 23:00Z Handled %s, no reply\n" % current)
        (state / "archive/2026/handoff.md").write_text(record("4", "Ruling " + archived, "kept"))
        (state / "archive/2026/legacy.md").write_text("## Progress log\n\n- 22:59Z Started\n- 23:00Z Handled\n"
                                                      "  %s, no reply\n" % legacy)
        (state / "delegate/handoff.md").write_text(record("5", "Handled " + delegated, "no reply"))
        (state / "delegate/archive/handoff.md").write_text(record("6", "Handled " + delegate_archived, "no reply"))
        # Every owner row in inbox order: listed with the default handoff, listed with state/delegate/handoff.md.
        table = (("answered by ref", False, False),
                 ("yes", False, False),
                 ("no, sibling", False, False),
                 ("same second as the reply", True, True),
                 ("correction after the reply", True, True),
                 ("closed answer", False, False),
                 ("logged answer", False, True),
                 ("archived answer", False, True),
                 ("request handled with no reply", False, True),
                 ("same second as a handled request", True, True),
                 ("thread root", False, False),
                 ("thread follow-up", False, False),
                 ("thread correction", True, True),
                 ("asked about root", False, False),
                 ("follow-up an ask does not answer", True, True),
                 ("caption", True, True),
                 ("late caption", True, True),
                 ("thread text", True, True),
                 ("text before a captioned file", True, True),
                 ("file F2 not fetched: no download url", True, True),
                 (captioned_file, True, True),
                 ("caption a record handled", False, True),
                 (str(self.home / "tmp/slack/files/F5-covered.png"), False, False),
                 ("text a reply names", False, False),
                 (str(self.home / "tmp/slack/files/F9-replied.png"), False, False),
                 ("text whose file a reply names", False, False),
                 (str(self.home / "tmp/slack/files/F10-replied.png"), False, False),
                 ("text whose file a record handled", False, True),
                 (str(self.home / "tmp/slack/files/F11-recorded.png"), False, False),
                 ("text answered before its file", False, False),
                 ("text a record handled before its file", False, True),
                 (str(self.home / "tmp/slack/files/F12-early.png"), False, False),
                 (str(self.home / "tmp/slack/files/F13-early.png"), False, False),
                 (late_file, True, True),
                 (late_recorded_file, True, False),
                 ("text after a reply named its file", True, True),
                 ("text after a record named its file", True, True),
                 (other_thread, True, True),
                 ("legacy archived", False, True),
                 ("legacy in the handoff", True, True),
                 ("delegate logged", True, False),
                 ("delegate archived", True, False),
                 ("unanswered", True, True),
                 (str(self.home / "tmp/slack/files/F14-day.png"), True, True),
                 (str(self.home / "tmp/slack/files/F15-old.png"), False, False),
                 ("request handled without no reply", True, True),
                 ("text after its file", True, True))
        return [text for text, listed, _ in table if listed], [text for text, _, listed in table if listed]

    def threaded(self, text, root, delivery):
        """An owner directive the relay delivered as delivery in the Slack thread under root, both `channel:ts`."""
        stamp = root.split(":")[1]
        parent = self.root / "parent"
        parent.write_text(json.dumps({"ts": stamp, "author": "owner", "excerpt": "root"}))
        return self.owner(text, "--directive", "--delivery-id", delivery, "--thread-ts", stamp, "--parent", parent)

    def test_table(self):
        plain, self.env = self.env, self.clocked(-25 * 3600)
        self.owner("a day old", "--directive", "--delivery-id", "C5:1.0")
        self.owner("text a day old", "--directive", "--delivery-id", "C16:1000.0")
        self.env = plain
        expected, delegate = self.world()
        day_file, old_file = (str(self.home / "tmp/slack/files" / name) for name in ("F14-day.png", "F15-old.png"))
        past, future, earlier = (datetime.datetime.fromtimestamp(self.base + hours * 3600, datetime.timezone.utc)
                                 .strftime("%Y-%m-%dT%H:%M:%SZ") for hours in (-1, 1, -26))
        selected = str(self.home / "state/delegate/handoff.md")
        runs = (("listed", ["--older", "10", "--since", past], 11 * 60, expected),
                ("younger than --older", ["--older", "11"], 0, []),
                ("older than --older", ["--older", "1"], 0, expected[:-2] + [old_file]),
                ("older than --since", ["--since", future], 0, []),
                ("earlier --since than the default day", ["--since", earlier], 0,
                 ["a day old", "text a day old"] + [text for text in expected if text != day_file]),
                ("relative --handoff", ["--handoff", "state/delegate/handoff.md"], 0, delegate),
                ("absolute --handoff", ["--handoff", selected], 0, delegate))
        for name, args, offset, listed in runs:
            with self.subTest(run=name):
                self.assertEqual(self.check(*args, offset=offset), listed)
        before = self.check()
        self.assertEqual(before, expected)
        self.compact()
        self.assertEqual(self.check(), before)

    def compact(self):
        late = self.root / "late"
        late.mkdir()
        late.joinpath("date").write_text('#!/bin/sh\ncase "$*" in *+%s*) echo 9999999999;; *) exec '
                                         + shutil.which("date") + ' "$@";; esac\n')
        late.joinpath("date").chmod(0o755)
        env = dict(self.env, PATH=str(late) + ":" + self.env["PATH"])
        result = self.command([LANE_MAIL, "compact", "--item", "overseer"], self.home, env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("to-overseer=0", result.stdout)

    def test_unreadable_mailbox(self):
        mail = self.packages / "mailbox/scripts/lane-mail"
        mail.write_text("#!/bin/sh\necho 'lane-mail: mailbox-unsafe=/x' >&2\nexit 2\n")
        result = self.command([BASH, self.scripts / "owner-unanswered"], self.home)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.splitlines()[:2], ["owner-unanswered: mailbox-unreadable=to-lane",
                                                          "lane-mail: mailbox-unsafe=/x"])

    def test_unreadable_evidence(self):
        """Evidence that cannot be read refuses; evidence that is gone only lists more."""
        plain, self.env = self.env, self.clocked(-60)
        identity = self.owner("waiting", "--directive", "--delivery-id", "C1:1.0")
        self.env = plain
        state, archive = self.home / "state", self.home / "state/archive"
        now, old = (datetime.datetime.fromtimestamp(self.base + hours * 3600, datetime.timezone.utc)
                    .strftime("%Y-%m-%dT%H:%MZ") for hours in (0, -48))
        covering = record("1", "Handled " + identity, "no reply").encode()
        # The watch passes the oldest waiting row's exact second as --since; a
        # file whose last record is in that minute is read.
        edge = datetime.datetime.fromtimestamp((self.base - 3600) // 60 * 60, datetime.timezone.utc)
        mid_minute = (edge + datetime.timedelta(seconds=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
        # name, files under the home, arguments, exit, stderr lines, listed.
        cases = (("default handoff missing", {}, [], 0, [], ["waiting"]),
                 ("selected handoff missing", {}, ["--handoff", "state/none.md"], 1,
                  ["owner-unanswered: handoff-missing=%s" % (state / "none.md")], None),
                 ("unreadable handoff", {"state/handoff.md": b"\xff"}, [], 1,
                  ["owner-unanswered: handoff-unreadable=%s" % (state / "handoff.md")], None),
                 ("unreadable archive in the window", {"state/archive/a.md": b"\xff"}, [], 1,
                  ["owner-unanswered: handoff-unreadable=%s" % (archive / "a.md")], None),
                 ("unreadable INDEX", {"state/archive/INDEX.md": b"\xff"}, [], 1,
                  ["owner-unanswered: handoff-unreadable=%s" % (archive / "INDEX.md")], None),
                 ("archive the INDEX ends before the window", {
                     "state/archive/a.md": b"\xff",
                     "state/archive/INDEX.md": ("- a.md dates=%s..%s\n" % (old, old)).encode()}, [], 0, [], ["waiting"]),
                 ("archive with an unread START the INDEX ends before the window", {
                     "state/archive/a.md": b"\xff",
                     "state/archive/INDEX.md": ("- a.md dates=unread..%s\n" % old).encode()}, [], 0, [], ["waiting"]),
                 ("archive the INDEX ends in the minute of --since", {
                     "state/archive/a.md": b"\xff",
                     "state/archive/INDEX.md": ("- a.md dates=%s..%s\n" % (old, edge.strftime("%Y-%m-%dT%H:%MZ"))).encode()},
                  ["--since", mid_minute], 1, ["owner-unanswered: handoff-unreadable=%s" % (archive / "a.md")], None),
                 ("archive the writer could not date", {
                     "state/archive/a.md": b"\xff",
                     "state/archive/INDEX.md": b"- a.md dates=unread..unread\n"}, [], 1,
                  ["owner-unanswered: handoff-unreadable=%s" % (archive / "a.md")], None),
                 ("archive the INDEX places in the window", {
                     "state/archive/a.md": covering,
                     "state/archive/INDEX.md": ("# Archive\n\n- a.md kind=x dates=%s..%s\n" % (old, now)).encode()},
                  [], 0, [], []),
                 ("pruned in the window", {"state/archive/INDEX.md": ("- gone.md dates=%s..%s\n" % (old, now)).encode()},
                  [], 0, ["owner-unanswered: archive-pruned=%s" % (archive / "gone.md")], ["waiting"]),
                 ("pruned with an unread end", {"state/archive/INDEX.md": b"- gone.md dates=soon\n"},
                  [], 0, ["owner-unanswered: archive-pruned=%s" % (archive / "gone.md")], ["waiting"]),
                 ("pruned before the window", {"state/archive/INDEX.md": ("- gone.md dates=%s..%s\n" % (old, old)).encode()},
                  [], 0, [], ["waiting"]))
        for name, files, args, code, stderr, listed in cases:
            with self.subTest(case=name):
                shutil.rmtree(state, ignore_errors=True)
                for path, data in files.items():
                    (self.home / path).parent.mkdir(parents=True, exist_ok=True)
                    (self.home / path).write_bytes(data)
                result = self.command([BASH, self.scripts / "owner-unanswered", *args], self.home, self.clocked(0))
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(result.stderr.splitlines()[:len(stderr)] if code else result.stderr.splitlines(),
                                 stderr)
                if listed is not None:
                    self.assertEqual([json.loads(line)["text"] for line in result.stdout.splitlines()], listed)

    def test_instrument_control(self):
        # Each planted defect, in a disposable copy, must fail the table:
        # a reader of the box files themselves, in place of lane-mail events,
        # including its compacted rows; and a thread reply that covers its
        # thread's rows whatever their time, which covers the correction
        # after the reply; and a reply that covers only the member it names,
        # which lists the text whose file a reply names.
        reader = ("        return watch.mailbox_events(bash, home, name)[1]\n",
                  "        box = home / 'tmp/lane-mail/overseer' / (name + '.jsonl')\n"
                  "        return [json.loads(row) for row in box.read_text().splitlines()]\n")
        order = ("key == reply_key and after(at))", "key == reply_key)")
        pair_reply = ("reaches(ref, at)", 'ref == row["id"]')
        for old, new in (reader, order, pair_reply):
            with self.subTest(planted=new), tempfile.TemporaryDirectory() as folder:
                copy = Path(folder) / "jarvis/scripts"
                shutil.copytree(SCRIPTS, copy)
                Path(folder, "mailbox").symlink_to(REPO / "skills/mailbox", target_is_directory=True)
                path = copy / "lib/owner_unanswered.py"
                source = path.read_text()
                self.assertEqual(source.count(old), 1)
                path.write_text(source.replace(old, new))
                case = OwnerUnanswered(methodName="test_table")
                case.scripts = copy
                case.setUp()
                try:
                    with self.assertRaises(AssertionError):
                        case.test_table()
                finally:
                    case.doCleanups()


if __name__ == "__main__":
    unittest.main()
