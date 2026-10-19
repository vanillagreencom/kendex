"""progress-log writes one clock-stamped record into the home handoff, or refuses and writes nothing."""
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

from mail_world import SCRIPTS, MailWorld, make_project

sys.path.insert(0, str(SCRIPTS / "lib"))
from progress import records  # noqa: E402

STAMP = "2026-10-18T23:05:01Z"
HANDOFF = ("# Handoff\n\n## State\n\nwork: KEN-1\n\n## Sub-agents\n\nnone\n\n## Instructions in force\n\nnone\n\n"
           "## Progress log\n\n- Id and time: P-20261018T220000Z 2026-10-18T22:00:00Z\n  - Operation: earlier\n"
           "  - Observed result and source: seen\n  - Decision: kept\n  - State change: none\n\n## Notes\n\nlast\n")
FIELDS = {"--operation": "Reply to 1791680510", "--result": "sent, receipt id=1",
          "--decision": "answer now", "--state-change": "none"}


class ProgressLog(MailWorld):
    scripts = SCRIPTS

    def setUp(self):
        super().setUp()
        self.home = make_project(self.root / "home", overseer=False)
        self.handoff = self.home / "state/handoff.md"
        self.handoff.parent.mkdir()
        self.executable("date", "#!/bin/sh\necho " + STAMP + "\n")

    def log(self, fields=FIELDS, cwd=None):
        args = [arg for pair in fields.items() for arg in pair]
        return self.command([sys.executable, "-B", self.scripts / "progress-log", *args], cwd or self.home)

    def test_records(self):
        # Each row: handoff text, fields, then the whole expected handoff or
        # the refusal. owner-unanswered and the successor read this form.
        record = ("- Id and time: P-20261018T230501Z " + STAMP + "\n  - Operation: Reply to 1791680510\n"
                  "  - Observed result and source: sent, receipt id=1\n  - Decision: answer now\n"
                  "  - State change: none\n")
        unterminated = HANDOFF.replace("\n\n## Notes\n\nlast\n", "")
        rows = (
            ("appends", HANDOFF, FIELDS,
             HANDOFF.replace("none\n\n## Notes", "none\n" + record + "\n## Notes")),
            ("unterminated", unterminated, FIELDS, unterminated + "\n" + record),
            ("empty section", "## Progress log", FIELDS, "## Progress log\n\n" + record),
            ("empty operation", HANDOFF, dict(FIELDS, **{"--operation": " "}), "field-empty=operation"),
            ("empty decision", HANDOFF, dict(FIELDS, **{"--decision": ""}), "field-empty=decision"),
            ("typed time", HANDOFF, dict(FIELDS, **{"--result": "23:04Z sent"}), "time-typed=observed-result-and-source"),
            ("typed stamp", HANDOFF, dict(FIELDS, **{"--operation": "2026-10-18T23:04 reply"}), "time-typed=operation"),
            ("no section", HANDOFF.replace("## Progress log", "## Log"), FIELDS, "section-missing=Progress log"),
        )
        for name, text, fields, expected in rows:
            with self.subTest(row=name):
                self.handoff.write_text(text)
                result = self.log(fields)
                if not expected.startswith(("#", "- ")):
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertTrue(result.stderr.startswith("progress-log: " + expected + " fix="), result.stderr)
                    self.assertTrue(result.stderr.split(" fix=", 1)[1].strip().endswith("long-session.md#progress-records"))
                    self.assertEqual(self.handoff.read_text(), text)
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.handoff.read_text(), expected)
                self.assertEqual(records(expected)[-1]["at"], STAMP)
        # A second record in the same second keeps a distinct id.
        self.handoff.write_text(HANDOFF)
        self.assertEqual(self.log().returncode, 0)
        self.assertEqual(self.log().returncode, 0)
        self.assertEqual([row["id"] for row in records(self.handoff.read_text())][1:],
                         ["P-20261018T230501Z", "P-20261018T230501Z-2"])

    def test_unwritable_and_subdirectory(self):
        self.handoff.write_text(HANDOFF)
        self.handoff.chmod(0o444)
        try:
            result = self.log()
            self.assertEqual(result.returncode, 2)
            self.assertTrue(result.stderr.startswith("progress-log: handoff-unwritable="), result.stderr)
            self.assertEqual(self.handoff.read_text(), HANDOFF)
        finally:
            self.handoff.chmod(0o644)
        inside = self.home / "notes/deeper"
        inside.mkdir(parents=True)
        result = self.log(cwd=inside)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(records(self.handoff.read_text())), 2)
        self.assertFalse((inside / "state").exists())

    def test_instrument_control(self):
        # A typed-in time, not the clock read, must fail the record row.
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "jarvis"
            shutil.copytree(SCRIPTS.parent / "scripts", copy / "scripts")
            shutil.copytree(SCRIPTS.parent / "references", copy / "references")
            script = copy / "scripts/progress-log"
            source = script.read_text()
            old = "    stamp = clock()\n"
            self.assertEqual(source.count(old), 1)
            script.write_text(source.replace(old, '    stamp = "2026-10-18T23:00:00Z"\n'))
            case = ProgressLog(methodName="test_records")
            case.scripts = copy / "scripts"
            case.setUp()
            try:
                with self.assertRaises(AssertionError):
                    case.test_records()
            finally:
                case.doCleanups()


if __name__ == "__main__":
    os.umask(0o022)
    unittest.main()
