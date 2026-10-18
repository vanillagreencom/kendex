"""The section reader returns complete text and refuses non-unique titles."""
import json
import os
from pathlib import Path
import shutil
import sys

from desktop_world import World, run_case


SECTION = "### Rule\nKeep this ruling.\n\n#### Detail\nKeep its child.\n\n"
DOCUMENT = "# Rules\n\n## Parent\n" + SECTION + "### Peer\nOther rule.\n## Next\nLast."


class Section(World):
    def test_selected_section(self):
        cases = [
            ("nested", DOCUMENT, "Rule", SECTION),
            ("moved", "Intro.\n\n" + DOCUMENT, "Rule", SECTION),
            ("parent", DOCUMENT, "Parent", "## Parent\n" + SECTION + "### Peer\nOther rule.\n"),
            ("higher", "## Parent\n" + SECTION + "# End\n", "Rule", SECTION),
            ("eof", DOCUMENT, "Next", "## Next\nLast."),
            ("fenced", "## Rule\n```md\n# Example\n```\n~~~\n## Rule\n~~~\n## End\n", "Rule",
             "## Rule\n```md\n# Example\n```\n~~~\n## Rule\n~~~\n"),
            ("closing marks", "  ### Rule ###\nRuling.\n## End\n", "Rule", "  ### Rule ###\nRuling.\n"),
            ("crlf", DOCUMENT.replace("\n", "\r\n"), "Rule", SECTION.replace("\n", "\r\n")),
        ]
        path = self.root / "rules.md"
        for name, document, title, expected in cases:
            with self.subTest(name=name):
                path.write_bytes(document.encode())
                result = self.run_tool("jarvis-section", path, title)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected.encode())

    def test_heading_refusal(self):
        path = self.root / "rules.md"
        for document, title, error, candidates in [
            (DOCUMENT, "Absent", "unknown-heading", ["Rules", "Parent", "Rule", "Detail", "Peer", "Next"]),
            ("# Parent\n### Rule\nA\n## Other\n### Rule\nB\n", "Rule", "ambiguous-heading", ["Rule", "Rule"]),
        ]:
            with self.subTest(error=error):
                path.write_text(document)
                result = self.run_tool("jarvis-section", path, title)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, b"")
                diagnostic = json.loads(result.stderr.decode().split(": ", 1)[1])
                self.assertEqual(diagnostic["error"], error)
                self.assertEqual([row["heading"] for row in diagnostic["candidates"]], candidates)
                self.assertEqual(len({row["line"] for row in diagnostic["candidates"]}), len(candidates))

    def test_line_range_control(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        # The prior line-range read loses the ruling's child and ignores ambiguity.
        scripts.joinpath("jarvis-section").write_text(
            "import pathlib,sys\n"
            "sys.stdout.buffer.write(b''.join(pathlib.Path(sys.argv[1]).read_bytes().splitlines(keepends=True)[3:5]))\n")
        tests = self.root / "tests"
        tests.mkdir()
        for name in ("section_test.py", "desktop_world.py"):
            shutil.copyfile(Path(__file__).parent / name, tests / name)
        env = dict(os.environ, JARVIS_TOOL_SCRIPTS=str(scripts))
        for row in ("Section.test_selected_section", "Section.test_heading_refusal"):
            with self.subTest(row=row):
                result = run_case(tests / "section_test.py", row, env)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(b"AssertionError", result.stderr)


if __name__ == "__main__":
    import unittest
    unittest.main()
