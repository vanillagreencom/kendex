"""Plant one defect in an owned, disposable source copy, never this tree."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from fixtures.harness import native_launcher


ROOT = Path(__file__).resolve().parents[3]
# The instrument is session_test.py: one control proves it goes red. Without
# the name check, Start acts on a foreign tmux session named jarvis.
CONTROLS = (("name ownership", "jarvis/scripts/lib/session.py", 'if existing.returncode == 0:', 'if False:',
             "test_unrelated_session_conflicts"),
            ("manager policy", "jarvis/scripts/lib/session.py", 'if policy:', 'if policy and False:',
             "test_manager_policy_reaches_native_and_source_failure_keeps_owner"))


def run_case(skills, env, test, *flags):
    return subprocess.run([os.environ["JARVIS_TEST_BASH"], str(skills / "jarvis/tests/session.test.sh"), *flags,
                           "SessionContract." + test], env=env, capture_output=True, text=True, timeout=90)


def main():
    with native_launcher() as native, tempfile.TemporaryDirectory() as allocation:
        skills = Path(allocation).resolve() / "skills"
        for package in ("jarvis", "orch", "mailbox"):
            shutil.copytree(ROOT / "skills" / package / "scripts", skills / package / "scripts")
        shutil.copytree(ROOT / "skills/jarvis/tests", skills / "jarvis/tests", ignore=shutil.ignore_patterns("__pycache__"))
        env = os.environ | {"JARVIS_TEST_SKILLS": str(skills), "JARVIS_TEST_NATIVE": str(native),
                            "JARVIS_TEST_SCRIPT": str(skills / "jarvis/scripts/jarvis-session")}
        for name, relative, old, new, test in CONTROLS:
            baseline = run_case(skills, env, test)
            assert baseline.returncode == 0, "clean case failed: " + test + "\n" + baseline.stdout + baseline.stderr
            path = skills / relative
            original = path.read_text()
            assert original.count(old) == 1, name
            mutant = original.replace(old, new)
            assert mutant != original
            path.write_text(mutant)
            try:
                result = run_case(skills, env, test, "--failfast")
                assert result.returncode != 0, name + " passed its planted defect"
                # Distinguish a red assertion from fixture/command failure.
                assert "FAILED (failures=" in result.stderr, result.stdout + result.stderr
                print("control: rejected=" + name, flush=True)
            finally:
                path.write_text(original)
    print(f"pass: {len(CONTROLS)} fail: 0")


if __name__ == "__main__":
    main()
