"""Plant each defect in an owned, disposable source copy, never this tree."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from session_test import BootReceiptScenario
from fixtures.harness import native_launcher


ROOT = Path(__file__).resolve().parents[3]
CONTROLS = [
    ("fixture installed toolchain", "jarvis/tests/fixtures/harness.py", 'cwd=path.parent,', 'cwd=None if True else path.parent,', "test_native_fixture_uses_installed_toolchain"),
    ("exact resume", "orch/scripts/lib/lane-relaunch.sh", '  [[ "$actual" == "$id" ]] || return 2', '  return 1', "test_claude_contract"),
    ("live desktop session", "jarvis/scripts/lib/session-backend.sh", '    lane_launch_keep_live_session\n', '', "test_claude_contract"),
    ("ensure", "jarvis/scripts/lib/session.py", 'if matching and record["state"] in ("starting", "running")', 'if False and record["state"] in ("starting", "running")', "test_claude_contract"),
    ("app Off", "jarvis/scripts/lib/session.py", 'if record and record.get("app_off") and args.origin != "app-on":', 'if False:', "test_off_and_boot_receipt"),
    ("app On", "jarvis/scripts/lib/session.py", 'if args.origin == "app-on":', 'if False:', "test_off_and_boot_receipt"),
    ("native identity", "jarvis/scripts/lib/session.py", 'if identity.get("native_session_id") and identity.get("started_at") and not record.get("brief_delivered") and observed in ("idle", "working"):', 'if not record.get("brief_delivered"):', "test_identity_before_private_brief"),
    ("live harness before brief", "orch/scripts/lib/pane-write.sh", 'pane_write_expect "$expect" || return', 'true || { pane_write_expect "$expect" || return; }', "test_identity_before_private_brief"),
    ("account before brief", "jarvis/scripts/lib/session-backend.sh", 'if [[ "$6" == confirmed ]]; then', 'if false; then', "test_account_is_checked_before_private_brief"),
    ("kickoff turn before the start", "jarvis/scripts/lib/session-backend.sh", 'if [[ "$6" == confirmed ]]; then', 'if [[ "$state" == working || "$6" == confirmed ]]; then', "test_session_start_at_first_prompt"),
    ("Copilot kickoff", "orch/scripts/lib/lane-launch.sh", "printf ' -i %s' \"$(lane_single_quote \"$LANE_SESSION_KICKOFF\")\"", 'true', "test_session_start_at_first_prompt"),
    ("Codex kickoff", "orch/scripts/lib/lane-launch.sh", "[[ -z \"$file\" ]] || printf ' resume %q' \"$id\"\n      printf ' %s' \"$(lane_single_quote \"$LANE_SESSION_KICKOFF\")\"", "[[ -z \"$file\" ]] || printf ' resume %q' \"$id\"", "test_codex_contract"),
    ("observed account acknowledgement", "jarvis/scripts/lib/session-backend.sh", 'lane_account_equivalent "${7:-}" "$account" ||', 'true || { lane_account_equivalent "${7:-}" "$account"; } ||', "test_account_is_checked_before_private_brief"),
    ("fixture EOF is not delivery", "jarvis/tests/fixtures/harness.py", 'if prompt == "":', 'if False and prompt == "":', "test_account_is_checked_before_private_brief"),
    ("local acquisition ownership", "jarvis/scripts/lib/session.py", 'acquired = record', 'acquired = None', "test_start_acquisition_failure_releases_ownership"),
    ("brief acquisition cleanup", "jarvis/scripts/lib/session.py", 'prompt.unlink()', 'if False:\n                                prompt.unlink()', "test_start_acquisition_failure_releases_ownership"),
    ("worker acquisition cleanup", "jarvis/scripts/lib/session.py", '            child.terminate()\n            try:\n                child.wait(timeout=2)\n            except subprocess.TimeoutExpired:\n                child.kill()\n                child.wait(timeout=2)', '            if False:\n                child.terminate()\n                try:\n                    child.wait(timeout=2)\n                except subprocess.TimeoutExpired:\n                    child.kill()\n                    child.wait(timeout=2)', "test_start_acquisition_failure_releases_ownership"),
    ("working turn", "jarvis/scripts/lib/session.py", 'record.get("brief_delivered") and (taken or observed == "working"):', 'record.get("brief_delivered"):', "test_idle_prompt_is_not_running"),
    ("brief taken", "jarvis/scripts/lib/session.py", '(taken or observed == "working")', '(observed == "working")', "test_turn_end_takes_the_brief"),
    ("Pi tool call takes the brief", "jarvis/scripts/lib/session.py", '(taken or observed == "working")', '(observed == "working")', "test_pi_contract"),
    ("Pi idle before the brief", "jarvis/scripts/lib/session-backend.sh", 'if [[ "$harness" == pi && "$6" == confirmed && "$brief" == undelivered ]]; then', 'if false; then', "test_pi_contract"),
    ("trust refusal", "jarvis/scripts/lib/session-backend.sh", "0) printf 'trust\\n%s\\n' \"$dialog\"; exit ;;", '0) ;;', "test_trust_dialog_is_refused"),
    ("trust below the last turn", "jarvis/scripts/lib/session-backend.sh", 'dialog="$(pane_trust_dialog "$slice")"', 'dialog="$(pane_trust_dialog "$screen")"', "test_resumed_history_is_no_trust_dialog"),
    ("trust before the start", "jarvis/scripts/lib/session-backend.sh", 'if [[ "$harness" == copilot && "$6" == pending ]]; then', 'if [[ "$harness" == copilot ]]; then', "test_resumed_history_is_no_trust_dialog"),
    ("pane refusal snapshot", "jarvis/scripts/lib/session.py", '                with self.locked():\n                    inspected = record', '                if observed == "trust":\n                    raise Refusal("trust-required", dialog_question(dialog))\n                with self.locked():\n                    inspected = record', "test_resumed_history_is_no_trust_dialog"),
    ("stamped pane read", "jarvis/scripts/lib/session.py", 'observed = self.backend(', 'observed = "" if taken else self.backend(', "test_sign_in_wall_after_the_stamp"),
    ("current-turn authentication", "jarvis/scripts/lib/session-backend.sh", 'lane_state state listed "$cmd" "$pid" "$screen" || exit 1', 'if lane_auth_failure "$screen"; then printf \'auth\\n\'; exit; fi\n    lane_state state listed "$cmd" "$pid" "$screen" || exit 1', "test_sign_in_failure"),
    ("authentication wall", "jarvis/scripts/lib/session-backend.sh", 'if [[ "$LANE_WALL_KIND" == auth ]]; then', 'if false; then', "test_sign_in_failure"),
    ("name ownership", "jarvis/scripts/lib/session.py", 'if existing.returncode == 0:', 'if False:', "test_unrelated_session_conflicts"),
    ("record reasons", "jarvis/scripts/lib/session.py", 'if record.get("reason") not in STATE_REASONS.get(record.get("state"), set()):', 'if False:', "test_record_contract_refuses_corruption"),
    ("detail length", "jarvis/scripts/lib/session.py", 'if not clean(detail) or len(detail) > 200:', 'if not clean(detail):', "test_record_contract_refuses_corruption"),
    ("detail controls", "jarvis/scripts/lib/session.py", 'if not clean(detail) or len(detail) > 200:', 'if len(detail) > 200:', "test_record_contract_refuses_corruption"),
    ("app On state", "jarvis/scripts/lib/session.py", 'if record["state"] == "off":', 'if False:', "test_off_and_boot_receipt"),
    ("confirmed account scope", "jarvis/scripts/lib/session.py", 'if pending.get("started_at") and (record.get("identity_verified") or record.get("state") == "running"):', 'if pending.get("started_at"):', "test_account_is_checked_before_private_brief"),
    ("confirmed history", "jarvis/scripts/lib/session.py", 'return record.get("history")', 'return None', "test_pi_contract"),
    ("launch bound", "jarvis/scripts/lib/session.py", 'if time.monotonic() >= self.deadline:', 'self.deadline = time.monotonic() + CALL_SECONDS\n                if time.monotonic() >= self.deadline:', "test_idle_prompt_is_not_running"),
    ("abandoned worker", "jarvis/scripts/lib/session.py", 'return result.returncode == 0', 'return True', "test_verbs_answer_with_held_launch"),
    ("record location", "jarvis/scripts/lib/session.py", 'self.path = state / "kendex/jarvis" / key / "jarvis-session.json"', 'self.path = Path(self.home) / "jarvis-session.json"', "test_copilot_contract"),
    ("retained running owner", "jarvis/scripts/lib/session.py", 'reason="existing" if controller_state == "running" else "launching", detail="")', 'reason="launching", detail="")\n        retained["state"] = "starting"', "test_cancelled_replacement_keeps_the_live_owner"),
    ("retained starting owner", "jarvis/scripts/lib/session.py", 'controller_state == "running"', 'controller_state in ("running", "starting")', "test_sign_in_failure"),
    ("stop request identity", "jarvis/scripts/lib/session.py", 'record["generation"] += 1', 'record["generation"] += 0', "test_cancelled_replacement_keeps_the_live_owner"),
    ("stop failure result", "jarvis/scripts/lib/session.py", 'if live:\n                    record = self.retain_live(record, live)', 'if live:\n                    if verb == "stop":\n                        return\n                    record = self.retain_live(record, live)', "test_cancelled_replacement_keeps_the_live_owner"),
    ("replacement cancellation", "jarvis/scripts/lib/session.py", 'dict(predecessor, generation=record["generation"] + 1, intent=', 'dict(predecessor, generation=record["generation"], intent=', "test_cancelled_replacement_keeps_the_live_owner"),
    ("confirmed cancellation", "jarvis/scripts/lib/session.py", 'predecessor["state"] == "running" and predecessor["harness"]', 'True and predecessor["harness"]', "test_cancelled_replacement_keeps_the_live_owner"),
    ("Stop intent before probe", "jarvis/scripts/lib/session.py", 'self.write(record)\n            if self.terminal(record) or self.terminal(record.get("predecessor"))', 'if False:\n                self.write(record)\n            if self.terminal(record) or self.terminal(record.get("predecessor"))', "test_off_and_boot_receipt"),
    ("boot scenario applicability", "jarvis/tests/session_controls.py", 'if boot_scenario.applicable:\n        controls.extend(boot_scenario.controls)', 'if True:\n        controls.extend(boot_scenario.controls)', "test_off_and_boot_receipt"),
]


def applicable_controls(boot_scenario=BootReceiptScenario):
    controls = list(CONTROLS)
    if boot_scenario.applicable:
        controls.extend(boot_scenario.controls)
    return controls


def main():
    controls = applicable_controls()
    if not BootReceiptScenario.applicable:
        for name, *_ in BootReceiptScenario.controls:
            print("control: unavailable=" + name + " producer=boot-receipt", flush=True)
    with native_launcher() as native, tempfile.TemporaryDirectory() as allocation:
        scratch = Path(allocation).resolve()
        skills = scratch / "skills"
        for package in ("jarvis", "orch", "mailbox"):
            shutil.copytree(ROOT / "skills" / package / "scripts", skills / package / "scripts")
        # The trust row replays a measured native capture.
        shutil.copytree(ROOT / "skills/orch/tests/fixtures/oversee-watch", skills / "orch/tests/fixtures/oversee-watch")
        # Test-owned applicability is mutated beside the existing contract case.
        shutil.copytree(ROOT / "skills/jarvis/tests", skills / "jarvis/tests",
                        ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copyfile(ROOT / "rust-toolchain.toml", scratch / "rust-toolchain.toml")
        clean = {}
        for name, relative, old, new, test in controls:
            env = os.environ | {"JARVIS_TEST_SKILLS": str(skills), "JARVIS_TEST_NATIVE": str(native),
                                "JARVIS_TEST_SCRIPT": str(skills / "jarvis/scripts/jarvis-session")}
            if test not in clean:
                started = time.monotonic()
                print("control: start=baseline name=" + test, flush=True)
                baseline = subprocess.run([os.environ["JARVIS_TEST_BASH"], str(skills / "jarvis/tests/session.test.sh"),
                                           "SessionContract." + test], env=env, capture_output=True, text=True, timeout=90)
                print(f"control: elapsed=baseline seconds={time.monotonic() - started:.3f} name={test}", flush=True)
                assert baseline.returncode == 0, "clean case failed: " + test + "\n" + baseline.stdout + baseline.stderr
                clean[test] = True
                print("control: clean=" + test, flush=True)
            path = skills / relative
            original = path.read_text()
            expected = 2 if name == "retained starting owner" else 1
            assert original.count(old) == expected, name
            mutant = original.replace(old, new)
            assert mutant != original
            path.write_text(mutant)
            try:
                started = time.monotonic()
                print("control: start=mutant name=" + name, flush=True)
                # One assertion failure proves rejection; later subtests add no evidence.
                result = subprocess.run([os.environ["JARVIS_TEST_BASH"], str(skills / "jarvis/tests/session.test.sh"),
                                         "--failfast", "SessionContract." + test], env=env, capture_output=True, text=True, timeout=90)
                print(f"control: elapsed=mutant seconds={time.monotonic() - started:.3f} name={name}", flush=True)
                assert result.returncode != 0, name + " passed its planted defect"
                # The test runner's outcome distinguishes a red assertion from
                # an import, fixture setup or command-launch failure.
                assert "FAILED (failures=" in result.stderr, result.stdout + result.stderr
                print("control: rejected=" + name, flush=True)
            finally:
                path.write_text(original)
    print("pass: " + str(len(controls)) + " fail: 0")


if __name__ == "__main__":
    main()
