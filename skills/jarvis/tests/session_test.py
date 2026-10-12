"""Contract rows use real tmux and the real identity carrier, with CLI fixtures."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
import threading
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
        if self.record.exists():
            self.call("stop")
            self.wait("off" if json.loads(self.record.read_text()).get("app_off") else "stopped")
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
        result = subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=60)
        self.assertLess(time.monotonic() - start, 60)
        return validate(result.stdout, result.returncode, verb, kwargs.get("duplicate_boot", False)), result.returncode

    def wait(self, state="running", reason=None):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            answer, _ = self.call("status")
            if answer["state"] == state and (reason is None or answer["reason"] == reason):
                return answer
            if answer["state"] in ("blocked", "failed"):
                self.fail(str(answer) + "\n" + (self.record.parent / "session.log").read_text())
            time.sleep(0.05)
        screen = subprocess.run(["tmux", "-L", self.label, "capture-pane", "-p"], capture_output=True, text=True).stdout
        self.fail("state did not settle: " + str(answer) + "\n" + self.record.read_text() + "\n" + screen + "\n" + (self.record.parent / "session.log").read_text())

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
        self.assertEqual(before["cwd"], str(self.home))
        self.assertEqual(before["account"], json.loads(self.record.read_text())["effective_home"])
        self.assertEqual(len(self.started()), 1)
        target = json.loads(self.record.read_text())["pending"].get("session_file")
        if target:
            for name, cwd in (("newer-same", str(self.home)), ("newer-other", str(self.root))):
                (Path(target).parent / (name + ".jsonl")).write_text(json.dumps({"type":"session_meta", "payload":{"id":name,"cwd":cwd}}) + "\n")
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
        self.call("start", origin="boot")
        self.wait()
        self.call("start", origin="boot", duplicate_boot=True)
        self.assertEqual(len(self.started()), 1)
        self.call("stop")
        self.wait("stopped")
        self.assertEqual(self.call("start", origin="boot", duplicate_boot=True)[0]["state"], "stopped")
        self.assertEqual(len(self.started()), 1)
        self.call("start")
        self.wait()
        answer, _ = self.call("stop", origin="app-off")
        self.assertEqual((answer["state"], answer["reason"]), ("stopping", "stop-requested"))
        self.wait("off")
        self.assertEqual(self.call("start")[0]["reason"], "app-off")
        self.call("start", origin="boot", duplicate_boot=True)
        self.assertEqual(len(self.started()), 2)
        self.call("start", origin="app-on")
        self.wait()
        self.assertFalse(json.loads(self.record.read_text())["app_off"])

    def test_concurrent_ensure(self):
        with ThreadPoolExecutor() as executor:
            answers = list(executor.map(lambda _: self.call("start", "copilot"), range(4)))
        self.assertTrue(all(code == 0 for _, code in answers))
        self.wait()
        self.assertEqual(len(self.started()), 1)

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

    def test_sign_in_failure(self):
        fixture = self.home / ".fixture.json"
        fixture.write_text(json.dumps(json.loads(fixture.read_text()) | {"auth_failure": True}))
        self.call("start", "claude")
        answer = self.wait("blocked", "sign-in-required")
        self.assertTrue(answer["detail"])

    def test_account_is_checked_before_private_brief(self):
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
        self.call("start", brief=private)
        self.wait("blocked", "selection-conflict")
        self.assertFalse(any("prompt" in json.loads(line) for line in self.rows.read_text().splitlines()))

    def test_unrelated_session_conflicts(self):
        subprocess.run(["tmux", "-L", self.label, "-f", os.devnull, "new-session", "-d", "-s", "jarvis",
                        os.environ["JARVIS_TEST_BASH"], "--noprofile", "--norc"], check=True)
        self.call("start")
        self.wait("blocked", "name-conflict")
        self.assertEqual(subprocess.run(["tmux", "-L", self.label, "has-session", "-t", "=jarvis"], capture_output=True).returncode, 0)

    def test_verbs_answer_with_held_launch(self):
        # This row measures the VGS time contract. The FIFO proves the native
        # producer has not started. Real time proves it is held past 60s.
        os.mkfifo(self.gate)
        self.call("start")
        deadline = time.monotonic() + 10
        while not self.rows.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(self.rows.exists())
        threading.Event().wait(61)
        self.assertEqual(self.call("status")[0]["state"], "starting")
        self.assertEqual(self.call("start")[0]["state"], "starting")
        self.assertEqual(self.call("stop")[0]["state"], "stopping")

    def test_record_is_outside_home(self):
        self.call("start")
        self.wait()
        self.assertFalse(self.record.is_relative_to(self.home))
        state = self.home / "state"
        state.mkdir()
        (state / "jarvis-session.json").write_text("not a runtime record")
        self.assertEqual(self.call("start")[0]["reason"], "existing")

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


if __name__ == "__main__":
    unittest.main()
