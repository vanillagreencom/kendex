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


ROOT = Path(__file__).resolve().parents[3]
SKILLS = Path(os.environ.get("JARVIS_TEST_SKILLS", ROOT / "skills"))


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
        # Only the external allowance endpoint is replaced. The consumer must
        # ask it about the same harness/model/account that it launches.
        lanes = self.skills / "orch/scripts/lanes"
        lanes.write_text("#!" + sys.executable + "\nimport json,sys\nfrom pathlib import Path\n"
            + "args=sys.argv[1:]; assert args[0]=='pick' and '--json' in args\n"
            + "Path('pick.json').write_text(json.dumps(args))\n"
            + "if Path('refuse-pick').exists(): sys.exit(3)\n"
            + "print(json.dumps({'config_dir':" + repr(str(self.account)) + "}))\n")
        # The fixture is kendex's existing model-resolution protocol, not a
        # second resolver: it returns the chosen selector for one known class.
        self.bin.joinpath("kendex").write_text("#!" + sys.executable + "\nimport json,sys\n"
            + "assert sys.argv[1]=='tier-model'\n"
            + "model=sys.argv[sys.argv.index('--model')+1]\n"
            + "print(json.dumps({'protocol':'model-resolution-v1','request':{'tag':'class' if model=='standard' else 'exact','class':'standard' if model=='standard' else None},'resolution':{'native_selector':'opus','diagnostics':[]},'warning':''}))\n")
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
                        JARVIS_GENERATION="999", JARVIS_BROWSER_PROFILE="/parent/browser")
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

    def launch(self, harness, suffix="", success=True):
        model = "standard" if harness == "claude" else "github-copilot/gpt-5" if harness == "pi" else "gpt-5"
        return self.call("launch", "--name", "Inspect " + harness + suffix, "--harness", harness,
                         "--model", model, "--task-file", self.task_file,
                         "--result-file", self.home / ("result-" + harness + suffix + ".md"),
                         "--input", self.task_file, "--account", self.account, "--browser", success=success)

    def acknowledgement(self, record):
        path = self.home / ("ack-" + record["id"] + ".json")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if path.exists():
                try:
                    return json.loads(path.read_text())
                except json.JSONDecodeError:
                    pass
            time.sleep(0.02)
        self.fail("native launch did not acknowledge: " + json.dumps(record))

    def test_launch_contract(self):
        profiles = set()
        rows = (("claude", "opus", "CLAUDE_CONFIG_DIR", "--model"),
                ("codex", "gpt-5", "CODEX_HOME", "-m"),
                ("copilot", "gpt-5", "COPILOT_HOME", "--model"),
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
                pick = json.loads(self.home.joinpath("pick.json").read_text())
                self.assertEqual(pick[pick.index("--harness") + 1], harness)
                self.assertEqual(pick[pick.index("--model") + 1], model)
                self.assertEqual(pick[pick.index("--lane") + 1], str(self.account))
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
