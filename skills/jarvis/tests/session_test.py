"""Contract rows use real tmux and the real identity carrier, with CLI fixtures."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout, redirect_stderr
import io
import errno
import fcntl
import runpy
from unittest.mock import patch
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import signal
import socket
import struct
import termios
import threading
from fixtures.harness import AUTH_MESSAGES, launch_prompt, main as harness_main, native_header, native_launcher
import shlex
import subprocess
import sys
import tempfile
import time
import traceback
import unittest


ROOT = Path(__file__).resolve().parents[3]
SKILLS = Path(os.environ.get("JARVIS_TEST_SKILLS", ROOT / "skills"))
SCRIPT = Path(os.environ.get("JARVIS_TEST_SCRIPT", SKILLS / "jarvis/scripts/jarvis-session"))
HARNESS_SCRIPT = Path(__file__).with_name("fixtures") / "harness.py"
# Independent VGS-1439 consumer contract. Each planted malformed answer below
# must fail this validator, rather than depending on the producer's table.
REASONS = {
    "running": {"resumed", "new-no-record", "new-history-gone", "new-selection-changed", "new-requested", "existing"},
    "starting": {"launching"}, "handing-over": {"succession"}, "stopping": {"stop-requested"},
    "stopped": {"never-started", "stopped", "ended"}, "off": {"app-off"},
    "blocked": {"app-off", "name-conflict", "record-unreadable", "sign-in-required", "selection-conflict", "tmux-missing", "app-missing",
                "trust-required", "home-not-dedicated"},
    "failed": {"launch-failed", "handover-failed"},
}
# The full-bypass words each harness's CLI takes for an unattended launch.
# Pi has none.
PERMISSION_WORDS = {"claude": {"--dangerously-skip-permissions"}, "codex": {"--dangerously-bypass-approvals-and-sandbox"},
                    "copilot": {"--allow-all"}, "pi": set()}
ANY_PERMISSION_WORD = set().union(*PERMISSION_WORDS.values())
# A blocked answer whose detail tells the person what to do.
DETAILED = {("blocked", "sign-in-required"), ("blocked", "trust-required"), ("blocked", "home-not-dedicated")}


def validate(output, code, verb, duplicate_boot=False, adopt=False):
    lines = output.splitlines()
    assert len(lines) == 1
    answer = json.loads(lines[0])
    assert set(answer) == {"v", "state", "reason", "home", "harness", "account", "origin", "boot", "terminal", "detail"}
    assert answer["v"] == 1 and answer["reason"] in REASONS[answer["state"]]
    for field in ("home", "harness", "account", "origin", "boot"):
        assert answer[field] is None or isinstance(answer[field], str) and all(c.isprintable() for c in answer[field])
    assert answer["harness"] in (None, "claude", "codex", "copilot", "pi")
    assert answer["origin"] in (None, "boot", "manual", "app-on")
    assert isinstance(answer["detail"], str) and len(answer["detail"]) <= 200
    assert all(c.isprintable() for c in answer["detail"])
    if answer["state"] == "failed" or (answer["state"], answer["reason"]) in DETAILED:
        assert answer["detail"]
    else:
        assert answer["detail"] == ""
    if answer["terminal"] is not None:
        assert set(answer["terminal"]) == {"server", "session", "window", "pane"}
        assert all(isinstance(v, str) and v and all(c.isprintable() for c in v) for v in answer["terminal"].values())
    if verb == "status":
        assert code == 0
    elif code == 1:
        assert answer["state"] in ("blocked", "failed")
    else:
        assert code == 0
        if verb == "start" and adopt:
            # An adopting Start answers the succession it begins.
            assert (answer["state"], answer["reason"]) == ("handing-over", "succession")
        elif verb == "start" and not duplicate_boot:
            assert answer["state"] in ("running", "starting")
        elif verb == "stop":
            assert answer["state"] in ("off", "stopped", "stopping")
    return answer


class SessionLogContract(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.root),
                    "XDG_STATE_HOME": str(self.root / "state"),
                    "JARVIS_BASH": os.environ["JARVIS_TEST_BASH"]}
        self.source = SKILLS / "jarvis/scripts/lib/session.py"
        with patch.dict(os.environ, self.env, clear=True):
            self.runtime = runpy.run_path(str(self.source))
            self.session = self.runtime["Session"](self.home, self.env)
        self.session.path.parent.mkdir(parents=True)
        self.log = self.session.path.with_name("session.log")

    @staticmethod
    def reap(child):
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)

    def test_session_log_stream_lines(self):
        # print and traceback split a line over writes; a flush may have no NL.
        stamp = time.struct_time((2026, 11, 8, 3, 40, 0, 6, 312, 0))
        with patch.object(self.runtime["time"], "gmtime", return_value=stamp) as clock, \
                self.runtime["SessionLog"](self.log.open("a", encoding="utf-8"), "manual") as stream, \
                redirect_stdout(stream), redirect_stderr(stream):
            print("stdout é")
            self.assertEqual(sys.stderr.write("fragment"), len("fragment"))
            self.assertEqual(sys.stderr.write("ed\nsecond\n\n"), len("ed\nsecond\n\n"))
            clock.return_value = time.struct_time((2026, 11, 8, 3, 41, 0, 6, 312, 0))
            sys.stdout.write("flushed tail")
            sys.stdout.flush()
            print("after flush")
            sys.stderr.write("closed tail")
        self.assertEqual(self.log.read_text().splitlines(), [
            "2026-11-08T03:40:00Z origin=manual stdout é",
            "2026-11-08T03:40:00Z origin=manual fragmented",
            "2026-11-08T03:40:00Z origin=manual second",
            "2026-11-08T03:40:00Z origin=manual ",
            "2026-11-08T03:41:00Z origin=manual flushed tail",
            "2026-11-08T03:41:00Z origin=manual after flush",
            "2026-11-08T03:41:00Z origin=manual closed tail"])

    def test_worker_session_log_lines(self):
        rows = (("start", "manual", None, "manual"), ("start", "boot", None, "boot"),
                ("start", "app-on", None, "app-on"), ("start", "watch-loop", None, "watch-loop"),
                ("succeed", "boot", None, "succession"), ("stop", "app-on", None, "manual"),
                ("stop", "app-on", "app-off", "app-off"), ("successor", "boot", None, "succession"))
        for verb, recorded, requested, origin in rows:
            with self.subTest(verb=verb, origin=origin):
                log = self.log
                if verb == "stop":
                    fixture = SessionContract()
                    fixture.setUp()
                    self.addCleanup(lambda fixture=fixture: self.assertTrue(fixture.doCleanups()))
                    self.addCleanup(fixture.tearDown)
                    fixture.call("start", origin=recorded, own_worker=True)
                    fixture.wait()
                    self.assertEqual(fixture.owned_workers[-1].wait(timeout=15), 0)
                    self.assertEqual(json.loads(fixture.record.read_text())["origin"], recorded)
                    log = fixture.record.with_name("session.log")
                    log.unlink(missing_ok=True)
                    fixture.refuse_teardown()
                    answer, code = fixture.call("stop", origin=requested, own_worker=True)
                    self.assertEqual((answer["state"], answer["origin"], code), ("stopping", recorded, 0))
                    self.assertNotEqual(fixture.owned_workers[-1].wait(timeout=15), 0)
                    self.assertEqual(json.loads(fixture.record.read_text())["origin"], recorded)
                else:
                    # An unreadable record is a real worker failure producer. Its
                    # diagnostic precedes the cleanup read's uncaught Refusal.
                    record = dict(v=1, home=str(self.home), origin=recorded, generation=1,
                                  state="invalid", reason="invalid")
                    self.session.write(record)
                    log.unlink(missing_ok=True)
                if verb == "successor":
                    driver = ("import os,runpy,sys; runtime=runpy.run_path(sys.argv[1]); "
                              "runtime['Session'](sys.argv[2], dict(os.environ)).successor(1)")
                    result = subprocess.run([sys.executable, "-B", "-c", driver, str(self.source), str(self.home)],
                                            env=self.env, capture_output=True, text=True, timeout=15)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout + result.stderr, "")
                elif verb != "stop":
                    children = []
                    real_popen = subprocess.Popen
                    def observe(*args, **kwargs):
                        child = real_popen(*args, **kwargs)
                        if kwargs.get("start_new_session"):
                            children.append(child)
                            self.addCleanup(self.reap, child)
                        return child
                    with patch.object(subprocess, "Popen", observe), self.session.locked():
                        self.session.detach(verb, record, origin=requested)
                    self.assertEqual(len(children), 1)
                    self.assertNotEqual(children[0].wait(timeout=15), 0)
                lines = log.read_text().splitlines()
                self.assertGreater(len(lines), 1)
                prefix = r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z origin=" + origin + " "
                for line in lines:
                    self.assertRegex(line, prefix)
                bodies = [re.sub(prefix, "", line) for line in lines]
                self.assertIn("Traceback (most recent call last):", bodies)
                self.assertRegex(bodies[-1], r"(?:^|\.)Refusal(?::|$)")
                if verb != "successor":
                    self.assertRegex("\n".join(bodies), r"(?:^|\n)jarvis-session: worker-failed .* cause=Refusal ")

    def test_worker_session_log_raw_stream_control(self):
        skills = self.root / "control/skills"
        scripts = skills / "jarvis/scripts"
        shutil.copytree(SKILLS / "jarvis/scripts", scripts)
        for dependency in ("mailbox", "orch", "github"):
            (skills / dependency).symlink_to(SKILLS / dependency, target_is_directory=True)
        source = scripts / "lib/session.py"
        self.assertFalse(source.is_symlink())
        before = source.read_text()
        old = "sys.stdout = sys.stderr = SessionLog(stream, origin)"
        self.assertEqual(before.count(old), 1)
        after = before.replace(old, "sys.stdout = sys.stderr = stream")
        self.assertNotEqual(before, after)
        source.write_text(after)
        result = subprocess.run([str(ROOT / "skills/jarvis/tests/session.test.sh"),
                                 "SessionLogContract.test_worker_session_log_lines", "--failfast"],
                                env=os.environ | {"JARVIS_TEST_SKILLS": str(skills)},
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("self.assertRegex(line, prefix)", result.stderr)


class BootReceiptScenario:
    # The specified receipt producer owns applicability for its contract rows.
    applicable = Path("/proc/sys/kernel/random/boot_id").is_file()


class MainHostContract(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        # This settings-only consumer inherits transport lookup, not the
        # calling session's credentials, role or selected private path.
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.root),
                    "XDG_STATE_HOME": str(self.root / "state")}

    def command(self, *words, code=0):
        result = subprocess.run([str(SCRIPT), *words, "--home", str(self.home)],
                                env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, code, result.stderr)
        return result

    def value(self, *words):
        # Consumer apps parse only this named setting, never the secret file.
        answer = json.loads(self.command("main-host", *words).stdout)
        self.assertEqual(set(answer), {"JARVIS_MAIN_HOST"})
        return answer["JARVIS_MAIN_HOST"]

    def test_main_host_private_file_contract(self):
        original = (b"# fixture private settings\r\nSECRET='first line\n"
                    b"JARVIS_MAIN_HOST=literal-secret-text\nlast line'\n"
                    b"export OTHER_SECRET='keep these bytes'\nJARVIS_MAIN_HOST='old:/home/old'")
        rows = (("default", None, None), ("configured", "private/role.env", None),
                ("override", "unused.env", "nested/selected.env"), ("linked", None, None))
        for name, configured, inherited in rows:
            with self.subTest(name=name):
                self.home = self.root / name
                self.home.mkdir()
                if configured:
                    (self.home / "kendex.settings.toml").write_text('[env]\nKENDEX_ENV_FILE = "' + configured + '"\n')
                self.env.pop("KENDEX_ENV_FILE", None)
                if inherited:
                    self.env["KENDEX_ENV_FILE"] = inherited
                private = self.home / (inherited or configured or ".env.local")
                private.parent.mkdir(parents=True, exist_ok=True)
                if name == "linked":
                    target = self.root / "shared-private.env"
                    private.symlink_to(target)
                private.write_bytes(original)
                private.chmod(0o640)
                self.assertEqual(self.value("--get"), "old:/home/old")
                sentinel = self.root / "evaluated"
                literal = "host:/home/O'Neil $USER `id` $(touch " + str(sentinel) + ")"
                for words, expected in ((("--set", literal), literal), (("--set", "next:/main"), "next:/main"),
                                        (("--clear",), ""), (("--clear",), "")):
                    self.assertEqual(self.value(*words), expected)
                    self.assertEqual(self.value("--get"), expected)
                    # Independently compare the complete pre-existing bytes
                    # and mode; a multiline secret is not an assignment list.
                    self.assertEqual(private.read_bytes()[:len(original)], original)
                    self.assertEqual(private.stat().st_mode & 0o777, 0o640)
                    status = json.loads(self.command("status", "--main").stdout)
                    self.assertEqual(status["role"], "satellite" if expected else "main")
                    if expected:
                        self.assertEqual(status["main"], expected.partition(":")[0])
                    self.assertFalse(sentinel.exists())
                self.assertEqual(private.is_symlink(), name == "linked")
                if inherited:
                    self.assertFalse((self.home / configured).exists())

    def test_main_host_preservation_control(self):
        skills = self.root / "control/skills"
        scripts = skills / "jarvis/scripts"
        shutil.copytree(SKILLS / "jarvis/scripts", scripts)
        for dependency in ("mailbox", "orch"):
            (skills / dependency).symlink_to(SKILLS / dependency, target_is_directory=True)
        source = scripts / "lib/session.py"
        self.assertFalse(source.is_symlink())
        before = source.read_text()
        match = "os.O_WRONLY | os.O_APPEND | os.O_CREAT"
        self.assertEqual(before.count(match), 1)
        after = before.replace(match, "os.O_WRONLY | os.O_TRUNC | os.O_CREAT")
        self.assertNotEqual(after, before)
        source.write_text(after)
        # The nested suite retains its installed compiler environment; its
        # settings cases select only their own fixture homes and environment.
        result = subprocess.run([str(ROOT / "skills/jarvis/tests/session.test.sh"),
                                 "MainHostContract.test_main_host_private_file_contract", "-v"],
                                env=os.environ | {"JARVIS_TEST_SCRIPT": str(scripts / "jarvis-session")},
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("self.assertEqual(private.read_bytes()[:len(original)], original)", result.stderr)

    def test_main_host_initialization_and_precedence(self):
        self.env["KENDEX_ENV_FILE"] = "private/new.env"
        private = self.home / "private/new.env"
        self.assertEqual(self.value("--get"), "")
        self.assertFalse(private.exists())
        self.assertEqual(self.value("--set", "saved:/main"), "saved:/main")
        self.assertEqual(private.stat().st_mode & 0o777, 0o600)
        self.env["JARVIS_MAIN_HOST"] = "caller:/main"
        self.assertEqual(self.value("--get"), "caller:/main")
        self.assertEqual(self.value("--clear"), "")
        self.assertEqual(self.value("--get"), "caller:/main")
        self.env.pop("JARVIS_MAIN_HOST")
        self.assertEqual(self.value("--get"), "")
        (self.home / "kendex.settings.toml").write_text('[env]\nJARVIS_MAIN_HOST = "shared:/main"\n')
        self.assertEqual(self.value("--get"), "")

    def test_main_host_refusals_do_not_mutate(self):
        private = self.home / ".env.local"
        original = b"SECRET='keep me'\n"
        private.write_bytes(original)
        private.chmod(0o640)
        for value in ("host", "-host:/main", "host:relative", "host name:/main", "host:/main\nother"):
            with self.subTest(value=value):
                result = self.command("main-host", "--set=" + value, code=2)
                self.assertEqual(result.stdout, "")
                self.assertIn("main-host=refused cause=setting-invalid", result.stderr)
                self.assertEqual(private.read_bytes(), original)
                self.assertEqual(private.stat().st_mode & 0o777, 0o640)
        for words in ((), ("--get", "--clear"), ("--set", "host:/main", "--clear")):
            with self.subTest(words=words):
                self.assertEqual(self.command("main-host", *words, code=2).stdout, "")
                self.assertEqual(private.read_bytes(), original)
        # The shared resolver, rather than a parallel path validator, refuses
        # paths outside the selected home. Loader output may contain secrets.
        self.env["KENDEX_ENV_FILE"] = "../outside.env"
        result = self.command("main-host", "--set", "host:/main", code=2)
        self.assertIn("main-host=refused cause=settings-unreadable", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(private.read_bytes(), original)
        self.env.pop("KENDEX_ENV_FILE")
        private.write_bytes(original + b"echo private-secret >&2\nreturn 1\n")
        result = self.command("main-host", "--get", code=2)
        self.assertNotIn("private-secret", result.stderr + result.stdout)

    def ignored(self):
        return subprocess.run(["git", "check-ignore", "-q", ".env.local"], cwd=self.home,
                              env=self.env, capture_output=True).returncode == 0

    def test_main_host_set_ignores_new_private_file(self):
        # A credential save's rule: a new private file gets its exact ignore line.
        subprocess.run(["git", "init", "-q"], cwd=self.home, env=self.env, check=True)
        (self.home / ".gitignore").write_text("/tmp/")
        self.assertFalse(self.ignored())
        self.assertEqual(self.value("--set", "host:/main"), "host:/main")
        self.assertTrue(self.ignored())
        self.assertEqual((self.home / ".gitignore").read_text(), "/tmp/\n/.env.local\n")

    def test_main_host_set_refuses_unignored_private_file(self):
        # An existing unignored private file is the person's: refuse, write nothing.
        subprocess.run(["git", "init", "-q"], cwd=self.home, env=self.env, check=True)
        private = self.home / ".env.local"
        private.write_bytes(b"SECRET='keep me'\n")
        result = self.command("main-host", "--set", "host:/main", code=2)
        self.assertEqual(result.stdout, "")
        self.assertIn("main-host=refused cause=private-file-unignored", result.stderr)
        self.assertIn("fix: add /.env.local to .gitignore, then run main-host again", result.stderr)
        self.assertEqual(private.read_bytes(), b"SECRET='keep me'\n")
        self.assertFalse((self.home / ".gitignore").exists())

    def test_main_host_set_refuses_when_ignore_line_has_no_effect(self):
        # A deeper .gitignore re-includes the file: git is asked again after
        # the line lands, and the private file is never written.
        subprocess.run(["git", "init", "-q"], cwd=self.home, env=self.env, check=True)
        (self.home / "kendex.settings.toml").write_text('[env]\nKENDEX_ENV_FILE = "keys/private.env"\n')
        (self.home / "keys").mkdir()
        (self.home / "keys" / ".gitignore").write_text("!private.env\n")
        result = self.command("main-host", "--set", "host:/main", code=2)
        self.assertEqual(result.stdout, "")
        self.assertIn("main-host=refused cause=private-file-unignored", result.stderr)
        self.assertIn("jarvis-session: fix: ", result.stderr)
        self.assertFalse((self.home / ".gitignore").exists())
        self.assertFalse((self.home / "keys" / "private.env").exists())


    def test_main_host_set_refuses_dangling_gitdir(self):
        (self.home / ".git").write_text("gitdir: " + str(self.root / "gone") + "\n")
        result = self.command("main-host", "--set", "host:/main", code=2)
        self.assertEqual(result.stdout, "")
        self.assertIn("main-host=refused cause=git-unreadable\n", result.stderr)
        self.assertFalse((self.home / ".env.local").exists())
        self.assertFalse((self.home / ".gitignore").exists())

    def test_main_host_linked_private_git_contract(self):
        rows = (("tracked", "private-file-tracked"), ("unignored", "private-file-unignored"),
                ("ignored", None), ("outside-repository", None))
        for name, cause in rows:
            with self.subTest(name=name):
                self.home = self.root / name
                self.home.mkdir()
                subprocess.run(["git", "init", "-q"], cwd=self.home, env=self.env, check=True)
                (self.home / ".gitignore").write_text("/.env.local\n")
                target = self.root / (name + "-target") / "shared.env"
                target.parent.mkdir()
                original = b"SECRET='keep me'\n"
                target.write_bytes(original)
                if name != "outside-repository":
                    subprocess.run(["git", "init", "-q"], cwd=target.parent, env=self.env, check=True)
                if name == "tracked":
                    subprocess.run(["git", "add", "shared.env"], cwd=target.parent, env=self.env, check=True)
                elif name == "ignored":
                    (target.parent / ".gitignore").write_text("/shared.env\n")
                private = self.home / ".env.local"
                private.symlink_to(target)
                for words, expected in ((("--set", "host:/main"), "host:/main"), (("--clear",), "")):
                    if cause is None:
                        self.assertEqual(self.value(*words), expected)
                        self.assertEqual(self.value("--get"), expected)
                        self.assertTrue(target.read_bytes().startswith(original))
                    else:
                        result = self.command("main-host", *words, code=2)
                        self.assertEqual(result.stdout, "")
                        self.assertIn("main-host=refused cause=" + cause + "\n", result.stderr)
                        self.assertEqual(target.read_bytes(), original)
                    self.assertTrue(private.is_symlink())

    def test_main_host_git_checks_ignore_inherited_redirects(self):
        foreign = self.root / "foreign"
        foreign.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=foreign, env=self.env, check=True)
        (foreign / ".gitignore").write_text("/.env.local\n")
        redirects = {"GIT_DIR": str(foreign / ".git"), "GIT_COMMON_DIR": str(foreign / ".git"),
                     "GIT_WORK_TREE": str(foreign), "GIT_INDEX_FILE": str(foreign / ".git/index")}
        rows = (("index", {"GIT_INDEX_FILE": redirects["GIT_INDEX_FILE"]}), ("repository", redirects))
        for name, inherited in rows:
            with self.subTest(name=name):
                self.home = self.root / name
                self.home.mkdir()
                subprocess.run(["git", "init", "-q"], cwd=self.home, env=self.env, check=True)
                (self.home / ".gitignore").write_text("/.env.local\n")
                private = self.home / ".env.local"
                original = b"SECRET='keep me'\n"
                private.write_bytes(original)
                subprocess.run(["git", "add", "-f", ".env.local"], cwd=self.home, env=self.env, check=True)
                self.env.update(inherited)
                try:
                    result = self.command("main-host", "--set", "host:/main", code=2)
                finally:
                    for key in inherited:
                        self.env.pop(key)
                self.assertEqual(result.stdout, "")
                self.assertIn("main-host=refused cause=private-file-tracked\n", result.stderr)
                self.assertEqual(private.read_bytes(), original)

    def test_main_host_set_rolls_back_ineffective_ignore_append(self):
        rows = (("absent", None), ("existing", b"# existing rules\r\n/tmp/"))
        for name, original in rows:
            with self.subTest(name=name):
                self.home = self.root / name
                self.home.mkdir()
                subprocess.run(["git", "init", "-q"], cwd=self.home, env=self.env, check=True)
                (self.home / "kendex.settings.toml").write_text('[env]\nKENDEX_ENV_FILE = "keys/private.env"\n')
                (self.home / "keys").mkdir()
                (self.home / "keys/.gitignore").write_text("!private.env\n")
                ignore = self.home / ".gitignore"
                if original is not None:
                    ignore.write_bytes(original)
                for _ in range(2):
                    result = self.command("main-host", "--set", "host:/main", code=2)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("main-host=refused cause=private-file-unignored\n", result.stderr)
                    self.assertEqual(ignore.read_bytes() if ignore.exists() else None, original)
                    self.assertFalse((self.home / "keys/private.env").exists())


def scratch_base():
    """A scratch base outside every Git work tree: a home fixture there qualifies.

    A lane's TMPDIR can lie under its worktree's tmp/, as the comment above
    TEMP_BASE in skills/reviewer/scripts/mutation-stability records.
    """
    base = tempfile.gettempdir()
    env = {key: value for key, value in os.environ.items()
           if key not in {"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"}}
    found = subprocess.run(["git", "-c", "safe.directory=*", "-C", base, "rev-parse", "--show-toplevel"],
                           env=env, capture_output=True, text=True, timeout=30)
    return base if found.returncode == 128 else "/tmp"


# The fixture's Codex file, comment included: a merge keeps every other byte.
CODEX_FIXTURE = "# features this home turns on\n[features]\nhooks = true\n"


class HomeInitContract(unittest.TestCase):
    """jarvis-session init and the first manual Start write one set of starting files."""

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(dir=scratch_base())
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        # No tmux on this PATH: every Start refuses after its initialization
        # step, so a row reads that step's effect without a launch.
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for tool in ("bash", "git", "cat", "flock", "mkdir", "rmdir", "sleep", "rm"):
            found = shutil.which(tool)
            if found:
                (bin_dir / tool).symlink_to(found)
        (bin_dir / "python3").symlink_to(sys.executable)
        login = self.root / "login"
        login.mkdir()
        self.account = self.root / "account"
        self.account.mkdir()
        # git reads no caller repository: GIT_DIR and its siblings stay unset.
        self.env = {"PATH": str(bin_dir), "HOME": str(login), "XDG_STATE_HOME": str(self.root / "state"),
                    "XDG_CONFIG_HOME": str(login / ".config"), "GIT_CONFIG_NOSYSTEM": "1", "LANG": "C.UTF-8"}

    def git_init(self, folder):
        for words in (("init", "-q"), ("config", "gc.auto", "0"), ("config", "maintenance.auto", "false")):
            subprocess.run(["git", "-C", str(folder), *words], env=self.env, check=True, capture_output=True)

    def home(self, name, *, git=True):
        """A folder after git init and kendex add: its harness files beside the layout."""
        home = self.root / name
        (home / ".agents/skills").mkdir(parents=True)
        (home / ".claude").mkdir()
        (home / ".claude/settings.json").write_text('{\n  "hooks": {\n    "Stop": []\n  }\n}\n')
        (home / ".codex").mkdir()
        (home / ".codex/config.toml").write_text(CODEX_FIXTURE)
        (home / "kendex.toml").write_text("")
        (home / ".gitignore").write_text("/tmp/\n")
        if git:
            self.git_init(home)
        return home

    def snapshot(self, home):
        tree = {}
        for path in sorted(home.rglob("*")):
            relative = path.relative_to(home)
            if relative.parts[0] == ".git":
                continue
            tree[str(relative)] = ("link", os.readlink(path)) if path.is_symlink() else (
                ("dir",) if path.is_dir() else ("file", path.read_bytes()))
        return tree

    def run_init(self, home):
        return subprocess.run([str(SCRIPT), "init", "--home", str(home)], env=self.env,
                              capture_output=True, text=True, timeout=60)

    def start(self, home, *words):
        result = subprocess.run([str(SCRIPT), "start", "--home", str(home), "--harness", "claude",
                                 "--account", str(self.account), *words],
                                env=self.env, capture_output=True, text=True, timeout=60)
        return validate(result.stdout, result.returncode, "start"), result

    @staticmethod
    def keyed(line):
        # The init line is a program's read: a leading key, then key=value,
        # where a value with spaces is a JSON string.
        return dict(re.findall(r'(\S+?)=("(?:[^"\\]|\\.)*"|\S*)', line.split(" ", 1)[1]))

    def unreadable(self, repository):
        # A config line git cannot parse: every git version refuses to read
        # this repository with exit 128.
        with (repository / ".git/config").open("a") as config:
            config.write("[core\n")

    def record(self, home):
        key = hashlib.sha256(os.fsencode(str(home))).hexdigest()
        return self.root / "state/kendex/jarvis" / key / "jarvis-session.json"

    def test_unqualified_folders_stay_unchanged(self):
        project = self.root / "project"
        project.mkdir()
        self.git_init(project)
        broken = self.root / "broken"
        broken.mkdir()
        self.git_init(broken)

        def planted(home):
            (home / "README.md").write_text("an ordinary project\n")
            return home

        def enclosed_by_unreadable():
            home = self.home("broken/jarvis")
            self.unreadable(broken)
            return home

        def own_unreadable():
            home = self.home("unreadable")
            self.unreadable(home)
            return home

        blocked, failed = ("blocked", "home-not-dedicated"), ("failed", "launch-failed")
        enclosing = {"init": "refused", "cause": "inside-work-tree", "work-tree": json.dumps(str(project))}
        rows = (
            # name, folder, the init line's keys but git's detail, Start's answer
            ("no-git", lambda: self.home("plain", git=False), {"init": "refused", "cause": "no-git"}, blocked),
            ("inside-project", lambda: self.home("project/jarvis", git=False), enclosing, blocked),
            ("nested-repository", lambda: self.home("project/nested"), enclosing, blocked),
            ("other-entry", lambda: planted(self.home("busy")),
             {"init": "refused", "cause": "other-entry", "entry": '"README.md"'}, blocked),
            # git exits 128 for a repository it cannot read, as for none: an
            # enclosing one must still keep the home from qualifying.
            ("enclosing-unreadable", enclosed_by_unreadable,
             {"init": "failed", "path": "..", "cause": "git-exit-128", "created": ""}, failed),
            ("own-unreadable", own_unreadable, {"init": "failed", "path": ".", "cause": "git-exit-128", "created": ""}, failed),
        )
        for name, make, line, (state, reason) in rows:
            with self.subTest(name=name):
                home = make()
                before = self.snapshot(home)
                result = self.run_init(home)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stdout, "")
                refusal = self.keyed(result.stderr.splitlines()[0])
                refusal.pop("detail", None)
                self.assertEqual(refusal, line)
                self.assertEqual(self.snapshot(home), before)
                answer, started = self.start(home)
                self.assertEqual((answer["state"], answer["reason"], started.returncode), (state, reason, 1))
                refusal = self.keyed(started.stderr.splitlines()[0])
                refusal.pop("detail", None)
                self.assertEqual(refusal, line)
                self.assertEqual(self.snapshot(home), before)
                self.assertFalse(self.record(home).exists())

    def test_init_and_first_manual_start_write_the_same_home(self):
        try:
            import tomllib
        except ImportError:
            tomllib = None
        homes = {}
        for caller in ("init", "start"):
            with self.subTest(caller=caller):
                home = self.home(caller)
                if caller == "init":
                    result = self.run_init(home)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    report = json.loads(result.stdout)
                    self.assertEqual((report["home"], sorted(report["created"]), report["kept"]),
                                     (str(home), ["AGENTS.md", "memory/MEMORY.md", "state"], []))
                    outcomes = {row["path"]: (row["key"], row["outcome"], row.get("cause")) for row in report["settings"]}
                    self.assertEqual(outcomes, {
                        ".claude/settings.json": ("autoMemoryEnabled", "merged", None),
                        ".codex/config.toml": ("features.memories",) + (("merged", None) if tomllib else ("refused", "toml-reader-missing"))})
                else:
                    # A person's Start names the harness alone: manual and new.
                    started = subprocess.run([str(SCRIPT), "start", "--home", str(home), "--harness", "claude"],
                                             env=self.env, capture_output=True, text=True, timeout=60)
                    answer = validate(started.stdout, started.returncode, "start")
                    self.assertEqual((answer["state"], answer["reason"]), ("blocked", "tmux-missing"))
                self.assertIn(".agents/skills/jarvis/persona.md", (home / "AGENTS.md").read_text())
                self.assertEqual((home / ".claude/settings.json").read_text(),
                                 '{\n  "autoMemoryEnabled": false,\n  "hooks": {\n    "Stop": []\n  }\n}\n')
                self.assertEqual((home / ".codex/config.toml").read_text(),
                                 "# features this home turns on\n[features]\nmemories = false\nhooks = true\n"
                                 if tomllib else CODEX_FIXTURE)
                homes[caller] = self.snapshot(home)
                # Repeating either caller keeps every file it finds.
                repeat = self.run_init(home)
                self.assertEqual(repeat.returncode, 0, repeat.stderr)
                report = json.loads(repeat.stdout)
                self.assertEqual((report["created"], sorted(report["kept"])), ([], ["AGENTS.md", "memory/MEMORY.md", "state"]))
                self.assertTrue(all(row["outcome"] in ("kept", "refused") for row in report["settings"]))
                self.assertEqual(self.snapshot(home), homes[caller])
        self.assertEqual(homes["init"], homes["start"])

    def test_initialized_home_clone_starts(self):
        # A clone carries AGENTS.md and memory/MEMORY.md but not an empty
        # state/. Its first manual Start on another machine adds state/ alone,
        # whatever else the person keeps in the home.
        home = self.home("clone")
        initialized = self.run_init(home)
        self.assertEqual(initialized.returncode, 0, initialized.stderr)
        (home / "state").rmdir()
        (home / "README.md").write_text("my notes\n")
        before = self.snapshot(home)
        answer, started = self.start(home)
        self.assertEqual((answer["state"], answer["reason"]), ("blocked", "tmux-missing"), started.stderr)
        self.assertEqual(self.snapshot(home), dict(before, state=("dir",)))

    def test_boot_and_app_starts_never_initialize(self):
        origins = ("app-on", "boot") if BootReceiptScenario.applicable else ("app-on",)
        for origin in origins:
            with self.subTest(origin=origin):
                home = self.home(origin)
                before = self.snapshot(home)
                answer, _ = self.start(home, "--mode", "resume", "--origin", origin)
                self.assertEqual(answer["reason"], "tmux-missing")
                self.assertEqual(self.snapshot(home), before)

    def test_partial_home_keeps_user_content(self):
        home = self.home("partial")
        (home / "AGENTS.md").write_text("My own standing instructions.\n")
        (home / ".claude/settings.json").write_text('{"autoMemoryEnabled": true}')
        (home / ".codex/config.toml").write_text("[features]\nmemories = true\n")
        kept = {path: (home / path).read_bytes() for path in ("AGENTS.md", ".claude/settings.json", ".codex/config.toml")}
        result = self.run_init(home)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual((sorted(report["created"]), report["kept"]), (["memory/MEMORY.md", "state"], ["AGENTS.md"]))
        self.assertEqual({row["path"]: row["outcome"] for row in report["settings"]},
                         {".claude/settings.json": "kept", ".codex/config.toml": "kept" if self.has_tomllib() else "refused"})
        self.assertEqual({path: (home / path).read_bytes() for path in kept}, kept)

    @staticmethod
    def has_tomllib():
        try:
            import tomllib  # noqa: F401
        except ImportError:
            return False
        return True

    def test_native_settings_preserve_content(self):
        # Native settings belong to the person. Compare bytes, including the
        # line endings their editor wrote, not universal-newline readback.
        outside = self.root / "outside.json"
        outside.write_bytes(b"{}\r\n")
        rows = (
            # name, harness, input (None is absent), expected text, outcome, cause
            ("claude-absent", "claude", None, '{\n  "autoMemoryEnabled": false\n}\n', "merged", None),
            ("claude-empty-object", "claude", "{ \n}\n", '{\n  "autoMemoryEnabled": false\n \n}\n', "merged", None),
            ("claude-compact", "claude", "{}", '{\n  "autoMemoryEnabled": false\n}', "merged", None),
            ("claude-missing", "claude", ' \n{\n\t"theme": "café"\n}\n ',
             ' \n{\n  "autoMemoryEnabled": false,\n\t"theme": "café"\n}\n ', "merged", None),
            ("claude-true", "claude", '{\n"autoMemoryEnabled": true\n}\n', None, "kept", None),
            ("claude-false", "claude", '{"autoMemoryEnabled": false}', None, "kept", None),
            ("claude-unreadable", "claude", "{", None, "refused", "unreadable"),
            ("claude-not-object", "claude", "[]\n", None, "refused", "shape"),
            ("claude-linked", "claude", "linked", None, "refused", "linked"),
            ("codex-absent", "codex", None, "[features]\nmemories = false\n", "merged", None),
            ("codex-empty", "codex", "", "[features]\nmemories = false\n", "merged", None),
            ("codex-no-table", "codex", 'model = "café"\n',
             'model = "café"\n\n[features]\nmemories = false\n', "merged", None),
            ("codex-no-final-newline", "codex", 'model = "café"',
             'model = "café"\n\n[features]\nmemories = false\n', "merged", None),
            ("codex-header", "codex", CODEX_FIXTURE,
             "# features this home turns on\n[features]\nmemories = false\nhooks = true\n", "merged", None),
            ("codex-commented-header", "codex", "# café\n\t[ features ] \t# native choices\nhooks = true\n",
             "# café\n\t[ features ] \t# native choices\nmemories = false\nhooks = true\n", "merged", None),
            ("codex-header-at-eof", "codex", "# café\n[features]",
             "# café\n[features]\nmemories = false", "merged", None),
            ("codex-true", "codex", "[features]\nmemories = true\n", None, "kept", None),
            ("codex-false", "codex", "[features]\nmemories = false\n", None, "kept", None),
            ("codex-unreadable", "codex", "[features\n", None, "refused", "unreadable"),
            ("codex-inline-table", "codex", "features = { hooks = true }\n", None, "refused", "shape"),
        )
        for newline_name, newline in (("lf", "\n"), ("crlf", "\r\n")):
            for name, harness, text, updated, outcome, cause in rows:
                # Files with no newline have no convention; new lines use LF.
                ending = newline if text and "\n" in text else "\n"
                expected = (updated.replace("\n", ending).encode("utf-8") if updated is not None else
                            text.replace("\n", newline).encode("utf-8"))
                with self.subTest(newline=newline_name, name=name):
                    home = self.home(newline_name + "-" + name)
                    relative = ".claude/settings.json" if harness == "claude" else ".codex/config.toml"
                    path = home / relative
                    if text is None or cause == "linked":
                        path.unlink()
                        if cause == "linked":
                            path.symlink_to(outside)
                    else:
                        path.write_bytes(text.replace("\n", newline).encode("utf-8"))
                    before = self.snapshot(home).get(relative)
                    if harness == "codex" and not self.has_tomllib():
                        outcome, cause = "refused", "toml-reader-missing"
                    result = self.run_init(home)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    row = next(row for row in json.loads(result.stdout)["settings"] if row["path"] == relative)
                    self.assertEqual((row["outcome"], row.get("cause")), (outcome, cause))
                    if outcome == "refused":
                        refusals = [self.keyed(line) for line in result.stderr.splitlines()
                                    if line.startswith("jarvis-session: init-settings=")]
                        self.assertIn({"init-settings": "refused", "path": relative, "cause": cause}, refusals)
                        self.assertEqual(self.snapshot(home).get(relative), before)
                    else:
                        self.assertEqual(path.read_bytes(), expected)
                    after = self.snapshot(home)
                    repeated = self.run_init(home)
                    self.assertEqual(repeated.returncode, 0, repeated.stderr)
                    self.assertEqual(self.snapshot(home), after)
                    self.assertEqual(outside.read_bytes(), b"{}\r\n")

    def test_home_init_controls(self):
        # A source copy drops each guarantee while leaving its input reachable.
        rows = (
            ("enclosing-search", 'root = toplevel(home.parent, "..") if home.parent != home else None', "root = None",
             "test_unqualified_folders_stay_unchanged", "(name='nested-repository')"),
            ("unreadable-as-none", "if result.returncode == 128 and NOT_A_REPOSITORY.search(result.stderr):",
             "if result.returncode == 128:", "test_unqualified_folders_stay_unchanged", "(name='enclosing-unreadable')"),
            ("newline-translation", 'path.open(encoding="utf-8", newline="")', 'path.open(encoding="utf-8")',
             "test_native_settings_preserve_content", "(newline='crlf', name='claude-missing')"),
        )
        for name, match, mutant, contract, row in rows:
            with self.subTest(name=name):
                skills = self.root / "control" / name / "skills"
                scripts = skills / "jarvis/scripts"
                shutil.copytree(SKILLS / "jarvis/scripts", scripts)
                for dependency in ("mailbox", "orch"):
                    (skills / dependency).symlink_to(SKILLS / dependency, target_is_directory=True)
                source = scripts / "lib/home.py"
                before = source.read_text()
                self.assertEqual(before.count(match), 1)
                changed = before.replace(match, mutant)
                self.assertNotEqual(changed, before)
                source.write_text(changed)
                result = subprocess.run([str(ROOT / "skills/jarvis/tests/session.test.sh"),
                                         "HomeInitContract." + contract, "-v"],
                                        env=os.environ | {"JARVIS_TEST_SCRIPT": str(scripts / "jarvis-session")},
                                        capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(row, result.stderr)
                self.assertNotIn("name='no-git'", result.stderr)


class SessionContract(unittest.TestCase):
    def setUp(self):
        self.owned_workers = []
        self.scratch = tempfile.TemporaryDirectory()
        # unittest releases later acquisitions first, including on failure.
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        # The fixture home has no Git repository and holds fixture files, so
        # initialization would refuse it; its starting files skip that step.
        (self.home / "AGENTS.md").write_text("fixture standing instructions\n")
        (self.home / "memory").mkdir()
        (self.home / "memory/MEMORY.md").write_text("# Memory index\n")
        (self.home / "state").mkdir()
        self.account = self.root / "account"
        self.account.mkdir()
        self.rows = self.root / "rows.jsonl"
        self.gate = self.root / "gate"
        (self.home / ".fixture.json").write_text(json.dumps({"rows": str(self.rows), "gate": str(self.gate),
            "bash": os.environ["JARVIS_TEST_BASH"], "skills": str(SKILLS)}))
        shutil.copyfile(HARNESS_SCRIPT, self.home / ".fixture-harness.py")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for harness in ("claude", "codex", "copilot", "pi"):
            target = bin_dir / harness
            shutil.copyfile(HARNESS, target)
            target.chmod(0o755)
        # This fixture changes account identity: inherit control transport only.
        self.env = {key: value for key, value in os.environ.items()
                    if key in {"PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TERM", "SSH_AUTH_SOCK",
                               "DBUS_SESSION_BUS_ADDRESS"} or key.startswith(("XDG_", "LC_"))} | {
                                 "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                                 "XDG_STATE_HOME": str(self.root / "state"), "XDG_SESSION_ID": "fixture-login",
                                 "WAYLAND_DISPLAY": "fixture-wayland", "DISPLAY": ":fixture",
                                 "JARVIS_TEST_BASH": os.environ["JARVIS_TEST_BASH"]}
        self.manager = self.root / "manager.json"
        self.manager.write_text("{}")
        login = self.root / "login"
        login.mkdir()
        # The servers Start opens read the login's tmux config, which a row
        # writes, and never the developer's.
        self.env["HOME"] = str(login)
        self.env["XDG_CONFIG_HOME"] = str(login / ".config")
        for tool in ("systemctl", "launchctl"):
            target = bin_dir / tool
            target.write_text("#!/usr/bin/env python3\nimport json, subprocess, sys\nfrom pathlib import Path\n"
                + "path=Path(" + repr(str(self.manager)) + ")\n"
                + "if not path.exists(): sys.exit(2)\nvalues=json.loads(path.read_text())\n"
                + "if sys.argv[1:] == ['--user', 'show-environment']:\n"
                + " for key, value in values.items():\n"
                + "  subprocess.run([" + repr(os.environ["JARVIS_TEST_BASH"])
                + ", '-c', 'printf \\\"%s=%q\\\\n\\\" \\\"$1\\\" \\\"$2\\\"', 'manager', key, value], check=True)\n"
                + "elif sys.argv[1] == 'getenv':\n"
                + " if sys.argv[2] in values: print(values[sys.argv[2]])\n"
                + "else: sys.exit(2)\n"
                + "if path.with_suffix('.once').exists() and (sys.argv[1] == '--user' or sys.argv[2] == 'CLAUDE_CODE_TMPDIR'): path.unlink()\n")
            target.chmod(0o755)
        # Keep the production 70 s window in step with the source timer.
        with patch.dict(os.environ, {"JARVIS_BASH": self.env["JARVIS_TEST_BASH"]}):
            self.launch_wait = runpy.run_path(str(SKILLS / "jarvis/scripts/lib/session.py"))["CALL_SECONDS"] * 70 / 55
        key = hashlib.sha256(os.fsencode(str(self.home))).hexdigest()
        self.record = self.root / "state/kendex/jarvis" / key / "jarvis-session.json"
        self.label = "jarvis-" + key[:32]

    def tearDown(self):
        (self.root / "refuse-teardown").unlink(missing_ok=True)
        try:
            if self.record.exists():
                self.call("stop", own_worker=True)
                self.wait("off" if json.loads(self.record.read_text()).get("app_off") else "stopped")
        finally:
            for worker in self.owned_workers:
                try:
                    worker.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    worker.terminate()
                    try:
                        worker.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        worker.kill()
                        worker.wait(timeout=5)
            subprocess.run(["tmux", "-L", self.label, "kill-server"], capture_output=True, env=self.env)

    def call(self, verb, harness="claude", mode="resume", origin="manual", **kwargs):
        argv = [str(SCRIPT), verb, "--home", str(self.home)]
        if verb == "start":
            argv += ["--harness", harness, "--account", str(kwargs.get("account", self.account)), "--mode", mode, "--origin", origin]
        elif verb == "stop" and origin == "app-off":
            argv += ["--origin", origin]
        elif verb == "succeed" and kwargs.get("account_walled"):
            argv += ["--account-walled"]
        if kwargs.get("brief") is not None:
            argv += ["--brief-file", str(kwargs["brief"])]
        if kwargs.get("adopt"):
            argv += ["--adopt-pane", kwargs["adopt"][0], "--adopt-pid", str(kwargs["adopt"][1])]
        for flag in ("model", "effort"):
            if kwargs.get(flag) is not None:
                argv += ["--" + flag, kwargs[flag]]
        start = time.monotonic()
        if kwargs.get("own_worker"):
            # The real public owner runs here so its detached worker remains
            # our child until wait. Observe the real constructor only.
            real_popen = subprocess.Popen
            def observe_child(*arguments, **options):
                child = real_popen(*arguments, **options)
                if options.get("start_new_session"):
                    self.owned_workers.append(child)
                return child
            output, errors = io.StringIO(), io.StringIO()
            with patch.dict(os.environ, self.env | {"JARVIS_BASH": self.env["JARVIS_TEST_BASH"]}, clear=True), \
                    patch.object(sys, "argv", argv), patch.object(subprocess, "Popen", observe_child), \
                    redirect_stdout(output), redirect_stderr(errors):
                runtime = runpy.run_path(str(SKILLS / "jarvis/scripts/lib/session.py"))
                code = runtime["main"]()
            result = subprocess.CompletedProcess(argv, code, output.getvalue(), errors.getvalue())
        else:
            result = subprocess.run(argv, env=kwargs.get("env", self.env), capture_output=True, text=True, timeout=60)
        self.assertLess(time.monotonic() - start, 60)
        self.stderr = result.stderr
        return validate(result.stdout, result.returncode, verb, kwargs.get("duplicate_boot", False),
                        bool(kwargs.get("adopt"))), result.returncode

    def model_classes(self):
        # Model classification is kendex's external boundary. Preserve native
        # defaults for class entries, as its protocol does, and answer each
        # with the warning line its JSON consumer prints (model_warning).
        kendex = self.root / "bin/kendex"
        kendex.write_text('#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps({"protocol":"model-resolution-v1","request":{"tag":"class","class":"standard"},'
                          '"resolution":{"diagnostics":[],"native_selector":"sonnet" if sys.argv[2] == "claude" else None},'
                          '"warning":"model-resolution: requested=standard harness=" + sys.argv[2]}))\n')
        kendex.chmod(0o755)

    @staticmethod
    def model_warning(harness):
        return "model-resolution: requested=standard harness=" + harness

    def model_lines(self):
        return [line for line in self.stderr.splitlines() if line.startswith("model-resolution:")]

    def wait(self, state="running", reason=None, seconds=20, persisted_stop=False):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            answer, _ = self.call("status")
            if answer["state"] == state and (reason is None or answer["reason"] == reason):
                # Public stopped status can precede the stop owner's write.
                # Acquisition subcases must await its saved release too.
                if not persisted_stop:
                    return answer
                saved = json.loads(self.record.read_text())
                if saved["state"] == "stopped" and saved["terminal"] is None:
                    return answer
            # tmux can disappear between ownership reads during failed-start
            # cleanup. Unknown ownership is a refusal until the final write.
            transient_cleanup = reason != "record-unreadable" and (answer["state"], answer["reason"]) == ("blocked", "record-unreadable")
            # A launch expected to fail must never accept the brief. Running
            # cannot become launch-failed without another Start request.
            unexpected_running = state == "failed" and answer["state"] == "running"
            if (answer["state"] in ("blocked", "failed") and not transient_cleanup) or unexpected_running:
                self.fail(str(answer) + "\n" + self.record.read_text() + "\n" + self.ownership_reads() + "\n" + self.session_log())
            time.sleep(0.05)
        target = (json.loads(self.record.read_text()).get("terminal") or {}).get("pane", "")
        screen = subprocess.run(["tmux", "-L", self.label, "capture-pane", "-p", "-t", target], capture_output=True, text=True).stdout
        self.fail("state did not settle: " + str(answer) + "\n" + self.record.read_text() + "\n" + screen + "\n"
                  + self.ownership_reads() + "\n" + self.session_log())

    def ownership_reads(self):
        # The values the backend's live read compares for the saved
        # controller and predecessor, read again at the failure, so a failed
        # run names the comparison that rejected a pane its capture still shows.
        try:
            saved = json.loads(self.record.read_text())
        except (OSError, ValueError) as failure:
            return "ownership-read: saved=unread " + repr(failure)
        lines = []
        for role, owner in (("controller", saved), ("predecessor", saved.get("predecessor"))):
            terminal = (owner or {}).get("terminal")
            if not terminal:
                lines.append("ownership-read: role=" + role + " terminal=none")
                continue
            lines.append("ownership-read: role=" + role + " saved=" + json.dumps({
                "terminal": terminal, "server_pid": owner.get("server_pid"), "server_started_at": owner.get("server_started_at"),
                "generation": owner.get("generation"), "pending_generation": (owner.get("pending") or {}).get("generation"),
                "process": owner.get("process")}, sort_keys=True))
            fields = "#{pid} #{start_time} #{session_name} #{window_id} #{@jarvis-generation}"
            for argv in (["display-message", "-p", "-t", terminal["pane"], fields],
                         ["list-panes", "-a", "-F", fields + " #{pane_id} #{pane_pid} #{pane_dead} #{@jarvis-task}"]):
                read = subprocess.run(["tmux", "-S", terminal["server"], *argv], capture_output=True, text=True, env=self.env, timeout=10)
                lines.append("ownership-read: role=" + role + " " + argv[0] + " rc=" + str(read.returncode)
                             + "\n" + read.stdout + read.stderr)
            server = subprocess.run(["ps", "-o", "pid=,comm=", "-p", str(owner.get("server_pid"))],
                                    capture_output=True, text=True, timeout=10)
            lines.append("ownership-read: role=" + role + " ps rc=" + str(server.returncode) + "\n" + server.stdout + server.stderr)
        return "\n".join(lines)

    def session_log(self):
        try:
            log = (self.record.parent / "session.log").read_text()
        except FileNotFoundError:
            log = "session-log=absent"
        if self.rows.exists():
            stamps = [line for line in self.rows.read_text().splitlines() if "stamp" in json.loads(line)]
            log += "\n" + "\n".join(stamps)
        return log

    def await_launches(self, count):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.rows.exists() and len(self.started()) >= count:
                return
            time.sleep(0.05)
        self.fail("the native fixture did not acknowledge its launch")

    def started(self):
        return [json.loads(line) for line in self.rows.read_text().splitlines() if "argv" in json.loads(line)]

    def observe_inspection(self):
        events = self.root / "inspect-events"
        real = shutil.which("tmux")
        wrapper = self.root / "bin/tmux"
        wrapper.write_text("#!" + os.environ["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
            + "for arg in \"$@\"; do if [[ $arg == capture-pane ]]; then printf 'inspect\\n' >> "
            + shlex.quote(str(events)) + "; fi; done\nexec " + shlex.quote(real) + ' "$@"\n')
        wrapper.chmod(0o755)
        return events

    def refuse_teardown(self):
        # tmux's nonzero owned if-shell result is the failure producer.
        flag = self.root / "refuse-teardown"
        flag.touch()
        real = shutil.which("tmux")
        wrapper = self.root / "bin/tmux"
        wrapper.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
            + "for arg in \"$@\"; do if [[ $arg == if-shell && -f " + shlex.quote(str(flag))
            + " ]]; then exit 1; fi; done\nexec " + shlex.quote(real) + ' \"$@\"\n')
        wrapper.chmod(0o755)
        return flag

    def hold_inspection_until_taken(self):
        # A barrier, not a clock: once the brief is delivered, every pane read
        # waits for the native hook's stamp.
        real = shutil.which("tmux")
        wrapper = self.root / "bin/tmux"
        wrapper.write_text("#!" + os.environ["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
            + "for arg in \"$@\"; do if [[ $arg == capture-pane ]]; then until jq -e "
            + shlex.quote('.state != "starting" or .brief_delivered != true or .pending.brief_taken == true')
            + " " + shlex.quote(str(self.record)) + " >/dev/null 2>&1; do sleep 0.05; done; fi; done\nexec "
            + shlex.quote(real) + ' "$@"\n')
        wrapper.chmod(0o755)

    def hold_inspection_until_drawn(self, events, drawn, *, started):
        # Count entry separately from the draw: a second entry proves the
        # worker judged the first captured draw before the test releases Start.
        real = shutil.which("tmux")
        wrapper = self.root / "bin/tmux"
        stamp = ("jq -e " + shlex.quote(".pending.started_at != null") + " "
                 + shlex.quote(str(self.record)) + " >/dev/null 2>&1 && ") if started else ""
        wrapper.write_text("#!" + os.environ["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
            + "for arg in \"$@\"; do if [[ $arg == capture-pane ]]; then printf 'inspect\\n' >> "
            + shlex.quote(str(events)) + "; until " + stamp + "screen=\"$(" + shlex.quote(real)
            + ' "$@")" && [[ $screen == *' + shlex.quote(drawn) + "* ]]; do sleep 0.05; done; "
            + "printf '%s\\n' \"$screen\"; exit; fi; done\nexec " + shlex.quote(real) + ' "$@"\n')
        wrapper.chmod(0o755)

    def await_worker_result(self):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            record = json.loads(self.record.read_text())
            if "worker" not in record:
                return record
            time.sleep(0.05)
        self.fail("the worker did not publish its final record\n" + self.record.read_text() + "\n" + self.session_log())

    def await_rows(self, events, count):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if events.exists() and len(events.read_text().splitlines()) >= count:
                return
            time.sleep(0.05)
        self.fail("the controller did not complete its inspection barrier")

    def lifecycle(self, harness):
        self.assertEqual(self.call("status")[0]["reason"], "never-started")
        with ThreadPoolExecutor() as executor:
            answers = list(executor.map(lambda _: self.call("start", harness), range(4)))
        self.assertTrue(all(code == 0 for _, code in answers))
        first = self.wait(reason="new-no-record")
        self.assertEqual(first["home"], str(self.home))
        self.assertEqual(first["account"], str(self.account))
        before = self.started()[-1]
        # Jarvis acts on the owner's desktop: its session keeps the live display.
        self.assertEqual(before["display"], ["fixture-wayland", ":fixture"])
        actual_record = Path(before["record"])
        self.assertTrue(actual_record.is_relative_to(Path(self.env["XDG_STATE_HOME"])))
        self.assertFalse(actual_record.is_relative_to(self.home))
        self.assertEqual(json.loads(actual_record.read_text())["home"], str(self.home))
        state = self.home / "state"
        (state / "jarvis-session.json").write_text("not a runtime record")
        self.assertEqual(before["cwd"], str(self.home))
        self.assertEqual(before["account"], json.loads(self.record.read_text())["effective_home"])
        self.assertEqual(len(self.started()), 1)
        target = json.loads(self.record.read_text())["pending"].get("session_file")
        if target:
            for name, cwd in (("newer-same", str(self.home)), ("newer-other", str(self.root))):
                competitor = Path(target).parent / (name + ".jsonl")
                competitor.write_text(json.dumps(native_header(harness, name, cwd)) + "\n")
                reader = subprocess.run([self.env["JARVIS_TEST_BASH"],
                    str(SKILLS / "jarvis/scripts/lib/session-backend.sh"), "history", harness,
                    before["account"], name, str(competitor)], env=self.env, capture_output=True, text=True)
                self.assertEqual(reader.returncode, 0, reader.stderr)
                self.assertEqual(reader.stdout.strip(), str(competitor))
        else:
            for name, cwd in (("newer-same", str(self.home)), ("newer-other", str(self.root))):
                folder = self.account / "session-state" / name
                folder.mkdir()
                (folder / "workspace.yaml").write_text("id: " + name + "\ncwd: " + cwd + "\n")
                (folder / "events.jsonl").write_text('{"type":"session.start"}\n')
        self.assertEqual(self.call("start", harness)[0]["reason"], "existing")
        self.assertEqual(len(self.started()), 1)
        self.call("stop")
        self.wait("stopped")
        # Stop a resumed launch before the native SessionStart producer writes.
        os.mkfifo(self.gate)
        launches = len(self.started())
        self.call("start", harness)
        self.await_launches(launches + 1)
        self.call("stop")
        self.wait("stopped")
        self.gate.unlink()
        self.call("start", harness)
        self.wait(reason="resumed")
        self.assertEqual(self.started()[-1]["id"], before["id"])
        self.call("stop")
        self.wait("stopped")
        self.call("start", harness, mode="new")
        self.wait(reason="new-requested")
        self.assertNotEqual(self.started()[-1]["id"], before["id"])
        self.call("stop")
        self.wait("stopped")
        current = json.loads(self.record.read_text())["pending"]
        history = Path(current["session_file"]) if current.get("session_file") else self.account / "session-state" / current["native_session_id"] / "workspace.yaml"
        history.unlink()
        self.call("start", harness)
        self.wait(reason="new-history-gone")
        self.call("stop")
        self.wait("stopped")
        current = json.loads(self.record.read_text())["pending"]
        history = Path(current["session_file"]) if current.get("session_file") else self.account / "session-state" / current["native_session_id"] / "workspace.yaml"
        saved = history.read_text()
        history.write_text("unreadable history\n")
        self.assertEqual(self.call("start", harness)[0]["reason"], "record-unreadable")
        history.write_text(saved)
        self.call("start", harness)
        self.wait(reason="resumed")
        other_account = self.root / "other-account"
        other_account.mkdir()
        old_id = self.started()[-1]["id"]
        self.call("start", harness, account=other_account)
        changed = self.wait(reason="new-selection-changed")
        self.assertEqual(changed["account"], str(other_account))
        self.assertNotEqual(self.started()[-1]["id"], old_id)
        self.assertEqual(len(subprocess.run(["tmux", "-L", self.label, "list-panes", "-a", "-F", "#{pane_id}"], capture_output=True, text=True).stdout.splitlines()), 1)

    def test_claude_contract(self): self.lifecycle("claude")
    def test_codex_contract(self): self.lifecycle("codex")
    def test_copilot_contract(self): self.lifecycle("copilot")
    def test_pi_contract(self): self.lifecycle("pi")

    def test_provider_home_and_selected_account(self):
        provider = self.root / "caller Claude provider's home"
        provider.mkdir()
        excluded = ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "CLAUDE_PROJECT_DIR",
                    "CODEX_THREAD_ID", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED",
                    "PI_SUBAGENT_CHILD_AGENT", "PI_SUBAGENT_PARENT_SESSION_ID", "PI_BRIDGE_PARENT_SESSION_ID",
                    "SECOND_OPINION_CURRENT_MODEL", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GH_TOKEN")
        config = self.home / ".fixture.json"
        config.write_text(json.dumps(json.loads(config.read_text()) | {"excluded_env": excluded}))
        self.manager.write_text(json.dumps({key: "fixture-manager-value" for key in (*excluded, "CLAUDE_CONFIG_DIR")}))
        for harness, caller in (("pi", str(provider)), ("pi", None), ("pi", ""),
                                ("claude", str(provider)), ("codex", str(provider)), ("copilot", str(provider))):
            with self.subTest(harness=harness, caller=caller):
                account = self.root / ("selected-" + harness + "-account")
                account.mkdir(exist_ok=True)
                self.env.update({key: "fixture-parent-value" for key in excluded})
                self.env.pop("CLAUDE_CONFIG_DIR", None)
                if caller is not None:
                    self.env["CLAUDE_CONFIG_DIR"] = caller
                self.call("start", harness, account=account, mode="new")
                self.wait()
                native = self.started()[-1]
                record = json.loads(self.record.read_text())
                self.assertEqual(record["account"], str(account))
                # Codex launches under the lane's prepared copy of the account.
                self.assertEqual(native["account"], record["effective_home"])
                if harness in ("pi", "claude"):
                    self.assertEqual(native["account"], str(account))
                expected = str(account) if harness == "claude" else (caller or None) if harness == "pi" else None
                self.assertEqual(native["claude_config_dir"], expected)
                self.assertEqual(native["excluded_env"], [])
                self.call("stop")
                self.wait("stopped", persisted_stop=True)

    def test_manager_policy_reaches_native_and_source_failure_keeps_owner(self):
        policy = {"ORCH_LANE_EXCLUDE": "3claude", "ORCH_LANE_RETIRE": "retired=2000-01-01",
                  "ORCH_LANE_ALIASES": "work=2claude", "FLEET_USER": "user 'quoted' $literal\\slash\tline\nend\r\n",
                  "AGENT_TMPDIR": str(self.root / "agent tmp"), "CLAUDE_CODE_TMPDIR": str(self.root / "agent tmp")}
        config = self.home / ".fixture.json"
        proxy = "https://fixture-user:fixture-private-value@proxy.invalid:8443"
        transport = {"HTTPS_PROXY": proxy, "TERM": "screen-256color"}
        config.write_text(json.dumps(json.loads(config.read_text()) | {"selected_env": [*policy, *transport]}))
        self.env.update({name: "stale-caller" for name in policy})
        # Authenticated proxies and TERM=dumb are supported caller inputs.
        self.env.update(HTTPS_PROXY=proxy, TERM="dumb")
        self.env["DATABASE_URL"] = "fixture-caller-credential"
        source = policy | {"DATABASE_URL": "fixture-manager-credential"}
        self.manager.write_text(json.dumps(source))
        self.manager.with_suffix(".once").touch()
        # Keep a pre-existing server, with stale policy and a credential whose
        # arbitrary name the harness scrub table cannot recognize.
        tmux = ["tmux", "-L", self.label, "-f", os.devnull]
        subprocess.run([*tmux, "new-session", "-d", "-s", "keeper"], env=self.env, check=True)
        subprocess.run([*tmux, "set-option", "-g", "default-terminal", transport["TERM"]], env=self.env, check=True)
        commands = self.root / "tmux-commands.jsonl"
        real_tmux = shutil.which("tmux")
        wrapper = self.root / "bin/tmux"
        wrapper.write_text("#!" + sys.executable + "\nimport json,os,sys\nfrom pathlib import Path\n"
            + "with Path(" + repr(str(commands)) + ").open('a') as stream: stream.write(json.dumps(sys.argv[1:])+'\\n')\n"
            + "os.execv(" + repr(real_tmux) + ", ['tmux', *sys.argv[1:]])\n")
        wrapper.chmod(0o755)
        for key, value in {"FLEET_USER": "stale-server", "DATABASE_URL": "fixture-credential"}.items():
            subprocess.run([*tmux, "set-environment", "-g", key, value], env=self.env, check=True)
        config.write_text(json.dumps(json.loads(config.read_text()) | {"excluded_env": ["DATABASE_URL"]}))
        for mode in ("new", "resume"):
            self.call("start", mode=mode)
            self.wait(reason="new-no-record" if mode == "new" else "resumed")
            self.assertEqual(self.started()[-1]["selected_env"], policy | transport)
            self.assertEqual(self.started()[-1]["excluded_env"], [])
            # Each succession gets fresh policy, then its worker and native
            # process must succeed after that source disappears.
            (self.home / "state").mkdir(exist_ok=True)
            (self.home / "state/handoff.md").write_text("handoff\n")
            for successor in range(2):
                self.manager.write_text(json.dumps(source | {"FLEET_USER": str(successor)}))
                self.call("succeed")
                self.wait()
                self.assertEqual(self.started()[-1]["selected_env"], policy | transport | {"FLEET_USER": str(successor)})
                self.assertEqual(self.started()[-1]["excluded_env"], [])
            predecessor = self.record.read_bytes()
            for verb in ("start", "succeed"):
                answer, code = self.call(verb)
                self.assertEqual((answer["reason"], code), ("launch-failed", 1))
                self.assertEqual(self.record.read_bytes(), predecessor)
                self.assertEqual(self.call("status")[0]["state"], "running")
            self.call("stop")
            self.wait("stopped", persisted_stop=True)
            self.manager.write_text(json.dumps(source))
        with patch.dict(os.environ, self.env | {"JARVIS_BASH": self.env["JARVIS_TEST_BASH"]}, clear=True):
            runtime = runpy.run_path(str(SKILLS / "jarvis/scripts/lib/session.py"))
            with patch.object(sys, "platform", "darwin"):
                selected = runtime["environment"](policy=True)
                self.assertEqual({name: selected.get(name) for name in policy}, policy)
        # Missing optional policy is a successful empty read, never a fallback.
        self.manager.write_text("{}")
        self.call("start")
        self.wait()
        self.assertEqual(self.started()[-1]["selected_env"], dict.fromkeys(policy) | transport)
        argv = commands.read_text()
        self.assertFalse(proxy in argv, "private transport entered tmux arguments")
        observed = {word for row in argv.splitlines() for word in json.loads(row)}
        self.assertTrue({"new-session", "new-window"} <= observed)
        pane = json.loads(self.record.read_text())["terminal"]["pane"]
        command = subprocess.run([*tmux, "display-message", "-p", "-t", pane, "#{pane_start_command}"],
                                 env=self.env, capture_output=True, text=True, check=True).stdout
        self.assertFalse(proxy in command, "private transport entered pane command text")

    def test_pane_channel_keeps_timeouts_private_and_releases_ownership(self):
        proxy = "https://fixture-user:fixture-private-value@proxy.invalid:8443"
        with patch.dict(os.environ, self.env | {"JARVIS_BASH": self.env["JARVIS_TEST_BASH"]}, clear=True):
            runtime = runpy.run_path(str(SKILLS / "jarvis/scripts/lib/session.py"))
        session = runtime["Session"](self.home, self.env | {"HTTPS_PROXY": proxy})
        for verb in ("new-session", "new-window"):
            with self.subTest(verb=verb):
                errors = io.StringIO()
                captured = []
                def timeout(argv, **kwargs):
                    captured.extend(argv)
                    raise subprocess.TimeoutExpired(argv, 1)
                with patch.object(subprocess, "run", side_effect=timeout), redirect_stderr(errors):
                    try:
                        with session.pane_command([sys.executable, "-c", "pass"]) as command:
                            channel = Path(command[-1])
                            self.assertEqual(channel.parent.stat().st_mode & 0o777, 0o700)
                            session.tmux(verb, *command)
                    except subprocess.TimeoutExpired as failure:
                        session.failure_log("worker-failed", failure)
                        propagated = "".join(traceback.format_exception(type(failure), failure, failure.__traceback__))
                    else:
                        self.fail("tmux timeout was swallowed")
                for evidence in (captured, errors.getvalue(), propagated):
                    self.assertFalse(proxy in str(evidence), "private transport entered diagnostic or argv")
                self.assertFalse(channel.parent.exists(), "failed launch retained its channel")
        # A pane process killed before receipt can close a queued connection.
        with self.assertRaises((OSError, runtime["Refusal"])):
            with session.pane_command([sys.executable, "-c", "pass"]) as command:
                channel = Path(command[-1])
                with socket.socket(socket.AF_UNIX) as peer:
                    peer.connect(str(channel))
        self.assertFalse(channel.parent.exists(), "closed receiver retained its channel")

    def test_manager_policy_excludes_reserved_account_through_selector(self):
        # Succession's subclass replaces lanes; this row needs its real owner.
        script = patch.dict(globals(), {"SCRIPT": SKILLS / "jarvis/scripts/jarvis-session"})
        script.start()
        self.addCleanup(script.stop)
        self.model_classes()
        reserved = Path(self.env["HOME"]) / ".3claude"
        reserved.mkdir()
        allowed = Path(self.env["HOME"]) / ".2claude"
        allowed.mkdir()
        for account in (reserved, allowed):
            (account / ".claude.json").write_text('{"hasCompletedOnboarding":true}')
        # The external meter and model classifier are fixtures. The real
        # selector must skip the reserved account despite its greater room.
        meter = self.root / "bin/meter"
        meter.write_text("#!" + sys.executable + "\nimport sys\n"
            + "if sys.argv[1]=='capabilities':\n print('kind=ssh\\tlaunch=ssh\\tchannel=mailbox\\tfiles=verb\\tstatus=verb\\tstop=verb\\trelaunch=resume\\tpark=none\\taccounts=none\\tpool=plan\\tland=lane'); sys.exit(0)\n"
            + "assert sys.argv[1]=='accounts'\n"
            + "for account, pct in " + repr([(str(self.account), 99), (str(reserved), 0), (str(allowed), 5)]) + ":\n"
            + " print('account='+account+'\\tharness=claude\\tsession-5h-pct='+str(pct)+'\\tweekly-pct='+str(pct)+'\\tmodel-pct='+str(pct)+'\\tmodel-label=Sonnet')\n")
        meter.chmod(0o755)
        (self.home / "kendex.settings.toml").write_text('[env]\nORCH_LANE_HOST = ' + json.dumps(str(meter))
            + '\nORCH_OVERSEER_PREFERENCE = "claude:standard:high"\n')
        self.manager.write_text('{"ORCH_LANE_EXCLUDE":"3claude"}')
        self.call("start")
        self.wait()
        (self.home / "state").mkdir(exist_ok=True)
        (self.home / "state/handoff.md").write_text("handoff\n")
        answer, code = self.call("succeed")
        self.assertEqual((answer["reason"], code), ("succession", 0),
                         str(answer) + "\n" + self.stderr + "\n" + self.session_log())
        self.assertEqual(self.wait()["account"], str(allowed))
        self.assertEqual(self.started()[-1]["account"], str(allowed))

    def test_unattended_start_posture(self):
        # The home's setting decides the launch line's permission words.
        settings = self.home / "kendex.settings.toml"
        for harness, named, unattended in (("claude", "claude", True), ("codex", " pi , codex ", True),
                                           ("copilot", "copilot", True), ("pi", "pi", False),
                                           ("claude", "", False), ("claude", "codex,copilot", False)):
            with self.subTest(harness=harness, named=named):
                settings.write_text('[env]\nJARVIS_UNATTENDED_HARNESSES = "' + named + '"\n')
                self.call("start", harness, mode="new")
                self.wait()
                words = set(self.started()[-1]["argv"]) & ANY_PERMISSION_WORD
                self.assertEqual(words, PERMISSION_WORDS[harness] if unattended else set())
                self.call("stop")
                self.wait("stopped", persisted_stop=True)

    def test_person_start_defaults(self):
        # A person's Start names the harness alone: the account directory the
        # harness itself uses, a new context and the manual origin.
        standard = Path(self.env["HOME"]) / ".claude"
        configured = self.root / "configured"
        for account in (standard, configured):
            account.mkdir()
        argv = [str(SCRIPT), "start", "--home", str(self.home), "--harness", "claude"]
        rows = (
            ("new-no-record", {}, standard),
            # A repeat on the same account starts new: the mode default.
            ("new-requested", {}, standard),
            ("new-selection-changed", {"CLAUDE_CONFIG_DIR": str(configured)}, configured),
        )
        for expected, env, account in rows:
            with self.subTest(reason=expected):
                result = subprocess.run(argv, env=self.env | env, capture_output=True, text=True, timeout=60)
                validate(result.stdout, result.returncode, "start")
                answer = self.wait(reason=expected)
                self.assertEqual((answer["account"], answer["origin"]), (str(account), "manual"))
                self.call("stop")
                self.wait("stopped")

    def test_first_launch_runs_in_its_created_pane(self):
        # The process tmux creates for a first Start is the one the record
        # owns and the native launch runs under: no second pane process.
        created = self.root / "created-pane-pids"
        real = shlex.quote(shutil.which("tmux"))
        wrapper = self.root / "bin/tmux"
        wrapper.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
            + 'if [[ " $* " == *" new-session "* ]]; then\n  created="$(' + real + ' "$@")"\n'
            + "  printf '%s\\n' \"$created\"\n"
            + "  " + real + " -S \"${created%%$'\\t'*}\" display-message -p -t \"${created##*$'\\t'}\" '#{pane_pid}' >> "
            + shlex.quote(str(created)) + "\n  exit\nfi\nexec " + real + ' "$@"\n')
        wrapper.chmod(0o755)
        self.call("start")
        self.wait()
        record = json.loads(self.record.read_text())
        pane = subprocess.run(["tmux", "-L", self.label, "display-message", "-p", "-t", record["terminal"]["pane"], "#{pane_pid}"],
                              capture_output=True, text=True, check=True).stdout.split()
        self.assertEqual(created.read_text().split(), [str(record["process"]["pid"])])
        self.assertEqual(pane, [str(record["process"]["pid"])])

    def test_start_model_and_effort(self):
        # The stated pair is read as a preference entry reads it, launched in
        # the harness's own words and recorded as the session's choice, with
        # kendex's line for a class printed once per launch. A Pi model is
        # refused only when it spends another harness's account: openai/
        # names a provider no reading measures, so it launches.
        self.model_classes()
        for harness, model, launched, words, foreign in (
                ("claude", "standard", "sonnet", ("--model", "--effort"), ()),
                ("pi", "github-copilot/gpt-5.5", "github-copilot/gpt-5.5", ("--model", "--thinking"),
                 (("pi-claude/claude-sonnet-4-5", True), ("openai/gpt-5", False)))):
            with self.subTest(harness=harness):
                def launch():
                    argv = self.started()[-1]["argv"]
                    return {word: argv[argv.index(word) + 1] for word in words if word in argv}, json.loads(self.record.read_text()).get("choice")

                def stated(effort):
                    return ({words[0]: launched, words[1]: effort},
                            {"harness": harness, "account": str(self.account), "model": launched, "effort": effort})

                self.call("start", harness, mode="new")
                self.wait()
                self.assertEqual(launch(), ({}, None))
                for other, refused in foreign:
                    with self.subTest(model=other):
                        before, count = self.record.read_bytes(), len(self.started())
                        answer, code = self.call("start", harness, mode="new", model=other, effort="high")
                        if refused:
                            self.assertEqual((answer["state"], answer["reason"], code), ("failed", "launch-failed", 1))
                            self.assertIn("jarvis-session: selection=pi-account-unlaunchable model=" + other, self.stderr.splitlines())
                            self.assertEqual((self.record.read_bytes(), len(self.started())), (before, count))
                        else:
                            self.assertEqual(self.wait()["reason"], "new-selection-changed")
                            self.assertEqual(json.loads(self.record.read_text())["choice"]["model"], other)
                count = len(self.started())
                # Each row: the stated effort, or none; the answer; whether it
                # launched; and the effort the session then runs.
                for effort, reason, launches, running in (("high", "new-selection-changed", 1, "high"), ("high", "existing", 0, "high"),
                                                          (None, "existing", 0, "high"), ("low", "new-selection-changed", 1, "low")):
                    with self.subTest(effort=effort, reason=reason):
                        answer, _ = self.call("start", harness, mode="new", **({"model": model, "effort": effort} if effort else {}))
                        self.assertEqual(self.model_lines(), [self.model_warning(harness)] * launches if harness == "claude" else [])
                        self.assertEqual(self.wait()["reason"] if launches else answer["reason"], reason)
                        count += launches
                        self.assertEqual(len(self.started()), count)
                        self.assertEqual(launch(), stated(running))
                self.call("stop")
                self.wait("stopped", persisted_stop=True)
                # A resume keeps the recorded choice, restated or not; a new
                # context that states none runs the app's own default.
                for mode, restated, reason, running in (("resume", {"model": model, "effort": "low"}, "resumed", stated("low")),
                                                        ("resume", {}, "resumed", stated("low")),
                                                        ("new", {}, "new-requested", ({}, None))):
                    with self.subTest(mode=mode, restated=bool(restated)):
                        self.call("start", harness, mode=mode, **restated)
                        self.assertEqual(self.wait()["reason"], reason)
                        self.assertEqual(launch(), running)
                        self.call("stop")
                        self.wait("stopped", persisted_stop=True)

    def test_contract_validator_controls(self):
        answer, _ = self.call("status")
        for patch in ({"reason": "unknown"}, {"detail": "x" * 201}, {"detail": "a\nb"}):
            with self.subTest(patch=patch), self.assertRaises(AssertionError):
                validate(json.dumps(answer | patch) + "\n", 0, "status")

    def test_off_and_boot_receipt(self):
        # A desktop with no selected app still has the lock/runtime tools.
        tool_bin = self.root / "tools"
        tool_bin.mkdir()
        for tool in ("bash", "python3", "cat", "flock", "perl", "sleep", "ps", "tmux", "mkdir", "rmdir", "rm", "date", "stat", "sed", "awk"):
            found = self.env["JARVIS_TEST_BASH"] if tool == "bash" else shutil.which(tool)
            if found:
                (tool_bin / tool).symlink_to(found)
        missing = self.env | {"PATH": str(tool_bin)}
        # The Linux boot producer is absent on macOS. Off/app-on is universal.
        origins = (["boot"] if BootReceiptScenario.applicable else []) + ["app-on"]
        for origin in origins:
            with self.subTest(origin=origin):
                if origin == "app-on":
                    self.call("start")
                    self.wait()
                    answer, _ = self.call("stop", origin="app-off")
                    self.assertEqual((answer["state"], answer["reason"]), ("stopping", "stop-requested"))
                    self.wait("off")
                    self.assertEqual(self.call("start")[0]["reason"], "app-off")
                answer, code = self.call("start", origin=origin, env=missing)
                self.assertEqual((answer["reason"], code), ("app-missing", 1))
                if origin == "boot":
                    self.assertEqual(self.call("start", origin="boot", duplicate_boot=True)[0]["state"], "stopped")
                    self.assertFalse(self.rows.exists())
                else:
                    self.assertFalse(json.loads(self.record.read_text())["app_off"])
                    self.assertEqual(self.call("status")[0]["state"], "stopped")
                    self.call("start")
                    self.wait(reason="resumed")
        # A desktop can lose its tmux client while the server stays live.
        before_stop = json.loads(self.record.read_text())
        (tool_bin / "tmux").unlink()
        for client_available, state, reason, code in ((False, "blocked", "tmux-missing", 1),
                                                    (True, "stopping", "stop-requested", 0)):
            with self.subTest(stop_client=client_available):
                answer, actual_code = self.call("stop", origin="app-off", env=self.env if client_available else missing)
                self.assertEqual((answer["state"], answer["reason"], actual_code), (state, reason, code))
                saved = json.loads(self.record.read_text())
                self.assertTrue(saved["app_off"])
                self.assertEqual(saved["intent"], "stop")
                if not client_available:
                    self.assertEqual(saved["state"], before_stop["state"])
                    self.assertEqual(saved["terminal"], before_stop["terminal"])
                    self.assertEqual(saved["pending"], before_stop["pending"])
                    self.assertEqual(self.call("status")[0]["terminal"], before_stop["terminal"])
                self.assertEqual(self.call("start")[0]["reason"], "app-off")
        self.wait("off")
        self.call("start", origin="app-on")
        self.wait(reason="resumed")
        if BootReceiptScenario.applicable:
            # A new login handles boot once, whether the session lives or ends.
            self.env["XDG_SESSION_ID"] = "second-fixture-login"
            self.call("start", origin="boot")
            count = len(self.started())
            self.call("stop")
            self.wait("stopped")
            self.assertEqual(self.call("start", origin="boot", duplicate_boot=True)[0]["state"], "stopped")
            self.assertEqual(len(self.started()), count)

    def test_update_brief(self):
        brief = self.home / "private.txt"
        brief.write_text("Continue the original work.")
        answer, code = self.call("update-brief", brief=brief)
        self.assertEqual((answer["state"], answer["reason"], code), ("blocked", "record-unreadable", 1))
        self.assertFalse(self.record.exists())
        self.model_classes()
        answer, code = self.call("start", brief=brief, model="sonnet", effort="high")
        self.assertEqual((answer["state"], code), ("starting", 0), self.stderr)
        running = self.wait()
        before = json.loads(self.record.read_text())
        brief.write_text("Continue the corrected work.")
        answer, code = self.call("update-brief", brief=brief)
        self.assertEqual((answer, code), (running, 0))
        self.assertEqual(json.loads(self.record.read_text()), before | {"private_brief": brief.read_text()})
        saved = self.record.read_bytes()
        missing = self.home / "missing.txt"
        cases = [("missing", missing, None, {}), ("empty-path", "", None, {}), ("directory", self.home, None, {}),
                 ("empty", brief, b" \n", {}), ("multiline", brief, b"one\ntwo", {}),
                 ("control", brief, b"one\x00two", {}), ("encoding", brief, b"\xff", {})]
        for state, reason in (("starting", "launching"), ("handing-over", "succession"),
                              ("stopping", "stop-requested"), ("failed", "handover-failed"),
                              ("stopped", "stopped"), ("off", "app-off"), ("blocked", "sign-in-required")):
            cases.append((state, brief, b"Replacement", {"state": state, "reason": reason}))
        cases.append(("app-off", brief, b"Replacement", {"app_off": True}))
        cases.append(("ended", brief, b"Replacement", {"terminal": None}))
        try:
            for name, path, contents, changes in cases:
                with self.subTest(input=name):
                    if contents is not None:
                        brief.write_bytes(contents)
                    record = json.loads(saved) | changes
                    self.record.write_text(json.dumps(record))
                    prior = self.record.read_bytes()
                    answer, code = self.call("update-brief", brief=path)
                    self.assertEqual((answer["state"], answer["reason"], code), ("blocked", "record-unreadable", 1))
                    self.assertEqual(self.record.read_bytes(), prior)
        finally:
            self.record.write_bytes(saved)

    def test_identity_before_private_brief(self):
        events = self.observe_inspection()
        os.mkfifo(self.gate)
        brief = self.home / "private.txt"
        brief.write_text("Continue the consumer's private work.")
        processes = ["selected", "unrelated-name"]
        try:
            os.readlink("/proc/self/exe")
        except OSError:
            pass
        else:
            processes.append("unrelated-path")
        for process in processes:
            with self.subTest(process=process):
                configuration = self.home / ".fixture.json"
                fixture = json.loads(configuration.read_text())
                if process != "selected":
                    fixture.update(harness="codex", hold_prompt=True)
                    native = self.root / "unrelated"
                    shutil.copyfile(HARNESS, native)
                    native.chmod(0o755)
                    wrapper = self.root / "bin/codex"
                    # Keep the readable-path row's accepted argv name. The
                    # portable row has no accepted harness process name.
                    command = "exec -a codex " if process == "unrelated-path" else "exec "
                    wrapper.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n" + command
                                       + shlex.quote(str(native)) + ' "$@"\n')
                configuration.write_text(json.dumps(fixture))
                inspections = len(events.read_text().splitlines()) if events.exists() else 0
                launches = len(self.started()) if self.rows.exists() else 0
                prompt_count = sum("prompt" in json.loads(line) for line in self.rows.read_text().splitlines()) if self.rows.exists() else 0
                self.call("start", "codex", brief=brief)
                self.await_launches(launches + 1)
                self.assertEqual(self.call("status")[0]["state"], "starting")
                self.assertEqual(sum("prompt" in json.loads(line) for line in self.rows.read_text().splitlines()), prompt_count)
                # A second inspection proves the first identity decision
                # completed while the FIFO remains closed.
                self.await_rows(events, inspections + 2)
                with self.gate.open("w") as stream:
                    stream.write("1")
                if process != "selected":
                    deadline = time.monotonic() + 10
                    while not json.loads(self.record.read_text())["pending"].get("started_at") and time.monotonic() < deadline:
                        time.sleep(0.05)
                    record = json.loads(self.record.read_text())
                    self.assertTrue(record["pending"].get("started_at"))
                    self.assertEqual(record["pending"]["native_session_id"], self.started()[-1]["id"])
                    terminal = self.call("status")[0]["terminal"]
                    self.assertIsNotNone(terminal)
                    # Account inspection also rejects this unrelated process.
                    # Exercise the actual delivery owner so its refusal proves
                    # the process gate independently of that earlier reader.
                    env = {key: value for key, value in self.env.items()
                           if key not in ("TMUX", "TMUX_PANE", "VGSHELL_RUNNER_PID")}
                    delivered = subprocess.run([self.env["JARVIS_TEST_BASH"], str(SKILLS / "jarvis/scripts/lib/session-backend.sh"),
                                                "deliver", terminal["server"], terminal["pane"], "codex", str(brief)],
                                               env=env, cwd=self.home, capture_output=True, text=True, timeout=10)
                    self.assertEqual(delivered.returncode, 1)
                    self.assertEqual(delivered.stderr.splitlines()[0].split()[:2], ["pane-write:", "process-mismatch"])
                    self.assertEqual(sum("prompt" in json.loads(line) for line in self.rows.read_text().splitlines()), prompt_count)
                else:
                    self.wait()
                    prompts = [json.loads(line)["prompt"] for line in self.rows.read_text().splitlines() if "prompt" in json.loads(line)]
                    self.assertEqual(len(prompts), prompt_count + 1)
                    self.assertIn(brief.read_text(), prompts[-1])
                    self.assertNotIn("oversee", prompts[-1])
                self.call("stop")
                self.wait("stopped")

    def test_idle_prompt_is_not_running(self):
        # Real time tests launch-timer wiring against a held native prompt.
        events = self.observe_inspection()
        fixture = self.home / ".fixture.json"
        fixture.write_text(json.dumps(json.loads(fixture.read_text()) | {"idle": True}))
        self.call("start", "claude")
        deadline = time.monotonic() + 10
        while (not self.rows.exists() or not any("prompt" in json.loads(line) for line in self.rows.read_text().splitlines())) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(any("prompt" in json.loads(line) for line in self.rows.read_text().splitlines()))
        self.await_rows(events, 3)
        self.assertEqual(self.call("status")[0]["state"], "starting")
        answer = self.wait("failed", "launch-failed", seconds=self.launch_wait)
        self.assertIsNone(answer["terminal"])
        self.assertTrue(json.loads(self.record.read_text())["history"]["pending"]["started_at"])

    def test_turn_end_takes_the_brief(self):
        # Claude Code 2.1.x's spinner matches no pane pattern; the native
        # hook's Stop stamp after the brief proves the Start brief taken.
        fixture = self.home / ".fixture.json"
        fixture.write_text(json.dumps(json.loads(fixture.read_text()) | {"turn": "spinner"}))
        self.call("start", "claude")
        answer = self.wait(reason="new-no-record")
        self.assertIsNotNone(answer["terminal"])
        self.assertIs(json.loads(self.record.read_text())["pending"]["brief_taken"], True)

    def test_resume_after_text_only_brief(self):
        # Both kickoff harnesses must accept a resumed brief with no tool call.
        fixture = self.home / ".fixture.json"
        real_tmux = shutil.which("tmux")
        for harness in ("copilot", "codex"):
            with self.subTest(harness=harness):
                fixture.write_text(json.dumps(json.loads(fixture.read_text()) | {"turn": "tools"}))
                self.call("start", harness, mode="new")
                self.wait(seconds=self.launch_wait)
                identity = self.started()[-1]["id"]
                self.call("stop")
                self.wait("stopped")
                fixture.write_text(json.dumps(json.loads(fixture.read_text()) | {"turn": "text-only"}))
                # Timer-wiring control: keep delivery's record lock past the
                # hook's default 2 s wait after the fixture receives its brief.
                prompts = sum("prompt" in json.loads(line) for line in self.rows.read_text().splitlines())
                wrapper = self.root / "bin/tmux"
                wrapper.write_text("#!" + sys.executable + "\n"
                    + "import json, subprocess, sys, time\nfrom pathlib import Path\n"
                    + "args = sys.argv[1:]\n"
                    + "result = subprocess.run([" + repr(real_tmux) + ", *args])\n"
                    + "if result.returncode == 0 and 'send-keys' in args and args[-1] == 'Enter':\n"
                    + "    rows = Path(" + repr(str(self.rows)) + ")\n"
                    + "    deadline = time.monotonic() + 10\n"
                    + "    while sum('prompt' in json.loads(line) for line in rows.read_text().splitlines()) <= " + str(prompts) + ":\n"
                    + "        assert time.monotonic() < deadline, 'the fixture did not receive its brief'\n"
                    + "        time.sleep(0.01)\n"
                    + "    started = time.monotonic()\n    time.sleep(3)\n"
                    + "    with rows.open('a') as stream:\n"
                    + "        stream.write(json.dumps({'delivery_hold': time.monotonic() - started}) + '\\n')\n"
                    + "sys.exit(result.returncode)\n")
                wrapper.chmod(0o755)
                self.call("start", harness, mode="resume")
                answer = self.wait(reason="resumed", seconds=self.launch_wait)
                self.assertIsNotNone(answer["terminal"])
                record = json.loads(self.record.read_text())
                self.assertEqual(self.started()[-1]["id"], identity)
                self.assertEqual(record["pending"]["native_session_id"], identity)
                self.assertIs(record["pending"].get("brief_taken"), True)
                self.assertIs(record["pending"].get("kickoff_ended"), True)
                holds = [json.loads(line)["delivery_hold"] for line in self.rows.read_text().splitlines()
                         if "delivery_hold" in json.loads(line)]
                self.assertGreaterEqual(holds[-1], 3)
                self.call("stop")
                self.wait("stopped")
                wrapper.unlink()

    def test_pi_text_only_brief(self):
        fixture = self.home / ".fixture.json"
        for outcome, state, reason in (("completed", "running", "new-no-record"),
                                       ("error", "failed", "launch-failed")):
            with self.subTest(outcome=outcome):
                fixture.write_text(json.dumps(json.loads(fixture.read_text())
                                              | {"turn": "text-only", "outcome": outcome}))
                self.call("start", "pi", mode="new")
                answer = self.wait(state, reason, seconds=self.launch_wait)
                record = json.loads(self.record.read_text())
                if state == "running":
                    self.assertIsNotNone(answer["terminal"])
                    self.assertIs(record["pending"].get("brief_taken"), True)
                else:
                    self.assertIsNone(answer["terminal"])
                    self.assertIsNone(record["history"]["pending"].get("brief_taken"))
                self.call("stop")
                self.wait("stopped")

    def test_session_start_at_first_prompt(self):
        # Copilot CLI and Codex fire SessionStart only once the first prompt is
        # submitted. Their kickoff turn draws a working line before its stamp
        # and a bare composer after it, and the brief waits for that turn's
        # native end.
        events = self.observe_inspection()
        fixture = self.home / ".fixture.json"
        fixture.write_text(json.dumps(json.loads(fixture.read_text()) | {"kickoff_barrier": str(events)}))
        brief = self.home / "private.txt"
        brief.write_text("Continue the consumer's private work.")
        for harness in ("copilot", "codex"):
            with self.subTest(harness=harness):
                launches = len(self.started()) if self.rows.exists() else 0
                self.call("start", harness, brief=brief)
                # The launch line itself submits the kickoff, as the harness
                # reads its argv; without one the start waits out its bound.
                self.await_launches(launches + 1)
                self.assertIsNotNone(launch_prompt(harness, self.started()[-1]["argv"]))
                answer = self.wait()
                self.assertIsNotNone(answer["terminal"])
                launched = self.started()[-1]
                record = json.loads(self.record.read_text())
                if harness == "copilot":
                    # The native id is the id Start preassigned at launch.
                    self.assertIn("--session-id=" + record["pending"]["native_session_id"], launched["argv"])
                self.assertEqual(record["pending"]["native_session_id"], launched["id"])
                self.assertEqual(record["history"]["pending"]["native_session_id"], launched["id"])
                self.assertTrue(record["history"]["pending"]["started_at"])
                self.assertIs(record["pending"].get("kickoff_ended"), True)
                # Running follows the session's own word that it took the brief.
                self.assertIs(record["pending"].get("brief_taken"), True)
                rows = [json.loads(line) for line in self.rows.read_text().splitlines()]
                own = [row for row in rows if row.get("id") == launched["id"] and ("kickoff" in row or "prompt" in row)]
                self.assertEqual(["kickoff" in row for row in own], [True, False])
                self.assertNotIn(brief.read_text(), own[0]["kickoff"])
                self.assertNotIn(str(brief), own[0]["kickoff"])
                self.assertIn(brief.read_text(), own[1]["prompt"])
                self.call("stop")
                self.wait("stopped")

    def test_trust_dialog_is_refused(self):
        # Copilot CLI 1.0.88's folder-trust question holds a new home before
        # its start; the refusal names it well inside the launch bound.
        capture = SKILLS / "orch/tests/fixtures/oversee-watch/copilot-dialog-trust.txt"
        question = next(re.sub(r"^[\s│]+|[\s│]+$", "", line) for line in capture.read_text().splitlines()
                        if "Do you trust the files" in line)
        fixture = self.home / ".fixture.json"
        fixture.write_text(json.dumps(json.loads(fixture.read_text()) | {"trust": str(capture)}))
        self.call("start", "copilot")
        answer = self.wait("blocked", "trust-required")
        self.assertEqual(answer["detail"], question)
        self.assertIsNone(answer["terminal"])
        self.assertEqual(subprocess.run(["tmux", "-L", self.label, "has-session", "-t", "=jarvis"],
                                        capture_output=True, env=self.env).returncode, 1)
        self.assertFalse(any("prompt" in json.loads(line) for line in self.rows.read_text().splitlines()))

    def test_resumed_history_is_no_trust_dialog(self):
        # A resumed Copilot session redraws its conversation; the folder-trust
        # question quoted there, before its start or after it, is no dialog.
        fixture = self.home / ".fixture.json"
        self.call("start", "copilot")
        self.wait()
        self.call("stop")
        self.wait("stopped")
        events = self.root / "inspect-events"
        os.mkfifo(self.gate)
        # Pending: the first read captures the history, and the second entry
        # proves the worker judged it while Start was held. Confirmed: the
        # first read captures after Start, so the worker discards that answer.
        for drawn, reads in (("pending", 2), ("confirmed", 1)):
            with self.subTest(drawn=drawn):
                self.hold_inspection_until_drawn(events,
                    "Noted." if drawn == "pending" else "Do you trust the files", started=drawn == "confirmed")
                fixture.write_text(json.dumps(json.loads(fixture.read_text()) | {"history": drawn}))
                inspections = len(events.read_text().splitlines()) if events.exists() else 0
                self.call("start", "copilot")
                self.await_rows(events, inspections + reads)
                with self.gate.open("w") as stream:
                    stream.write("1")
                answer = self.wait(reason="resumed")
                self.assertIsNotNone(answer["terminal"])
                self.call("stop")
                self.wait("stopped")

    def test_sign_in_wall_after_the_stamp(self):
        # A tool call stamps the brief taken and the turn then meets the
        # sign-in wall: the pane read with the stamp standing still refuses.
        # The stamp lands in the worker's poll pause after the delivery, and
        # every later pane read waits for it.
        self.hold_inspection_until_taken()
        fixture = self.home / ".fixture.json"
        fixture.write_text(json.dumps(json.loads(fixture.read_text()) | {"auth_mode": "current", "auth_event": "PreToolUse"}))
        for harness in AUTH_MESSAGES:
            with self.subTest(harness=harness):
                self.call("start", harness)
                answer = self.wait("blocked", "sign-in-required")
                self.assertIsNone(answer["terminal"])
                self.assertIs(json.loads(self.record.read_text())["history"]["pending"]["brief_taken"], True)
                self.call("stop")
                self.wait("stopped")

    def test_sign_in_failure(self):
        fixture = self.home / ".fixture.json"
        for harness in AUTH_MESSAGES:
            fixture.write_text(json.dumps(json.loads(fixture.read_text()) | {"auth_mode": None}))
            self.call("start", harness)
            self.wait()
            confirmed = self.started()[-1]["id"]
            self.call("stop")
            self.wait("stopped")
            for auth_mode, teardown in (("stale", "allowed"), ("current", "allowed"), ("current", "refused")):
                with self.subTest(harness=harness, auth_mode=auth_mode, teardown=teardown):
                    fixture.write_text(json.dumps(json.loads(fixture.read_text()) | {"auth_mode": auth_mode}))
                    flag = self.refuse_teardown() if teardown == "refused" else None
                    self.call("start", harness)
                    if auth_mode == "stale":
                        answer = self.wait(reason="resumed")
                        self.assertIsNotNone(answer["terminal"])
                        self.assertEqual(self.started()[-1]["id"], confirmed)
                        self.assertEqual(json.loads(self.record.read_text())["pending"]["native_session_id"], confirmed)
                    else:
                        record = self.await_worker_result()
                        answer, _ = self.call("status")
                        if flag:
                            self.assertEqual((answer["state"], answer["reason"]), ("starting", "launching"))
                            self.assertIsNotNone(answer["terminal"])
                            self.assertEqual(answer["detail"], "")
                            self.assertTrue(record["history"]["pending"]["started_at"])
                            flag.unlink()
                        else:
                            self.assertEqual((answer["state"], answer["reason"]), ("blocked", "sign-in-required"))
                            self.assertIsNone(answer["terminal"])
                            self.assertTrue(answer["detail"])
                    self.call("stop")
                    self.wait("stopped")

    def test_account_is_checked_before_private_brief(self):
        self.call("start")
        self.wait()
        confirmed = self.started()[-1]["id"]
        self.call("stop")
        self.wait("stopped")
        # EOF is a fixture input, distinct from any delivered prompt. Exercise
        # this owner with its native-writer dependency acknowledged separately.
        count = len(self.rows.read_text().splitlines())
        previous_cwd = Path.cwd()
        try:
            os.chdir(self.home)
            with patch.dict(os.environ, self.env | {"JARVIS_RECORD": str(self.record),
                    "JARVIS_GENERATION": str(json.loads(self.record.read_text())["generation"]),
                    "JARVIS_TEST_HARNESS": "claude", "CLAUDE_CONFIG_DIR": str(self.account)}, clear=True), \
                    patch.object(sys, "argv", ["claude", "--resume", confirmed]), \
                    patch.object(sys, "stdin", io.StringIO("")), \
                    patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                    patch("fixtures.harness.select.select", return_value=([], [], [])), \
                    redirect_stdout(io.StringIO()):
                harness_main()
        finally:
            os.chdir(previous_cwd)
        eof_rows = [json.loads(line) for line in self.rows.read_text().splitlines()[count:]]
        self.assertTrue(any(row.get("eof") is True for row in eof_rows))
        self.assertFalse(any("prompt" in row for row in eof_rows))
        # A real CLI wrapper can override the selected account before exec.
        wrong = self.root / "wrong-account"
        wrong.mkdir()
        native = self.root / "native/claude"
        native.parent.mkdir()
        shutil.copyfile(HARNESS, native)
        native.chmod(0o755)
        wrapper = self.root / "bin/claude"
        wrapper.write_text("#!" + os.environ["JARVIS_TEST_BASH"] + "\nset -euo pipefail\nexport CLAUDE_CONFIG_DIR="
                           + shlex.quote(str(wrong)) + "\nexec " + shlex.quote(str(native)) + ' "$@"\n')
        private = self.root / "private-brief"
        private.write_text("private-account-work")
        wrapper_source = wrapper.read_text()
        for observation in ("process", "native-hook-only"):
            with self.subTest(observation=observation):
                skills = self.root / observation
                for package in ("jarvis", "orch", "mailbox"):
                    shutil.copytree(SKILLS / package / "scripts", skills / package / "scripts")
                if observation == "native-hook-only":
                    # This host capability supplies no process environment.
                    # Keep the reader's matched rule in the disposable copy.
                    reader = skills / "orch/scripts/lib/lane-launch.sh"
                    text = reader.read_text()
                    rule = '  [[ -r "/proc/$$/environ" ]]'
                    self.assertEqual(text.count(rule), 1)
                    reader.write_text(text.replace(rule, '  false && ' + rule.strip()))
                configuration = self.home / ".fixture.json"
                fixture = json.loads(configuration.read_text())
                fixture["skills"] = str(skills)
                configuration.write_text(json.dumps(fixture))
                with patch.dict(globals(), {"SKILLS": skills, "SCRIPT": skills / "jarvis/scripts/jarvis-session"}):
                    wrapper.write_text(wrapper_source)
                    count = len(self.started())
                    prompt_count = sum("prompt" in json.loads(line) for line in self.rows.read_text().splitlines())
                    self.call("start", mode="new", brief=private)
                    self.wait("blocked", "selection-conflict")
                    saved = json.loads(self.record.read_text())
                    self.assertFalse(saved.get("identity_verified", False))
                    self.assertEqual(sum("prompt" in json.loads(line) for line in self.rows.read_text().splitlines()), prompt_count)
                    self.assertEqual(saved["history"]["pending"]["native_session_id"], confirmed)
                    shutil.copyfile(HARNESS, wrapper)
                    self.call("start")
                    self.wait(reason="resumed")
                    saved = json.loads(self.record.read_text())
                    self.assertEqual(saved["pending"]["observed_account"], str(self.account))
                    self.assertTrue(saved["identity_verified"])
                    self.assertEqual(self.started()[-1]["id"], confirmed)
                    self.assertEqual(len(self.started()), count + 2)
                    # Missing native acknowledgement is never equivalent to
                    # the selected account, even with an unavailable reader.
                    terminal = saved["terminal"]
                    for acknowledgement in ("", str(wrong)):
                        result = subprocess.run([self.env["JARVIS_TEST_BASH"], str(skills / "jarvis/scripts/lib/session-backend.sh"),
                            "inspect", terminal["server"], terminal["pane"], "claude", "CLAUDE_CONFIG_DIR",
                            str(self.account), "confirmed", acknowledgement, "delivered"], capture_output=True, text=True, env=self.env, timeout=10)
                        self.assertEqual((result.returncode, result.stdout.strip()), (0, "wrong-account"))
                    self.call("stop")
                    self.wait("stopped")
        fixture["skills"] = str(SKILLS)
        configuration.write_text(json.dumps(fixture))

    def test_start_acquisition_failure_releases_ownership(self):
        for mode, failure in (("first", "set-option"), ("new", "set-option"), ("resume", "set-option"),
                              ("first", "first-write"), ("new", "first-write"), ("resume", "first-write"),
                              ("first", "first-write-retained"), ("resume", "worker-write"), ("resume", "brief-write")):
            with self.subTest(mode=mode, failure=failure):
                if mode == "first":
                    self.record.unlink(missing_ok=True)
                previous = self.started()[-1]["id"] if mode == "resume" else None
                if failure == "set-option":
                    real = shutil.which("tmux")
                    wrapper = self.root / "bin/tmux"
                    flag = self.root / "refuse-setup"
                    flag.touch()
                    wrapper.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
                        + 'for arg in "$@"; do if [[ $arg == set-option && -f ' + shlex.quote(str(flag))
                        + ' ]]; then rm -- ' + shlex.quote(str(flag)) + '; exit 1; fi; done\nexec '
                        + shlex.quote(real) + ' "$@"\n')
                    wrapper.chmod(0o755)
                    self.call("start", mode="new" if mode == "new" else "resume")
                    self.wait("failed", "launch-failed")
                    self.await_worker_result()
                    wrapper.unlink()
                elif failure == "worker-write":
                    replace = os.replace
                    injected = []
                    def refuse_worker_ownership(source, destination):
                        data = json.loads(Path(source).read_text())
                        if data.get("worker") and not injected:
                            injected.append(True)
                            raise OSError("fixture worker write refused")
                        return replace(source, destination)
                    with patch.object(os, "replace", refuse_worker_ownership):
                        answer, code = self.call("start", own_worker=True)
                    self.assertEqual((answer["state"], answer["reason"], code), ("blocked", "record-unreadable", 1))
                    self.assertEqual(injected, [True])
                    self.assertIsNotNone(self.owned_workers[-1].returncode)
                    self.assertNotIn("worker", json.loads(self.record.read_text()))
                else:
                    # A refused preparation leaves the real public request
                    # record available to the same worker acquisition owner.
                    config = self.account / ".claude.json"
                    config.write_text(json.dumps({"projects": {str(self.home): {"hasTrustDialogAccepted": False}}}))
                    self.call("start", mode="new" if mode == "new" else "resume")
                    self.wait("failed", "launch-failed")
                    config.unlink()
                    request = json.loads(self.record.read_text())
                    retained = self.refuse_teardown() if failure == "first-write-retained" else None
                    replace = os.replace
                    injected = []
                    def refuse_first_ownership(source, destination):
                        data = json.loads(Path(source).read_text())
                        if data.get("terminal") and not injected:
                            injected.append(True)
                            raise OSError(errno.EIO, "fixture ownership write refused")
                        return replace(source, destination)
                    open_file = Path.open
                    class RefusedBrief:
                        def __init__(self, stream):
                            self.stream = stream
                        def __enter__(self):
                            return self
                        def __exit__(self, *arguments):
                            self.stream.close()
                        def write(self, content):
                            injected.append(True)
                            raise OSError(errno.EIO, "fixture brief write refused")
                    def refuse_brief(path, *arguments, **options):
                        stream = open_file(path, *arguments, **options)
                        if path.name == "start-" + str(request["generation"]) + ".txt" and arguments == ("x",):
                            return RefusedBrief(stream)
                        return stream
                    errors = io.StringIO()
                    # CI reads these structured fields. Capture intentional
                    # failures so its log exposes only unexpected failures.
                    with patch.dict(os.environ, self.env | {"JARVIS_BASH": self.env["JARVIS_TEST_BASH"]}, clear=True), redirect_stderr(errors):
                        runtime = runpy.run_path(str(SKILLS / "jarvis/scripts/lib/session.py"))
                        if failure == "brief-write":
                            with patch.object(Path, "open", refuse_brief), self.assertRaises(OSError):
                                runtime["Session"](self.home).worker("start", request["generation"])
                        else:
                            with patch.object(os, "replace", refuse_first_ownership), self.assertRaises(OSError):
                                runtime["Session"](self.home).worker("start", request["generation"])
                    diagnostic = re.search(r'jarvis-session: worker-failed operation=("(?:[^"\\]|\\.)*") cause=OSError errno=EIO message=("(?:[^"\\]|\\.)*")', errors.getvalue())
                    self.assertIsNotNone(diagnostic, errors.getvalue())
                    self.assertEqual(json.loads(diagnostic[1]), 'stream.write(launch["brief"])' if failure == "brief-write" else "os.replace(name, self.path)")
                    message = json.loads(diagnostic[2])
                    self.assertIn("fixture brief write refused" if failure == "brief-write" else "fixture ownership write refused", message)
                    self.assertEqual(injected, [True])
                    self.assertEqual(list(self.record.parent.glob("start-*.txt")), [])
                    if retained:
                        saved = json.loads(self.record.read_text())
                        self.assertEqual((saved["state"], saved["reason"]), ("starting", "launching"))
                        self.assertIsNotNone(self.call("status")[0]["terminal"])
                        self.assertEqual(saved["pending"]["generation"], request["generation"])
                        self.assertNotIn("worker", saved)
                        retained.unlink()
                        (self.root / "bin/tmux").unlink()
                        self.call("stop")
                        self.wait("stopped", persisted_stop=True)
                saved = json.loads(self.record.read_text())
                self.assertIsNone(saved["terminal"])
                self.assertEqual(subprocess.run(["tmux", "-L", self.label, "has-session", "-t", "=jarvis"],
                                               capture_output=True, env=self.env).returncode, 1)
                self.call("stop")
                self.wait("stopped", persisted_stop=True)
                self.call("start", mode="new" if mode == "new" else "resume")
                self.wait()
                if previous:
                    self.assertEqual(self.started()[-1]["id"], previous)
                self.call("stop")
                self.wait("stopped", persisted_stop=True)

    def test_unrelated_session_conflicts(self):
        subprocess.run(["tmux", "-L", self.label, "-f", os.devnull, "new-session", "-d", "-s", "jarvis",
                        os.environ["JARVIS_TEST_BASH"], "--noprofile", "--norc"], check=True)
        self.call("start")
        self.wait("blocked", "name-conflict")
        self.assertEqual(subprocess.run(["tmux", "-L", self.label, "has-session", "-t", "=jarvis"], capture_output=True).returncode, 0)

    def test_verbs_answer_with_held_launch(self):
        # The FIFO holds the native identity producer while the fixture ends
        # its own worker. A subsequent Start must acquire a new live worker.
        os.mkfifo(self.gate)
        self.call("start", own_worker=True)
        self.await_launches(1)
        self.assertEqual(len(self.owned_workers), 1)
        handle = self.owned_workers[0]
        original_record = json.loads(self.record.read_text())
        worker = original_record["worker"]
        self.assertEqual(worker["pid"], handle.pid)
        self.assertEqual(self.call("status")[0]["state"], "starting")
        # This unreaped child cannot share its PID with a later process.
        handle.terminate()
        self.assertEqual(handle.wait(timeout=10), -signal.SIGTERM)
        terminal = self.call("status")[0]["terminal"]
        flag = self.refuse_teardown()
        retained, _ = self.call("start")
        self.assertEqual((retained["state"], retained["reason"], retained["terminal"]),
                         ("starting", "launching", terminal))
        self.assertNotIn("worker", json.loads(self.record.read_text()))
        flag.unlink()
        self.assertEqual(self.call("start")[0]["state"], "starting")
        self.await_launches(2)
        replacement_record = json.loads(self.record.read_text())
        replacement = replacement_record["worker"]
        self.assertNotEqual(replacement, worker)
        replacement_terminal = self.call("status")[0]["terminal"]
        self.assertIsNotNone(replacement_terminal)
        self.assertEqual(replacement_terminal, replacement_record["terminal"])
        self.assertEqual(replacement_record["pending"]["generation"], replacement_record["generation"])
        self.assertNotEqual(replacement_record["pending"]["generation"], original_record["pending"]["generation"])
        flag.touch()
        self.assertEqual(self.call("stop", origin="app-off")[0]["state"], "stopping")
        result = self.await_worker_result()
        answer, _ = self.call("status")
        self.assertEqual((answer["state"], answer["reason"], answer["terminal"]),
                         ("starting", "launching", replacement_terminal))
        self.assertTrue(result["app_off"])
        self.assertEqual(self.call("start")[0]["reason"], "app-off")
        flag.unlink()
        self.call("stop")
        self.wait("off")

    def test_record_contract_refuses_corruption(self):
        self.call("stop")
        saved = self.record.read_text()
        for patch in ({"reason": "unknown"}, {"detail": "x" * 201}, {"detail": "a\nb"}):
            with self.subTest(patch=patch):
                self.record.write_text(json.dumps(json.loads(saved) | patch))
                try:
                    answer, code = self.call("status")
                    self.assertEqual((answer["state"], answer["reason"], code), ("blocked", "record-unreadable", 0))
                finally:
                    self.record.write_text(saved)

    def test_controller_server_without_its_pane_is_gone(self):
        # The fixture's tmux server stands for a recorded server pid still
        # running as tmux after its pane ended. A server exits once its last
        # session closes, but until then it serves its socket holding no
        # session; exit-empty off holds it in that state without a bound.
        tmux = ["tmux", "-L", self.label, "-f", os.devnull]
        subprocess.run([*tmux, "new-session", "-d", "-s", "probe", os.environ["JARVIS_TEST_BASH"], "--noprofile", "--norc",
                        ";", "set-option", "-s", "exit-empty", "off"], check=True, env=self.env)
        server, own_socket = subprocess.run([*tmux, "display-message", "-p", "#{pid} #{socket_path}"], check=True,
                                            capture_output=True, text=True, env=self.env).stdout.split()
        subprocess.run([*tmux, "kill-session", "-t", "=probe"], check=True, env=self.env)
        for label, socket in (("socket no server serves", str(self.root / "unserved.sock")),
                              ("server holding no session", own_socket)):
            with self.subTest(label):
                record = {"terminal": {"server": socket, "pane": "%0", "window": "@0"},
                          "server_pid": int(server), "server_started_at": "0", "generation": 1}
                live = subprocess.run([self.env["JARVIS_TEST_BASH"], str(SKILLS / "jarvis/scripts/lib/session-backend.sh"), "live",
                                       socket, server, "0", "%0", "1", "@0", "staging"],
                                      env=self.env, capture_output=True, text=True, timeout=60)
                self.assertEqual(live.returncode, 1, live.stderr)
                with patch.dict(os.environ, self.env | {"JARVIS_BASH": self.env["JARVIS_TEST_BASH"]}, clear=True):
                    runtime = runpy.run_path(str(SKILLS / "jarvis/scripts/lib/session.py"))
                    try:
                        terminal = runtime["Session"](self.home).terminal(record)
                    except runtime["Refusal"] as refusal:
                        self.fail("refusal=" + refusal.reason)
                self.assertIsNone(terminal)

    def test_owned_close_of_a_pane_already_gone(self):
        # A failed successor's runner exits by design once it hands over: its
        # pane, and with no other session its server, can end between
        # end_owned's liveness read and its close. Each row ends the pane or
        # the server right after that read. The close is done either way, and
        # a session end (window=False) also ends the task windows left behind.
        tmux = ["tmux", "-L", self.label]
        for gone, window in (("pane", False), ("server", False), ("pane", True), ("server", True)):
            with self.subTest(gone=gone, window=window):
                # A failed row leaves its server; each row starts on none.
                subprocess.run([*tmux, "kill-server"], capture_output=True, env=self.env)
                pane, window_id = subprocess.run(
                    [*tmux, "new-session", "-d", "-s", "jarvis", "-P", "-F", "#{pane_id} #{window_id}",
                     self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc"],
                    check=True, capture_output=True, text=True, env=self.env).stdout.split()
                subprocess.run([*tmux, "set-option", "-p", "-t", pane, "@jarvis-generation", "1"], check=True, env=self.env)
                task = subprocess.run([*tmux, "new-window", "-d", "-t", "=jarvis", "-P", "-F", "#{pane_id}",
                                       self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc"],
                                      check=True, capture_output=True, text=True, env=self.env).stdout.strip()
                subprocess.run([*tmux, "set-option", "-p", "-t", task, "@jarvis-task", "task-1"], check=True, env=self.env)
                socket, server, started = subprocess.run([*tmux, "display-message", "-p", "-t", pane, "#{socket_path} #{pid} #{start_time}"],
                                                         check=True, capture_output=True, text=True, env=self.env).stdout.split()
                record = {"terminal": {"server": socket, "session": "jarvis", "window": window_id, "pane": pane},
                          "server_pid": int(server), "server_started_at": int(started), "generation": 1,
                          "pending": {"generation": 1}}
                with patch.dict(os.environ, self.env | {"JARVIS_BASH": self.env["JARVIS_TEST_BASH"]}, clear=True):
                    runtime = runpy.run_path(str(SKILLS / "jarvis/scripts/lib/session.py"))
                    session = runtime["Session"](self.home)
                    read = session.terminal
                    reads = []

                    def raced(owner):
                        answer = read(owner)
                        if answer and not reads:
                            subprocess.run([*tmux, "kill-pane", "-t", pane] if gone == "pane" else [*tmux, "kill-server"],
                                           check=True, env=self.env)
                        reads.append(answer)
                        return answer

                    session.terminal = raced
                    errors = io.StringIO()
                    try:
                        with redirect_stderr(errors):
                            session.end_owned(record, window=window)
                    except runtime["Refusal"] as refusal:
                        self.fail("refusal=" + refusal.reason + "\n" + errors.getvalue())
                self.assertTrue(reads[0])
                windows = subprocess.run([*tmux, "list-panes", "-s", "-t", "=jarvis", "-F", "#{pane_id}"],
                                         capture_output=True, text=True, env=self.env)
                # A window end leaves the task window to the successor.
                self.assertEqual(windows.stdout.split(), [task] if gone == "pane" and window else [])

    def test_bad_arguments_have_no_object(self):
        for arguments in ([], ["unknown"], ["status"], ["_worker", "start", str(self.home), "1"],
                          ["start", "--home", str(self.home), "--harness", "unknown"],
                          *(["start", "--home", str(self.home), "--harness", "claude", "--account", str(self.account),
                             "--mode", "new", "--origin", "manual", *stated]
                            for stated in (["--model", "standard"], ["--effort", "high"], ["--model", "standard", "--effort", ""],
                                           ["--model", "claude:standard", "--effort", "high"]))):
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(SCRIPT), *arguments], env=self.env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertEqual(len(result.stderr.splitlines()), 1)
                self.assertRegex(result.stderr, r"^jarvis-session: [a-z-]+=[a-z-]+\n$")

    def test_native_fixture_uses_installed_toolchain(self):
        rustup = shutil.which("rustup")
        self.assertIsNotNone(rustup, "native-fixture: dependency=rustup")
        compiler = shutil.which("rustc")
        self.assertIsNotNone(compiler, "native-fixture: dependency=rustc")
        with tempfile.TemporaryDirectory() as allocation:
            scratch = Path(allocation).resolve()
            environment = dict(os.environ)
            environment.pop("RUSTUP_TOOLCHAIN", None)
            environment.pop("JARVIS_TEST_NATIVE", None)
            installed = subprocess.run([rustup, "which", "rustc"], cwd=scratch,
                                       env=environment, capture_output=True, text=True, timeout=60)
            self.assertEqual(installed.returncode, 0, installed.stderr)
            packaged = scratch / "packaged"
            packaged.mkdir()
            for name, executable in (("rustup", rustup), ("rustc", compiler)):
                wrapper = packaged / name
                wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(executable) + ' "$@"\n')
                wrapper.chmod(0o755)
            rustup, compiler = str(packaged / "rustup"), str(packaged / "rustc")
            environment.update(HOME=str(scratch / "home"), RUSTUP_HOME=str(scratch / "rustup"),
                               CARGO_HOME=str(scratch / "cargo"), RUSTUP_AUTO_INSTALL="0")
            Path(environment["HOME"]).mkdir()
            binary = scratch / "bin"
            binary.mkdir()
            # A packaged rustup can be a wrapper whose exec fixes argv[0] to
            # rustup. Forward through the supplied rustc entry point instead.
            proxy = binary / "rustc"
            proxy.write_text("#!/bin/sh\nexec " + shlex.quote(compiler) + ' "$@"\n')
            proxy.chmod(0o755)
            environment["PATH"] = str(binary) + os.pathsep + environment["PATH"]
            for arguments in (("toolchain", "link", "fixture-installed", str(Path(installed.stdout.strip()).parent.parent)),
                              ("default", "fixture-installed")):
                configured = subprocess.run([rustup, *arguments], cwd=scratch, env=environment,
                                            capture_output=True, text=True, timeout=60)
                self.assertEqual(configured.returncode, 0, configured.stderr)
            missing = subprocess.run([rustup, "which", "rustc"], cwd=ROOT, env=environment,
                                     capture_output=True, text=True, timeout=60)
            self.assertNotEqual(missing.returncode, 0)
            self.assertEqual(missing.stdout, "")
            # The real Rustup proxy must compile from this caller's repository
            # while the fixture owner selects a directory outside it.
            previous_cwd = Path.cwd()
            try:
                os.chdir(ROOT)
                with patch.dict(os.environ, environment, clear=True):
                    try:
                        with native_launcher() as native:
                            self.assertTrue(native.is_file() and os.access(native, os.X_OK))
                    except RuntimeError as failure:
                        self.fail(str(failure))
            finally:
                os.chdir(previous_cwd)

    def test_native_fixture_reports_compiler_failure(self):
        # This row consumes the structured CI failure record, including the
        # empty-stderr wrapper failure and a compiler ended by a signal.
        environment = dict(os.environ)
        environment.pop("JARVIS_TEST_NATIVE", None)
        for status, stdout, stderr in ((1, "wrapper rejected compiler arguments", ""),
                                       (-signal.SIGKILL, "", ""), (7, "", "compiler failed")):
            with self.subTest(returncode=status):
                result = subprocess.CompletedProcess([], status, stdout, stderr)
                with patch.dict(os.environ, environment, clear=True), \
                     patch("fixtures.harness.subprocess.run", return_value=result):
                    with self.assertRaises(RuntimeError) as caught:
                        with native_launcher():
                            self.fail("compiler failure accepted")
                record = json.loads(str(caught.exception).split(" ", 2)[2])
                self.assertEqual(record, {"returncode": status, "signal": -status if status < 0 else None,
                                          "stdout": stdout, "stderr": stderr})

    def test_native_fixture_reports_compiler_timeout(self):
        # The CI failure record must retain output from a compiler that stalls.
        # This timer-wiring row shortens only its child driver's compile limit.
        compiler = self.root / "rustc"
        compiler.write_text("#!" + sys.executable + "\n"
                            "import os, signal\n"
                            "os.write(1, b'compiler stdout \\xc3\\xa9\\n')\n"
                            "os.write(2, b'compiler stderr \\xe2')\n"
                            "signal.pause()\n")
        compiler.chmod(0o755)
        driver = """\
import subprocess
import sys
from unittest.mock import patch
from fixtures.harness import native_launcher

run = subprocess.run
def bounded_compile(*args, **kwargs):
    kwargs["timeout"] = 1
    return run(*args, **kwargs)

try:
    with patch("fixtures.harness.subprocess.run", side_effect=bounded_compile):
        with native_launcher():
            pass
except RuntimeError as failure:
    print(failure)
    sys.exit(23)
"""
        environment = dict(os.environ)
        environment.pop("JARVIS_TEST_NATIVE", None)
        environment["PATH"] = str(self.root) + os.pathsep + environment["PATH"]
        result = subprocess.run([sys.executable, "-c", driver], env=environment,
                                cwd=HARNESS_SCRIPT.parent.parent, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        category, record = result.stdout.removeprefix("native-fixture: ").split(" ", 1)
        self.assertEqual(category, "compile-timeout")
        self.assertEqual(json.loads(record), {"timeout": 1, "stdout": "compiler stdout é\n",
                                              "stderr": "compiler stderr \\xe2"})
        self.assertEqual(result.stderr, "")

    def test_cancelled_replacement_keeps_the_live_owner(self):
        for phase in ("pending", "running"):
            with self.subTest(predecessor_state=phase):
                launches = len(self.started()) if self.rows.exists() else 0
                if phase == "pending":
                    os.mkfifo(self.gate)
                self.call("start")
                self.await_launches(launches + 1)
                first = self.call("status")[0] if phase == "pending" else self.wait()
                original = json.loads(self.record.read_text())
                account = self.root / ("pending-account-" + phase)
                account.mkdir()
                (account / ".claude.json").write_text('{"fixture":"hold-preparation"}')
                acknowledgement = self.root / ("prepare-ack-" + phase)
                gate = self.root / ("prepare-gate-" + phase)
                os.mkfifo(gate)
                jq = shutil.which("jq")
                wrapper = self.root / "bin/jq"
                wrapper.write_text("#!/usr/bin/env python3\nimport sys, subprocess\nfrom pathlib import Path\n"
                    + "data=sys.stdin.read()\nack=Path(" + repr(str(acknowledgement)) + ")\n"
                    + "if 'hold-preparation' in data and not ack.exists():\n ack.write_text('ready\\n')\n"
                    + " with Path(" + repr(str(gate)) + ").open() as stream: stream.read(1)\n"
                    + "result=subprocess.run([" + repr(jq) + ", *sys.argv[1:]], input=data, text=True, capture_output=True)\n"
                    + "sys.stdout.write(result.stdout)\nsys.stderr.write(result.stderr)\nsys.exit(result.returncode)\n")
                wrapper.chmod(0o755)
                self.call("start", account=account)
                self.await_rows(acknowledgement, 1)
                replacement = json.loads(self.record.read_text())
                generation = replacement["generation"]
                try:
                    answer, code = self.call("start")
                    restored = json.loads(self.record.read_text())
                    self.assertEqual(restored["generation"], generation + 1)
                    if phase == "pending":
                        self.assertEqual((answer["state"], answer["reason"], code), ("starting", "launching", 0))
                        self.assertNotEqual(restored["worker"], original["worker"])
                        self.assertNotEqual(restored["worker"], replacement["worker"])
                    else:
                        self.assertEqual((answer["state"], answer["reason"], code), ("running", "existing", 0))
                        self.assertEqual(answer["terminal"], first["terminal"])
                finally:
                    # Preparation acknowledged its held reader. Release it
                    # even when a planted cancellation defect fails the row.
                    with gate.open("w") as stream:
                        stream.write("1")
                log = self.record.parent / "session.log"
                deadline = time.monotonic() + 10
                marker = "jarvis-session: worker=cancelled generation=" + str(generation)
                prefix = r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z origin=manual "
                while not any(re.sub(prefix, "", line) == marker for line in log.read_text().splitlines()) and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(any(re.match(prefix, line) and re.sub(prefix, "", line) == marker
                                    for line in log.read_text().splitlines()))
                if phase == "pending":
                    self.await_launches(launches + 2)
                    current = json.loads(self.record.read_text())
                    self.assertEqual(current["pending"]["generation"], current["generation"])
                    self.assertNotEqual(current["pending"]["generation"], original["pending"]["generation"])
                    self.assertEqual(self.call("status")[0]["state"], "starting")
                    with self.gate.open("w") as stream:
                        stream.write("1")
                    first = self.wait()
                    self.assertEqual(first["account"], str(self.account))
                    self.assertEqual(len(self.started()), launches + 2)
                    self.gate.unlink()
                    self.call("stop")
                    self.wait("stopped")
                    continue
                self.assertEqual(self.call("status")[0]["state"], "running")
                self.assertEqual(len(self.started()), launches + 1)
                # The native account config emits an explicit trust refusal.
                (account / ".claude.json").write_text(json.dumps({"projects": {str(self.home): {"hasTrustDialogAccepted": False}}}))
                self.call("start", account=account)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    record = json.loads(self.record.read_text())
                    if record["state"] == "running":
                        break
                    time.sleep(0.05)
                answer, _ = self.call("status")
                self.assertEqual((answer["state"], answer["account"], answer["terminal"]),
                                 ("running", str(self.account), first["terminal"]))
                self.assertEqual(record["generation"], generation + 2)
                self.assertEqual(len(self.started()), launches + 1)
                flag = self.refuse_teardown()
                before_stop = json.loads(self.record.read_text())
                origins = ("manual", "app-off")
                with ThreadPoolExecutor() as executor:
                    answers = list(executor.map(lambda origin: self.call("stop", origin=origin), origins))
                self.assertTrue(all(code == 0 and answer["state"] == "stopping" for answer, code in answers))
                record = self.await_worker_result()
                self.assertEqual(record["generation"], before_stop["generation"] + len(origins))
                self.assertEqual(record["pending"]["generation"], before_stop["pending"]["generation"])
                answer, _ = self.call("status")
                self.assertEqual((answer["state"], answer["reason"], answer["terminal"]),
                                 ("running", "existing", first["terminal"]))
                self.assertTrue(record["app_off"])
                self.assertEqual(record["history"]["pending"]["native_session_id"], original["pending"]["native_session_id"])
                self.assertEqual(self.call("start")[0]["reason"], "app-off")
                flag.unlink()
                self.call("stop")
                self.wait("off")
                self.assertEqual(json.loads(self.record.read_text())["generation"], record["generation"] + 1)

    # Attach rows drive real tmux clients on pseudo-terminals. A client
    # outside tmux carries no TMUX; one the command runs inside sets both.
    def outside_env(self):
        return {key: value for key, value in self.env.items() if key not in ("TMUX", "TMUX_PANE")} | {"TERM": "xterm-256color"}

    def tmux_read(self, socket, *args):
        return subprocess.run(["tmux", "-S", socket, *args], env=self.outside_env(), capture_output=True, text=True, timeout=10)

    def stand_in(self, *sessions):
        # The owner's default server, played by a server of this fixture's own.
        label = self.label + "-owner"
        tmux = ["tmux", "-L", label, "-f", os.devnull]
        for name in sessions:
            subprocess.run([*tmux, "new-session", "-d", "-s", name, os.environ["JARVIS_TEST_BASH"], "--noprofile", "--norc"],
                           check=True, env=self.outside_env())
        self.addCleanup(subprocess.run, ["tmux", "-L", label, "kill-server"], capture_output=True, env=self.outside_env())
        return subprocess.run([*tmux, "display-message", "-p", "#{socket_path}"], check=True, env=self.outside_env(),
                              capture_output=True, text=True).stdout.strip()

    def pane_of(self, socket, session):
        return self.tmux_read(socket, "display-message", "-p", "-t", "=" + session + ":", "#{pane_id}").stdout.strip()

    def inside_env(self, socket, session):
        line = self.tmux_read(socket, "display-message", "-p", "-t", "=" + session + ":", "#{socket_path},#{pid},#{session_id}")
        return self.outside_env() | {"TMUX": line.stdout.strip(), "TMUX_PANE": self.pane_of(socket, session)}

    def pty_client(self, argv, sockets):
        # The drain keeps the client's terminal writes from filling the pty.
        # Cleanup reaps the client before the stand-in and scratch cleanups.
        primary, secondary = os.openpty()
        fcntl.ioctl(secondary, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        client = subprocess.Popen(argv, stdin=secondary, stdout=secondary, stderr=secondary, env=self.outside_env(),
                                  start_new_session=True)
        os.close(secondary)
        drain = threading.Thread(target=lambda: self.drain(primary), daemon=True)
        drain.start()

        def release():
            for socket in sockets:
                for line in self.tmux_read(socket, "list-clients", "-F", "#{client_pid} #{client_name}").stdout.splitlines():
                    pid, name = line.split(" ", 1)
                    if int(pid) == client.pid:
                        self.tmux_read(socket, "detach-client", "-t", name)
            try:
                client.wait(timeout=5)
            except subprocess.TimeoutExpired:
                client.kill()
                client.wait(timeout=5)
            drain.join(timeout=5)
            os.close(primary)
        self.addCleanup(release)
        return client

    @staticmethod
    def drain(fd):
        try:
            while os.read(fd, 4096):
                pass
        except OSError:
            pass

    def clients(self, socket, deadline=10, until=None):
        # The client rows of one server, once they satisfy until.
        limit = time.monotonic() + deadline
        while True:
            listed = self.tmux_read(socket, "list-clients", "-F", "#{client_pid} #{session_name}")
            rows = listed.stdout.splitlines() if listed.returncode == 0 else []
            if until is None or until(rows) or time.monotonic() >= limit:
                return rows
            time.sleep(0.05)

    def attach(self, env):
        # No terminal on stdin: a regressed exec of tmux attach-session then
        # fails at once rather than drawing on the runner's terminal.
        return subprocess.run([str(SCRIPT), "attach", "--home", str(self.home)], env=env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=60)

    def test_attach_outside_tmux(self):
        self.call("start")
        terminal = self.wait()["terminal"]
        # The command status prints runs as printed, from a PATH without it.
        prefix = "jarvis-session: attach="
        printed = [line[len(prefix):] for line in self.stderr.splitlines() if line.startswith(prefix)]
        self.assertEqual(len(printed), 1)
        command = shlex.split(printed[0])
        self.assertTrue(os.path.isabs(command[0]), command)
        self.assertEqual(command[1:], ["attach", "--home", str(self.home)])
        client = self.pty_client(command, [terminal["server"]])
        # The command execs the client: the attached client is its process.
        rows = self.clients(terminal["server"], until=bool)
        self.assertEqual(rows, [str(client.pid) + " jarvis"])
        self.call("stop")
        self.wait("stopped")
        self.assertFalse([line for line in self.stderr.splitlines() if line.startswith("jarvis-session: attach=")])

    # The terminals the rows put on PATH. fixture-term takes its command after
    # -e, as a terminal a $TERMINAL names does, and xdg-terminal-exec takes it
    # bare; each runs it on a pseudo-terminal of its own and records its name
    # and what it was handed. FIXTURE_TERMINAL_MODE fail exits 1 with a
    # reason on stderr; idle exits 0 at once, as a launcher handing off to a
    # server can.
    TERMINAL_STUB = """#!/usr/bin/env python3
import fcntl, json, os, pty, struct, sys, termios
name = os.path.basename(sys.argv[0])
if os.environ.get("FIXTURE_TERMINAL_MODE") == "fail":
    sys.exit(name + ": display unavailable")
if os.environ.get("FIXTURE_TERMINAL_MODE") == "idle":
    sys.exit(0)
command = sys.argv[1:] if name == "xdg-terminal-exec" else sys.argv[2:]
assert name == "xdg-terminal-exec" or sys.argv[1] == "-e", sys.argv
assert command[:2] == ["bash", "-lc"], sys.argv
with open(os.environ["FIXTURE_TERMINAL_RECORD"], "w") as stream:
    json.dump({"name": name, "pid": os.getpid(),
               "env": {key: os.environ.get(key) for key in ("TMUX", "TMUX_PANE", "WAYLAND_DISPLAY")}}, stream)
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    os.execvp(command[0], command)
try:
    while os.read(fd, 4096):
        pass
except OSError:
    pass
os.waitpid(pid, 0)
"""

    def terminal_stubs(self, desktop):
        # fixture-term on PATH always, beside xdg-terminal-exec on the
        # desktop's PATH and beside every other command but it otherwise.
        stubs = self.root / ("terminals" if desktop else "terminals-bare")
        stubs.mkdir(exist_ok=True)
        for name in ("fixture-term", "xdg-terminal-exec") if desktop else ("fixture-term",):
            (stubs / name).write_text(self.TERMINAL_STUB)
            (stubs / name).chmod(0o755)
        return str(stubs) + os.pathsep + (self.env["PATH"] if desktop else self.bare_path())

    def bare_path(self):
        # Every command on PATH but xdg-terminal-exec, so no row resolves the
        # developer's own terminal.
        farm = self.root / "bare-path"
        if farm.exists():
            return str(farm)
        farm.mkdir()
        for directory in self.env["PATH"].split(os.pathsep):
            if not os.path.isdir(directory):
                continue
            for entry in os.scandir(directory):
                if entry.name != "xdg-terminal-exec" and not os.path.lexists(farm / entry.name):
                    (farm / entry.name).symlink_to(entry.path)
        self.assertIsNone(shutil.which("xdg-terminal-exec", path=str(farm)))
        return str(farm)

    # open-window's terminal choice, one row per case: the $TERMINAL the
    # caller sets (None for unset), whether xdg-terminal-exec is on PATH, and
    # the outcome. A $TERMINAL that names a terminal on PATH changes no
    # outcome. The window and refusal tests each run the rows of their
    # outcome.
    TERMINAL_CHOICE = (
        ("xdg-terminal-exec", None, True, "window"),
        ("TERMINAL beside xdg-terminal-exec", "fixture-term", True, "window"),
        ("no xdg-terminal-exec", None, False, "refused"),
        ("TERMINAL, no xdg-terminal-exec", "fixture-term", False, "refused"),
    )

    def choices(self, outcome):
        # The rows of one outcome, each with the TERMINAL (None for unset)
        # and PATH it runs under.
        return [(label, terminal, self.terminal_stubs(desktop))
                for label, terminal, desktop, result in self.TERMINAL_CHOICE if result == outcome]

    @staticmethod
    def chosen(env, terminal, path):
        return {key: value for key, value in env.items() if key != "TERMINAL"} | {"PATH": path} | (
            {"TERMINAL": terminal} if terminal else {})

    def test_attach_opens_a_terminal_window(self):
        self.call("start")
        home = self.wait()["terminal"]["server"]
        owner = self.stand_in("owner")
        original = self.pty_client(["tmux", "-S", owner, "attach-session", "-t", "=owner"], [owner, home])
        before = [str(original.pid) + " owner"]
        self.assertEqual(self.clients(owner, until=bool), before)
        inside = self.inside_env(owner, "owner")

        def release(handed):
            # The terminal ends once its client leaves the home server.
            self.tmux_read(home, "detach-client", "-s", "=jarvis")
            if not handed.exists():
                return
            pid, limit = json.loads(handed.read_text())["pid"], time.monotonic() + 10
            while time.monotonic() < limit:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
        for index, (label, terminal, path) in enumerate(self.choices("window")):
            with self.subTest(label):
                handed = self.root / ("terminal-" + str(index) + ".json")
                env = self.chosen(inside, terminal, path) | {"HOME": str(self.root), "FIXTURE_TERMINAL_RECORD": str(handed)}
                result = self.attach(env)
                try:
                    self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
                    # The window's own client attached; the caller's client,
                    # its server and its session are where they were.
                    record = json.loads(handed.read_text())
                    self.assertEqual(record["name"], "xdg-terminal-exec")
                    rows = self.clients(home)
                    self.assertEqual([row.split(" ")[1] for row in rows], ["jarvis"])
                    parent = subprocess.run(["ps", "-o", "ppid=", "-p", rows[0].split(" ")[0]], capture_output=True, text=True)
                    self.assertEqual(parent.stdout.strip(), str(record["pid"]))
                    self.assertEqual(self.clients(owner), before)
                    self.assertEqual(self.tmux_read(owner, "has-session", "-t", "=owner").returncode, 0)
                    self.assertEqual(record["env"], {"TMUX": None, "TMUX_PANE": None, "WAYLAND_DISPLAY": "fixture-wayland"})
                finally:
                    release(handed)

    def test_attach_refuses_a_terminal_that_does_not_open(self):
        self.call("start")
        home = self.wait()["terminal"]["server"]
        owner = self.stand_in("owner")
        desktop = self.terminal_stubs(True)
        # Jarvis already open in another window: its client is no proof that
        # this attach's window opened.
        held = self.pty_client(["tmux", "-S", home, "attach-session", "-t", "=jarvis"], [home])
        existing = [str(held.pid) + " jarvis"]
        self.assertEqual(self.clients(home, until=bool), existing)
        # A launcher that does not open a window, and a missing launcher,
        # refuse rather than attach in the caller's pane.
        unresolved = ("terminal-unresolved", "jarvis-session: terminal=unresolved launcher=xdg-terminal-exec")
        rows = [("launcher exits non-zero", None, desktop, "fail", ("terminal-launch-failed",
                 "jarvis-session: terminal=xdg-terminal-exec exit=1\nxdg-terminal-exec: display unavailable")),
                ("no client within the bound", None, desktop, "idle",
                 ("terminal-launch-failed", "jarvis-session: terminal=xdg-terminal-exec client=none seconds=5")),
                *((label, terminal, path, None, unresolved) for label, terminal, path in self.choices("refused"))]
        for label, terminal, path, mode, (cause, detail) in rows:
            with self.subTest(label):
                env = self.chosen(self.inside_env(owner, "owner"), terminal, path) | (
                    {"FIXTURE_TERMINAL_MODE": mode} if mode else {})
                result = self.attach(env)
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (1, "", "jarvis-session: attach=refused cause=" + cause + "\n" + detail + "\n"))
                self.assertEqual(self.clients(home), existing)

    def test_attach_refuses_without_a_controller(self):
        for label in ("never started", "stopped"):
            with self.subTest(label):
                if label == "stopped":
                    self.call("stop")
                saved = self.record.read_bytes() if self.record.exists() else None
                result = self.attach(self.outside_env())
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (1, "", "jarvis-session: attach=refused cause=no-controller\n"))
                self.assertEqual(self.record.read_bytes() if self.record.exists() else None, saved)
                self.assertNotEqual(subprocess.run(["tmux", "-L", self.label, "list-sessions"], capture_output=True,
                                                   env=self.outside_env()).returncode, 0)


class FixtureLifetimeContract(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()

    def test_clients_release_before_scratch(self):
        fixture = SessionContract()
        fixture.setUp()
        released = []

        def before_removal():
            self.assertTrue(fixture.root.is_dir())
            self.assertIsNotNone(client.poll())
            self.assertNotEqual(fixture.tmux_read(server, "list-sessions").returncode, 0)
            released.append(True)

        fixture.addCleanup(before_removal)
        try:
            server = fixture.stand_in("keeper")
            client = fixture.pty_client(["tmux", "-S", server, "attach-session", "-t", "=keeper"], [server])
            self.assertEqual(fixture.clients(server, until=bool), [str(client.pid) + " keeper"])
        finally:
            try:
                fixture.tearDown()
            finally:
                self.assertTrue(fixture.doCleanups())
        self.assertEqual(released, [True])
        self.assertFalse(fixture.root.exists())

    def test_stop_writer_exits_before_scratch(self):
        skills = self.root / "skills"
        scripts = skills / "jarvis/scripts"
        shutil.copytree(SKILLS / "jarvis/scripts", scripts)
        for dependency in ("mailbox", "orch", "github"):
            (skills / dependency).symlink_to(SKILLS / dependency, target_is_directory=True)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(15)
            source = scripts / "lib/session.py"
            self.assertFalse(source.is_symlink())
            before = source.read_text()
            match = '                    self.end_owned(record.get("predecessor"))\n'
            self.assertEqual(before.count(match), 1)
            barrier = ("                    import socket\n"
                       "                    with socket.create_connection(" + repr(listener.getsockname()) + ", timeout=15) as peer:\n"
                       "                        peer.sendall(b'1')\n"
                       "                        assert peer.recv(1) == b'1'\n")
            changed = before.replace(match, match + barrier)
            self.assertNotEqual(changed, before)
            source.write_text(changed)
            with patch.dict(globals(), {"SKILLS": skills, "SCRIPT": scripts / "jarvis-session"}):
                fixture = SessionContract()
                fixture.setUp()
                released = False
                real_wait = subprocess.Popen.wait

                def release_writer():
                    nonlocal released
                    with listener.accept()[0] as peer:
                        peer.settimeout(15)
                        self.assertEqual(peer.recv(1), b"1")
                        saved = json.loads(fixture.record.read_text())
                        self.assertEqual(saved["state"], "stopping")
                        self.assertTrue(fixture.root.is_dir())
                        self.assertEqual(fixture.call("status")[0]["state"], "stopped")
                        peer.sendall(b"1")
                    released = True

                def wait(child, *args, **kwargs):
                    if child in fixture.owned_workers and child.poll() is None:
                        release_writer()
                    return real_wait(child, *args, **kwargs)

                def before_removal():
                    worker = fixture.owned_workers[-1]
                    returncode = worker.poll()
                    saved = json.loads(fixture.record.read_text())
                    if not released:
                        # Reap even a rejected control's held writer.
                        release_writer()
                        real_wait(worker, timeout=15)
                    self.assertEqual(returncode, 0)
                    self.assertEqual((saved["state"], saved["terminal"]), ("stopped", None))

                fixture.addCleanup(before_removal)
                try:
                    fixture.call("start", own_worker=True)
                    fixture.wait()
                    self.assertEqual(fixture.owned_workers[-1].wait(timeout=15), 0)
                finally:
                    try:
                        with patch.object(subprocess.Popen, "wait", wait):
                            fixture.tearDown()
                    finally:
                        self.assertTrue(fixture.doCleanups())
                self.assertFalse(fixture.root.exists())

    def test_lifetime_controls(self):
        rows = (
            ("scratch-first", "            subprocess.run([\"tmux\", \"-L\", self.label, \"kill-server\"], capture_output=True, env=self.env)\n",
             "            self.scratch.cleanup()\n", "test_clients_release_before_scratch"),
            ("skip-join", "            for worker in self.owned_workers:\n                try:\n                    worker.wait(timeout=5)\n",
             "            for worker in self.owned_workers:\n                try:\n                    worker.wait(timeout=5) if False else worker.poll()\n", "test_stop_writer_exits_before_scratch"),
        )
        for name, match, mutation, contract in rows:
            with self.subTest(name=name):
                tests = self.root / name / "skills/jarvis/tests"
                tests.mkdir(parents=True)
                (tests / "fixtures").symlink_to(HARNESS_SCRIPT.parent, target_is_directory=True)
                shutil.copyfile(Path(__file__).with_name("session.test.sh"), tests / "session.test.sh")
                source = Path(__file__).read_text()
                self.assertEqual(source.count(match), 1)
                changed = source.replace(match, match + mutation if name == "scratch-first" else mutation)
                self.assertNotEqual(changed, source)
                (tests / "session_test.py").write_text(changed)
                result = subprocess.run([os.environ["JARVIS_TEST_BASH"], str(tests / "session.test.sh"),
                                         "FixtureLifetimeContract." + contract],
                                        env=os.environ | {"JARVIS_TEST_SKILLS": str(SKILLS), "JARVIS_TEST_NATIVE": str(HARNESS)},
                                        capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("FAIL: " + contract, result.stderr)


if __name__ == "__main__":
    with native_launcher() as HARNESS:
        unittest.main()
