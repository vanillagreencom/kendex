"""Plant one defect in an owned, disposable source copy, never this tree."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from fixtures.harness import native_launcher


ROOT = Path(__file__).resolve().parents[3]
SESSION = "jarvis/scripts/lib/session.py"
BACKEND = "jarvis/scripts/lib/session-backend.sh"
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
    # A respawned first-launch pane is a second pane process, not the created one.
    ("launch respawn", SESSION, 'self.tmux("wait-for", "-S", channel)',
     'with self.pane_command([BASH, "--noprofile", "--norc", "-c", prepared["line"]]) as command:\n'
     '                        self.tmux("respawn-pane", "-k", "-t", pane, "-c", self.home, command)',
     "test_first_launch_runs_in_its_created_pane"),
    # Attach outside tmux execs a client on the recorded socket and session.
    ("attach line", SESSION, '"attach-session", "-t", "=" + terminal["session"]]',
     '"attach-session", "-t", "=" + terminal["session"] + "-"]', "test_attach_outside_tmux"),
    # Inside tmux, the outside route would nest a client in the caller's pane.
    ("terminal window", SESSION, 'if os.environ.get("TMUX"):', 'if False:', "test_attach_opens_a_terminal_window"),
    # xdg-terminal-exec takes its command bare, not after -e.
    ("desktop terminal", BACKEND, 'launch=(xdg-terminal-exec bash -lc "$line")',
     'launch=(xdg-terminal-exec -e bash -lc "$line")', "test_attach_opens_a_terminal_window"),
    # A $TERMINAL naming nothing is replaced by xdg-terminal-exec in silence.
    ("fallback notice", BACKEND, '[[ -z "${TERMINAL:-}" || "${launch[0]}" == "$TERMINAL" ]] ||', 'true ||',
     "test_attach_opens_a_terminal_window"),
    # No terminal at all reads as a refusal instead of the nested attach.
    ("no terminal", BACKEND, 'else\n      exit 3\n', 'else\n      exit 4\n', "test_attach_nests_without_a_terminal"),
    # A terminal that failed to open falls back to the nested attach.
    ("launch failure", SESSION, 'if opened.returncode not in (0, 3):', 'if opened.returncode not in (0, 3, 5):',
     "test_attach_refuses_a_terminal_that_does_not_open"),
    # A launcher that exits 0 counts as an opened window.
    ("client proof", BACKEND, "client=none seconds=5\\n' \"${launch[0]}\" >&2\n    exit 5",
     "client=none seconds=5\\n' \"${launch[0]}\" >&2\n    exit 0", "test_attach_refuses_a_terminal_that_does_not_open"),
    # A client already on the session counts as the new window's.
    ("existing client", BACKEND, "[[ $'\\n'\"$before\"$'\\n' == *$'\\n'\"$pid\"$'\\n'* ]] || exit 0", "exit 0",
     "test_attach_refuses_a_terminal_that_does_not_open"),
    # A terminal's non-zero exit hides the terminal's own reason.
    ("terminal reason", BACKEND, 'tail -n 5 -- "$errors" >&2', ':', "test_attach_refuses_a_terminal_that_does_not_open"),
    # An unresolvable $TERMINAL reads as no terminal.
    ("unresolved terminal", BACKEND, 'exit 4\n    else', 'exit 3\n    else',
     "test_attach_refuses_a_terminal_that_does_not_open"),
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
        for package in ("jarvis", "orch", "mailbox", "github"):
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
