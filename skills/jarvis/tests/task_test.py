"""Real tmux and agent-runtime's launch and account judge; native CLIs are fixtures."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from fixtures.tmux_scope import isolate
isolate()

ROOT = Path(__file__).resolve().parents[3]
SKILLS = Path(os.environ.get("JARVIS_TEST_SKILLS", ROOT / "skills"))
REAL_KENDEX = os.environ.get("JARVIS_TEST_REAL_KENDEX", shutil.which("kendex"))
# Each harness's composer at rest, as agent-runtime's own rows capture it.
IDLE = ROOT / "skills/agent-runtime/tests/rust/fixtures"


def install(skills):
    """The packages a task runs, laid out as an install: the scripts of
    jarvis, orch and the mailbox copied, so a control can change one, and
    agent-runtime and orch's runtime linked, whose sources key their built
    binaries."""
    for package in ("jarvis", "orch", "mailbox"):
        shutil.copytree(SKILLS / package / "scripts", skills / package / "scripts")
    (skills / "agent-runtime").symlink_to(SKILLS / "agent-runtime", target_is_directory=True)
    (skills / "orch/runtime").symlink_to(SKILLS / "orch/runtime", target_is_directory=True)


class TaskContract(unittest.TestCase):
    def setUp(self):
        self.allocation = tempfile.TemporaryDirectory()
        self.root = Path(self.allocation.name).resolve()
        self.home = self.root / "home with spaces"
        self.home.mkdir()
        # The home is its own repository, so its settings and its state
        # directory are its own wherever the scratch stands.
        for words in (("init", "-q"), ("config", "gc.auto", "0"), ("config", "maintenance.auto", "false")):
            subprocess.run(["git", "-C", str(self.home), *words], check=True, capture_output=True,
                           env={"PATH": os.environ["PATH"], "HOME": str(self.root), "GIT_CONFIG_NOSYSTEM": "1"})
        self.skills = self.root / "skills"
        install(self.skills)
        self.script = self.skills / "jarvis/scripts/task"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Managed-session recovery reads the platform manager; this task
        # fixture publishes no launch policy and never reads the host's.
        for tool in ("systemctl", "launchctl"):
            self.bin.joinpath(tool).write_text("#!" + os.environ["JARVIS_TEST_BASH"] + "\nexit 0\n")
            self.bin.joinpath(tool).chmod(0o755)
        # Exercise agent-runtime's account judge over accounts it reads
        # measured: each harness's own account, its sign-in and a fresh
        # usage record. No live quota endpoint is read.
        self.account_state = self.root / "account-state"
        self.accounts = {harness: self.root / ("picked-" + harness) for harness in ("claude", "codex", "copilot", "pi")}
        for harness in self.accounts:
            self.plant(harness, 5)
        self.configure()
        shutil.copyfile(ROOT / "skills/orch/tests/fixtures/tier-model/kendex", self.bin / "kendex")
        self.bin.joinpath("kendex").chmod(0o755)
        native = ("#!" + sys.executable + "\nimport json,os,signal,sys\nfrom pathlib import Path\n"
                  + "keys={'CLAUDE_CONFIG_DIR','CODEX_HOME','COPILOT_HOME','PI_CODING_AGENT_DIR','JARVIS_BROWSER_PROFILE','JARVIS_BROWSER_PORT','JARVIS_TASK_SCRATCH','WAYLAND_DISPLAY','DISPLAY'}\n"
                  + "row={'harness':Path(sys.argv[0]).name,'cwd':str(Path.cwd()),'argv':sys.argv[1:],'env_keys':list(os.environ),'env':{k:os.environ[k] for k in keys if k in os.environ}}\n"
                  + "Path(" + repr(str(self.home)) + ",'ack-'+os.environ['JARVIS_TASK_ID']+'.json').write_text(json.dumps(row))\n"
                  # Each harness draws its own composer at rest.
                  + "sys.stdout.write(Path(" + repr(str(IDLE)) + ",Path(sys.argv[0]).name+'-idle.txt').read_text().rstrip('\\n'))\n"
                  + "sys.stdout.flush()\n"
                  + "while True: signal.pause()\n")
        for harness in ("claude", "codex", "copilot", "pi"):
            self.bin.joinpath(harness).write_text(native)
            self.bin.joinpath(harness).chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        XDG_STATE_HOME=str(self.root / "state"), CLAUDECODE="parent",
                        CLAUDE_CODE_SESSION_ID="parent", CODEX_THREAD_ID="parent",
                        PI_SUBAGENT_PARENT_SESSION_ID="parent", JARVIS_BROWSER_PROFILE="/parent/browser",
                        JARVIS_BROWSER_PORT="9222", WAYLAND_DISPLAY="fixture-wayland", DISPLAY=":fixture",
                        JARVIS_TEST_REAL_KENDEX=REAL_KENDEX or "")
        # The account judge reads no account of the caller's own login; the
        # runtimes' cache stays the caller's.
        login = self.root / "login"
        login.mkdir()
        cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "kendex/agent-runtime"
        self.env.setdefault("AGENT_RUNTIME_CACHE", str(cache))
        # A task window's shell is the suite's own Bash, which reads nothing
        # of the caller's login.
        self.env.update(HOME=str(login), XDG_CONFIG_HOME=str(login / ".config"), SHELL=os.environ["JARVIS_TEST_BASH"])
        key = hashlib.sha256(os.fsencode(str(self.home))).hexdigest()
        self.record_path = self.root / "state/kendex/jarvis" / key / "jarvis-session.json"
        self.label = "jarvis-" + key[:32]
        # The controller's window carries the name Start gives it.
        created = self.tmux("new-session", "-d", "-s", "jarvis", "-n", "jarvis", "-P", "-F",
                            "#{socket_path}\t#{pid}\t#{start_time}\t#{window_id}\t#{pane_id}",
                            self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc")
        socket, server, started, window, pane = created.stdout.strip().split("\t")
        self.terminal = dict(server=socket, session="jarvis", window=window, pane=pane)
        # A task pane is wide and tall enough to hold each harness's screen whole.
        self.tmux("set-option", "-t", "jarvis", "default-size", "240x60")
        # The running controller the home's fleet record names: this pane's
        # own process on the private server, live under its recorded start.
        holder = self.tmux("display-message", "-p", "-t", pane, "#{pane_pid}").stdout.strip()
        ticks = Path("/proc", holder, "stat").read_text().rsplit(")", 1)[1].split()[19]
        fleet = self.root / "orch-state/workflow-state-oversee.json"
        fleet.parent.mkdir(parents=True)
        fleet.write_text(json.dumps({"controller": {
            "runtime": "tmux", "generation": 1, "server": server, "server_start": int(started), "server_socket": socket,
            "pane": pane, "harness": "claude", "account": str(self.root / "controller-account"), "harness_pid": holder,
            "harness_start": "ticks:" + ticks, "cwd": str(self.home), "seat": "jarvis"}}))
        self.record_path.parent.mkdir(parents=True)
        self.task_file = self.home / "task brief.md"
        self.task_file.write_text("Inspect the selected site. Write the Output section.\n")

    def tearDown(self):
        subprocess.run(["tmux", "-L", self.label, "kill-server"], env=self.env, capture_output=True, timeout=10)
        self.allocation.cleanup()

    def plant(self, harness, used, account=None, limits=()):
        """HARNESS's account read measured at USED percent of its week: a
        Claude or Codex sign-in with a fresh usage record, a Copilot pool
        stated by its owner (`configure`). A Claude account has finished its
        first-run setup; LIMITS are its model windows, each a model's name
        and its percent."""
        account = account or self.accounts[harness]
        account.mkdir(exist_ok=True)
        now = int(time.time())
        iso = lambda seconds: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + seconds))
        if harness in ("copilot", "pi"):
            self.pool = dict(getattr(self, "pool", {}), **{str(account): used})
            return account
        if harness == "claude":
            files = {".credentials.json": {"claudeAiOauth": {
                "accessToken": "token", "refreshToken": "refresh", "expiresAt": (now + 86400) * 1000,
                "subscriptionType": "max"}}, ".claude.json": {"hasCompletedOnboarding": True}}
            usage = {"five_hour": {"utilization": 1, "resets_at": iso(3600)},
                     "seven_day": {"utilization": used, "resets_at": iso(60 * 3600)},
                     "limits": [{"kind": "weekly_scoped", "percent": percent, "resets_at": iso(60 * 3600),
                                 "scope": {"model": {"display_name": name}}} for name, percent in limits]}
        else:
            files = {"auth.json": {"tokens": {"access_token": "token", "account_id": "account"}}}
            usage = {"rate_limit": {
                "primary_window": {"used_percent": 1, "reset_at": now + 3600, "limit_window_seconds": 18000},
                "secondary_window": {"used_percent": used, "reset_at": now + 60 * 3600, "limit_window_seconds": 604800}}}
        for name, body in files.items():
            account.joinpath(name).write_text(json.dumps(body))
            os.utime(account / name, (now - 60, now - 60))
        text = str(account)
        crc = subprocess.run(["cksum"], input=text.encode(), capture_output=True, check=True).stdout.split()[0].decode()
        record = self.account_state / "usage" / (harness + "-" + crc + "-" + str(len(text.encode())) + ".json")
        record.parent.mkdir(parents=True, exist_ok=True)
        record.write_text(json.dumps({"harness": harness, "config_dir": text, "fetched_at": now,
                                      "sample_claims": 1, "prior": None, "usage": usage}))
        return account

    def configure(self, listed=("claude", "codex"), burn=0):
        """The home's settings: the accounts the judge lists, each harness's
        burn per lane hour, the Copilot pools stated."""
        settings = {"ORCH_STATE_DIR": str(self.root / "orch-state"),
                    "AGENT_RUNTIME_ACCOUNT_STATE_DIR": str(self.account_state),
                    "AGENT_RUNTIME_ACCOUNT_DIRS": ":".join(str(self.accounts[harness]) for harness in listed),
                    "AGENT_RUNTIME_COPILOT_POOL": ",".join(dir + "=" + str(used) + "/100" for dir, used in self.pool.items()),
                    "AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR": str(burn)}
        (self.home / "kendex.settings.toml").write_text("[env]\n" + "".join(
            key + " = " + json.dumps(value) + "\n" for key, value in settings.items()))

    def tmux(self, *args):
        return subprocess.run(["tmux", "-L", self.label, "-f", os.devnull, *args],
                              env=self.env, capture_output=True, text=True, timeout=10, check=True)

    def call(self, verb, *args, success=True, cwd=None):
        result = subprocess.run([str(self.script), verb, "--home", str(self.home), *map(str, args)],
                                cwd=cwd, env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0 if success else 1, result.stderr)
        return json.loads(result.stdout) if success else result

    def launch(self, harness, suffix="", success=True, model=None):
        model = model or ("github-copilot/gpt-5" if harness == "pi" else "standard")
        return self.call("launch", "--name", "Inspect " + harness + suffix, "--harness", harness,
                         "--model", model, "--task-file", self.task_file,
                         "--result-file", self.home / ("result-" + harness + suffix + ".md"),
                         "--input", self.task_file, "--account", self.accounts[harness], "--browser", success=success)

    def saved_tasks(self):
        return [json.loads(path.read_text()) for path in self.record_path.parent.joinpath("tasks").glob("*.json")]

    def acknowledgement(self, record, stage=None):
        path = self.home / ("ack-" + record["id"] + ".json")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if path.exists():
                try:
                    observed = json.loads(path.read_text())
                    if stage is None or observed.get("stage") == stage:
                        return observed
                except json.JSONDecodeError:
                    pass
            time.sleep(0.02)
        self.fail("native launch did not acknowledge: " + json.dumps(record))

    def test_launch_contract(self):
        profiles = set()
        rows = (("claude", "opus", "CLAUDE_CONFIG_DIR", "--model"),
                ("codex", "native-default", "CODEX_HOME", "-m"),
                ("copilot", "native-default", "COPILOT_HOME", "--model"),
                ("pi", "github-copilot/gpt-5", "PI_CODING_AGENT_DIR", "--model"))
        for harness, model, account_var, model_flag in rows:
            with self.subTest(harness=harness):
                record = self.launch(harness)
                observed = self.acknowledgement(record)
                self.assertEqual(observed["harness"], harness)
                self.assertEqual((record["harness"], record["model"], record["account"]),
                                 (harness, model, str(self.accounts[harness])))
                self.assertEqual(record["inputs"], [str(self.task_file)])
                self.assertEqual(record["task_file"], str(self.task_file))
                self.assertEqual(record["result_path"], str(self.home / ("result-" + harness + ".md")))
                self.assertEqual(record["terminal"]["server"], self.terminal["server"])
                self.assertNotEqual(record["terminal"]["window"], self.terminal["window"])
                if model == "native-default":
                    self.assertNotIn(model_flag, observed["argv"])
                else:
                    # Pi takes the effort as its model's thinking level.
                    spelled = model + ":high" if harness == "pi" else model
                    self.assertEqual(observed["argv"][observed["argv"].index(model_flag) + 1], spelled)
                self.assertTrue(observed["env"][account_var].startswith(str(self.accounts[harness])))
                for identity in ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID",
                                 "PI_SUBAGENT_PARENT_SESSION_ID"):
                    self.assertNotIn(identity, observed["env_keys"])
                profile = Path(record["browser_profile"])
                self.assertTrue(profile.is_absolute() and profile.is_dir())
                self.assertEqual(profile.parent, Path(record["scratch"]))
                self.assertEqual(observed["env"]["JARVIS_BROWSER_PROFILE"], str(profile))
                self.assertEqual(record["browser_port"], 0)
                self.assertEqual(observed["env"]["JARVIS_BROWSER_PORT"], "0")
                # The task's browser and desktop tools reach the owner's screen.
                self.assertEqual((observed["env"].get("WAYLAND_DISPLAY"), observed["env"].get("DISPLAY")),
                                 ("fixture-wayland", ":fixture"))
                self.assertNotIn(profile, profiles)
                profiles.add(profile)
        # Keep all four tasks live while proving profile isolation, then
        # preserve their results while closing only their owned windows.
        for path in sorted(self.record_path.parent.joinpath("tasks").glob("*.json")):
            record = json.loads(path.read_text())
            self.call("cleanup", "--id", record["id"], success=False)
            self.assertTrue(Path(record["scratch"]).is_dir())
            self.call("complete", "--id", record["id"], "--outcome", "succeeded", success=False)
            self.assertIsNone(self.call("status", "--id", record["id"])["completion"])
            Path(record["result_path"]).write_text("Output: checked\n")
            completed = self.call("complete", "--id", record["id"], "--outcome", "succeeded")
            self.assertEqual(completed["completion"]["outcome"], "succeeded")
            cleaned = self.call("cleanup", "--id", record["id"])
            self.assertEqual(cleaned["cleanup"]["state"], "done")
            self.assertFalse(Path(record["scratch"]).exists())
            self.assertTrue(Path(record["result_path"]).is_file())
            self.assertEqual(json.loads(path.read_text()), cleaned)
            self.assertEqual(self.call("cleanup", "--id", record["id"]), cleaned)
        windows = self.tmux("list-windows", "-t", "=jarvis", "-F", "#{window_id}").stdout.splitlines()
        self.assertEqual(windows, [self.terminal["window"]])

    def screen_launch(self, harness, name):
        # The startup bound ends at the first reading agent-runtime takes once
        # the screen native has drawn its fixture, so a pane that never draws
        # a ready prompt answers then rather than at CALL_SECONDS.
        code = """
import sys,time
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import task
original=task.Task.inspected
home=Path(sys.argv[2])
def inspected(self):
    drawn=home.joinpath('drawn-'+self.path.stem).exists()
    seen=original(self)
    if drawn and seen['state']['state'] not in ('idle','working'):
        self.deadline=time.monotonic()+0.5
    return seen
task.Task.inspected=inspected
sys.argv=[sys.argv[0],*sys.argv[3:]]
sys.exit(task.main())
"""
        args = ["launch", "--home", str(self.home), "--harness", harness,
                "--model", "github-copilot/gpt-5" if harness == "pi" else "standard",
                "--name", name, "--task-file", str(self.task_file),
                "--result-file", str(self.home / (name + ".md")), "--account", str(self.accounts[harness])]
        return subprocess.run([sys.executable, "-B", "-c", code, str(self.skills / "jarvis/scripts/lib"),
                               str(self.home), *args], env=dict(self.env, JARVIS_BASH=self.env["JARVIS_TEST_BASH"]),
                              capture_output=True, text=True, timeout=60)

    def test_setup_screen_refuses(self):
        # Claude Code's first-run theme picker, whose numbered row takes the
        # plain space rather than the composer's U+00A0.
        theme = self.root / "claude-theme.txt"
        theme.write_text("Choose the text style that looks best with your terminal\n\n"
                         "\u276f 1. Dark mode \u2714\n  2. Light mode\n")
        captured = ROOT / "skills/orch/tests/fixtures/oversee-watch"
        # A None outcome is a launch that records running: a harness at its
        # composer, or in a turn.
        rows = (("claude", theme, "harness-not-ready"),
                ("codex", captured / "codex-dialog-trust.txt", "harness-not-ready"),
                ("codex", captured / "codex-rate-limit-switch.txt", "harness-not-ready"),
                ("copilot", captured / "copilot-dialog-trust.txt", "harness-not-ready"),
                ("copilot", captured / "copilot-working.txt", None),
                ("codex", captured / "codex-composer-idle.txt", None),
                ("codex", captured / "codex-working.txt", None))
        for index, (harness, screen, reason) in enumerate(rows):
            with self.subTest(harness=harness, screen=screen.name):
                path = self.bin / harness
                original = path.read_text()
                path.write_text("#!" + sys.executable + "\nimport os,signal,sys\nfrom pathlib import Path\n"
                                + "sys.stdout.write(Path(" + repr(str(screen)) + ").read_text().rstrip('\\n'))\n"
                                + "sys.stdout.flush()\n"
                                + "Path(" + repr(str(self.home)) + ",'drawn-'+os.environ['JARVIS_TASK_ID']).write_text('')\n"
                                + "while True: signal.pause()\n")
                try:
                    result = self.screen_launch(harness, "setup-" + str(index))
                finally:
                    path.write_text(original)
                record = next(row for row in self.saved_tasks() if row["name"] == "setup-" + str(index))
                if reason is None:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(record["state"], "running")
                    self.assertIn("launched_at", record)
                    self.call("complete", "--id", record["id"], "--outcome", "failed")
                    self.assertEqual(self.call("cleanup", "--id", record["id"])["cleanup"]["state"], "done")
                else:
                    self.assertEqual(result.returncode, 1, result.stderr)
                    lines = result.stderr.splitlines()
                    self.assertEqual(lines[0], "jarvis-task: refused=" + reason + " id=" + record["id"])
                    self.assertTrue(lines[1].startswith("fix="), result.stderr)
                    self.assertEqual((record["state"], record["failure"]["reason"], record["completion"]["outcome"]),
                                     ("failed", reason, "failed"))
                    self.assertNotIn("launched_at", record)
                    self.assertEqual(record["cleanup"]["state"], "done")
                    # The refusal carries the screen the harness stopped on.
                    drawn = [line.strip() for line in screen.read_text().splitlines() if line.strip()]
                    self.assertIn(drawn[-1], record["failure"]["detail"])
                self.assertEqual(self.tmux("list-windows", "-t", "=jarvis", "-F", "#{window_id}").stdout.splitlines(),
                                 [self.terminal["window"]])

    def test_a_task_s_directory_is_trusted_before_its_harness_starts(self):
        # Nobody is at the pane to answer a trust question: the account's
        # home trusts the task's directory before the harness reads it.
        selected = self.root / "never trusted"
        selected.mkdir()
        for harness in ("claude", "codex"):
            with self.subTest(harness=harness):
                record = self.call("launch", "--name", "trusted-" + harness, "--harness", harness,
                                   "--model", "standard", "--task-file", self.task_file, "--cwd", selected,
                                   "--result-file", self.home / "trusted.md", "--account", self.accounts[harness])
                observed = self.acknowledgement(record)
                if harness == "claude":
                    config = json.loads(self.accounts["claude"].joinpath(".claude.json").read_text())
                    entry = config.get("projects", {}).get(str(selected), {})
                    self.assertIs(entry.get("hasTrustDialogAccepted"), True, config)
                else:
                    config = Path(observed["env"]["CODEX_HOME"], "config.toml")
                    self.assertIn('[projects."' + str(selected) + '"]\ntrust_level = "trusted"',
                                  config.read_text() if config.exists() else "")

    def test_launch_directory_contract(self):
        selected = self.root / "project 'quoted' $folder#{pid};"
        selected.mkdir()
        imported = self.root / "project-module-imported"
        (selected / "argparse.py").write_text(
            "from pathlib import Path\nPath(" + repr(str(imported)) + ").touch()\n")
        dangling = self.home / "dangling"
        dangling.symlink_to(self.root / "missing")
        input_file = self.home / "extra input.md"
        input_file.write_text("Additional context.\n")
        result = self.home / "directory-result.md"
        launch = ("--name", "directory", "--harness", "codex", "--model", "gpt-5",
                  "--task-file", self.task_file.relative_to(self.root), "--input", input_file.relative_to(self.root),
                  "--result-file", result.relative_to(self.root), "--account", self.accounts["codex"], "--browser")
        for invalid in ("missing", self.task_file.relative_to(self.root), dangling.relative_to(self.root), ""):
            with self.subTest(invalid=invalid):
                refused = self.call("launch", *launch, "--cwd", invalid, cwd=self.root, success=False)
                self.assertIn("refused=cwd-unavailable", refused.stderr)
                if invalid:
                    self.assertIn(str(invalid), refused.stderr)
                self.assertEqual(self.saved_tasks(), [])
                self.assertFalse((self.home / "tmp/scratch").exists())
                self.assertEqual(self.tmux("list-windows", "-t", "=jarvis", "-F", "#{window_id}").stdout.splitlines(),
                                 [self.terminal["window"]])
        for options, expected in (((), self.home), (("--cwd", selected.name), selected)):
            with self.subTest(cwd=expected):
                record = self.call("launch", *launch, *options, cwd=self.root)
                observed = self.acknowledgement(record)
                self.assertFalse(imported.exists())
                self.assertEqual(observed["cwd"], str(expected))
                self.assertEqual(record["cwd"], str(expected))
                self.assertEqual(record["home"], str(self.home))
                self.assertEqual(record["task_file"], str(self.task_file))
                self.assertEqual(record["inputs"], [str(input_file)])
                self.assertEqual(record["result_path"], str(result))
                self.assertEqual(Path(record["scratch"]).parent, self.home / "tmp/scratch")
                self.assertEqual(observed["env"]["JARVIS_TASK_SCRATCH"], record["scratch"])
                brief = observed["argv"][-1]
                for path in (self.task_file, input_file, result, Path(record["scratch"])):
                    self.assertIn(json.dumps(str(path)), brief)
                self.assertIn(shlex.join(["--home", str(self.home)]), brief)
                self.assertIn(record, self.saved_tasks())
                result.write_text("Output: checked\n")
                self.call("complete", "--id", record["id"], "--outcome", "succeeded")
                self.call("cleanup", "--id", record["id"])
                self.assertFalse(Path(record["scratch"]).exists())
                self.assertEqual(result.read_text(), "Output: checked\n")

    def test_failed_pick_releases_task_scratch(self):
        self.plant("codex", 99)
        refused = self.launch("codex", success=False)
        self.assertIn("refused=account-walled", refused.stderr)
        paths = list(self.record_path.parent.joinpath("tasks").glob("*.json"))
        self.assertEqual(len(paths), 1)
        record = json.loads(paths[0].read_text())
        self.assertEqual(record["state"], "failed")
        self.assertEqual(record["cleanup"]["state"], "done")
        self.assertFalse(Path(record["scratch"]).exists())
        self.assertEqual(self.tmux("list-windows", "-t", "=jarvis", "-F", "#{window_id}").stdout.splitlines(),
                         [self.terminal["window"]])

    def test_a_short_task_is_judged_up_to_the_wall_and_on_its_projected_wall(self):
        # A Claude account past the launch bound with room below its wall,
        # and a named one whose reading is well inside the bound while a
        # lane's burn to its week's reset projects it past the wall.
        spent = self.plant("claude", 97)
        named = self.plant("claude", 50, self.root / "named-claude")
        rows = (("full task", (), 0, "account-none"),
                ("short task", ("--short",), 0, None),
                ("full task on a named account", ("--account", named), 30, None),
                ("short task on a named account", ("--short", "--account", named), 30, "account-walled"))
        for index, (case, args, burn, refusal) in enumerate(rows):
            with self.subTest(case=case):
                self.configure(listed=("claude",), burn=burn)
                answer = self.call("launch", "--name", "short-" + str(index), "--harness", "claude",
                                   "--model", "standard", "--task-file", self.task_file,
                                   "--result-file", self.home / "result-short.md", *args, success=refusal is None)
                if refusal:
                    self.assertIn("jarvis-task: refused=" + refusal + " ", answer.stderr)
                else:
                    account = named if "--account" in args else spent
                    self.assertEqual(answer["account"], str(account))
                    self.assertTrue(self.acknowledgement(answer)["env"]["CLAUDE_CONFIG_DIR"].startswith(str(account)))

    def front_window(self):
        return self.tmux("display-message", "-p", "-t", "=jarvis:", "#{window_id}").stdout.strip()

    def test_cleanup_front_window(self):
        # The owner reads the other task, then the shown one. Closing the
        # window in front leaves tmux to pick its last one, the other task's;
        # closing one behind it leaves the owner's choice in front.
        for shown, front in (("cleaned", "controller"), ("other", "other")):
            with self.subTest(shown=shown):
                tasks = {"other": self.launch("claude", "-" + shown), "cleaned": self.launch("codex", "-" + shown)}
                windows = {"controller": self.terminal["window"], "other": tasks["other"]["terminal"]["window"]}
                for task in tasks.values():
                    self.acknowledgement(task)
                for name in sorted(tasks, key=lambda name: name == shown):
                    self.tmux("select-window", "-t", tasks[name]["terminal"]["window"])
                for name in ("cleaned", "other"):
                    Path(tasks[name]["result_path"]).write_text("Output: checked\n")
                    self.call("complete", "--id", tasks[name]["id"], "--outcome", "succeeded")
                    self.assertEqual(self.call("cleanup", "--id", tasks[name]["id"])["cleanup"]["state"], "done")
                    if name == "cleaned":
                        self.assertEqual(self.front_window(), windows[front])

    def test_no_task_window_takes_the_live_window_name(self):
        # tmux expands formats in a window name, so a name spelling the
        # session's own would otherwise open a window called jarvis.
        for name, launched in (("jarvis", False), ("Jarvis", False), ("#S", True), ("#{session_name}", True)):
            with self.subTest(name=name):
                tasks = len(self.saved_tasks())
                answer = self.call("launch", "--name", name, "--harness", "claude", "--model", "standard",
                                   "--task-file", self.task_file, "--result-file", self.home / "result.md",
                                   success=launched)
                windows = dict(row.split("\t", 1) for row in self.tmux(
                    "list-windows", "-t", "=jarvis:", "-F", "#{window_id}\t#{window_name}").stdout.splitlines())
                self.assertEqual(windows.pop(self.terminal["window"]), "jarvis")
                self.assertNotIn("jarvis", {shown.casefold() for shown in windows.values()})
                if launched:
                    self.assertEqual(windows[answer["terminal"]["window"]], name)
                else:
                    self.assertIn("refused=name-reserved", answer.stderr)
                    self.assertEqual(len(self.saved_tasks()), tasks)

    def test_native_start_failure_is_recoverable(self):
        # Resolve tools from a private PATH so an optional harness installed
        # elsewhere cannot turn the missing-executable row into a live launch.
        for directory in os.environ["PATH"].split(os.pathsep):
            folder = Path(directory)
            if not folder.is_dir():
                continue
            for path in folder.iterdir():
                target = self.bin / path.name
                if path.name not in ("claude", "codex", "copilot", "pi") and not target.exists() and path.is_file():
                    target.symlink_to(path.resolve())
        self.env["PATH"] = str(self.bin)
        for harness in ("claude", "codex", "copilot", "pi"):
            path = self.bin / harness
            original = path.read_text()
            # A late exit ends after the harness took its pane, during the
            # wait for its prompt.
            for mode in ("missing", "early-exit", "late-exit"):
                with self.subTest(harness=harness, mode=mode):
                    if mode == "missing":
                        path.unlink()
                    else:
                        path.write_text("#!" + sys.executable + "\nimport sys,time\n"
                                        + ("time.sleep(1)\n" if mode == "late-exit" else "") + "sys.exit(23)\n")
                        path.chmod(0o755)
                    # A launch bound short of the caller's: a harness that
                    # ended is answered at once, never waited out.
                    model = "gpt-5" if harness in ("codex", "copilot") else (
                        "github-copilot/gpt-5" if harness == "pi" else "standard")
                    code = ("import sys; sys.path.insert(0,sys.argv[1]); import session, task;"
                            " session.CALL_SECONDS=10; sys.argv=[sys.argv[0],*sys.argv[2:]]; sys.exit(task.main())")
                    failed = subprocess.run([sys.executable, "-B", "-c", code, str(self.skills / "jarvis/scripts/lib"),
                                             "launch", "--home", str(self.home), "--name", "Inspect " + harness + mode,
                                             "--harness", harness, "--model", model, "--task-file", str(self.task_file),
                                             "--result-file", str(self.home / ("result-" + harness + mode + ".md")),
                                             "--account", str(self.accounts[harness])],
                                            env=dict(self.env, JARVIS_BASH=self.env["JARVIS_TEST_BASH"]),
                                            capture_output=True, text=True, timeout=60)
                    self.assertEqual(failed.returncode, 1, failed.stderr)
                    record = self.saved_tasks()[-1] if len(self.saved_tasks()) == 1 else next(
                        row for row in self.saved_tasks() if row["name"] == "Inspect " + harness + mode)
                    self.assertIn("id=" + record["id"], failed.stderr)
                    self.assertEqual(record["state"], "failed")
                    self.assertEqual(record["failure"]["reason"], "app-missing" if mode == "missing" else "native-exited")
                    self.assertEqual(record["completion"]["outcome"], "failed")
                    self.assertEqual(self.call("cleanup", "--id", record["id"])["cleanup"]["state"], "done")
                    path.write_text(original)
                    path.chmod(0o755)
        self.assertEqual(self.tmux("list-windows", "-t", "=jarvis", "-F", "#{window_id}").stdout.splitlines(),
                         [self.terminal["window"]])

    def test_expired_launch_retains_rollback_ownership(self):
        for unread in (False, True):
            with self.subTest(unread=unread):
                wrapper = self.bin / "tmux"
                wrapper.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
                    + 'for arg in "$@"; do if [[ $arg == kill-window && -e ' + shlex.quote(str(self.home / "refuse-close"))
                    + ' ]]; then exit 2; fi; done\n'
                    + "exec " + shlex.quote(shutil.which("tmux")) + ' "$@"\n')
                wrapper.chmod(0o755)
                code = """
import sys,time
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import task
unread=sys.argv[2]=='True'
original=task.Task.runtime
def expire(self,*args,**kwargs):
    answer=original(self,*args,**kwargs)
    if args[0]=='launch':
        self.deadline=time.monotonic()-1
        if unread: Path(self.home,'refuse-close').touch()
    return answer
task.Task.runtime=expire
sys.argv=[sys.argv[0],*sys.argv[3:]]
sys.exit(task.main())
"""
                args = ["launch", "--home", str(self.home), "--harness", "codex", "--model", "gpt-5",
                        "--name", "expired-" + str(unread), "--task-file", str(self.task_file),
                        "--result-file", str(self.home / "output.md"), "--account", str(self.accounts["codex"]), "--browser"]
                result = subprocess.run([sys.executable, "-B", "-c", code,
                    str(self.skills / "jarvis/scripts/lib"), str(unread), *args],
                    env=dict(self.env, JARVIS_BASH=self.env["JARVIS_TEST_BASH"]),
                    capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 1, result.stderr)
                record = next(row for row in self.saved_tasks() if row["name"] == "expired-" + str(unread))
                self.assertEqual(record["state"], "failed")
                self.assertIn("id=" + record["id"], result.stderr)
                self.assertEqual(record["failure"]["reason"], "TimeoutExpired")
                self.assertEqual(record["completion"]["outcome"], "failed")
                self.assertIsNotNone(record["terminal"])
                self.assertEqual(record["cleanup"]["state"], "pending" if unread else "done")
                self.assertEqual(Path(record["scratch"]).exists(), unread)
                self.home.joinpath("refuse-close").unlink(missing_ok=True)
                wrapper.unlink()
                cleaned = self.call("cleanup", "--id", record["id"])
                self.assertEqual(cleaned["cleanup"]["state"], "done")
                self.assertFalse(Path(record["scratch"]).exists())
                self.assertEqual(self.tmux("list-windows", "-t", "=jarvis", "-F", "#{window_id}").stdout.splitlines(),
                                 [self.terminal["window"]])

    def test_a_task_whose_server_ended_reads_controller_ended(self):
        # A task whose server is gone, or whose socket another server now
        # answers, reads failed with controller-ended, and its cleanup
        # completes: nothing remains to complete it.
        gone, replaced = self.launch("codex", "gone", model="gpt-5"), self.launch("codex", "replaced", model="gpt-5")
        for task in (gone, replaced):
            self.acknowledgement(task)
        self.tmux("kill-server")
        rows = (("gone", gone), ("replaced", replaced))
        for name, task in rows:
            with self.subTest(server=name):
                if name == "replaced":
                    self.tmux("new-session", "-d", "-s", "other", self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc")
                path = self.record_path.parent / "tasks" / (task["id"] + ".json")
                read = self.call("status", "--id", task["id"])
                self.assertEqual((read["state"], (read["completion"] or {}).get("outcome"), read.get("failure")),
                                 ("failed", "failed", {"reason": "controller-ended", "detail": ""}))
                self.assertEqual(json.loads(path.read_text()), read)
                self.assertEqual(self.call("cleanup", "--id", task["id"])["cleanup"]["state"], "done")

    def test_model_classes_use_production_picker(self):
        if not REAL_KENDEX:
            self.skipTest("kendex executable unavailable")
        self.bin.joinpath("kendex").unlink()
        self.bin.joinpath("kendex").symlink_to(REAL_KENDEX)
        isolated = self.root / "empty-home"
        isolated.mkdir()
        self.env.update(HOME=str(isolated), XDG_CONFIG_HOME=str(isolated / ".config"))
        for harness in ("codex", "copilot"):
            with self.subTest(harness=harness):
                record = self.launch(harness)
                self.assertEqual(record["model"], "native-default")
                self.acknowledgement(record)
        # A resolved alias must spend the bucket of that native model. The
        # project's fast override deliberately points at the other bucket.
        self.home.joinpath("kendex.toml").write_text('schema = 7\n[model-classes]\n'
            'standard = "anthropic/claude-haiku-5-5"\nfast = "anthropic/claude-opus-5-5"\n')
        self.plant("claude", 0, limits=(("Haiku", 5), ("Opus", 99)))
        record = self.launch("claude")
        self.assertEqual(record["model"], "haiku")
        observed = self.acknowledgement(record)
        self.assertEqual(observed["argv"][observed["argv"].index("--model") + 1], "haiku")

    def test_launch_directory_control(self):
        self.regression_controls((("fixed-home", "task.py", ((
            '            # Results outlive scratch cleanup; the caller selects their home.\n',
            '            cwd = self.home\n            # Results outlive scratch cleanup; the caller selects their home.\n'),),
            "test_launch_directory_contract"),))

    def test_browser_profile_control(self):
        path = self.skills / "jarvis/scripts/lib/task.py"
        source = path.read_text()
        old = '"JARVIS_BROWSER_PROFILE": str(profile) if profile else ""'
        replacement = '"JARVIS_BROWSER_PROFILE": "/parent/browser"'
        self.assertEqual(source.count(old), 1)
        changed = source.replace(old, replacement)
        self.assertNotEqual(changed, source)
        self.assertFalse(path.is_symlink())
        path.write_text(changed)
        env = dict(self.env, JARVIS_TEST_SKILLS=str(self.skills))
        result = subprocess.run([sys.executable, "-B", str(Path(__file__).resolve()),
                                 "TaskContract.test_launch_contract"], env=env,
                                capture_output=True, text=True, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL: test_launch_contract", result.stderr)

    def test_regression_controls(self):
        rows = (
            ("startup", "task.py", (
                ('if not shutil.which(chosen["harness"], path=self.env["PATH"]):',
                 'if False and not shutil.which(chosen["harness"], path=self.env["PATH"]):'),
                ('if self.ended(seen) or (state == "exited" and seen.get("harness_process")):', 'if False:')),
             "test_native_start_failure_is_recoverable"),
            ("rollback", "task.py", (("self.deadline = time.monotonic() + 3",
                "self.deadline = time.monotonic() + 3 if False else self.deadline"),),
             "test_expired_launch_retains_rollback_ownership"),
            ("ready-wait", "task.py", (('if state in ("idle", "working"):', "if True:"),), "test_setup_screen_refuses"),
            ("picker", "task.py", (('pick += ["--native-model", chosen["model"]]', 'pick += []'),),
             "test_model_classes_use_production_picker"),
            ("short-bound", "task.py", (('pick += ["--max-pct", "100"] + ', 'pick += '),),
             "test_a_short_task_is_judged_up_to_the_wall_and_on_its_projected_wall"),
            ("short-projected", "task.py", (('(["--projected"] if args.account else [])', '[]'),),
             "test_a_short_task_is_judged_up_to_the_wall_and_on_its_projected_wall"),
            ("live-front", "task.py", (('            self.tmux("select-window", "-t", live["window"], socket=terminal["server"], check=False)',
                '            pass'),), "test_cleanup_front_window"),
            ("front-only", "task.py", (("        if not front:", "        if False:"),), "test_cleanup_front_window"),
            ("reserved-name", "task.py", (("if args.name.casefold() == SESSION_NAME:", "if False:"),),
             "test_no_task_window_takes_the_live_window_name"),
            ("task-ended", "task.py", (("            if ended:\n", "            if False:\n"),),
             "test_a_task_whose_server_ended_reads_controller_ended"),
            ("replaced-server", "task.py", (('SERVER_ENDED = {"server-gone", "server-replaced"}',
                'SERVER_ENDED = {"server-gone"}'),), "test_a_task_whose_server_ended_reads_controller_ended"),
            ("browser-endpoint", "task.py", (('env["JARVIS_BROWSER_PORT"] = "0"',
                'env["JARVIS_BROWSER_PORT"] = "9222"'),), "test_launch_contract"),
            ("desktop", "task.py", (("                    env.update({name: os.environ[name] for name in DESKTOP_DISPLAY if name in os.environ})\n", ""),),
             "test_launch_contract"),
            ("unconfirmed-close", "task.py", (('if code or stopped["window"]["close"] == "unreadable":', 'if code:'),),
             "test_an_unconfirmed_close_keeps_the_cleanup_pending"),
        )
        self.regression_controls(rows)

    def regression_controls(self, rows):
        for name, filename, edits, case in rows:
            with self.subTest(control=name):
                if name == "picker" and not REAL_KENDEX:
                    self.skipTest("picker: kendex executable unavailable")
                with tempfile.TemporaryDirectory() as allocation:
                    root = Path(allocation).resolve()
                    install(root)
                    path = root / "jarvis/scripts/lib" / filename
                    self.assertFalse(path.is_symlink())
                    source = path.read_text()
                    env = dict(self.env, JARVIS_TEST_SKILLS=str(root))
                    if name == "picker":
                        clean = subprocess.run([sys.executable, "-B", str(Path(__file__).resolve()),
                            "TaskContract." + case], env=env, capture_output=True, text=True, timeout=120)
                        self.assertEqual(clean.returncode, 0, clean.stderr)
                        self.assertNotIn("skipped", clean.stderr)
                    for old, replacement in edits:
                        self.assertEqual(source.count(old), 1)
                        changed = source.replace(old, replacement)
                        self.assertNotEqual(changed, source)
                        source = changed
                    path.write_text(source)
                    result = subprocess.run([sys.executable, "-B", str(Path(__file__).resolve()),
                        "TaskContract." + case], env=env,
                        capture_output=True, text=True, timeout=240)
                    self.assertNotEqual(result.returncode, 0, name)
                    self.assertIn("FAIL: " + case, result.stderr)
                    self.assertNotIn("ERROR: ", result.stderr)

    def test_an_unconfirmed_close_keeps_the_cleanup_pending(self):
        # A window close agent-runtime could not confirm leaves the task's
        # cleanup pending and its scratch kept, for a cleanup that can.
        record = self.launch("codex")
        self.acknowledgement(record)
        self.call("complete", "--id", record["id"], "--outcome", "failed")
        wrapper = self.bin / "tmux"
        wrapper.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
            + 'for arg in "$@"; do if [[ $arg == kill-window ]]; then exit 2; fi; done\n'
            + "exec " + shlex.quote(shutil.which("tmux")) + ' "$@"\n')
        wrapper.chmod(0o755)
        self.call("cleanup", "--id", record["id"], success=False)
        self.assertIsNone(self.call("status", "--id", record["id"])["cleanup"])
        self.assertTrue(Path(record["scratch"]).is_dir())
        wrapper.unlink()
        self.assertEqual(self.call("cleanup", "--id", record["id"])["cleanup"]["state"], "done")
        self.assertFalse(Path(record["scratch"]).exists())


if __name__ == "__main__":
    unittest.main()
