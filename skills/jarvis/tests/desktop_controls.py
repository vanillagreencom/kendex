"""Must-fail controls use disposable production copies and the normal suite files."""
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest
from desktop_world import kendex_path, run_case

PACKAGE = Path(__file__).resolve().parents[1]


class Controls(unittest.TestCase):
    def test_independent_rules(self):
        # One planted defect per instrument suite proves that suite goes red.
        rows = [
            ("browser-profile-launch", "scripts/jarvis-browser", '"--user-data-dir=" + str(profile)', '"--user-data-dir=wrong-profile"', "browser_test.py", "Browser.test_profile_and_url"),
            ("capture-exclusivity", "scripts/human-input", 'os.O_WRONLY | os.O_CREAT | os.O_EXCL', 'os.O_WRONLY | os.O_CREAT', "human_input_test.py", "HumanInput.test_capture_exclusive"),
            ("private-mode", "scripts/lib/op_fifo.py", " or stat.S_IMODE(info.st_mode) != mode", "", "op_broker_test.py", "Broker.test_private_transport"),
            ("required-agent-browser", "SKILL.md", '- command: agent-browser', '- command: missing-fixture-replacement', "command_declarations_test.py", "Declaration.test_missing_agent_browser"),
        ]
        baseline_env = dict(os.environ, JARVIS_TOOL_SCRIPTS=str(PACKAGE / "scripts"), JARVIS_TOOL_SKILL=str(PACKAGE / "SKILL.md"))
        for rule, relative, before, after, suite, case in rows:
            if rule == "required-agent-browser" and kendex_path() is None and not os.environ.get("HARNESS_CI_REQUIRE_KENDEX"):
                print("control=" + rule + " unavailable dependency=kendex", flush=True)
                continue
            clean = run_case(PACKAGE / "tests" / suite, case, baseline_env)
            self.assertEqual(clean.returncode, 0, clean.stderr)
            # unittest's documented summary for one case its platform marker skipped.
            if re.search(rb"^OK \(skipped=1\)$", clean.stderr, re.MULTILINE):
                print("control=" + rule + " unavailable platform=" + sys.platform, flush=True)
                continue
            with self.subTest(rule=rule), tempfile.TemporaryDirectory(prefix="jarvis-control-") as scratch:
                copy = Path(scratch) / "jarvis"
                shutil.copytree(PACKAGE, copy)
                target = copy / relative
                original = target.read_text()
                self.assertEqual(original.count(before), 1, rule)
                changed = original.replace(before, after, 1)
                self.assertNotEqual(changed, original)
                target.write_text(changed)
                env = dict(os.environ, JARVIS_TOOL_SCRIPTS=str(copy / "scripts"), JARVIS_TOOL_SKILL=str(copy / "SKILL.md"))
                result = run_case(PACKAGE / "tests" / suite, case, env)
                self.assertNotEqual(result.returncode, 0, rule + " survived")
                self.assertIn(b"FAIL:", result.stderr, result.stderr)
                print("control=" + rule + " rejected", flush=True)


if __name__ == "__main__":
    unittest.main()
