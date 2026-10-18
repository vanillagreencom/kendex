"""Reject the absent succession verb and a removed process identity check."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from fixtures.harness import native_launcher


ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--main-ref", help="Also prove each succession case fails on this pre-change revision")
    args = parser.parse_args()
    completed = 0
    with native_launcher() as native, tempfile.TemporaryDirectory() as allocation:
        scratch = Path(allocation).resolve()
        skills = scratch / "skills"
        for package in ("jarvis", "orch", "mailbox"):
            shutil.copytree(ROOT / "skills" / package / "scripts", skills / package / "scripts")
        source = skills / "jarvis/scripts/lib/session.py"
        controls = [("absent verb", "jarvis/scripts/lib/session.py", 'for verb in ("start", "status", "stop", "succeed"):',
                     'for verb in ("start", "status", "stop"):', "test_succession_contract"),
                    ("process identity", "jarvis/scripts/lib/session-backend.sh", '    lane_stop_identity "$1" "$2" "$3" ;;',
                     '    lane_stop_identity "$1" "$(lane_process_start "$1")" "$3" ;;', "test_succession_identity"),
                    ("walled account reused", "jarvis/scripts/lib/session.py",
                     'choice = json.loads(self.backend("select", record["harness"], record["account"], self.home,\n                                             choice.get("model", ""), choice.get("effort", "")).stdout)',
                     'choice = {"harness": record["harness"], "account": record["account"], "model": "", "effort": ""}', "test_account_succession"),
                    ("missing dependency status", "jarvis/scripts/lib/session.py",
                     'if not (BACKEND.parents[3] / "orch/scripts").is_dir():',
                     'if False:', "test_missing_orch_keeps_predecessor"),
                    ("model context helper missing", "jarvis/scripts/lib/session-backend.sh",
                     '    source "$SCRIPT_DIR/lib/lane-context.sh"',
                     '    : source "$SCRIPT_DIR/lib/lane-context.sh"', "test_account_succession"),
                    ("selected launch words dropped", "jarvis/scripts/lib/session-backend.sh",
                     'if [[ -n "${8:-}${9:-}" ]]; then',
                     'if false && [[ -n "${8:-}${9:-}" ]]; then', "test_account_succession"),
                    ("native launch posture changed", "jarvis/scripts/lib/session-backend.sh",
                     '      flags="$(printf \' %q\' ${LAUNCH_CHOICE_ARGV[@]+"${LAUNCH_CHOICE_ARGV[@]}"})" || exit 1',
                     '      launch_choice_lead_settings --model "${8:-}" "$harness" ${LAUNCH_CHOICE_ARGV[@]+"${LAUNCH_CHOICE_ARGV[@]}"} || exit 1\n'
                     '      LAUNCH_CHOICE_ARGV=("${LAUNCH_CHOICE_KEPT[@]}")\n'
                     '      flags="$(printf \' %q\' ${LAUNCH_CHOICE_ARGV[@]+"${LAUNCH_CHOICE_ARGV[@]}"})" || exit 1', "test_account_succession"),
                    ("duplicate native boolean", "jarvis/scripts/lib/session-backend.sh",
                     '      cmd="$harness$flags${cmd#"$harness"}"',
                     '      cmd="$harness$flags${cmd#"$harness"}"\n'
                     '      [[ "$harness" != codex ]] || cmd="$cmd --dangerously-bypass-hook-trust"', "test_account_succession"),
                    ("recorded account seat reserve", "jarvis/scripts/lib/session-backend.sh",
                     '--harness "$OL_ACCOUNT_HARNESS" --for-overseer',
                     '--harness "$OL_ACCOUNT_HARNESS"', "test_account_succession"),
                    ("missing selected app", "jarvis/scripts/lib/session.py",
                     'if not shutil.which(choice["harness"]):',
                     'if False and not shutil.which(choice["harness"]):', "test_account_succession")]
        cases = ("test_account_succession", "test_missing_orch_keeps_predecessor")
        env = os.environ | {"JARVIS_TEST_SKILLS": str(skills), "JARVIS_TEST_NATIVE": str(native),
                            "JARVIS_TEST_SCRIPT": str(skills / "jarvis/scripts/jarvis-session")}

        def rejected(name, case):
            nonlocal completed
            result = subprocess.run([os.environ["JARVIS_TEST_BASH"], str(ROOT / "skills/jarvis/tests/succession.test.sh"),
                                     "--failfast", "SuccessionContract." + case], env=env, capture_output=True, text=True, timeout=90)
            assert result.returncode != 0, name + " passed its planted defect"
            assert "FAILED (failures=" in result.stderr, result.stdout + result.stderr
            completed += 1
            print("control: rejected=" + name + " case=" + case, flush=True)

        for name, relative, old, new, case in controls:
            target = skills / relative
            clean = target.read_text()
            assert clean.count(old) == 1, name
            mutant = clean.replace(old, new)
            assert mutant != clean
            target.write_text(mutant)
            try:
                rejected(name, case)
            finally:
                target.write_text(clean)
        if args.main_ref:
            result = subprocess.run(["git", "-C", str(ROOT), "show", args.main_ref + ":skills/jarvis/scripts/lib/session.py"],
                                    capture_output=True, text=True, check=True, timeout=30,
                                    env={k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")})
            source.write_text(result.stdout)
            for case in cases:
                rejected("main=" + args.main_ref, case)
    print(f"pass: {completed} fail: 0")


if __name__ == "__main__":
    main()
