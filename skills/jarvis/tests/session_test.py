"""Contract rows use real tmux and the real identity carrier, with CLI fixtures."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout, redirect_stderr
import io
import errno
import runpy
from unittest.mock import patch
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import signal
from fixtures.harness import AUTH_MESSAGES, launch_prompt, main as harness_main, native_header, native_launcher
import shlex
import subprocess
import sys
import tempfile
import time
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
                "trust-required"},
    "failed": {"launch-failed", "handover-failed"},
}
# A blocked answer whose detail tells the person what to do.
DETAILED = {("blocked", "sign-in-required"), ("blocked", "trust-required")}


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
        if verb == "start" and not duplicate_boot:
            assert answer["state"] in ("running", "starting")
        elif verb == "stop":
            assert answer["state"] in ("off", "stopped", "stopping")
    return answer


class BootReceiptScenario:
    # The specified receipt producer owns applicability for its contract rows
    # and every mutation of that scenario.
    applicable = Path("/proc/sys/kernel/random/boot_id").is_file()
    controls = (
        ("boot receipt", "jarvis/scripts/lib/session.py", 'if boot and record and record.get("boot") == boot:', 'if False:', "test_off_and_boot_receipt"),
        ("boot refusal receipt", "jarvis/scripts/lib/session.py", 'if boot:\n                    record["boot"] = boot\n                if args.origin == "app-on":', 'if False:\n                    record["boot"] = boot\n                if args.origin == "app-on":', "test_off_and_boot_receipt"),
    )


class SessionContract(unittest.TestCase):
    def setUp(self):
        self.owned_workers = []
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
        shutil.copyfile(HARNESS_SCRIPT, self.home / ".fixture-harness.py")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for harness in ("claude", "codex", "copilot", "pi"):
            target = bin_dir / harness
            shutil.copyfile(HARNESS, target)
            target.chmod(0o755)
        self.env = os.environ | {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                                 "XDG_STATE_HOME": str(self.root / "state"), "XDG_SESSION_ID": "fixture-login",
                                 "WAYLAND_DISPLAY": "fixture-wayland", "DISPLAY": ":fixture",
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
            for worker in self.owned_workers:
                worker.terminate()
                try:
                    worker.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    worker.kill()
                    worker.wait(timeout=5)
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
        return validate(result.stdout, result.returncode, verb, kwargs.get("duplicate_boot", False)), result.returncode

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
                self.fail(str(answer) + "\n" + self.record.read_text() + "\n" + self.session_log())
            time.sleep(0.05)
        target = (json.loads(self.record.read_text()).get("terminal") or {}).get("pane", "")
        screen = subprocess.run(["tmux", "-L", self.label, "capture-pane", "-p", "-t", target], capture_output=True, text=True).stdout
        self.fail("state did not settle: " + str(answer) + "\n" + self.record.read_text() + "\n" + screen + "\n" + self.session_log())

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
        # Jarvis acts on the owner's desktop: its session keeps the live display.
        self.assertEqual(before["display"], ["fixture-wayland", ":fixture"])
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
        from session_controls import applicable_controls
        for available in (False, True):
            with self.subTest(boot_producer=available), patch.object(BootReceiptScenario, "applicable", available):
                names = {row[0] for row in applicable_controls(BootReceiptScenario)}
                for name, *_ in BootReceiptScenario.controls:
                    self.assertEqual(name in names, available)
                self.assertTrue({"app Off", "app On", "app On state"} <= names)
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
        answer = self.wait("failed", "launch-failed", seconds=70)
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
                self.wait(seconds=70)
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
                answer = self.wait(reason="resumed", seconds=70)
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
                answer = self.wait(state, reason, seconds=70)
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

    def test_bad_arguments_have_no_object(self):
        for arguments in ([], ["unknown"], ["status"], ["_worker", "start", str(self.home), "1"],
                          ["start", "--home", str(self.home), "--harness", "unknown"]):
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(SCRIPT), *arguments], env=self.env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertEqual(len(result.stderr.splitlines()), 1)
                self.assertRegex(result.stderr, r"^jarvis-session: [a-z-]+=[a-z-]+\n$")

    def test_native_fixture_uses_installed_toolchain(self):
        rustup = shutil.which("rustup")
        self.assertIsNotNone(rustup, "native-fixture: dependency=rustup")
        with tempfile.TemporaryDirectory() as allocation:
            scratch = Path(allocation).resolve()
            environment = dict(os.environ)
            environment.pop("RUSTUP_TOOLCHAIN", None)
            environment.pop("JARVIS_TEST_NATIVE", None)
            installed = subprocess.run([rustup, "which", "rustc"], cwd=scratch,
                                       env=environment, capture_output=True, text=True, timeout=60)
            self.assertEqual(installed.returncode, 0, installed.stderr)
            environment.update(HOME=str(scratch / "home"), RUSTUP_HOME=str(scratch / "rustup"),
                               CARGO_HOME=str(scratch / "cargo"), RUSTUP_AUTO_INSTALL="0")
            Path(environment["HOME"]).mkdir()
            binary = scratch / "bin"
            binary.mkdir()
            (binary / "rustc").symlink_to(rustup)
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
                while marker not in log.read_text().splitlines() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertIn(marker, log.read_text().splitlines())
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


if __name__ == "__main__":
    with native_launcher() as HARNESS:
        unittest.main()
