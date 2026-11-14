"""Reject planted succession and adoption defects in a disposable source copy."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from fixtures.harness import native_launcher


ROOT = Path(__file__).resolve().parents[3]
SESSION = "jarvis/scripts/lib/session.py"
# Each planted defect proves succession_test.py goes red on its own case.
DEFECTS = (
    # Without the repeat, an unproved first successor ends the hand-over.
    ("repeat", SESSION, "if attempted and attempted in marked:", "if False:",
     "test_a_successor_that_cannot_sign_in_is_passed_for_the_next_account"),
    # Without the wait on the job, a failed attempt reads as a hand-over.
    ("outcome", SESSION, 'code = self.settled_transfer(recorded.get("generation"))', "code = 0",
     "test_a_successor_that_cannot_sign_in_is_passed_for_the_next_account"),
    # A walled account is kept as a context mark keeps it.
    ("walled", SESSION, '"headroom" if account_walled else "context"', '"context"',
     "test_with_no_account_left_the_answer_names_each_unproved_account_and_jarvis_keeps_running"),
    # The header an attempt wrote refuses the next attempt's body.
    ("handoff header", SESSION, 'if not line.startswith("Start here:")', "if True",
     "test_with_no_account_left_the_answer_names_each_unproved_account_and_jarvis_keeps_running"),
    # An updated private brief never reaches a successor.
    ("brief replacement", SESSION, 'record["private_brief"] = private',
     'record["private_brief"] = record.get("private_brief")',
     "test_a_context_succession_keeps_the_account_and_retires_the_predecessor_after_its_proof"),
    # An adopted session's successor loses the seat its record was written without.
    ("seat", SESSION, "successor = dict(choice[\"successor\"], window=SESSION_NAME, seat=SEAT)",
     "successor = dict(choice[\"successor\"], window=SESSION_NAME)",
     "test_an_adopted_session_is_handed_to_a_managed_successor_on_the_private_server"),
    # The adopted session's successor opens on the person's own server.
    ("adopted server", SESSION, 'return self._hand_over(record, "context", self.server(args.harness))',
     'return self._hand_over(record, "context", caller_socket)',
     "test_an_adopted_session_is_handed_to_a_managed_successor_on_the_private_server"),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", help="Prove only the planted defects for this named test case")
    args = parser.parse_args()
    defects = [row for row in DEFECTS if not args.case or row[4] == args.case]
    if not defects:
        parser.error("no planted defect for case " + args.case)
    with native_launcher() as native, tempfile.TemporaryDirectory() as allocation:
        skills = Path(allocation).resolve() / "skills"
        for package in ("jarvis", "orch", "mailbox"):
            shutil.copytree(ROOT / "skills" / package / "scripts", skills / package / "scripts")
        # The runtimes' sources key their built binaries.
        (skills / "agent-runtime").symlink_to(ROOT / "skills/agent-runtime", target_is_directory=True)
        (skills / "orch/runtime").symlink_to(ROOT / "skills/orch/runtime", target_is_directory=True)
        shutil.copytree(ROOT / "skills/jarvis/tests", skills / "jarvis/tests", ignore=shutil.ignore_patterns("__pycache__"))
        env = os.environ | {"JARVIS_TEST_SKILLS": str(skills), "JARVIS_TEST_NATIVE": str(native),
                            "JARVIS_TEST_SCRIPT": str(skills / "jarvis/scripts/jarvis-session")}
        for name, relative, old, new, case in defects:
            path = skills / relative
            original = path.read_text()
            assert original.count(old) == 1, name
            path.write_text(original.replace(old, new))
            try:
                result = subprocess.run([os.environ["JARVIS_TEST_BASH"], str(skills / "jarvis/tests/succession.test.sh"),
                                         "--failfast", "SuccessionContract." + case],
                                        env=env, capture_output=True, text=True, timeout=600)
            finally:
                path.write_text(original)
            assert result.returncode != 0, name + " passed its planted defect"
            assert "FAILED (failures=" in result.stderr, name + "\n" + result.stdout + result.stderr
            print("control: rejected=" + name + " case=" + case, flush=True)
        print("pass: " + str(len(defects)) + " fail: 0")


if __name__ == "__main__":
    main()
