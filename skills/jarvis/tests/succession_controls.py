"""Reject a removed process identity check in a disposable source copy."""
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
        # One planted defect proves succession_test.py goes red: without the
        # identity check, succession stops a process the record does not own.
        name, relative, old, new, case = ("process identity", "jarvis/scripts/lib/session-backend.sh",
                                          '    lane_stop_identity "$1" "$2" "$3" || rc=$?',
                                          '    lane_stop_identity "$1" "$(lane_process_start "$1")" "$3" || rc=$?',
                                          "test_succession_identity")
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
