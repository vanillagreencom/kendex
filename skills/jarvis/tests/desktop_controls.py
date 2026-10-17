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
        rows = [
            ("browser-profile-launch", "scripts/jarvis-browser", '"--user-data-dir=" + str(profile)', '"--user-data-dir=wrong-profile"', "browser_test.py", "Browser.test_profile_and_url"),
            ("browser-profile-absolute", "scripts/jarvis-browser", "if not profile.is_absolute():", "if False:", "browser_test.py", "Browser.test_refused_inputs"),
            ("browser-port", "scripts/jarvis-browser", 'if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:', 'if False:', "browser_test.py", "Browser.test_refused_inputs"),
            ("browser-url", "scripts/jarvis-browser", 'if urlsplit(args.url).scheme not in ("http", "https", "about", "file"):', 'if False:', "browser_test.py", "Browser.test_refused_inputs"),
            ("browser-platform", "scripts/jarvis-browser", 'if sys.platform not in ("linux", "darwin"):', 'if False:', "browser_test.py", "Browser.test_platform_refusal"),
            ("browser-platform-wrong-cause", "scripts/jarvis-browser", 'if sys.platform not in ("linux", "darwin"):', 'if shutil.which("google-chrome"):', "browser_test.py", "Browser.test_platform_refusal"),
            ("human-input-operation", "scripts/human-input", '"0xC1"', '"0xC0"', "human_input_test.py", "HumanInput.test_input_commands"),
            ("human-input-platform", "scripts/human-input", 'if sys.platform != "linux" or not os.environ.get("WAYLAND_DISPLAY"):', 'if False:', "human_input_test.py", "HumanInput.test_dependencies_platform_and_failed_capture"),
            ("input-platform-refusal", "scripts/human-input", 'if sys.platform != "linux" or not os.environ.get("WAYLAND_DISPLAY"):', 'if False:', "human_input_test.py", "HumanInput.test_platform_refusal"),
            ("input-platform-wrong-cause", "scripts/human-input", 'if sys.platform != "linux" or not os.environ.get("WAYLAND_DISPLAY"):', 'if shutil.which("wtype"):', "human_input_test.py", "HumanInput.test_platform_refusal"),
            ("human-input-dependency", "scripts/human-input", 'if command is None:', 'if False:', "human_input_test.py", "HumanInput.test_dependencies_platform_and_failed_capture"),
            ("capture-exclusivity", "scripts/human-input", 'os.O_WRONLY | os.O_CREAT | os.O_EXCL', 'os.O_WRONLY | os.O_CREAT', "human_input_test.py", "HumanInput.test_capture_exclusive"),
            ("capture-absolute", "scripts/human-input", 'if not args.output.is_absolute():', 'if False:', "human_input_test.py", "HumanInput.test_capture_exclusive"),
            ("capture-failure-cleanup", "scripts/human-input", 'args.output.unlink()', 'pass', "human_input_test.py", "HumanInput.test_dependencies_platform_and_failed_capture"),
            ("optional-op", "scripts/lib/op_fifo.py", 'if op is None:', 'if False:', "op_broker_test.py", "Broker.test_optional_op_refusal"),
            ("private-type", "scripts/lib/op_fifo.py", "not kind(info.st_mode) or ", "", "op_broker_test.py", "Broker.test_private_transport"),
            ("private-mode", "scripts/lib/op_fifo.py", " or stat.S_IMODE(info.st_mode) != mode", "", "op_broker_test.py", "Broker.test_private_transport"),
            ("private-owner", "scripts/lib/op_fifo.py", "info.st_uid != os.getuid() or ", "", "op_broker_test.py", "Broker.test_transport_owner_and_symlinks"),
            ("directory-symlink", "scripts/lib/op_fifo.py", 'os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW', 'os.O_RDONLY | os.O_DIRECTORY', "op_broker_test.py", "Broker.test_transport_owner_and_symlinks"),
            ("reply-path", "scripts/lib/op_fifo.py", 'if not isinstance(reply, str) or not re.fullmatch(REPLY_NAME, reply):', 'if False:', "op_broker_test.py", "Broker.test_request_contract"),
            ("request-verb", "scripts/lib/op_fifo.py", "if verb not in (\"op\", \"script\"):", "if False:", "op_broker_test.py", "Broker.test_request_contract"),
            ("request-reference", "scripts/lib/op_fifo.py", ' or not reference.startswith("op://")', '', "op_broker_test.py", "Broker.test_request_contract"),
            ("broker-session", "scripts/lib/op_fifo.py", 'env["OP_SESSION"] = token', 'env["OP_SESSION"] = "wrong-session"', "op_broker_test.py", "Broker.test_session_and_parallel_clients"),
            ("broker-no-desktop-prompts", "scripts/lib/op_fifo.py", 'OP_BIOMETRIC_UNLOCK_ENABLED="false"', 'OP_BIOMETRIC_UNLOCK_ENABLED="true"', "op_broker_test.py", "Broker.test_session_and_parallel_clients"),
            ("client-output-exclusivity", "scripts/lib/op_fifo.py", 'os.O_WRONLY | os.O_CREAT | os.O_EXCL', 'os.O_WRONLY | os.O_CREAT', "op_broker_test.py", "Broker.test_read_failure_and_existing_output"),
            ("required-agent-browser", "SKILL.md", '- command: agent-browser', '- command: missing-fixture-replacement', "command_declarations_test.py", "Declaration.test_missing_agent_browser"),
            ("client-cancellation", "scripts/lib/op_fifo.py", 'except Cancelled as cancelled:\n        if kind == "broker":', 'except Cancelled as cancelled:\n        if True:', "op_broker_test.py", "Broker.test_cancelled_clients"),
            ("exact-field-bytes", "scripts/lib/op_fifo.py", '[op, "read", "--no-newline", reference]', '[op, "read", reference]', "op_broker_test.py", "Broker.test_exact_field_bytes"),
            ("fifo-capability", "scripts/lib/op_fifo.py", 'if os.mkfifo in os.supports_dir_fd:', 'if True:', "op_broker_test.py", "Broker.test_fifo_creation_capabilities"),
            ("noninteractive-deadline", "scripts/lib/op_fifo.py", 'timeout=None if interactive else CALL_SECONDS', 'timeout=None', "op_broker_test.py", "Broker.test_noninteractive_deadline"),
            ("op-arguments", "scripts/lib/op_fifo.py", "if not isinstance(args, list) or not args or not all(isinstance(word, str) for word in args):", "if False:", "op_broker_test.py", "Broker.test_request_contract"),
            ("record-platform", "scripts/lib/op_fifo.py", "if sys.platform != \"linux\":\n        return {\"status\": \"platform-unsupported\"}", "if False:\n        return {\"status\": \"platform-unsupported\"}", "op_broker_test.py", "Broker.test_request_contract"),
            ("record-exit", "scripts/lib/op_fifo.py", "\"exit\": result.returncode", "\"exit\": 0", "op_broker_test.py", "Broker.test_op_request_record"),
            ("request-size", "scripts/lib/op_fifo.py", "if len(request) > os.fpathconf(directory, \"PC_PIPE_BUF\"):", "if False:", "op_broker_test.py", "Broker.test_op_request_record"),
            ("script-private", "scripts/lib/op_fifo.py", "return private(fd, stat.S_ISREG, 0o700, \"script=private-owner-required\")", "return fd", "op_broker_test.py", "Broker.test_script_request"),
            ("script-nofollow", "scripts/lib/op_fifo.py", "os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)", "os.open(path, os.O_RDONLY | os.O_NONBLOCK)", "op_broker_test.py", "Broker.test_script_request"),
            ("work-group-exit", "scripts/lib/op_fifo.py", "os.killpg(process.pid, signal.SIGKILL)\n        while reading", "while reading", "op_broker_test.py", "Broker.test_work_process_group"),
            ("service-session", "scripts/lib/op_fifo.py", "if not os.isatty(0):", "if False:", "op_broker_test.py", "Broker.test_service_form"),
            ("service-restart", "scripts/lib/op_fifo.py", "except FileExistsError:\n", "except FileExistsError:\n        raise\n", "op_broker_test.py", "Broker.test_service_form"),
            ("reuse-platform", "scripts/lib/op_fifo.py", "if sys.platform != \"linux\":\n            raise Refusal(\"directory=exists", "if False:\n            raise Refusal(\"directory=exists", "op_broker_test.py", "Broker.test_broker_platform"),
            ("directory-foreign", "scripts/lib/op_fifo.py", "        if reused:\n            check_own_entries(directory)\n", "", "op_broker_test.py", "Broker.test_directory_states"),
            ("directory-foreign-type", "scripts/lib/op_fifo.py", "kind is None or not kind(", "kind is None or not bool(", "op_broker_test.py", "Broker.test_directory_states"),
            ("script-missing", "scripts/lib/op_fifo.py", "        except FileNotFoundError:\n            return {\"status\": \"script-missing\"}\n", "", "op_broker_test.py", "Broker.test_script_request"),
            ("service-stale-requests", "scripts/lib/op_fifo.py", "os.unlink(\"requests\", dir_fd=directory)\n        except FileNotFoundError", "pass\n        except FileNotFoundError", "op_broker_test.py", "Broker.test_service_form"),
            ("service-platform", "scripts/lib/op_fifo.py", "if kind == \"broker\" and configured and sys.platform != \"linux\":", "if False:", "op_broker_test.py", "Broker.test_broker_platform"),
            ("directory-lock", "scripts/lib/op_fifo.py", "fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)", "pass", "op_broker_test.py", "Broker.test_directory_states"),
            ("keepalive-interval", "scripts/lib/op_fifo.py", "keepalive if renewing else None", "None", "op_broker_test.py", "Broker.test_keepalive"),
            ("keepalive-failure-armed", "scripts/lib/op_fifo.py", "                keep_session(op, env)\n", "                keep_session(op, env)\n                renewing = False\n", "op_broker_test.py", "Broker.test_keepalive"),
            ("keepalive-failure-logged", "scripts/lib/op_fifo.py", "    if status:\n        print(", "    if False:\n        print(", "op_broker_test.py", "Broker.test_keep_session"),
            ("keepalive-opt-in", "scripts/lib/op_fifo.py", "    if not value:\n        return None", "    if not value:\n        return 1", "op_broker_test.py", "Broker.test_keepalive"),
            ("browser-port-report", "scripts/jarvis-browser", "print(port)", "print(\"9222\")", "browser_test.py", "Browser.test_port_and_shim"),
            ("browser-shim", "scripts/jarvis-browser", "/ \"browser-shim\")", "/ \"missing-shim\")", "browser_test.py", "Browser.test_port_and_shim"),
            ("browser-shim-detach", "scripts/browser-shim/xdg-open", "--detach -- \"$1\"", "-- \"$1\"", "browser_test.py", "Browser.test_port_and_shim"),
            ("browser-profile-parents", "scripts/jarvis-browser", "profile.mkdir(mode=0o700, parents=True, exist_ok=True)", "profile.mkdir(mode=0o700, exist_ok=True)", "browser_test.py", "Browser.test_downloads_and_class"),
            ("browser-downloads-absolute", "scripts/jarvis-browser", "if downloads and not Path(downloads).is_absolute():", "if False:", "browser_test.py", "Browser.test_refused_inputs"),
            ("browser-downloads", "scripts/jarvis-browser", "        set_downloads(profile, Path(downloads))", "        pass", "browser_test.py", "Browser.test_downloads_and_class"),
            ("browser-open-profile", "scripts/jarvis-browser", "if os.path.lexists(profile / \"SingletonLock\"):", "if False:", "browser_test.py", "Browser.test_downloads_and_class"),
            ("browser-class", "scripts/jarvis-browser", "*([\"--class=\" + window] if window else [])", "*([] if window else [])", "browser_test.py", "Browser.test_downloads_and_class"),
        ]
        baseline_env = dict(os.environ, JARVIS_TOOL_SCRIPTS=str(PACKAGE / "scripts"), JARVIS_TOOL_SKILL=str(PACKAGE / "SKILL.md"))
        skipped = {}
        for rule, relative, before, after, suite, case in rows:
            if rule == "required-agent-browser" and kendex_path() is None and not os.environ.get("HARNESS_CI_REQUIRE_KENDEX"):
                print("control=" + rule + " unavailable dependency=kendex", flush=True)
                continue
            if (suite, case) not in skipped:
                clean = run_case(PACKAGE / "tests" / suite, case, baseline_env)
                self.assertEqual(clean.returncode, 0, clean.stderr)
                # unittest's documented summary for one case its platform marker skipped.
                skipped[suite, case] = re.search(rb"^OK \(skipped=1\)$", clean.stderr, re.MULTILINE) is not None
            if skipped[suite, case]:
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
