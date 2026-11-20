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
            ("private-mode", "scripts/lib/op_fifo.py", " and stat.S_IMODE(info.st_mode) == mode", "", "op_broker_test.py", "Broker.test_private_transport"),
            ("caller-link-recheck", "scripts/lib/op_fifo.py", 'if stat_fields(read("%d/stat" % pid)) != (parent, started):', "if False:", "op_broker_test.py", "Broker.test_caller_identity"),
            ("caller-peer-user", "scripts/lib/op_fifo.py", "if uid != os.getuid() or pid <= 0:", "if pid <= 0:", "op_broker_test.py", "Broker.test_unverified_peer"),
            ("session-start-bound", "scripts/lib/op_fifo.py", "any((step, ticks) == session for", "any(step == session[0] for", "op_broker_test.py", "Broker.test_caller_identity"),
            ("controller-live", "scripts/lib/op_fifo.py", 'status.get("live") is not True', "False", "op_broker_test.py", "Broker.test_controller_record_states"),
            # Against agent-runtime's real read of a tmux pane's controller; a Linux-only case, since macOS names no caller.
            ("controller-start-read", "scripts/lib/op_fifo.py", "return int(pid), int(ticks)", "return int(pid), int(ticks) + 1", "op_broker_test.py", "Broker.test_tmux_session_caller"),
            # Its broker directory's socket path is past Linux's sun_path, which only the descriptor's name reaches.
            ("client-socket-address", "scripts/lib/op_fifo.py", "connection.connect(socket_address(directory, root))", "connection.connect(str(root / SOCKET))", "op_broker_test.py", "Broker.test_op_request_record"),
            ("client-fifo-broker", "scripts/lib/op_fifo.py", "            exchange = fifo_exchange\n", "            raise\n", "op_broker_test.py", "Broker.test_fifo_broker"),
            ("broker-isolated", "scripts/op-broker", "#!/usr/bin/env -S python3 -I\n", "#!/usr/bin/env -S python3\n", "op_broker_test.py", "Broker.test_session_and_parallel_clients"),
            ("required-agent-browser", "SKILL.md", '- command: agent-browser', '- command: missing-fixture-replacement', "command_declarations_test.py", "Declaration.test_missing_agent_browser"),
        ]
        for rule, relative, before, after, suite, case in rows:
            if rule == "required-agent-browser" and kendex_path() is None and not os.environ.get("HARNESS_CI_REQUIRE_KENDEX"):
                print("control=" + rule + " unavailable dependency=kendex", flush=True)
                continue
            with self.subTest(rule=rule), tempfile.TemporaryDirectory(prefix="jarvis-control-") as scratch:
                copy = Path(scratch) / "jarvis"
                shutil.copytree(PACKAGE, copy)
                # The scripts run the sibling packages' scripts; the copy reads them unchanged.
                for sibling in ("mailbox", "orch", "agent-runtime"):
                    (Path(scratch) / sibling).symlink_to(PACKAGE.parent / sibling)
                env = dict(os.environ, JARVIS_TOOL_SCRIPTS=str(copy / "scripts"), JARVIS_TOOL_SKILL=str(copy / "SKILL.md"))
                # The unchanged copy passes the case, so a failure after the change is the planted defect's.
                clean = run_case(PACKAGE / "tests" / suite, case, env)
                self.assertEqual(clean.returncode, 0, clean.stderr)
                # unittest's documented summary for one case its platform marker skipped.
                if re.search(rb"^OK \(skipped=1\)$", clean.stderr, re.MULTILINE):
                    print("control=" + rule + " unavailable platform=" + sys.platform, flush=True)
                    continue
                target = copy / relative
                original = target.read_text()
                self.assertEqual(original.count(before), 1, rule)
                changed = original.replace(before, after, 1)
                self.assertNotEqual(changed, original)
                target.write_text(changed)
                result = run_case(PACKAGE / "tests" / suite, case, env)
                self.assertNotEqual(result.returncode, 0, rule + " survived")
                self.assertIn(b"FAIL:", result.stderr, result.stderr)
                print("control=" + rule + " rejected", flush=True)


if __name__ == "__main__":
    unittest.main()
