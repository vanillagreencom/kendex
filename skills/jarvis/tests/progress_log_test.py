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

    def log(self, fields=FIELDS, cwd=None, handoff=None):
        args = [arg for pair in fields.items() for arg in pair]
        if handoff is not None:
            args += ["--handoff", str(handoff)]
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
            ("ambiguous section", HANDOFF + "\n## Progress log\n", FIELDS, "section-ambiguous=Progress log"),
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
        result = self.log()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stderr.split("=", 1)[0], "progress-log: handoff-missing")
        self.assertFalse(self.handoff.exists())
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

    def test_selected_handoff(self):
        self.handoff.write_text(HANDOFF)
        selected = self.home / "state/delegate/handoff.md"
        selected.parent.mkdir()
        inside = self.home / "notes/deeper"
        inside.mkdir(parents=True)
        for target in ("state/delegate/handoff.md", selected):
            with self.subTest(target=target):
                selected.write_text(HANDOFF)
                for suffix in ("", "-2"):
                    result = self.log(cwd=inside, handoff=target)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    row = records(selected.read_text())[-1]
                    self.assertEqual(row["id"], "P-20261018T230501Z" + suffix)
                    self.assertEqual(row["at"], STAMP)
                    self.assertEqual(row["Operation"], FIELDS["--operation"])
                    self.assertEqual(row["Observed result and source"], FIELDS["--result"])
                    self.assertEqual(row["Decision"], FIELDS["--decision"])
                    self.assertEqual(row["State change"], FIELDS["--state-change"])
                before, after = HANDOFF.split("## Progress log", 1)[0], "## Notes\n\nlast\n"
                self.assertTrue(selected.read_text().startswith(before))
                self.assertTrue(selected.read_text().endswith(after))
                self.assertEqual(self.handoff.read_text(), HANDOFF)
        for text, mode, category in (
                (None, 0o644, "handoff-missing"),
                (HANDOFF, 0o444, "handoff-unwritable"),
                ("## State\nunchanged\n", 0o644, "section-missing"),
                (HANDOFF + "\n## Progress log\n", 0o644, "section-ambiguous")):
            with self.subTest(category=category):
                selected.unlink(missing_ok=True)
                if text is not None:
                    selected.write_text(text)
                    selected.chmod(mode)
                try:
                    result = self.log(cwd=inside, handoff="state/delegate/handoff.md")
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stderr.split("=", 1)[0], "progress-log: " + category)
                    if text is None:
                        self.assertFalse(selected.exists())
                    else:
                        self.assertEqual(selected.read_text(), text)
                    self.assertEqual(self.handoff.read_text(), HANDOFF)
                finally:
                    if selected.exists():
                        selected.chmod(0o644)
        # The selected-target assertions must reject a writer that ignores the option.
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "jarvis"
            shutil.copytree(SCRIPTS.parent / "scripts", copy / "scripts")
            script = copy / "scripts/progress-log"
            source = script.read_text()
            old = " / args.handoff, values)"
            self.assertEqual(source.count(old), 1)
            script.write_text(source.replace(old, ' / "state/handoff.md", values)'))
            scripts, self.scripts = self.scripts, copy / "scripts"
            try:
                with self.assertRaises(AssertionError):
                    selected.write_text(HANDOFF)
                    result = self.log(handoff=selected)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(records(selected.read_text())[-1]["at"], STAMP)
            finally:
                self.scripts = scripts

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
