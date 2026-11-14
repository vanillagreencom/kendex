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
    # Without the home's own server named, a start opens nothing anywhere.
    ("private server", SESSION, '"--mail-root", self.home, "--socket", socket]', '"--mail-root", self.home]',
     "test_start_status_stop_and_resume_on_the_controller_record"),
    # A record that still names a pane is no live controller once its harness died.
    ("running is live", SESSION, 'if not (status or {}).get("live") or not socket or not pane:',
     "if not socket or not pane:", "test_start_status_stop_and_resume_on_the_controller_record"),
    # Without the seat on its start, the turn end hands Jarvis orch's succession.
    ("seat", SESSION, "self.detach(dict(pending, window=SESSION_NAME, seat=SEAT), socket, start_brief(private))",
     "self.detach(dict(pending, window=SESSION_NAME), socket, start_brief(private))",
     "test_start_status_stop_and_resume_on_the_controller_record"),
    # A resume Start opens a new native session.
    ("resume", SESSION, 'resumable = (args.mode == "resume"', 'resumable = (False',
     "test_start_status_stop_and_resume_on_the_controller_record"),
    # A sign-in failure reads as a launch failure, with nothing to do.
    ("sign-in", SESSION, 'BLOCKED_NOTES = {"successor-not-signed-in": "sign-in-required",',
     'BLOCKED_NOTES = {"successor-not-signed-in-unread": "sign-in-required",',
     "test_a_start_whose_account_cannot_sign_in_asks_for_the_sign_in"),
    # Off no longer holds a Start.
    ("app-off", SESSION, '            if record.get("app_off"):\n                self.write(record)',
     '            if False:\n                self.write(record)',
     "test_app_off_blocks_starts_and_a_repeated_boot_never_relaunches"),
    # The same boot starts the session again.
    ("boot", SESSION, 'if boot and record and record.get("boot") == boot:', "if False:",
     "test_app_off_blocks_starts_and_a_repeated_boot_never_relaunches"),
    # A released record is read as a controller's.
    ("record form", SESSION, 'record.get("v") != 2', 'record.get("v") not in (1, 2)',
     "test_a_record_of_another_form_is_unreadable"),
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
                          timeout=180 * len(test))


def main():
    with native_launcher() as native, tempfile.TemporaryDirectory() as allocation:
        skills = Path(allocation).resolve() / "skills"
        for package in ("jarvis", "orch", "mailbox", "github"):
            shutil.copytree(ROOT / "skills" / package / "scripts", skills / package / "scripts")
        # The runtimes' sources key their built binaries.
        (skills / "agent-runtime").symlink_to(ROOT / "skills/agent-runtime", target_is_directory=True)
        (skills / "orch/runtime").symlink_to(ROOT / "skills/orch/runtime", target_is_directory=True)
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
