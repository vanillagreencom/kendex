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
CONTROL = ("name ownership", "jarvis/scripts/lib/session.py", 'if existing.returncode == 0:', 'if False:',
           "test_unrelated_session_conflicts")


def run_case(skills, env, test, *flags):
    return subprocess.run([os.environ["JARVIS_TEST_BASH"], str(skills / "jarvis/tests/session.test.sh"), *flags,
                           "SessionContract." + test], env=env, capture_output=True, text=True, timeout=90)


def main():
    name, relative, old, new, test = CONTROL
    with native_launcher() as native, tempfile.TemporaryDirectory() as allocation:
        skills = Path(allocation).resolve() / "skills"
        for package in ("jarvis", "orch", "mailbox"):
            shutil.copytree(ROOT / "skills" / package / "scripts", skills / package / "scripts")
        shutil.copytree(ROOT / "skills/jarvis/tests", skills / "jarvis/tests", ignore=shutil.ignore_patterns("__pycache__"))
        env = os.environ | {"JARVIS_TEST_SKILLS": str(skills), "JARVIS_TEST_NATIVE": str(native),
                            "JARVIS_TEST_SCRIPT": str(skills / "jarvis/scripts/jarvis-session")}
        baseline = run_case(skills, env, test)
        assert baseline.returncode == 0, "clean case failed: " + test + "\n" + baseline.stdout + baseline.stderr
        path = skills / relative
        original = path.read_text()
        assert original.count(old) == 1, name
        mutant = original.replace(old, new)
        assert mutant != original
        path.write_text(mutant)
        result = run_case(skills, env, test, "--failfast")
        assert result.returncode != 0, name + " passed its planted defect"
        # The test runner's outcome distinguishes a red assertion from
        # an import, fixture setup or command-launch failure.
        assert "FAILED (failures=" in result.stderr, result.stdout + result.stderr
        print("control: rejected=" + name, flush=True)
    print("pass: 1 fail: 0")


if __name__ == "__main__":
    main()
