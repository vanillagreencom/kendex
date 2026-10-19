"""Real tmux and shared launch code; account meter and native CLIs are fixtures."""
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

from fixtures.harness import native_launcher

ROOT = Path(__file__).resolve().parents[3]
SKILLS = Path(os.environ.get("JARVIS_TEST_SKILLS", ROOT / "skills"))
REAL_KENDEX = os.environ.get("JARVIS_TEST_REAL_KENDEX", shutil.which("kendex"))


class TaskContract(unittest.TestCase):
    def setUp(self):
        self.allocation = tempfile.TemporaryDirectory()
        self.root = Path(self.allocation.name).resolve()
        self.home = self.root / "home with spaces"
        self.home.mkdir()
        self.skills = self.root / "skills"
        for package in ("jarvis", "orch", "mailbox"):
            shutil.copytree(SKILLS / package / "scripts", self.skills / package / "scripts")
        self.script = self.skills / "jarvis/scripts/task"
        self.account = self.root / "picked account"
        self.account.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Exercise the production picker; only its external host meter is a
        # fixture. No account credentials or live quota endpoints are read.
        meter = self.bin / "meter"
        meter.write_text("#!" + sys.executable + "\nfrom pathlib import Path\nimport sys\n"
            + "if sys.argv[1]=='capabilities':\n print('kind=ssh\\tlaunch=ssh\\tchannel=mailbox\\tfiles=verb\\tstatus=verb\\tstop=verb\\trelaunch=resume\\tpark=none\\taccounts=none\\tpool=plan\\tland=lane'); sys.exit(0)\n"
            + "assert sys.argv[1]=='accounts'\n"
            + "pct=99 if Path('refuse-pick').exists() else 5\n"
            + "for harness in ('claude','codex','copilot','pi'):\n"
            + " print('account=' + " + repr(str(self.account)) + " + '\\tharness='+harness+'\\tsession-5h-pct='+str(pct)+'\\tweekly-pct='+str(pct)+'\\tmodel-pct='+str(pct)+'\\tmodel-label=Opus\\tmonthly-pct='+str(pct))\n")
        meter.chmod(0o755)
        settings = {"ORCH_LANE_HOST": str(meter), "LANES_HOME": str(self.root / "empty-home"),
                    "OVERSEE_WATCH_STATE_DIR": str(self.root / "meter-state"),
                    "ORCH_STATE_DIR": str(self.root / "orch-state")}
        (self.home / "kendex.settings.toml").write_text("[env]\n" + "".join(
            key + " = " + json.dumps(value) + "\n" for key, value in settings.items()))
        shutil.copyfile(ROOT / "skills/orch/tests/fixtures/tier-model/kendex", self.bin / "kendex")
        self.bin.joinpath("kendex").chmod(0o755)
        native = ("#!" + sys.executable + "\nimport json,os,signal,sys\nfrom pathlib import Path\n"
                  + "keys={'CLAUDE_CONFIG_DIR','CODEX_HOME','COPILOT_HOME','PI_CODING_AGENT_DIR','JARVIS_BROWSER_PROFILE','JARVIS_TASK_SCRATCH'}\n"
                  + "row={'harness':Path(sys.argv[0]).name,'argv':sys.argv[1:],'env_keys':list(os.environ),'env':{k:os.environ[k] for k in keys if k in os.environ}}\n"
                  + "Path('ack-'+os.environ['JARVIS_TASK_ID']+'.json').write_text(json.dumps(row))\n"
                  + "while True: signal.pause()\n")
        for harness in ("claude", "codex", "copilot", "pi"):
            self.bin.joinpath(harness).write_text(native)
            self.bin.joinpath(harness).chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        XDG_STATE_HOME=str(self.root / "state"), CLAUDECODE="parent",
                        CLAUDE_CODE_SESSION_ID="parent", CODEX_THREAD_ID="parent",
                        PI_SUBAGENT_PARENT_SESSION_ID="parent", JARVIS_RECORD="parent",
                        JARVIS_GENERATION="999", JARVIS_BROWSER_PROFILE="/parent/browser",
                        JARVIS_TEST_REAL_KENDEX=REAL_KENDEX or "")
        key = hashlib.sha256(os.fsencode(str(self.home))).hexdigest()
        self.record_path = self.root / "state/kendex/jarvis" / key / "jarvis-session.json"
        self.label = "jarvis-" + key[:32]
        created = self.tmux("new-session", "-d", "-s", "jarvis", "-P", "-F",
                            "#{socket_path}\t#{pid}\t#{start_time}\t#{window_id}\t#{pane_id}",
                            self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc")
        socket, server, started, window, pane = created.stdout.strip().split("\t")
        self.terminal = dict(server=socket, session="jarvis", window=window, pane=pane)
        self.tmux("set-option", "-p", "-t", pane, "@jarvis-generation", "1")
        self.record_path.parent.mkdir(parents=True)
        self.record_path.write_text(json.dumps(dict(v=1, home=str(self.home), harness="claude",
            account=str(self.account), generation=1, state="running", reason="existing", detail="",
            terminal=self.terminal, server_pid=int(server), server_started_at=int(started), process=True)))
        self.task_file = self.home / "task brief.md"
        self.task_file.write_text("Inspect the selected site. Write the Output section.\n")

    def tearDown(self):
        subprocess.run(["tmux", "-L", self.label, "kill-server"], env=self.env, capture_output=True, timeout=10)
        self.allocation.cleanup()

    def tmux(self, *args):
        return subprocess.run(["tmux", "-L", self.label, "-f", os.devnull, *args],
                              env=self.env, capture_output=True, text=True, timeout=10, check=True)

    def call(self, verb, *args, success=True):
        result = subprocess.run([str(self.script), verb, "--home", str(self.home), *map(str, args)],
                                env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0 if success else 1, result.stderr)
        return json.loads(result.stdout) if success else result

    def launch(self, harness, suffix="", success=True, model=None):
        model = model or ("github-copilot/gpt-5" if harness == "pi" else "standard")
        return self.call("launch", "--name", "Inspect " + harness + suffix, "--harness", harness,
                         "--model", model, "--task-file", self.task_file,
                         "--result-file", self.home / ("result-" + harness + suffix + ".md"),
                         "--input", self.task_file, "--account", self.account, "--browser", success=success)

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
                                 (harness, model, str(self.account)))
                self.assertEqual(record["inputs"], [str(self.task_file)])
                self.assertEqual(record["task_file"], str(self.task_file))
                self.assertEqual(record["result_path"], str(self.home / ("result-" + harness + ".md")))
                self.assertEqual(record["terminal"]["server"], self.terminal["server"])
                self.assertNotEqual(record["terminal"]["window"], self.terminal["window"])
                if model == "native-default":
                    self.assertNotIn(model_flag, observed["argv"])
                else:
                    self.assertEqual(observed["argv"][observed["argv"].index(model_flag) + 1], model)
                self.assertTrue(observed["env"][account_var].startswith(str(self.account)))
                for identity in ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID",
                                 "PI_SUBAGENT_PARENT_SESSION_ID", "JARVIS_RECORD", "JARVIS_GENERATION"):
                    self.assertNotIn(identity, observed["env_keys"])
                profile = Path(record["browser_profile"])
                self.assertTrue(profile.is_absolute() and profile.is_dir())
                self.assertEqual(profile.parent, Path(record["scratch"]))
                self.assertEqual(observed["env"]["JARVIS_BROWSER_PROFILE"], str(profile))
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

    def test_failed_pick_releases_task_scratch(self):
        self.home.joinpath("refuse-pick").touch()
        self.launch("codex", success=False)
        paths = list(self.record_path.parent.joinpath("tasks").glob("*.json"))
        self.assertEqual(len(paths), 1)
        record = json.loads(paths[0].read_text())
        self.assertEqual(record["state"], "failed")
        self.assertEqual(record["cleanup"]["state"], "done")
        self.assertFalse(Path(record["scratch"]).exists())
        self.assertEqual(self.tmux("list-windows", "-t", "=jarvis", "-F", "#{window_id}").stdout.splitlines(),
                         [self.terminal["window"]])

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
            for mode in ("missing", "early-exit"):
                with self.subTest(harness=harness, mode=mode):
                    if mode == "missing":
                        path.unlink()
                    else:
                        path.write_text("#!" + sys.executable + "\nimport sys\nsys.exit(23)\n")
                        path.chmod(0o755)
                    failed = self.launch(harness, mode, success=False,
                                         model="gpt-5" if harness in ("codex", "copilot") else None)
                    record = self.saved_tasks()[-1] if len(self.saved_tasks()) == 1 else next(
                        row for row in self.saved_tasks() if row["name"] == "Inspect " + harness + mode)
                    self.assertIn("id=" + record["id"], failed.stderr)
                    self.assertEqual(record["state"], "failed")
                    self.assertEqual(record["failure"]["reason"], "app-missing" if mode == "missing" else "native-exited")
                    if mode == "early-exit":
                        self.assertEqual(record["failure"]["exit"], 23)
                    self.assertEqual(record["completion"]["outcome"], "failed")
                    self.assertEqual(self.call("cleanup", "--id", record["id"])["cleanup"]["state"], "done")
                    path.write_text(original)
                    path.chmod(0o755)

    def test_expired_launch_retains_rollback_ownership(self):
        for unread in (False, True):
            with self.subTest(unread=unread):
                wrapper = self.bin / "tmux"
                wrapper.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
                    + 'for arg in "$@"; do if [[ $arg == list-panes && -e refuse-close ]]; then exit 2; fi; done\n'
                    + "exec " + shlex.quote(shutil.which("tmux")) + ' "$@"\n')
                wrapper.chmod(0o755)
                code = """
import sys,time
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import task
unread=sys.argv[2]=='True'
original=task.Task.tmux
def expire(self,*args,**kwargs):
    answer=original(self,*args,**kwargs)
    if args[0]=='new-window':
        self.deadline=time.monotonic()-1
        if unread: Path(self.home,'refuse-close').touch()
    return answer
task.Task.tmux=expire
sys.argv=[sys.argv[0],*sys.argv[3:]]
sys.exit(task.main())
"""
                args = ["launch", "--home", str(self.home), "--harness", "codex", "--model", "gpt-5",
                        "--name", "expired-" + str(unread), "--task-file", str(self.task_file),
                        "--result-file", str(self.home / "output.md"), "--account", str(self.account), "--browser"]
                result = subprocess.run([sys.executable, "-B", "-c", code,
                    str(self.skills / "jarvis/scripts/lib"), str(unread), *args],
                    env=dict(self.env, JARVIS_BASH=self.env["JARVIS_TEST_BASH"]),
                    capture_output=True, text=True, timeout=15)
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

    def test_controller_exit_recovers_task_windows(self):
        self.tmux("new-session", "-d", "-s", "unrelated", self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc")
        task = self.launch("codex", model="gpt-5")
        self.acknowledgement(task)
        self.tmux("kill-window", "-t", self.terminal["window"])
        # The replacement is a real managed controller, using the existing
        # native fixture and SessionStart carrier rather than a mocked worker.
        with native_launcher() as launcher:
            shutil.copyfile(launcher, self.bin / "claude")
            self.bin.joinpath("claude").chmod(0o755)
            shutil.copyfile(Path(__file__).with_name("fixtures") / "harness.py", self.home / ".fixture-harness.py")
            (self.home / ".fixture.json").write_text(json.dumps({"rows": str(self.root / "rows.jsonl"),
                "gate": str(self.root / "gate"), "bash": self.env["JARVIS_TEST_BASH"], "skills": str(self.skills)}))
            session = self.skills / "jarvis/scripts/jarvis-session"
            for recovery in ("start", "stop"):
                with self.subTest(recovery=recovery):
                    args = [str(session), recovery, "--home", str(self.home)]
                    if recovery == "start":
                        args += ["--harness", "claude", "--account", str(self.account), "--mode", "new", "--origin", "manual"]
                    result = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    deadline = time.monotonic() + 20
                    while time.monotonic() < deadline:
                        saved = json.loads(self.record_path.read_text())
                        if saved["state"] == ("running" if recovery == "start" else "stopped"):
                            break
                        self.assertNotIn(saved["state"], ("blocked", "failed"), saved)
                        time.sleep(0.05)
                    else:
                        self.fail(self.record_path.read_text())
                    self.tmux("has-session", "-t", "=unrelated")
                    ended = self.call("status", "--id", task["id"])
                    self.assertIsNotNone(ended["completion"])
                    self.assertEqual(ended["completion"]["outcome"], "failed")
                    self.assertTrue(Path(ended["scratch"]).is_dir())
                    if recovery == "start":
                        self.terminal = saved["terminal"]
                        # Leave another task window after this controller ends
                        # so the explicit stop path reaches the same condition.
                        task = self.launch("codex", "again", model="gpt-5")
                        self.tmux("kill-window", "-t", self.terminal["window"])
            self.call("cleanup", "--id", task["id"])

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
        self.account.joinpath(".credentials.json").write_text(json.dumps({"claudeAiOauth": {
            "accessToken": "fixture-token", "expiresAt": (time.time() + 3600) * 1000,
            "subscriptionType": "max"}}))
        body = {"five_hour": {"utilization": 0}, "seven_day": {"utilization": 0},
                "limits": [{"kind": "weekly_scoped", "percent": percent,
                            "scope": {"model": {"display_name": name}}}
                           for name, percent in (("Haiku", 5), ("Opus", 99))]}
        fetch = self.bin / "fetch"
        fetch.write_text("#!" + sys.executable + "\nprint('200')\nprint(" + repr(json.dumps(body)) + ")\n")
        fetch.chmod(0o755)
        self.home.joinpath("kendex.settings.toml").write_text("[env]\n" + "".join(
            key + " = " + json.dumps(value) + "\n" for key, value in {
                "ORCH_LANE_HOST": "local", "LANES_HOME": str(isolated),
                "ORCH_LANE_DIRS": str(self.account), "ORCH_LANES_FETCH_CMD": str(fetch),
                "OVERSEE_WATCH_STATE_DIR": str(self.root / "claude-meter")}.items()))
        record = self.launch("claude")
        self.assertEqual(record["model"], "haiku")
        observed = self.acknowledgement(record)
        self.assertEqual(observed["argv"][observed["argv"].index("--model") + 1], "haiku")

    def test_terminal_interrupt_preserves_native_lifetime(self):
        native = self.bin / "pi"
        native.write_text("#!" + sys.executable + "\n" + '''import json,os,signal,sys,termios,tty
from pathlib import Path
path=Path('ack-'+os.environ['JARVIS_TASK_ID']+'.json')
def ack(stage):
    path.write_text(json.dumps({'stage':stage,'ignored':signal.getsignal(signal.SIGINT)==signal.SIG_IGN}))
ack('started')
if Path('suspend-native').exists():
    saved=termios.tcgetattr(0)
    tty.setraw(0)
    ack('raw')
    assert os.read(0,1)==b'\\x1a'
    signal.signal(signal.SIGINT,lambda *_: ack('interrupt'))
    signal.signal(signal.SIGQUIT,lambda *_: ack('quit'))
    termios.tcsetattr(0,termios.TCSANOW,saved)
    ack('cooked')
    assert sys.stdin.readline().strip()=='finish'
    sys.exit(23)
while True: signal.pause()
''')
        native.chmod(0o755)
        for suspended in (False, True):
            with self.subTest(suspended=suspended):
                if suspended:
                    self.home.joinpath("suspend-native").touch()
                record = self.launch("pi", str(suspended))
                observed = self.acknowledgement(record, "raw" if suspended else "started")
                self.assertFalse(observed["ignored"])
                pane = record["terminal"]["pane"]
                if suspended:
                    self.tmux("send-keys", "-t", pane, "C-z")
                    self.acknowledgement(record, "cooked")
                self.tmux("send-keys", "-t", pane, "C-c")
                if suspended:
                    self.acknowledgement(record, "interrupt")
                    self.assertEqual(self.tmux("display-message", "-p", "-t", pane, "#{pane_dead}").stdout.strip(), "0")
                    self.tmux("send-keys", "-t", pane, "C-\\")
                    self.acknowledgement(record, "quit")
                    self.assertEqual(self.tmux("display-message", "-p", "-t", pane, "#{pane_dead}").stdout.strip(), "0")
                    self.tmux("send-keys", "-t", pane, "finish", "Enter")
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    dead = self.tmux("display-message", "-p", "-t", pane, "#{pane_dead}").stdout.strip()
                    if dead == "1":
                        break
                    time.sleep(0.02)
                self.assertEqual(dead, "1")
                if suspended:
                    self.assertEqual(self.tmux("display-message", "-p", "-t", pane, "#{pane_dead_status}").stdout.strip(), "23")

    def test_controller_teardown_refusals(self):
        original = json.loads(self.record_path.read_text())
        self.tmux("new-session", "-d", "-s", "unrelated", self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc")
        for verb, live in (("stop", False), ("start", False), ("stop", True)):
            with self.subTest(verb=verb, live=live):
                saved = dict(original, terminal=self.terminal, pending={"generation": 1})
                self.record_path.write_text(json.dumps(saved))
                task = self.launch("codex", verb + str(live), model="gpt-5")
                self.acknowledgement(task)
                if not live:
                    self.tmux("kill-window", "-t", self.terminal["window"])
                wrapper = self.bin / "tmux"
                wrapper.write_text("#!" + sys.executable + "\nimport os,sys\n"
                    + "if '#{@jarvis-task}' in sys.argv: sys.exit(2)\n"
                    + "os.execv(" + repr(shutil.which("tmux")) + ", ['tmux',*sys.argv[1:]])\n")
                wrapper.chmod(0o755)
                args = [str(self.skills / "jarvis/scripts/jarvis-session"), verb, "--home", str(self.home)]
                if verb == "start":
                    args += ["--harness", "claude", "--account", str(self.account), "--mode", "new", "--origin", "manual"]
                result = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0 if live else 1, result.stderr)
                self.assertTrue(result.stdout, result.stderr)
                answer = json.loads(result.stdout)
                self.assertEqual((answer["state"], answer["reason"]),
                                 ("stopping", "stop-requested") if live else ("failed", "launch-failed"))
                if live:
                    deadline = time.monotonic() + 15
                    while time.monotonic() < deadline:
                        repaired = json.loads(self.record_path.read_text())
                        if "worker" not in repaired:
                            break
                        time.sleep(0.02)
                    self.assertNotIn("worker", repaired)
                    self.assertEqual(repaired["state"], "running")
                    self.tmux("has-session", "-t", "=jarvis")
                wrapper.unlink()
                ended = self.call("status", "--id", task["id"])
                self.assertEqual(ended["completion"]["outcome"], "failed")
                self.assertEqual(self.call("cleanup", "--id", task["id"])["cleanup"]["state"], "done")
                self.tmux("has-session", "-t", "=unrelated")
                if not live:
                    created = self.tmux("new-session", "-d", "-s", "jarvis", "-P", "-F", "#{window_id}\t#{pane_id}",
                                        self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc")
                    window, pane = created.stdout.strip().split("\t")
                    self.terminal = dict(self.terminal, window=window, pane=pane)
                    self.tmux("set-option", "-p", "-t", pane, "@jarvis-generation", "1")

    def test_browser_profile_control(self):
        path = self.skills / "jarvis/scripts/lib/task.py"
        source = path.read_text()
        old = '"JARVIS_BROWSER_PROFILE=" + (str(profile) if profile else "")'
        replacement = '"JARVIS_BROWSER_PROFILE=" + "/parent/browser"'
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
                ('if not shutil.which(prepared["harness"], path=self.env["PATH"]):',
                 'if False and not shutil.which(prepared["harness"], path=self.env["PATH"]):'),
                ('if startup["state"] != "started":', 'if False and startup["state"] != "started":')),
             "test_native_start_failure_is_recoverable"),
            ("rollback", "task.py", (("self.deadline = time.monotonic() + 3",
                "self.deadline = time.monotonic() + 3 if False else self.deadline"),),
             "test_expired_launch_retains_rollback_ownership"),
            ("picker", "session-backend.sh", (('pick_args+=(--native-model "$model")',
                'pick_args+=(--model "$model")'),), "test_model_classes_use_production_picker"),
            ("controller", "session.py", (("if not record or not record.get(\"terminal\"):\n            return\n        paths =",
                "if True or not record or not record.get(\"terminal\"):\n            return\n        paths ="),),
             "test_controller_exit_recovers_task_windows"),
            ("refusal", "session.py", (("sys.exit(session.main())", "sys.exit(main())"),),
             "test_controller_teardown_refusals"),
            ("interrupt", "task.py", ((
                "if signal.getsignal(signum) != signal.SIG_IGN:",
                "if False and signal.getsignal(signum) != signal.SIG_IGN:"),),
             "test_terminal_interrupt_preserves_native_lifetime"),
        )
        for name, filename, edits, case in rows:
            with self.subTest(control=name):
                if name == "picker" and not REAL_KENDEX:
                    self.skipTest("picker: kendex executable unavailable")
                with tempfile.TemporaryDirectory() as allocation:
                    root = Path(allocation).resolve()
                    for package in ("jarvis", "orch", "mailbox"):
                        shutil.copytree(SKILLS / package / "scripts", root / package / "scripts")
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
                        capture_output=True, text=True, timeout=120)
                    self.assertNotEqual(result.returncode, 0, name)
                    self.assertIn("FAIL: " + case, result.stderr)
                    self.assertNotIn("ERROR: ", result.stderr)

    def test_cleanup_keeps_unread_terminal_open(self):
        record = self.launch("codex")
        self.acknowledgement(record)
        self.call("complete", "--id", record["id"], "--outcome", "failed")
        wrapper = self.bin / "tmux"
        wrapper.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
            + 'for arg in "$@"; do if [[ $arg == list-panes ]]; then exit 2; fi; done\n'
            + "exec " + shlex.quote(shutil.which("tmux")) + ' "$@"\n')
        wrapper.chmod(0o755)
        self.call("cleanup", "--id", record["id"], success=False)
        self.assertIsNone(self.call("status", "--id", record["id"])["cleanup"])
        self.assertTrue(Path(record["scratch"]).is_dir())
        wrapper.unlink()
        self.assertEqual(self.call("cleanup", "--id", record["id"])["cleanup"]["state"], "done")


if __name__ == "__main__":
    unittest.main()
