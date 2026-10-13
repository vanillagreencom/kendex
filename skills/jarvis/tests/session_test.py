"""Contract rows use real tmux and the real identity carrier, with CLI fixtures."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
from fixtures.harness import native_header
import shlex
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[3]
SKILLS = Path(os.environ.get("JARVIS_TEST_SKILLS", ROOT / "skills"))
SCRIPT = Path(os.environ.get("JARVIS_TEST_SCRIPT", SKILLS / "jarvis/scripts/jarvis-session"))
HARNESS = Path(__file__).with_name("fixtures") / "harness.py"
# Independent VGS-1439 consumer contract. Each planted malformed answer below
# must fail this validator, rather than depending on the producer's table.
REASONS = {
    "running": {"resumed", "new-no-record", "new-history-gone", "new-selection-changed", "new-requested", "existing"},
    "starting": {"launching"}, "handing-over": {"succession"}, "stopping": {"stop-requested"},
    "stopped": {"never-started", "stopped", "ended"}, "off": {"app-off"},
    "blocked": {"app-off", "name-conflict", "record-unreadable", "sign-in-required", "selection-conflict", "tmux-missing", "app-missing"},
    "failed": {"launch-failed", "handover-failed"},
}


def validate(output, code, verb, duplicate_boot=False):
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
    if answer["state"] == "failed" or (answer["state"], answer["reason"]) == ("blocked", "sign-in-required"):
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
        if verb == "start" and not duplicate_boot:
            assert answer["state"] in ("running", "starting")
        elif verb == "stop":
            assert answer["state"] in ("off", "stopped", "stopping")
    return answer


class SessionContract(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.account = self.root / "account"
        self.account.mkdir()
        self.rows = self.root / "rows.jsonl"
        self.gate = self.root / "gate"
        (self.home / ".fixture.json").write_text(json.dumps({"rows": str(self.rows), "gate": str(self.gate),
            "bash": os.environ["JARVIS_TEST_BASH"], "skills": str(SKILLS)}))
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for harness in ("claude", "codex", "copilot", "pi"):
            target = bin_dir / harness
            shutil.copyfile(HARNESS, target)
            target.chmod(0o755)
        self.env = os.environ | {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                                 "XDG_STATE_HOME": str(self.root / "state"), "XDG_SESSION_ID": "fixture-login",
                                 "JARVIS_TEST_BASH": os.environ["JARVIS_TEST_BASH"]}
        key = hashlib.sha256(os.fsencode(str(self.home))).hexdigest()
        self.record = self.root / "state/kendex/jarvis" / key / "jarvis-session.json"
        self.label = "jarvis-" + key[:32]

    def tearDown(self):
        # Kill only the server this fixture started, then remove its scratch.
        (self.root / "refuse-teardown").unlink(missing_ok=True)
        try:
            if self.record.exists():
                self.call("stop")
                self.wait("off" if json.loads(self.record.read_text()).get("app_off") else "stopped")
        finally:
            subprocess.run(["tmux", "-L", self.label, "kill-server"], capture_output=True, env=self.env)
            self.scratch.cleanup()

    def call(self, verb, harness="claude", mode="resume", origin="manual", **kwargs):
        argv = [str(SCRIPT), verb, "--home", str(self.home)]
        if verb == "start":
            argv += ["--harness", harness, "--account", str(kwargs.get("account", self.account)), "--mode", mode, "--origin", origin]
        elif verb == "stop" and origin == "app-off":
            argv += ["--origin", origin]
        if kwargs.get("brief"):
            argv += ["--brief-file", str(kwargs["brief"])]
        start = time.monotonic()
        result = subprocess.run(argv, env=kwargs.get("env", self.env), capture_output=True, text=True, timeout=60)
        self.assertLess(time.monotonic() - start, 60)
        return validate(result.stdout, result.returncode, verb, kwargs.get("duplicate_boot", False)), result.returncode

    def wait(self, state="running", reason=None, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            answer, _ = self.call("status")
            if answer["state"] == state and (reason is None or answer["reason"] == reason):
                return answer
            # tmux can disappear between ownership reads during failed-start
            # cleanup. Unknown ownership is a refusal until the final write.
            transient_cleanup = reason != "record-unreadable" and (answer["state"], answer["reason"]) == ("blocked", "record-unreadable")
            if answer["state"] in ("blocked", "failed") and not transient_cleanup:
                self.fail(str(answer) + "\n" + (self.record.parent / "session.log").read_text())
            time.sleep(0.05)
        screen = subprocess.run(["tmux", "-L", self.label, "capture-pane", "-p"], capture_output=True, text=True).stdout
        self.fail("state did not settle: " + str(answer) + "\n" + self.record.read_text() + "\n" + screen + "\n" + (self.record.parent / "session.log").read_text())

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

    def await_worker_result(self):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            record = json.loads(self.record.read_text())
            if "worker" not in record:
                return record
            time.sleep(0.05)
        self.fail("the worker did not publish its final record")

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
        actual_record = Path(before["record"])
        self.assertTrue(actual_record.is_relative_to(Path(self.env["XDG_STATE_HOME"])))
        self.assertFalse(actual_record.is_relative_to(self.home))
        self.assertEqual(json.loads(actual_record.read_text())["home"], str(self.home))
        state = self.home / "state"
        state.mkdir()
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
        origins = (["boot"] if Path("/proc/sys/kernel/random/boot_id").is_file() else []) + ["app-on"]
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
        if Path("/proc/sys/kernel/random/boot_id").is_file():
            # A new login handles boot once, whether the session lives or ends.
            self.env["XDG_SESSION_ID"] = "second-fixture-login"
            self.call("start", origin="boot")
            count = len(self.started())
            self.call("stop")
            self.wait("stopped")
            self.assertEqual(self.call("start", origin="boot", duplicate_boot=True)[0]["state"], "stopped")
            self.assertEqual(len(self.started()), count)

    def test_identity_before_private_brief(self):
        events = self.observe_inspection()
        os.mkfifo(self.gate)
        brief = self.home / "private.txt"
        brief.write_text("Continue the consumer's private work.")
        self.call("start", "codex", brief=brief)
        deadline = time.monotonic() + 10
        while not self.rows.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(self.call("status")[0]["state"], "starting")
        self.assertFalse(any("prompt" in json.loads(line) for line in self.rows.read_text().splitlines()))
        # A second inspection proves the first identity decision completed.
        # The FIFO remains closed throughout that decision.
        self.await_rows(events, 2)
        with self.gate.open("w") as stream:
            stream.write("1")
        self.wait()
        prompts = [json.loads(line)["prompt"] for line in self.rows.read_text().splitlines() if "prompt" in json.loads(line)]
        self.assertEqual(len(prompts), 1)
        self.assertIn(brief.read_text(), prompts[0])
        self.assertNotIn("oversee", prompts[0])

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
        answer = self.wait("failed", "launch-failed", seconds=70)
        self.assertIsNone(answer["terminal"])
        self.assertTrue(json.loads(self.record.read_text())["history"]["pending"]["started_at"])

    def test_sign_in_failure(self):
        fixture = self.home / ".fixture.json"
        fixture.write_text(json.dumps(json.loads(fixture.read_text()) | {"auth_failure": True}))
        for teardown in ("allowed", "refused"):
            with self.subTest(teardown=teardown):
                flag = self.refuse_teardown() if teardown == "refused" else None
                self.call("start", "claude")
                record = self.await_worker_result()
                answer, _ = self.call("status")
                if flag:
                    self.assertEqual((answer["state"], answer["reason"]), ("starting", "launching"))
                    self.assertIsNotNone(answer["terminal"])
                    self.assertEqual(answer["detail"], "")
                    self.assertTrue(record["history"]["pending"]["started_at"])
                    flag.unlink()
                    self.call("stop")
                    self.wait("stopped")
                else:
                    self.assertEqual((answer["state"], answer["reason"]), ("blocked", "sign-in-required"))
                    self.assertIsNone(answer["terminal"])
                    self.assertTrue(answer["detail"])

    def test_account_is_checked_before_private_brief(self):
        self.call("start")
        self.wait()
        confirmed = self.started()[-1]["id"]
        self.call("stop")
        self.wait("stopped")
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
        count = len(self.started())
        prompt_count = sum("prompt" in json.loads(line) for line in self.rows.read_text().splitlines())
        self.call("start", mode="new", brief=private)
        self.wait("blocked", "selection-conflict")
        self.assertEqual(sum("prompt" in json.loads(line) for line in self.rows.read_text().splitlines()), prompt_count)
        self.assertEqual(json.loads(self.record.read_text())["history"]["pending"]["native_session_id"], confirmed)
        shutil.copyfile(HARNESS, wrapper)
        self.call("start")
        self.wait(reason="resumed")
        self.assertEqual(self.started()[-1]["id"], confirmed)
        self.assertEqual(len(self.started()), count + 2)

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
        self.call("start")
        deadline = time.monotonic() + 10
        while not self.rows.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(self.rows.exists())
        worker = json.loads(self.record.read_text())["worker"]
        # The worker belongs to this fixture and is still held by the FIFO.
        identity = subprocess.run([self.env["JARVIS_TEST_BASH"],
            str(SKILLS / "jarvis/scripts/lib/session-backend.sh"), "worker-live",
            str(worker["pid"]), worker["started_at"]], env=self.env, capture_output=True)
        self.assertEqual(identity.returncode, 0)
        os.kill(worker["pid"], signal.SIGTERM)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            result = subprocess.run([self.env["JARVIS_TEST_BASH"],
                str(SKILLS / "jarvis/scripts/lib/session-backend.sh"), "worker-live",
                str(worker["pid"]), worker["started_at"]], env=self.env, capture_output=True)
            if result.returncode == 1:
                break
            time.sleep(0.05)
        self.assertEqual(result.returncode, 1)
        terminal = self.call("status")[0]["terminal"]
        flag = self.refuse_teardown()
        retained, _ = self.call("start")
        self.assertEqual((retained["state"], retained["reason"], retained["terminal"]),
                         ("starting", "launching", terminal))
        self.assertNotIn("worker", json.loads(self.record.read_text()))
        flag.unlink()
        self.assertEqual(self.call("start")[0]["state"], "starting")
        replacement = json.loads(self.record.read_text())["worker"]
        self.assertNotEqual(replacement, worker)
        flag.touch()
        self.assertEqual(self.call("stop", origin="app-off")[0]["state"], "stopping")
        result = self.await_worker_result()
        answer, _ = self.call("status")
        self.assertEqual((answer["state"], answer["reason"], answer["terminal"]),
                         ("starting", "launching", result["terminal"]))
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

    def test_bad_arguments_have_no_object(self):
        for arguments in ([], ["unknown"], ["status"], ["_worker", "start", str(self.home), "1"],
                          ["start", "--home", str(self.home), "--harness", "unknown"]):
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(SCRIPT), *arguments], env=self.env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertEqual(len(result.stderr.splitlines()), 1)
                self.assertRegex(result.stderr, r"^jarvis-session: [a-z-]+=[a-z-]+\n$")

    def test_cancelled_replacement_keeps_the_live_owner(self):
        self.call("start")
        first = self.wait()
        account = self.root / "pending-account"
        account.mkdir()
        (account / ".claude.json").write_text('{"fixture":"hold-preparation"}')
        acknowledgement = self.root / "prepare-ack"
        gate = self.root / "prepare-gate"
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
        generation = json.loads(self.record.read_text())["generation"]
        answer, _ = self.call("start")
        self.assertEqual(answer["reason"], "existing")
        self.assertEqual(answer["terminal"], first["terminal"])
        with gate.open("w") as stream:
            stream.write("1")
        log = self.record.parent / "session.log"
        deadline = time.monotonic() + 10
        marker = "jarvis-session: worker=cancelled generation=" + str(generation)
        while marker not in log.read_text().splitlines() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertIn(marker, log.read_text().splitlines())
        self.assertEqual(self.call("status")[0]["state"], "running")
        self.assertEqual(len(self.started()), 1)
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
        self.assertEqual(len(self.started()), 1)
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
        self.assertEqual(record["history"]["pending"]["native_session_id"], self.started()[0]["id"])
        self.assertEqual(self.call("start")[0]["reason"], "app-off")
        flag.unlink()
        self.call("stop")
        self.wait("off")
        self.assertEqual(json.loads(self.record.read_text())["generation"], record["generation"] + 1)


if __name__ == "__main__":
    unittest.main()
