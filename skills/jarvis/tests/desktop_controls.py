"""Must-fail controls use disposable production copies and the normal suite files."""
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from desktop_world import kendex_path, run_case

PACKAGE = Path(__file__).resolve().parents[1]


class Controls(unittest.TestCase):
    def test_independent_rules(self):
        rows = [
            ("browser-profile-launch", "scripts/jarvis-browser", '"--user-data-dir=" + str(profile)', '"--user-data-dir=wrong-profile"', "browser_test.py", "Browser.test_profile_and_url"),
            ("browser-profile-absolute", "scripts/jarvis-browser", "if not profile.is_absolute():", "if False:", "browser_test.py", "Browser.test_refused_inputs"),
            ("browser-port", "scripts/jarvis-browser", 'if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:', 'if False:', "browser_test.py", "Browser.test_refused_inputs"),
            ("browser-url", "scripts/jarvis-browser", 'if urlsplit(args.url).scheme not in ("http", "https", "about", "file"):', 'if False:', "browser_test.py", "Browser.test_refused_inputs"),
            ("browser-platform", "scripts/jarvis-browser", 'if sys.platform not in ("linux", "darwin"):', 'if False:', "browser_test.py", "Browser.test_platform_refusal"),
            ("human-input-operation", "scripts/human-input", '"0xC1"', '"0xC0"', "human_input_test.py", "HumanInput.test_input_commands"),
            ("human-input-platform", "scripts/human-input", 'if sys.platform != "linux" or not os.environ.get("WAYLAND_DISPLAY"):', 'if False:', "human_input_test.py", "HumanInput.test_dependencies_platform_and_failed_capture"),
            ("input-platform-refusal", "scripts/human-input", 'if sys.platform != "linux" or not os.environ.get("WAYLAND_DISPLAY"):', 'if False:', "human_input_test.py", "HumanInput.test_platform_refusal"),
            ("human-input-dependency", "scripts/human-input", 'if command is None:', 'if False:', "human_input_test.py", "HumanInput.test_dependencies_platform_and_failed_capture"),
            ("capture-exclusivity", "scripts/human-input", 'os.O_WRONLY | os.O_CREAT | os.O_EXCL', 'os.O_WRONLY | os.O_CREAT', "human_input_test.py", "HumanInput.test_capture_exclusive"),
            ("capture-absolute", "scripts/human-input", 'if not args.output.is_absolute():', 'if False:', "human_input_test.py", "HumanInput.test_capture_exclusive"),
            ("capture-failure-cleanup", "scripts/human-input", 'args.output.unlink()', 'pass', "human_input_test.py", "HumanInput.test_dependencies_platform_and_failed_capture"),
            ("optional-op", "scripts/lib/op_fifo.py", 'if op is None:', 'if False:', "op_broker_test.py", "Broker.test_optional_op_refusal"),
            ("fifo-type", "scripts/lib/op_fifo.py", 'not stat.S_ISFIFO(info.st_mode) or ', '', "op_broker_test.py", "Broker.test_private_transport"),
            ("fifo-permissions", "scripts/lib/op_fifo.py", 'if not stat.S_ISFIFO(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:', 'if not stat.S_ISFIFO(info.st_mode) or info.st_uid != os.getuid():', "op_broker_test.py", "Broker.test_private_transport"),
            ("directory-private", "scripts/lib/op_fifo.py", 'if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:', 'if info.st_uid != os.getuid():', "op_broker_test.py", "Broker.test_private_transport"),
            ("directory-owner", "scripts/lib/op_fifo.py", 'if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:', 'if stat.S_IMODE(info.st_mode) != 0o700:', "op_broker_test.py", "Broker.test_transport_owner_and_symlinks"),
            ("fifo-owner", "scripts/lib/op_fifo.py", 'if not stat.S_ISFIFO(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:', 'if not stat.S_ISFIFO(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:', "op_broker_test.py", "Broker.test_transport_owner_and_symlinks"),
            ("directory-symlink", "scripts/lib/op_fifo.py", 'os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW', 'os.O_RDONLY | os.O_DIRECTORY', "op_broker_test.py", "Broker.test_transport_owner_and_symlinks"),
            ("reply-path", "scripts/lib/op_fifo.py", 'if not isinstance(reply, str) or not re.fullmatch(r"[0-9a-f]{32}\\.reply", reply):', 'if False:', "op_broker_test.py", "Broker.test_request_contract"),
            ("request-verb", "scripts/lib/op_fifo.py", 'request.get("verb") != "read" or ', '', "op_broker_test.py", "Broker.test_request_contract"),
            ("request-reference", "scripts/lib/op_fifo.py", ' or not reference.startswith("op://")', '', "op_broker_test.py", "Broker.test_request_contract"),
            ("broker-session", "scripts/lib/op_fifo.py", 'env["OP_SESSION"] = token', 'env["OP_SESSION"] = "wrong-session"', "op_broker_test.py", "Broker.test_session_and_parallel_clients"),
            ("broker-no-desktop-prompts", "scripts/lib/op_fifo.py", 'OP_BIOMETRIC_UNLOCK_ENABLED="false"', 'OP_BIOMETRIC_UNLOCK_ENABLED="true"', "op_broker_test.py", "Broker.test_session_and_parallel_clients"),
            ("client-output-exclusivity", "scripts/lib/op_fifo.py", 'os.O_WRONLY | os.O_CREAT | os.O_EXCL', 'os.O_WRONLY | os.O_CREAT', "op_broker_test.py", "Broker.test_read_failure_and_existing_output"),
            ("required-agent-browser", "SKILL.md", '- command: agent-browser', '- command: missing-fixture-replacement', "command_declarations_test.py", "Declaration.test_missing_agent_browser"),
            ("client-cancellation", "scripts/lib/op_fifo.py", 'except Cancelled as cancelled:\n        if kind == "broker":', 'except Cancelled as cancelled:\n        if True:', "op_broker_test.py", "Broker.test_cancelled_clients"),
            ("exact-field-bytes", "scripts/lib/op_fifo.py", '[op, "read", "--no-newline", reference]', '[op, "read", reference]', "op_broker_test.py", "Broker.test_exact_field_bytes"),
            ("fifo-capability", "scripts/lib/op_fifo.py", 'if os.mkfifo in os.supports_dir_fd:', 'if True:', "op_broker_test.py", "Broker.test_fifo_creation_capabilities"),
            ("noninteractive-deadline", "scripts/lib/op_fifo.py", 'timeout=None if interactive else CALL_SECONDS', 'timeout=None', "op_broker_test.py", "Broker.test_noninteractive_deadline"),
        ]
        baseline_env = dict(os.environ, JARVIS_TOOL_SCRIPTS=str(PACKAGE / "scripts"), JARVIS_TOOL_SKILL=str(PACKAGE / "SKILL.md"))
        baselines = set()
        for rule, relative, before, after, suite, case in rows:
            if suite == "human_input_test.py" and case != "HumanInput.test_platform_refusal" and sys.platform != "linux":
                print("control=" + rule + " unavailable platform=" + sys.platform, flush=True)
                continue
            if rule == "required-agent-browser" and kendex_path() is None and not os.environ.get("HARNESS_CI_REQUIRE_KENDEX"):
                print("control=" + rule + " unavailable dependency=kendex", flush=True)
                continue
            if (suite, case) not in baselines:
                clean = run_case(PACKAGE / "tests" / suite, case, baseline_env)
                self.assertEqual(clean.returncode, 0, clean.stderr)
                baselines.add((suite, case))
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
