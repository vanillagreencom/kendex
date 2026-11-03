"""Plant one defect in an owned, disposable source copy, never this tree."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from fixtures.harness import native_launcher


ROOT = Path(__file__).resolve().parents[3]
SESSION = "jarvis/scripts/lib/session.py"
# The instrument is session_test.py: each control proves its case goes red.
CONTROLS = (
    # Without the name check, Start acts on a foreign tmux session named jarvis.
    ("name ownership", SESSION, 'if existing.returncode == 0:', 'if False:', "test_unrelated_session_conflicts"),
    ("manager policy", SESSION, 'if policy:', 'if policy and False:',
     "test_manager_policy_reaches_native_and_source_failure_keeps_owner"),
    ("private pane transport", SESSION,
     'yield shlex.join([sys.executable, "-B", "-X", "utf8", "-c", receiver, address])',
     'yield shlex.join([sys.executable, "-B", "-X", "utf8", "-c", receiver, address]) + " " + shlex.quote(self.env.get("HTTPS_PROXY", ""))',
     "test_manager_policy_reaches_native_and_source_failure_keeps_owner"),
    ("native pane terminal", SESSION, "('TERM', 'TMUX', 'TMUX_PANE')", "('TMUX', 'TMUX_PANE')",
     "test_manager_policy_reaches_native_and_source_failure_keeps_owner"),
    # Attach outside tmux execs a client on the recorded socket and session.
    ("attach line", SESSION, '"attach-session", "-t", target])', '"attach-session", "-t", target + "-"])',
     "test_attach_outside_tmux"),
    # Inside tmux, the outside route would nest a client in the caller's pane.
    ("no nesting", SESSION, 'if not os.environ.get("TMUX"):\n            sys.stderr.flush()',
     'if True:\n            sys.stderr.flush()', "test_attach_inside_tmux"),
    # display-message falls back to another terminal's client.
    ("pane client", SESSION, '"list-clients", "-t", pane, "-F", "#{client_name}"',
     '"display-message", "-p", "-t", pane, "#{client_name}"', "test_attach_moves_only_the_pane_client"),
    ("no controller", SESSION, 'if not terminal:\n            raise Refusal("no-controller")',
     'if False:\n            raise Refusal("no-controller")', "test_attach_refuses_without_a_controller"),
)


def run_case(skills, env, test, *flags):
    return subprocess.run([os.environ["JARVIS_TEST_BASH"], str(skills / "jarvis/tests/session.test.sh"), *flags,
                           *("SessionContract." + name for name in test)], env=env, capture_output=True, text=True,
                          timeout=90 * len(test))


def main():
    with native_launcher() as native, tempfile.TemporaryDirectory() as allocation:
        skills = Path(allocation).resolve() / "skills"
        for package in ("jarvis", "orch", "mailbox"):
            shutil.copytree(ROOT / "skills" / package / "scripts", skills / package / "scripts")
        shutil.copytree(ROOT / "skills/jarvis/tests", skills / "jarvis/tests", ignore=shutil.ignore_patterns("__pycache__"))
        env = os.environ | {"JARVIS_TEST_SKILLS": str(skills), "JARVIS_TEST_NATIVE": str(native),
                            "JARVIS_TEST_SCRIPT": str(skills / "jarvis/scripts/jarvis-session")}
        baseline = run_case(skills, env, list(dict.fromkeys(test for *_, test in CONTROLS)))
        assert baseline.returncode == 0, "clean cases failed\n" + baseline.stdout + baseline.stderr
        for name, relative, old, new, test in CONTROLS:
            path = skills / relative
            original = path.read_text()
            assert original.count(old) == 1, name
            mutant = original.replace(old, new)
            assert mutant != original
            path.write_text(mutant)
            try:
                result = run_case(skills, env, [test], "--failfast")
            finally:
                path.write_text(original)
            assert result.returncode != 0, name + " passed its planted defect"
            # The test runner's outcome distinguishes a red assertion from
            # an import, fixture setup or command-launch failure.
            assert "FAILED (failures=" in result.stderr, name + "\n" + result.stdout + result.stderr
            print("control: rejected=" + name, flush=True)
        print("pass: " + str(len(CONTROLS)) + " fail: 0")


if __name__ == "__main__":
    main()
