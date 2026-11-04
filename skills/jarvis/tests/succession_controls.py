"""Reject planted succession and adoption defects in a disposable source copy."""
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
    parser.add_argument("--case", help="Prove only the planted defects for this named test case")
    args = parser.parse_args()
    completed = 0
    with native_launcher() as native, tempfile.TemporaryDirectory() as allocation:
        scratch = Path(allocation).resolve()
        skills = scratch / "skills"
        for package in ("jarvis", "orch", "mailbox"):
            shutil.copytree(ROOT / "skills" / package / "scripts", skills / package / "scripts")
        source = skills / "jarvis/scripts/lib/session.py"
        # Each planted defect proves succession_test.py goes red: without the
        # identity check, succession stops a process the record does not own;
        # without the pane comparison, adoption takes a process its named
        # pane does not run. The adoption rows each reject the defect their
        # guarantee names: a starting Start's worker, the consumer's other
        # panes, Start's brief and harness, the home's task session, the
        # harness detected at the call and nearest PID, and a moved pane.
        backend, session = "jarvis/scripts/lib/session-backend.sh", "jarvis/scripts/lib/session.py"
        defects = (("known wall exclusion", backend,
                    (('    exclude="${6:-}" mark=context caller="" OL_WALK_REFUSE_ID=""',
                      '    exclude="" mark=context caller="" OL_WALK_REFUSE_ID=""'),),
                    "test_known_wall_selection"),
                   ("process identity", backend,
                    (('    lane_stop_identity "$1" "$2" "$3" || rc=$?',
                      '    lane_stop_identity "$1" "$(lane_process_start "$1")" "$3" || rc=$?'),),
                    "test_succession_identity"),
                   ("adopted pane process", backend,
                    (('    [[ "$pane_pid" == "$pid" ]] || refuse pid-mismatch', '    : || refuse pid-mismatch'),),
                    "test_adoption_refusals"),
                   ("starting worker", session,
                    (("(self.terminal(record) or self.worker_live(record)", "(self.terminal(record)"),),
                    "test_adoption_refusals"),
                   ("adopted pane only", session,
                    (('action = "kill-pane" if adopted', 'action = "kill-session" if adopted'),),
                    "test_adoption_contract"),
                   ("adoption brief", session,
                    (('if record else None, "private_brief": private}', 'if record else None, "private_brief": None}'),),
                    "test_adoption_contract"),
                   ("Start's harness", session,
                    (("self._hand_over(base, choice, predecessor, None)",
                      'self._hand_over(base, dict(choice, harness=predecessor["harness"]), predecessor, None)'),),
                    "test_adoption_contract"),
                   ("task session", session,
                    (("                elif adopted:\n                    self.end_task_session()\n", ""),),
                    "test_adoption_contract"),
                   ("detected harness", backend,
                    (('    jq -cn --arg harness "$harness" --arg socket', '    jq -cn --arg harness pi --arg socket'),),
                    "test_adoption_contract"),
                   ("nearest harness", backend,
                    (('      if [[ -z "$nearest" ]] || (( hops < nearest )); then',
                      '      if [[ -z "$nearest" ]] || (( hops > nearest )); then'),),
                    "test_adoption_contract"),
                   ("moved pane", backend,
                    (('        [[ "$pid" == "$5" ]] || exit 1 ;;', '        [[ "$pid" == "$5" && "$window" == "$6" ]] || exit 1 ;;'),),
                    "test_adoption_recovery"),
                   ("retry brief", session,
                    (('                saved_handoff = record["transfer"]["handoff"]\n',
                      '                saved_handoff = record["transfer"]["handoff"]\n                record = dict(record, private_brief=None)\n'),),
                    "test_adoption_recovery"))
        # The rows the latest change added, which its pre-change revision fails.
        cases = ("test_succession_contract",)
        if args.case and args.case not in {case for _, _, _, case in defects}:
            parser.error("no planted defect for case " + args.case)
        env = os.environ | {"JARVIS_TEST_SKILLS": str(skills), "JARVIS_TEST_NATIVE": str(native),
                            "JARVIS_TEST_SCRIPT": str(skills / "jarvis/scripts/jarvis-session")}

        def rejected(name, case):
            nonlocal completed
            result = subprocess.run([os.environ["JARVIS_TEST_BASH"], str(ROOT / "skills/jarvis/tests/succession.test.sh"),
                                     "--failfast", "SuccessionContract." + case], env=env, capture_output=True, text=True, timeout=180)
            print(result.stdout, end="", flush=True)
            print(result.stderr, end="", flush=True)
            assert result.returncode != 0, name + " passed its planted defect"
            assert "FAILED (failures=" in result.stderr, result.stdout + result.stderr
            completed += 1
            print("control: rejected=" + name + " case=" + case, flush=True)

        for name, relative, edits, case in defects:
            if args.case and case != args.case:
                continue
            target = skills / relative
            clean = mutant = target.read_text()
            for old, new in edits:
                assert mutant.count(old) == 1, name
                mutant = mutant.replace(old, new)
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
                if args.case and case != args.case:
                    continue
                rejected("main=" + args.main_ref, case)
    print(f"pass: {completed} fail: 0")


if __name__ == "__main__":
    main()
