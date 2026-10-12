"""Plant each defect in an owned, disposable source copy, never this tree."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]
CONTROLS = [
    ("exact resume", "orch/scripts/lib/lane-relaunch.sh", '  [[ "$actual" == "$id" ]] || return 2', '  return 1', "test_claude_contract"),
    ("ensure", "jarvis/scripts/lib/session.py", 'if matching and record["state"] in ("starting", "running")', 'if False and record["state"] in ("starting", "running")', "test_claude_contract"),
    ("boot receipt", "jarvis/scripts/lib/session.py", 'if boot and record and record.get("boot") == boot:', 'if False:', "test_off_and_boot_receipt"),
    ("app Off", "jarvis/scripts/lib/session.py", 'if record and record.get("app_off") and args.origin != "app-on":', 'if False:', "test_off_and_boot_receipt"),
    ("app On", "jarvis/scripts/lib/session.py", '"app_off": False, "intent": "start", "terminal": None,', '"app_off": args.origin == "app-on", "intent": "start", "terminal": None,', "test_off_and_boot_receipt"),
    ("native identity", "jarvis/scripts/lib/session.py", 'if identity.get("native_session_id") and identity.get("started_at") and not record.get("brief_delivered") and observed in ("idle", "working"):', 'if not record.get("brief_delivered"):', "test_identity_before_private_brief"),
    ("account before brief", "jarvis/scripts/lib/session-backend.sh", 'if [[ "$state" == working || "$6" == confirmed ]]; then', 'if [[ "$state" == working ]]; then', "test_account_is_checked_before_private_brief"),
    ("working turn", "jarvis/scripts/lib/session.py", 'elif record.get("brief_delivered") and observed == "working":', 'elif record.get("brief_delivered"):', "test_idle_prompt_is_not_running"),
    ("name ownership", "jarvis/scripts/lib/session.py", 'if existing.returncode == 0:', 'if False:', "test_unrelated_session_conflicts"),
    ("record reasons", "jarvis/scripts/lib/session.py", 'if record.get("reason") not in STATE_REASONS.get(record.get("state"), set()):', 'if False:', "test_record_contract_refuses_corruption"),
    ("detail length", "jarvis/scripts/lib/session.py", 'if not clean(detail) or len(detail) > 200:', 'if not clean(detail):', "test_record_contract_refuses_corruption"),
    ("detail controls", "jarvis/scripts/lib/session.py", 'if not clean(detail) or len(detail) > 200:', 'if len(detail) > 200:', "test_record_contract_refuses_corruption"),
    ("replacement cancellation", "jarvis/scripts/lib/session.py", 'dict(predecessor, generation=record["generation"] + 1, intent=', 'dict(predecessor, generation=record["generation"], intent=', "test_cancelled_replacement_keeps_the_live_owner"),
]


with tempfile.TemporaryDirectory() as allocation:
    scratch = Path(allocation).resolve()
    skills = scratch / "skills"
    for package in ("jarvis", "orch", "mailbox"):
        shutil.copytree(ROOT / "skills" / package / "scripts", skills / package / "scripts")
    for name, relative, old, new, test in CONTROLS:
        path = skills / relative
        original = path.read_text()
        assert original.count(old) == 1, name
        mutant = original.replace(old, new)
        assert mutant != original
        path.write_text(mutant)
        try:
            env = os.environ | {"JARVIS_TEST_SKILLS": str(skills),
                                "JARVIS_TEST_SCRIPT": str(skills / "jarvis/scripts/jarvis-session")}
            result = subprocess.run([os.environ["JARVIS_TEST_BASH"], str(ROOT / "skills/jarvis/tests/session.test.sh"),
                                     "SessionContract." + test], env=env, capture_output=True, text=True, timeout=90)
            assert result.returncode != 0, name + " passed its planted defect"
            # The test runner's outcome distinguishes a red assertion from
            # an import, fixture setup or command-launch failure.
            assert "FAILED (failures=" in result.stderr, result.stdout + result.stderr
            print("control: rejected=" + name, flush=True)
        finally:
            path.write_text(original)
print("pass: " + str(len(CONTROLS)) + " fail: 0")
