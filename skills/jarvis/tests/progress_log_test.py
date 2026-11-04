"""progress-log writes one clock-stamped record into the home handoff, or refuses and writes nothing.

--check-state lists the State entries to correct from live tracker reads.
"""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

from mail_world import SCRIPTS, MailWorld, make_project

sys.path.insert(0, str(SCRIPTS / "lib"))
from progress import index_ends, records  # noqa: E402

STAMP = "2026-10-18T23:05:01Z"
HANDOFF = ("# Handoff\n\n## State\n\nwork: KEN-1\n\n## Sub-agents\n\nnone\n\n## Instructions in force\n\nnone\n\n"
           "## Progress log\n\n- Id and time: P-20261018T220000Z 2026-10-18T22:00:00Z\n  - Operation: earlier\n"
           "  - Observed result and source: seen\n  - Decision: kept\n  - State change: none\n\n## Notes\n\nlast\n")
FIELDS = {"--operation": "Reply to 1791680510", "--result": "sent, receipt id=1",
          "--decision": "answer now", "--state-change": "none"}
# The tracker boundary: skills/linear `issues bulk-get --stdin --format=compact`.
# A row takes lib/formatters.sh format_issues_list_compact's shape; a ref
# Linear has no issue for refuses the whole read with lib/common.sh
# linear_issue_refs_read's `missing` line, after the lookup's own error line.
# A ref numbered 0 or 0N fails Linear's argument validation for the whole read.
LINEAR = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
home = Path(os.environ["HOME"])
world = json.loads((home / "linear-world.json").read_text())
refs = sys.stdin.read().split()
with (home / "linear-calls").open("a") as calls:
    calls.write(json.dumps([sys.argv[1:], refs]) + "\\n")
if world.get("fail"):
    print(json.dumps({"error": "HTTP 503"}), file=sys.stderr)
    sys.exit(1)
if any(ref.rsplit("-", 1)[-1].startswith("0") for ref in refs):
    print(json.dumps({"error": "Argument Validation Error"}), file=sys.stderr)
    sys.exit(1)
missing = [ref for ref in refs if ref in world.get("missing", ())]
if missing:
    print(json.dumps({"error": "Entity not found: Issue"}), file=sys.stderr)
    print(json.dumps({"error": "Issues not read: " + ", ".join(missing), "missing": missing}), file=sys.stderr)
    sys.exit(1)
rows = [world["issues"][ref] for ref in refs if ref in world["issues"]]
print(json.dumps([{"id": row[0], "title": "", "state": row[1], "state_type": row[2]} for row in rows]))
"""
DONE, CANCELED, OPEN = ("Done", "completed"), ("Canceled", "canceled"), ("In Progress", "started")
BULK_GET = ["issues", "bulk-get", "--stdin", "--format=compact"]


def state_handoff(state):
    """A handoff whose State section holds state from line 5."""
    return ("# Handoff\n\n## State\n\n" + state + "\n## Sub-agents\n\nnone\n\n## Instructions in force\n\nnone\n\n"
            "## Progress log\n\n")


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
            old = ", args.handoff), values)"
            self.assertEqual(source.count(old), 1)
            script.write_text(source.replace(old, ", DEFAULT_HANDOFF), values)"))
            scripts, self.scripts = self.scripts, copy / "scripts"
            try:
                with self.assertRaises(AssertionError):
                    selected.write_text(HANDOFF)
                    result = self.log(handoff=selected)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(records(selected.read_text())[-1]["at"], STAMP)
            finally:
                self.scripts = scripts

    def test_archive_index(self):
        # Each row: archived files under state/, the INDEX.md text before,
        # --handoff, --archived, then the INDEX.md text after or the
        # refusal. owner-unanswered reads this line to skip an archive.
        dated = ("## Progress log\n\n- Id and time: P-20261018T230559Z 2026-10-18T23:05:59Z\n  - Operation: later\n"
                 "- Id and time: P-20261017T220000Z 2026-10-17T22:00:00Z\n  - Operation: earlier\n")
        line = "- 2026/h.md dates=2026-10-17T22:00Z..2026-10-18T23:05Z\n"
        archive = self.home / "state/archive"
        rows = (
            ("dated", {"archive/2026/h.md": dated}, None, None, "state/archive/2026/h.md", line),
            ("absolute and appended", {"archive/2026/h.md": dated}, "- old.md dates=x..y", None,
             archive / "2026/h.md", "- old.md dates=x..y\n" + line),
            ("legacy entry", {"archive/l.md": dated + "- 22:00Z Handled 1791680510\n"}, None, None,
             "state/archive/l.md", "- l.md dates=unread..unread\n"),
            ("no record", {"archive/e.md": "# Handoff\n"}, None, None, "state/archive/e.md",
             "- e.md dates=unread..unread\n"),
            ("selected handoff", {"delegate/archive/h.md": dated}, None, "state/delegate/handoff.md",
             "state/delegate/archive/h.md", "- h.md dates=2026-10-17T22:00Z..2026-10-18T23:05Z\n"),
            ("outside the archive", {"handoff.md": dated}, None, None, "state/handoff.md", "archive-outside"),
            ("another handoff's archive", {"archive/h.md": dated}, None, "state/delegate/handoff.md",
             "state/archive/h.md", "archive-outside"),
            ("missing", {}, None, None, "state/archive/h.md", "archive-missing"),
            ("unreadable", {"archive/h.md": b"\xff"}, None, None, "state/archive/h.md", "archive-unreadable"),
        )
        for name, files, before, handoff, archived, expected in rows:
            with self.subTest(row=name):
                shutil.rmtree(self.home / "state", ignore_errors=True)
                for path, data in files.items():
                    target = self.home / "state" / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data if isinstance(data, bytes) else data.encode())
                index = self.home / ("state/delegate/archive" if handoff else "state/archive") / "INDEX.md"
                if before is not None:
                    index.write_text(before)
                args = ["--archived", str(archived)] + (["--handoff", handoff] if handoff else [])
                result = self.command([sys.executable, "-B", self.scripts / "progress-log", *args], self.home)
                if not expected.startswith("- "):
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stderr.split("=", 1)[0], "progress-log: " + expected)
                    self.assertFalse(index.exists())
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([row.split(" entries=", 1)[0] for row in index.read_text().splitlines()],
                                 expected.splitlines())
        # An INDEX.md that cannot take the line refuses.
        shutil.rmtree(self.home / "state")
        (archive / "INDEX.md").mkdir(parents=True)
        archive.joinpath("h.md").write_text(dated)
        result = self.command([sys.executable, "-B", self.scripts / "progress-log", "--archived",
                               "state/archive/h.md"], self.home)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stderr.split("=", 1)[0], "progress-log: index-unwritable")

    def test_archive_facts_and_import(self):
        # Retained facts are expected independently of the parser; the index
        # consumer can locate the archive and source entry before reading it.
        dated = ("## Progress log\n\n"
                 "- Id and time: P-20261017T220000Z 2026-10-17T22:00:00Z\n"
                 "  - Operation: Rule on KEN-12, owner C0123ABC:1793515695.587049 session=42\n"
                 "  - Observed result and source: checked KEN-12 session=ignored\n"
                 "  - Decision: session=42 session=group-a lesson retained\n"
                 "  - State change: none\n"
                 "- Id and time: P-20261018T230559Z 2026-10-18T23:05:59Z\n"
                 "  - Operation: Handle 1793515834-3208082-27491; 123 01234567-89ab-cdef-0123-456789abcdef\n"
                 "  - Observed result and source: unread\n"
                 "  - Decision: no reply\n"
                 "  - State change: none\n")
        facts = [{"id": "P-20261017T220000Z", "line": 3, "at": "2026-10-17T22:00:00Z",
                  "sessions": ["42", "group-a"], "trackers": ["KEN-12"], "messages": ["C0123ABC:1793515695.587049"]},
                 {"id": "P-20261018T230559Z", "line": 8, "at": "2026-10-18T23:05:59Z",
                  "sessions": "unread", "trackers": "unread", "messages": ["1793515834-3208082-27491"]}]
        legacy = "\n- 11:00Z Ruled on KEN-18 session=prior-7\n  owner 1793515834-3208082-27491\n"
        rows = (("dated", dated, facts, "2026-10-18T23:05Z"),
                ("legacy", dated + legacy, facts + [
                    {"id": "unread", "line": 14, "at": "unread", "sessions": ["prior-7"], "trackers": ["KEN-18"],
                     "messages": ["1793515834-3208082-27491"], "time": "11:00Z"}], None),
                ("unavailable facts", "# Retained archive\n", [], None))
        archive = self.home / "state/archive"
        archive.mkdir()
        source, index = archive / "a.md", archive / "INDEX.md"
        untouched = "- lost.md dates=unread..unread source=receipt-7\n"
        for name, text, expected, end in rows:
            with self.subTest(row=name):
                source.write_bytes(text.encode())
                index.write_text("# Archives\n" + untouched)
                command = [sys.executable, "-B", self.scripts / "progress-log", "--archived", "state/archive/a.md"]
                result = self.command(command, self.home)
                self.assertEqual(result.returncode, 0, result.stderr)
                retained = index.read_text()
                line = retained.splitlines()[-1]
                self.assertEqual(line.split()[1], "a.md")
                fields = dict(field.split("=", 1) for field in line.split()[2:])
                self.assertEqual(json.loads(fields["entries"]), expected)
                self.assertEqual(index_ends(retained), {"lost.md": None, "a.md": end})
                # Import the pre-enrichment row while preserving its provenance.
                original = ("# Archives\n" + line.split(" entries=", 1)[0] + " origin=retained source=entry-42\n"
                            "- a.md dates=unread..unread origin=older\n" + untouched)
                index.write_text(original)
                previous = None
                for _ in range(2):
                    result = self.command(command, self.home)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    imported = index.read_text()
                    self.assertEqual(result.stdout.split("indexed ", 1)[1], imported.splitlines()[1] + "\n")
                    self.assertEqual(imported.splitlines()[0], "# Archives")
                    imported_fields = dict(field.split("=", 1) for field in imported.splitlines()[1].split()[2:])
                    self.assertEqual(json.loads(imported_fields.pop("entries")), expected)
                    self.assertEqual(imported_fields, dict(dates=fields["dates"], origin="retained", source="entry-42"))
                    self.assertEqual(imported.splitlines()[2].split(" entries=", 1)[0],
                                     "- a.md dates=unread..unread origin=older")
                    self.assertEqual(index_ends(imported), {"a.md": None, "lost.md": None})
                    self.assertTrue(imported.endswith(untouched))
                    self.assertEqual(source.read_bytes(), text.encode())
                    if _:
                        self.assertEqual(imported, previous)
                    previous = imported
                # Missing or unreadable evidence keeps the retained index whole.
                for data, key in ((None, "archive-missing"), (b"\xff", "archive-unreadable")):
                    source.unlink(missing_ok=True)
                    if data is not None:
                        source.write_bytes(data)
                    result = self.command(command, self.home)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stderr.split("=", 1)[0], "progress-log: " + key)
                    self.assertEqual(index.read_text(), previous)

    def test_archive_facts_control(self):
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "scripts"
            shutil.copytree(SCRIPTS, copy)
            library = copy / "lib/progress.py"
            source = library.read_text()
            old = 'json.dumps(entries, separators=(",", ":"))'
            self.assertEqual(source.count(old), 1)
            library.write_text(source.replace(old, 'json.dumps([], separators=(",", ":"))'))
            case = ProgressLog(methodName="test_archive_facts_and_import")
            case.scripts = copy
            case.setUp()
            try:
                with self.assertRaises(AssertionError):
                    case.test_archive_facts_and_import()
            finally:
                case.doCleanups()

    def check(self, world, handoff=None):
        """Run --check-state from the installed copy of self.scripts beside a linear stub reading world."""
        packages = self.root / "packages"
        shutil.rmtree(packages, ignore_errors=True)
        shutil.copytree(self.scripts, packages / "jarvis/scripts")
        (self.root / "linear-calls").unlink(missing_ok=True)
        if world is not None:
            stub = packages / "linear/scripts/linear.sh"
            stub.parent.mkdir(parents=True)
            stub.write_text(LINEAR)
            stub.chmod(0o755)
            (self.root / "linear-world.json").write_text(json.dumps(
                {"issues": {ref: [row[0] if len(row) == 3 else ref, *row[-2:]] for ref, row in world.get("issues", {}).items()},
                 "missing": world.get("missing", []), "fail": world.get("fail", False)}))
        args = ["--check-state"] + (["--handoff", str(handoff)] if handoff else [])
        result = self.command([sys.executable, "-B", packages / "jarvis/scripts/progress-log", *args], self.home)
        calls = self.root / "linear-calls"
        return result, [json.loads(row) for row in calls.read_text().splitlines()] if calls.exists() else []

    def test_check_state(self):
        # Each row: State text, the tracker world (None: no linear package),
        # then the listed lines, the summary counts, the exit, the stderr key
        # and each bulk read's refs. The writer corrects what is listed.
        issues = {"KEN-1": DONE, "KEN-3": OPEN, "KEN-4": CANCELED}
        rows = (
            ("closed and id-less listed", "- KEN-1 shipped\n- Call the vendor\n- KEN-3 in review\n", {"issues": issues},
             ["closed line=5 ids=KEN-1:Done", "unbound line=6"], (3, 1, 1, 0, 0), 0, None, [["KEN-1", "KEN-3"]]),
            ("both removed", "- KEN-3 in review\n", {"issues": issues}, [], (1, 0, 0, 0, 0), 0, None, [["KEN-3"]]),
            ("canceled", "- KEN-4 dropped\n", {"issues": issues}, ["closed line=5 ids=KEN-4:Canceled"],
             (1, 1, 0, 0, 0), 0, None, [["KEN-4"]]),
            ("mixed kept", "- KEN-1 and KEN-3\n", {"issues": issues}, [], (1, 0, 0, 0, 0), 0, None, [["KEN-1", "KEN-3"]]),
            ("open child keeps its parent, State ends at its heading", "- KEN-1 parent\n  - KEN-3 child\n\n## Notes\n- KEN-1 again\n",
             {"issues": issues}, [], (1, 0, 0, 0, 0), 0, None, [["KEN-1", "KEN-3"]]),
            ("mailbox and Slack ids bind", "- Reply to 1793515834-3208082-27491\n- Thread C0123ABC:1793515695.587049\n",
             {"issues": issues}, [], (2, 0, 0, 0, 0), 0, None, []),
            ("a date binds nothing", "- Checked 2026-11-02 at P-20261102T080000Z\n", {"issues": issues},
             ["unbound line=5"], (1, 0, 1, 0, 0), 0, None, []),
            ("not an issue", "- UTF-8 names\n- KEN-1 shipped\n", {"issues": issues, "missing": ["UTF-8"]},
             ["not-issue line=5 ids=UTF-8", "unbound line=5", "closed line=6 ids=KEN-1:Done"], (2, 1, 1, 0, 1), 0, None,
             [["UTF-8", "KEN-1"], ["KEN-1"]]),
            ("zero-numbered tokens bind nothing", "- KEN-4849 read HYPRLAND-0.57-FALLBACK-FACTS-2026-11-02.md and PP-06\n",
             {"issues": dict(issues, **{"KEN-4849": DONE})}, ["closed line=5 ids=KEN-4849:Done"], (1, 1, 0, 0, 0), 0,
             None, [["KEN-4849"]]),
            ("tracker failure", "- KEN-1 shipped\n- Call the vendor\n", {"issues": issues, "fail": True},
             ["unread line=5 ids=KEN-1", "unbound line=6"], (2, 0, 1, 1, 0), 1, "tracker-unavailable=exit-1",
             [["KEN-1"]]),
            ("no linear package", "- KEN-1 shipped\n- Call the vendor\n", None,
             ["unread line=5 ids=KEN-1", "unbound line=6"], (2, 0, 1, 1, 0), 1, "tracker-unavailable=linear-missing", []),
            ("moved issue", "- KEN-7 shipped\n", {"issues": {"KEN-7": ("KEN-9",) + DONE}},
             ["unread line=5 ids=KEN-7"], (1, 0, 0, 1, 0), 1, "tracker-unmatched=KEN-7", [["KEN-7"]]),
            ("no section", "# Handoff\n\n## Progress log\n", {"issues": issues}, "section-missing=State", None, 2, None, []),
            ("ambiguous section", state_handoff("- KEN-1\n") + "## State\n", {"issues": issues},
             "section-ambiguous=State", None, 2, None, []),
            ("no handoff", None, {"issues": issues}, "handoff-missing", None, 2, None, []),
        )
        for name, state, world, listed, counts, code, key, reads in rows:
            with self.subTest(row=name):
                self.handoff.unlink(missing_ok=True)
                if state is not None:
                    self.handoff.write_text(state if state.startswith("#") else state_handoff(state))
                before = self.handoff.read_bytes() if state is not None else None
                result, calls = self.check(world)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(calls, [[BULK_GET, refs] for refs in reads])
                self.assertEqual(self.handoff.read_bytes() if state is not None else None, before)
                if counts is None:
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(result.stderr.split(" fix=", 1)[0].split("=", 1)[0],
                                     "progress-log: " + listed.split("=", 1)[0])
                    self.assertTrue(result.stderr.startswith("progress-log: " + listed), result.stderr)
                    self.assertTrue(result.stderr.strip().endswith("long-session.md#handoff"), result.stderr)
                    continue
                summary = "checked entries=%d closed=%d unbound=%d unread=%d not-issue=%d" % counts
                self.assertEqual(result.stdout.splitlines(), ["progress-log: " + line for line in listed + [summary]])
                if key is None:
                    self.assertEqual(result.stderr, "")
                else:
                    self.assertTrue(result.stderr.startswith("progress-log: " + key + (" " if "unavailable" in key else "\n")),
                                    result.stderr)

    def test_check_selected_handoff(self):
        self.handoff.write_text(state_handoff("- Call the vendor\n"))
        selected = self.home / "state/delegate/handoff.md"
        selected.parent.mkdir()
        selected.write_text(state_handoff("- KEN-3 in review\n- KEN-1 shipped\n"))
        for target in ("state/delegate/handoff.md", selected):
            with self.subTest(target=target):
                result, calls = self.check({"issues": {"KEN-1": DONE, "KEN-3": OPEN}}, handoff=target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [
                    "progress-log: closed line=6 ids=KEN-1:Done",
                    "progress-log: checked entries=2 closed=1 unbound=0 unread=0 not-issue=0"])
                self.assertEqual(calls, [[BULK_GET, ["KEN-3", "KEN-1"]]])

    def test_check_state_control(self):
        # A closed rule that drops Canceled must fail the canceled row; the
        # earlier tracker pattern must fail the zero-numbered row.
        for old, new in (('CLOSED_TYPES = ("completed", "canceled")', 'CLOSED_TYPES = ("completed",)'),
                         ('_TRACKER_ID = r"[A-Z][A-Z0-9]*-[1-9]\\d*"', '_TRACKER_ID = r"[A-Z][A-Z0-9]*-\\d+"')):
            with self.subTest(mutation=new), tempfile.TemporaryDirectory() as folder:
                copy = Path(folder) / "jarvis/scripts"
                shutil.copytree(SCRIPTS, copy)
                library = copy / "lib/progress.py"
                source = library.read_text()
                self.assertEqual(source.count(old), 1)
                library.write_text(source.replace(old, new))
                case = ProgressLog(methodName="test_check_state")
                case.scripts = copy
                case.setUp()
                try:
                    with self.assertRaises(AssertionError):
                        case.test_check_state()
                finally:
                    case.doCleanups()

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
