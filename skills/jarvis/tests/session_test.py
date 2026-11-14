"""Contract rows use real tmux and the real identity carrier, with CLI fixtures."""
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import signal
import struct
import termios
import threading
from fixtures.harness import native_launcher
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from fixtures.tmux_scope import SCOPE, isolate
isolate()


ROOT = Path(__file__).resolve().parents[3]
SKILLS = Path(os.environ.get("JARVIS_TEST_SKILLS", ROOT / "skills"))
SCRIPT = Path(os.environ.get("JARVIS_TEST_SCRIPT", SKILLS / "jarvis/scripts/jarvis-session"))
HARNESS_SCRIPT = Path(__file__).with_name("fixtures") / "harness.py"
# The Start procedure every controller is briefed with, its private
# brief after it.
START_BRIEF = "Read .agents/skills/jarvis/SKILL.md and follow the Start procedure in .agents/skills/jarvis/workflows/session.md."
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
            # An adopting Start answers the succession it began, or its end.
            assert answer["state"] in ("handing-over", "running")
        elif verb == "start" and not duplicate_boot:
            assert answer["state"] in ("running", "starting")
        elif verb == "stop":
            assert answer["state"] in ("off", "stopped", "stopping")
    return answer


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
        original = (b"# fixture private settings\r\nSECRET='first line "
                    b"JARVIS_MAIN_HOST=literal-secret-text last line'\n"
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
                literal = "host:/home/O Neil $USER `id` $(touch " + str(sentinel) + ")"
                for words, expected in ((("--set", literal), literal), (("--set", "next:/main"), "next:/main"),
                                        (("--clear",), ""), (("--clear",), "")):
                    self.assertEqual(self.value(*words), expected)
                    self.assertEqual(self.value("--get"), expected)
                    # Independently compare the complete pre-existing bytes
                    # and mode; a quoted secret is not an assignment list.
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
        # A valid role the private file cannot hold as a single-quoted value.
        for value, problem in (("host:/home/O'Neil", "apostrophe"), ("host\x01:/main", "control-character")):
            with self.subTest(value=value):
                result = self.command("main-host", "--set=" + value, code=2)
                self.assertEqual(result.stdout, "")
                self.assertIn("main-host=refused cause=value-unwritable key=JARVIS_MAIN_HOST problem=" + problem,
                              result.stderr)
                self.assertEqual(private.read_bytes(), original)
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
    """jarvis-session over agent-runtime's controller record: the built
    runtime opens the fixture harness on the home's private tmux server."""

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        # unittest releases later acquisitions first, including on failure.
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        # The home is its own repository, so its settings and its state
        # directory are its own wherever the scratch stands, a checkout
        # included. Its starting files skip the initialization step.
        for words in (("init", "-q"), ("config", "gc.auto", "0"), ("config", "maintenance.auto", "false")):
            subprocess.run(["git", "-C", str(self.home), *words], check=True, capture_output=True,
                           env={"PATH": os.environ["PATH"], "HOME": str(self.root), "GIT_CONFIG_NOSYSTEM": "1"})
        (self.home / "AGENTS.md").write_text("fixture standing instructions\n")
        (self.home / "memory").mkdir()
        (self.home / "memory/MEMORY.md").write_text("# Memory index\n")
        (self.home / "state").mkdir()
        (self.home / "state/handoff.md").write_text("# Handoff\nWhere the work stands.\n")
        self.rows = self.root / "rows.jsonl"
        self.fixture = {"rows": str(self.rows), "unsigned": [], "mute": []}
        self.write_fixture()
        shutil.copyfile(HARNESS_SCRIPT, self.home / ".fixture-harness.py")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        shutil.copyfile(HARNESS, bin_dir / "claude")
        (bin_dir / "claude").chmod(0o755)
        # The platform manager publishes no policy, and no job reaches the
        # host's user manager: the runtime's jobs run under setsid.
        for tool, body in (("systemctl", "exit 0"), ("launchctl", "exit 0"), ("systemd-run", "exit 1")):
            (bin_dir / tool).write_text("#!/bin/sh\n" + body + "\n")
            (bin_dir / tool).chmod(0o755)
        login = self.root / "login"
        login.mkdir()
        # This fixture changes account identity: inherit control transport only.
        self.env = {key: value for key, value in os.environ.items()
                    if key in {"PATH", "USER", "LOGNAME", "SHELL", "LANG", "TERM", "AGENT_RUNTIME_CACHE"}
                    or key.startswith("LC_")} | {
                        "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "HOME": str(login),
                        "XDG_STATE_HOME": str(self.root / "state"), "XDG_CONFIG_HOME": str(login / ".config"),
                        "XDG_SESSION_ID": "fixture-login", "WAYLAND_DISPLAY": "fixture-wayland", "DISPLAY": ":fixture",
                        "JARVIS_TEST_BASH": os.environ["JARVIS_TEST_BASH"]}
        if "AGENT_RUNTIME_CACHE" not in self.env:
            # The runtime wrappers resolve their cache under HOME, which is
            # the login's here: the caller's own cache stays the one read.
            cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
            self.env["AGENT_RUNTIME_CACHE"] = str(cache / "kendex/agent-runtime")
        self.account_state = self.root / "account-state"
        self.accounts = []
        self.account = self.plant_account("claude-a", 10)
        key = hashlib.sha256(os.fsencode(str(self.home))).hexdigest()
        self.record = self.root / "state/kendex/jarvis" / key / "jarvis-session.json"
        self.label = "jarvis-" + key[:32]
        self.fleet = self.root / "orch-state/workflow-state-oversee.json"

    def tearDown(self):
        try:
            if self.fleet.exists():
                self.call("stop")
                self.settled()
        finally:
            subprocess.run(["tmux", "-L", self.label, "kill-server"], capture_output=True, env=self.env)

    def write_fixture(self):
        (self.home / ".fixture.json").write_text(json.dumps(self.fixture))

    def plant_account(self, name, used):
        """A Claude account the account judge reads measured: its sign-in
        and a usage record of `used` percent of its week, fresh."""
        account = self.root / "accounts" / name
        account.mkdir(parents=True)
        now = int(time.time())
        credential = account / ".credentials.json"
        credential.write_text(json.dumps({"claudeAiOauth": {
            "accessToken": "token-" + name, "refreshToken": "refresh-" + name,
            "expiresAt": (now + 365 * 86400) * 1000, "subscriptionType": "max"}}))
        os.utime(credential, (now - 60, now - 60))
        iso = lambda seconds: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + seconds))
        text = str(account)
        crc = subprocess.run(["cksum"], input=text.encode(), capture_output=True, check=True).stdout.split()[0].decode()
        usage = self.account_state / "usage" / ("claude-" + crc + "-" + str(len(text.encode())) + ".json")
        usage.parent.mkdir(parents=True, exist_ok=True)
        usage.write_text(json.dumps({"harness": "claude", "config_dir": text, "fetched_at": now, "sample_claims": 1,
                                     "prior": None, "usage": {
                                         "five_hour": {"utilization": 5, "resets_at": iso(3600)},
                                         "seven_day": {"utilization": used, "resets_at": iso(60 * 3600)}}}))
        self.accounts.append(text)
        # The home's state directory is the scratch's own: a home under a
        # checkout would otherwise resolve that checkout's common root.
        # No preference: a context succession keeps its own entry, a wall
        # walks the caller's own harness, and no model class is read.
        settings = {"ORCH_STATE_DIR": str(self.root / "orch-state"), "AGENT_RUNTIME_CONTROLLER_PREFERENCE": "",
                    "AGENT_RUNTIME_ACCOUNT_STATE_DIR": str(self.account_state),
                    "AGENT_RUNTIME_ACCOUNT_DIRS": ":".join(self.accounts),
                    "AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR": "0"}
        (self.home / "kendex.settings.toml").write_text("[env]\n" + "".join(
            key + " = " + json.dumps(value) + "\n" for key, value in settings.items()))
        return account

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
        result = subprocess.run(argv, env=kwargs.get("env", self.env), capture_output=True, text=True, timeout=120)
        self.stderr = result.stderr
        try:
            return validate(result.stdout, result.returncode, verb, kwargs.get("duplicate_boot", False)), result.returncode
        except AssertionError:
            self.fail(verb + " exit=" + str(result.returncode) + " answered " + result.stdout + result.stderr
                      + "\n" + self.diagnostics())

    def wait(self, state="running", reason=None, seconds=90):
        deadline = time.monotonic() + seconds
        answer = None
        while time.monotonic() < deadline:
            answer, _ = self.call("status")
            if answer["state"] == state and (reason is None or answer["reason"] == reason):
                return answer
            if answer["state"] in ("blocked", "failed") and state not in ("blocked", "failed"):
                break
            time.sleep(0.2)
        self.fail("state did not settle: " + str(answer) + "\n" + self.diagnostics())

    def settled(self, seconds=90):
        # No intent of the runtime's open: its jobs and the detached start ended.
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not self.fleet.exists() or not [intent for intent in json.loads(self.fleet.read_text()).get("intents", [])
                                               if not intent.get("completed_at")]:
                return
            time.sleep(0.2)

    def diagnostics(self):
        log = self.record.with_name("session.log")
        parts = [self.fleet.read_text() if self.fleet.exists() else "fleet=absent",
                 " ".join(str(path.relative_to(self.home)) for path in sorted(self.home.rglob("*"))
                          if ".agents" not in path.parts),
                 log.read_text() if log.exists() else "session-log=absent",
                 self.rows.read_text() if self.rows.exists() else "rows=absent"]
        return "\n".join(parts)

    def started(self):
        if not self.rows.exists():
            return []
        return [json.loads(line) for line in self.rows.read_text().splitlines() if "argv" in json.loads(line)]

    def prompts(self):
        return [json.loads(line)["prompt"] for line in self.rows.read_text().splitlines() if "prompt" in json.loads(line)]

    def controller(self):
        return json.loads(self.fleet.read_text())["controller"]

    def windows(self):
        return subprocess.run(["tmux", "-L", self.label, "list-windows", "-t", "=jarvis", "-F", "#{window_id}"],
                              capture_output=True, text=True, env=self.env).stdout.split()

    def test_start_status_stop_and_resume_on_the_controller_record(self):
        # The failure each step stops: a controller opened on the caller's own
        # server, a second launch beside a live one, a stop that ends the
        # home's session or recalls delivered work, a resume that opens a new
        # native session, and a dead harness still read as running.
        self.assertEqual(self.call("status")[0]["reason"], "never-started")
        other = self.stand_in("caller")
        brief = self.root / "brief.md"
        brief.write_text("Keep notes in the progress log.\n")
        inside = self.inside_env(other, "caller")
        answer, code = self.call("start", brief=brief, env=inside)
        self.assertEqual((answer["state"], code), ("starting", 0), self.stderr)
        first = self.wait(reason="new-no-record")
        self.assertEqual((first["home"], first["account"], first["harness"]), (str(self.home), str(self.account), "claude"))
        private = subprocess.run(["tmux", "-L", self.label, "display-message", "-p", "#{socket_path}"], env=self.env,
                                 capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual((first["terminal"]["server"], first["terminal"]["session"]), (private, "jarvis"))
        caller_panes = self.tmux_read(other, "list-panes", "-a", "-F", "#{pane_id}").stdout.split()
        self.assertEqual(len(caller_panes), 1, "the caller's server took a window")
        launched = self.started()
        self.assertEqual(len(launched), 1)
        self.assertEqual((launched[0]["cwd"], launched[0]["account"]), (str(self.home), str(self.account)))
        # Jarvis acts on the owner's desktop: its session keeps the live display.
        self.assertEqual(launched[0]["display"], ["fixture-wayland", ":fixture"])
        self.assertIn("--session-id", launched[0]["argv"])
        self.assertEqual(self.prompts(), [START_BRIEF + " Keep notes in the progress log."])
        self.assertEqual(self.controller().get("seat"), "jarvis", "the start names the Jarvis seat")
        self.assertEqual(self.call("start")[0]["reason"], "existing")
        self.assertEqual(len(self.started()), 1, "a second launch beside the live one")
        # Delivered work outlives a stop.
        outbox = self.record.with_name("forward.json")
        outbox.write_text('{"entries":[{"id":"k1"}]}\n')
        mail = self.home / "tmp/lane-mail/overseer/inbox.jsonl"
        mail.parent.mkdir(parents=True, exist_ok=True)
        mail.write_text('{"id":"m1"}\n')
        self.assertEqual(self.call("stop")[0]["state"], "stopping")
        self.wait("stopped", "stopped")
        self.assertEqual((outbox.read_text(), mail.read_text()), ('{"entries":[{"id":"k1"}]}\n', '{"id":"m1"}\n'))
        self.assertEqual(len(self.windows()), 1, "the stop ended the home's session")
        self.call("start")
        self.wait(reason="resumed")
        resumed = self.started()[-1]["argv"]
        self.assertEqual(resumed[resumed.index("--resume") + 1], launched[0]["id"])
        self.call("stop")
        self.wait("stopped", "stopped")
        self.call("start", mode="new")
        self.wait(reason="new-requested")
        self.assertNotEqual(self.started()[-1]["id"], launched[0]["id"])
        os.kill(self.started()[-1]["pid"], signal.SIGKILL)
        self.wait("stopped", "ended", seconds=30)

    def test_a_register_from_the_managed_pane_keeps_jarvis_s_own_succession(self):
        # Wanted outcome 1: no command the session runs from its own managed
        # pane changes which hand-over its seat gets. A register there binds
        # the same pane again; its turn end past the context mark is still
        # told Jarvis's own succession, never orch's.
        self.call("start")
        terminal = self.wait(reason="new-no-record")["terminal"]
        server = subprocess.run(["tmux", "-S", terminal["server"], "display-message", "-p", "#{pid}"], env=self.env,
                                capture_output=True, text=True, check=True).stdout.strip()
        pane = self.env | {"TMUX": terminal["server"] + "," + server + ",0", "TMUX_PANE": terminal["pane"],
                           "CLAUDE_CONFIG_DIR": str(self.account), "PWD": str(self.home)}
        registered = subprocess.run([str(SKILLS / "orch/scripts/orch-runtime"), "register", "--fleet"], cwd=self.home, env=pane,
                                    capture_output=True, text=True, timeout=60)
        self.assertEqual(registered.returncode, 0, registered.stdout + registered.stderr)
        self.assertEqual(self.controller().get("seat"), "jarvis", "the register dropped the seat")
        session = self.started()[-1]["id"]
        transcript = next(self.account.glob("projects/*/" + session + ".jsonl"))
        with transcript.open("a") as stream:
            stream.write(json.dumps({"type": "assistant", "message": {"model": "claude-opus-4-5", "usage": {
                "input_tokens": 1, "cache_read_input_tokens": 649992, "cache_creation_input_tokens": 0,
                "output_tokens": 7}}}) + "\n")
        hooks = self.root / "install/.claude/hooks"
        hooks.mkdir(parents=True)
        ended = subprocess.run([str(SKILLS / "orch/scripts/orch-runtime"), "turn-end", "--hook-dir", str(hooks)],
                               input=json.dumps({"session_id": session, "transcript_path": str(transcript)}),
                               cwd=self.home, env=pane, capture_output=True, text=True, timeout=60)
        self.assertEqual(ended.returncode, 2, ended.stdout + ended.stderr)
        self.assertIn("jarvis-session succeed --home " + str(self.home), ended.stderr)

    def test_a_start_whose_account_cannot_sign_in_asks_for_the_sign_in(self):
        # A start on an account the harness reports signed out answers what
        # the person must do, never running.
        self.fixture["unsigned"] = [str(self.account)]
        self.write_fixture()
        self.call("start")
        answer = self.wait("blocked", "sign-in-required")
        self.assertTrue(answer["detail"])
        self.assertIsNone(answer["terminal"])

    def test_app_off_blocks_starts_and_a_repeated_boot_never_relaunches(self):
        # The VGS contract: Off holds until app-on, and a boot start the
        # machine already made answers without a second launch.
        self.assertEqual(self.call("stop", origin="app-off")[0]["state"], "off")
        answer, code = self.call("start")
        self.assertEqual((answer["state"], answer["reason"], code), ("blocked", "app-off", 1))
        self.assertEqual(self.started(), [])
        self.call("start", origin="app-on")
        self.wait()
        if BootReceiptScenario.applicable:
            self.call("stop")
            self.wait("stopped", "stopped")
            self.call("start", origin="boot")
            self.wait()
            self.call("stop")
            self.wait("stopped", "stopped")
            answer, _ = self.call("start", origin="boot", duplicate_boot=True)
            self.assertEqual((answer["state"], len(self.started())), ("stopped", 2), "the same boot launched again")

    def test_a_record_of_another_form_is_unreadable(self):
        # No record form but this one is read: a released record is never
        # taken for a controller.
        self.record.parent.mkdir(parents=True)
        self.record.write_text(json.dumps({"v": 1, "home": str(self.home), "state": "running", "reason": "existing"}))
        answer, code = self.call("status")
        self.assertEqual((answer["state"], answer["reason"], code), ("blocked", "record-unreadable", 0))
        answer, code = self.call("start")
        self.assertEqual((answer["reason"], code), ("record-unreadable", 1))
        self.assertEqual(self.started(), [])

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
    # -e, as a $TERMINAL does, and xdg-terminal-exec takes it bare; each runs
    # it on a pseudo-terminal of its own and records what it was handed. fail
    # exits 1 with a reason on stderr; idle exits 0 at once, as a launcher
    # handing off to a server can.
    TERMINAL_STUB = """#!/usr/bin/env python3
import fcntl, json, os, pty, struct, sys, termios
name = os.path.basename(sys.argv[0])
if name == "fixture-fail":
    sys.exit("fixture-fail: display unavailable")
if name == "fixture-idle":
    sys.exit(0)
command = sys.argv[1:] if name == "xdg-terminal-exec" else sys.argv[2:]
assert name == "xdg-terminal-exec" or sys.argv[1] == "-e", sys.argv
assert command[:2] == ["bash", "-lc"], sys.argv
with open(os.environ["FIXTURE_TERMINAL_RECORD"], "w") as stream:
    json.dump({"pid": os.getpid(), "env": {key: os.environ.get(key) for key in ("TMUX", "TMUX_PANE", "WAYLAND_DISPLAY")}}, stream)
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

    def terminal_stubs(self):
        stubs = self.root / "terminals"
        stubs.mkdir(exist_ok=True)
        for name in ("fixture-term", "fixture-fail", "fixture-idle", "xdg-terminal-exec"):
            (stubs / name).write_text(self.TERMINAL_STUB)
            (stubs / name).chmod(0o755)
        return str(stubs) + os.pathsep + self.env["PATH"]

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

    # open-window's terminal choice, one row per branch: the $TERMINAL the
    # caller sets (None for unset), whether xdg-terminal-exec is on PATH, and
    # the outcome. A window row gives the stderr attach prints; a refusal row
    # its cause and detail. The window, nested and refusal tests each run the
    # rows of their outcome, so a branch without a row here has no test.
    TERMINAL_CHOICE = (
        ("TERMINAL on PATH", "fixture-term", True, ("window", "")),
        ("TERMINAL names nothing, xdg-terminal-exec", "fixture-missing", True,
         ("window", "jarvis-session: terminal=fallback requested=fixture-missing selected=xdg-terminal-exec\n")),
        ("no TERMINAL, xdg-terminal-exec", None, True, ("window", "")),
        ("no TERMINAL, no xdg-terminal-exec", None, False, ("nested",)),
        ("TERMINAL names nothing, no xdg-terminal-exec", "fixture-missing", False,
         ("refused", "terminal-unresolved", "jarvis-session: terminal=unresolved requested=fixture-missing")),
    )

    def choices(self, outcome):
        # The rows of one outcome, each with the TERMINAL (None for unset)
        # and PATH it runs under, and the rest of its outcome.
        paths = {True: self.terminal_stubs(), False: self.bare_path()}
        return [(label, terminal, paths[desktop], result[1:])
                for label, terminal, desktop, result in self.TERMINAL_CHOICE if result[0] == outcome]

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
        for index, (label, terminal, path, (stderr,)) in enumerate(self.choices("window")):
            with self.subTest(label):
                handed = self.root / ("terminal-" + str(index) + ".json")
                env = self.chosen(inside, terminal, path) | {"HOME": str(self.root), "FIXTURE_TERMINAL_RECORD": str(handed)}
                result = self.attach(env)
                try:
                    self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", stderr))
                    # The window's own client attached; the caller's client,
                    # its server and its session are where they were.
                    record = json.loads(handed.read_text())
                    rows = self.clients(home)
                    self.assertEqual([row.split(" ")[1] for row in rows], ["jarvis"])
                    parent = subprocess.run(["ps", "-o", "ppid=", "-p", rows[0].split(" ")[0]], capture_output=True, text=True)
                    self.assertEqual(parent.stdout.strip(), str(record["pid"]))
                    self.assertEqual(self.clients(owner), before)
                    self.assertEqual(self.tmux_read(owner, "has-session", "-t", "=owner").returncode, 0)
                    self.assertEqual(record["env"], {"TMUX": None, "TMUX_PANE": None, "WAYLAND_DISPLAY": "fixture-wayland"})
                finally:
                    release(handed)

    def test_attach_nests_without_a_terminal(self):
        self.call("start")
        home = self.wait()["terminal"]["server"]
        owner = self.stand_in("owner")
        for index, (label, terminal, path, _) in enumerate(self.choices("nested")):
            with self.subTest(label):
                errors, picker = self.root / ("attach-" + str(index) + ".err"), "picker-" + str(index)
                line = ("exec env -u TERMINAL " + ("TERMINAL=" + shlex.quote(terminal) + " " if terminal else "")
                        + "PATH=" + shlex.quote(path) + " " + shlex.quote(str(SCRIPT)) + " attach --home "
                        + shlex.quote(str(self.home)) + " 2>" + shlex.quote(str(errors)))
                self.tmux_read(owner, "new-session", "-d", "-s", picker, line)
                pane = self.tmux_read(owner, "display-message", "-p", "-t", "=" + picker + ":", "#{pane_pid}").stdout.strip()
                try:
                    # The client runs in the picker's own pane: its process
                    # is the pane's.
                    self.assertEqual(self.clients(home, until=bool), [pane + " jarvis"])
                    # The fallback explains itself in one line before the
                    # nested client.
                    self.assertEqual(len(errors.read_text().splitlines()), 1)
                    self.assertEqual(self.tmux_read(owner, "has-session", "-t", "=owner").returncode, 0)
                finally:
                    self.tmux_read(home, "detach-client", "-s", "=jarvis")

    def test_attach_refuses_a_terminal_that_does_not_open(self):
        self.call("start")
        home = self.wait()["terminal"]["server"]
        owner = self.stand_in("owner")
        stubs = self.terminal_stubs()
        # Jarvis already open in another window: its client is no proof that
        # this attach's window opened.
        held = self.pty_client(["tmux", "-S", home, "attach-session", "-t", "=jarvis"], [home])
        existing = [str(held.pid) + " jarvis"]
        self.assertEqual(self.clients(home, until=bool), existing)
        # A found terminal that does not open, and the choice's refusal rows,
        # refuse rather than nest in the pane.
        rows = [("launcher exits non-zero", "fixture-fail", stubs, ("terminal-launch-failed",
                 "jarvis-session: terminal=fixture-fail exit=1\nfixture-fail: display unavailable")),
                ("no client within the bound", "fixture-idle", stubs,
                 ("terminal-launch-failed", "jarvis-session: terminal=fixture-idle client=none seconds=5")),
                *self.choices("refused")]
        for label, terminal, path, (cause, detail) in rows:
            with self.subTest(label):
                result = self.attach(self.chosen(self.inside_env(owner, "owner"), terminal, path))
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

    def test_failed_run_leaves_no_tmux_server(self):
        # A run that starts a server in a pane holding a lock, then fails on
        # purpose or takes the SIGTERM the battery runner stops an overdue
        # suite with, starts outside this run's tmux folder as a developer's does.
        # The SIGKILL a control's timeout sends ends it with no exit at all.
        scope = Path(os.environ[SCOPE])
        env = {key: value for key, value in os.environ.items() if key not in (SCOPE, "TMUX_TMPDIR", "TMUX", "TMUX_PANE")}
        env["PATH"] = os.pathsep.join(entry for entry in env["PATH"].split(os.pathsep) if Path(entry).parent != scope)
        for ending, status, code in (("failed", 1, "self.fail('planted failure')"),
                                     ("terminated", -signal.SIGTERM, "os.kill(os.getpid(), signal.SIGTERM)"),
                                     ("killed", -signal.SIGKILL, "os.kill(os.getpid(), signal.SIGKILL)")):
            with self.subTest(ending=ending):
                lock = self.root / (ending + ".lock")
                lock.touch()
                row = self.root / (ending + ".py")
                row.write_text(
                    "import fcntl, os, signal, subprocess, sys, time, unittest\n"
                    "sys.path.insert(0, " + repr(str(Path(__file__).resolve().parent)) + ")\n"
                    "from fixtures.tmux_scope import isolate\n"
                    "guard = isolate()\n"
                    "class Row(unittest.TestCase):\n"
                    "    def test_ends(self):\n"
                    "        pane = 'exec python3 -c ' + repr('import fcntl, sys, time; f = open(sys.argv[1]); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(1000)') + ' ' + repr(sys.argv[1])\n"
                    "        subprocess.run(['tmux', '-L', 'row', '-f', os.devnull, 'new-session', '-d', pane], check=True)\n"
                    "        with open(sys.argv[1]) as held:\n"
                    "            deadline = time.monotonic() + 15\n"
                    "            while True:\n"
                    "                try:\n"
                    "                    fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
                    "                except BlockingIOError:\n"
                    "                    break\n"
                    "                fcntl.flock(held, fcntl.LOCK_UN)\n"
                    "                self.assertLess(time.monotonic(), deadline)\n"
                    "                time.sleep(0.05)\n"
                    "        with open(sys.argv[1] + '.guard', 'w') as noted:\n"
                    "            noted.write(str(guard.pid))\n"
                    "        print(subprocess.run(['tmux', '-L', 'row', 'display-message', '-p', '#{socket_path}'], check=True,\n"
                    "                             capture_output=True, text=True).stdout, end='', file=sys.__stdout__, flush=True)\n"
                    "        " + code + "\n"
                    "unittest.main(argv=sys.argv[:1])\n")
                result = subprocess.run([sys.executable, "-B", str(row), str(lock)], env=env, capture_output=True, text=True, timeout=60)
                server = Path(result.stdout.strip())
                self.addCleanup(subprocess.run, ["tmux", "-S", str(server), "kill-server"], capture_output=True)
                self.assertEqual((result.returncode, server.is_absolute()), (status, True), result.stderr)
                self.assertNotEqual(server.parent, Path("/tmp") / ("tmux-%d" % os.getuid()))
                self.assertFalse(server.exists())
                self.assertFalse(server.parents[2].exists())
                with lock.open() as held:
                    fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if ending == "failed":
                    # The exit a passing run takes too: it reaps its guard before it ends.
                    with self.assertRaises(ProcessLookupError):
                        os.kill(int(Path(str(lock) + ".guard").read_text()), 0)


if __name__ == "__main__":
    with native_launcher() as HARNESS:
        unittest.main()
