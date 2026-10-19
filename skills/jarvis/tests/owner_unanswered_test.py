"""owner-unanswered judges real lane-mail rows against replies, closes and progress records."""
import datetime
import json
from pathlib import Path
import shutil
import tempfile
import time
import unittest

from mail_world import BASH, LANE_MAIL, REPO, SCRIPTS, MailWorld, make_project


def record(identity, operation, decision):
    return ("- Id and time: P-20261018T23000%sZ %s\n  - Operation: %s\n  - Observed result and source: read\n"
            "  - Decision: %s\n  - State change: none\n") % (identity, "2026-10-18T23:00:00Z", operation, decision)


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

        at(-900)
        asks = [self.mail(self.home, "ask", "question %d" % n, "--to", "owner", "--options", "yes,no",
                          "--recommend", "yes") for n in range(4)]
        at(-800)
        replied = self.owner("answered by ref", "--directive", "--delivery-id", next(key))
        self.mail(self.home, "notice", "reply", "--to", "owner", "--ref", replied)
        at(-700)
        self.owner("yes", "--re", asks[0], "--delivery-id", next(key))
        self.owner("no, sibling", "--re", asks[0], "--delivery-id", next(key))
        self.mail(self.home, "notice", "ruling reported", "--to", "owner", "--ref", asks[0])
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
        at(-200)
        self.owner("no delivery id", "--directive")
        self.owner("watch-loop batch", "--directive", "--delivery-id", "jarvis-0123abcd")
        at(-100)
        self.owner("unanswered", "--directive", "--delivery-id", next(key))
        at(0)
        request = self.owner("request handled without no reply", "--directive", "--delivery-id", next(key))
        self.env = plain
        state = self.home / "state"
        (state / "archive/2026").mkdir(parents=True)
        (state / "handoff.md").write_text("## Progress log\n\n" + record("1", "Read " + logged, "apply it") +
                                          record("2", "Handled " + request, "done") +
                                          record("3", "Handled " + quiet, "done, No reply needed"))
        (state / "archive/2026/handoff.md").write_text(record("4", "Ruling " + archived, "kept"))
        return ["correction after the reply", "same second as a handled request", "unanswered",
                "request handled without no reply"]

    def test_table(self):
        expected = self.world()
        past, future = (datetime.datetime.fromtimestamp(self.base + hours * 3600, datetime.timezone.utc)
                        .strftime("%Y-%m-%dT%H:%M:%SZ") for hours in (-1, 1))
        runs = (("listed", ["--older", "10", "--since", past], 11 * 60, expected),
                ("younger than --older", ["--older", "11"], 0, []),
                ("older than --older", ["--older", "1"], 0, expected[:-1]),
                ("older than --since", ["--since", future], 0, []))
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

    def test_instrument_control(self):
        # A reader of the box files themselves, in place of lane-mail events,
        # must fail the table, including its compacted rows.
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "jarvis/scripts"
            shutil.copytree(SCRIPTS, copy)
            Path(folder, "mailbox").symlink_to(REPO / "skills/mailbox", target_is_directory=True)
            path = copy / "lib/owner_unanswered.py"
            source = path.read_text()
            old = "        return watch.mailbox_events(bash, home, name)[1]\n"
            self.assertEqual(source.count(old), 1)
            path.write_text(source.replace(old, "        box = home / 'tmp/lane-mail/overseer' / (name + '.jsonl')\n"
                                           "        return [json.loads(row) for row in box.read_text().splitlines()]\n"))
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
