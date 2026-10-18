"""Succession uses real tmux and native identity hooks with deterministic CLI fixtures."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
import unittest
from unittest.mock import patch
import session_test
from session_test import SessionContract, SKILLS
from fixtures.harness import native_launcher


class SuccessionContract(SessionContract):
    def handoff(self):
        path = self.home / "state/handoff.md"
        path.parent.mkdir(exist_ok=True)
        contents = "# Handoff\n\n## State\n\nwork: TASK-ref\n\n## Sub-agents\n\nnone\n\n## Instructions in force\n\nnone\n\n## Progress log\n"
        path.write_text(contents)
        return contents

    def test_succession_contract(self):
        # Real tmux and the native hook carrier; CLI behaviour is a fixture.
        # One table covers every launch shape, including deferred kickoff.
        for harness in ("claude", "codex", "copilot", "pi"):
            with self.subTest(harness=harness):
                self.call("start", harness=harness, mode="new")
                self.wait()
                predecessor = json.loads(self.record.read_text())
                contents = self.handoff()
                native_count = len(self.started())
                answer, code = self.call("succeed")
                self.assertEqual((answer["state"], answer["reason"], code), ("handing-over", "succession", 0))
                current = self.wait()
                successor = json.loads(self.record.read_text())
                self.assertEqual((current["home"], current["account"], current["harness"]),
                                 (str(self.home), str(self.account), harness))
                for field in ("server", "session"):
                    self.assertEqual(current["terminal"][field], predecessor["terminal"][field])
                self.assertNotEqual(current["terminal"]["window"], predecessor["terminal"]["window"])
                self.assertNotEqual(successor["pending"]["native_session_id"], predecessor["pending"]["native_session_id"])
                self.assertEqual(successor["transfer"]["phase"], "complete")
                self.assertEqual(Path(successor["transfer"]["handoff"]).read_text(), contents)
                self.assertEqual((self.home / "state/handoff.md").read_text(), contents)
                self.assertEqual(len(self.started()), native_count + 1)
                pid = predecessor["process"]["pid"]
                result = subprocess.run([self.env["JARVIS_TEST_BASH"], str(SKILLS / "jarvis/scripts/lib/session-backend.sh"),
                                         "worker-live", str(pid), predecessor["process"]["started_at"]],
                                        capture_output=True, env=self.env, timeout=10)
                self.assertEqual(result.returncode, 1)
                self.call("stop")
                self.wait("stopped", persisted_stop=True)

    def test_succession_identity(self):
        self.handoff()
        self.call("start")
        original = self.wait()
        record = json.loads(self.record.read_text())
        identity = dict(record["process"])
        record["process"]["started_at"] = "a different start time"
        self.record.write_text(json.dumps(record))
        self.call("succeed")
        saved = self.await_worker_result()
        answer, _ = self.call("status")
        self.assertEqual((answer["state"], answer["terminal"]), ("running", original["terminal"]))
        self.assertEqual(len(self.started()), 1)
        self.assertEqual(saved["pending"]["native_session_id"], record["pending"]["native_session_id"])
        saved["process"] = identity
        self.record.write_text(json.dumps(saved))

    def test_succession_foreign_session(self):
        self.handoff()
        self.call("start")
        self.wait()
        self.call("succeed")
        self.wait()
        self.call("stop")
        self.wait("stopped", persisted_stop=True)
        failed = json.loads(self.record.read_text())
        failed.update(state="failed", reason="handover-failed", detail="Retry succession.", intent="succeed", terminal=None)
        failed.pop("worker", None)
        self.record.write_text(json.dumps(failed))
        foreign = subprocess.run(["tmux", "-L", self.label, "new-session", "-d", "-s", "jarvis", "-P", "-F", "#{window_id}",
                                  self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc"],
                                 capture_output=True, text=True, env=self.env, timeout=10, check=True).stdout.strip()
        count = len(self.started())
        self.call("succeed")
        self.wait("failed", "handover-failed")
        self.await_worker_result()
        windows = subprocess.run(["tmux", "-L", self.label, "list-windows", "-t", "jarvis", "-F", "#{window_id}"],
                                 capture_output=True, text=True, env=self.env, timeout=10, check=True)
        self.assertEqual(windows.stdout.splitlines(), [foreign])
        self.assertEqual(len(self.started()), count)

    def test_succession_recovery(self):
        # Interrupt the real writer before/after each transition write. Only
        # the disposable script copy gains barriers; operations stay production.
        skills = self.root / "instrumented/skills"
        for package in ("jarvis", "orch", "mailbox"):
            shutil.copytree(SKILLS / package / "scripts", skills / package / "scripts")
        source = skills / "jarvis/scripts/lib/session.py"
        original = source.read_text()
        marker = "            os.replace(name, self.path)"
        self.assertEqual(original.count(marker), 1)
        instrumented = original.replace(marker, "            self.checkpoint(record, 'before')\n" + marker + "\n            self.checkpoint(record, 'after')")
        method = '''    def checkpoint(self, record, edge):
        config = Path(self.home) / ".succession-pause.json"
        if not config.exists():
            return
        point = json.loads(config.read_text())
        if record.get("intent") != "succeed" or record.get("transfer", {}).get("phase") != point["phase"] or edge != point["edge"]:
            return
        try:
            stream = Path(point["event"]).open("x")
        except FileExistsError:
            return
        with stream:
            json.dump(json.loads(self.backend("process", os.getpid()).stdout), stream)
        while not Path(point["release"]).exists():
            time.sleep(0.05)

'''
        self.assertEqual(instrumented.count("    def write(self, record):"), 1)
        instrumented = instrumented.replace("    def write(self, record):", method + "    def write(self, record):")
        self.assertNotEqual(original, instrumented)
        source.write_text(instrumented)
        script = skills / "jarvis/scripts/jarvis-session"
        pause = self.home / ".succession-pause.json"
        event = self.root / "checkpoint.json"
        release = self.root / "release"
        phases = ("saved", "waiting", "predecessor-ended", "confirmed", "brief-delivered", "complete")
        with patch.object(session_test, "SCRIPT", script):
            for harness in ("claude", "codex", "copilot", "pi"):
                for phase in phases:
                    for edge in ("before", "after"):
                        with self.subTest(harness=harness, phase=phase, edge=edge):
                            print("succession-row: harness=" + harness + " phase=" + phase + " edge=" + edge, flush=True)
                            self.handoff()
                            self.call("start", harness=harness, mode="new")
                            self.wait()
                            previous = json.loads(self.record.read_text())
                            native_count = len(self.started())
                            event.unlink(missing_ok=True)
                            pause.write_text(json.dumps({"phase": phase, "edge": edge, "event": str(event), "release": str(release)}))
                            with subprocess.Popen([str(script), "succeed", "--home", str(self.home)],
                                                  env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as request:
                                deadline = time.monotonic() + 15
                                identity = None
                                while time.monotonic() < deadline:
                                    if event.exists():
                                        try:
                                            identity = json.loads(event.read_text())
                                            break
                                        except json.JSONDecodeError:
                                            pass
                                    if request.poll() is not None and request.returncode:
                                        self.fail("succession request refused: " + str(request.communicate()))
                                    time.sleep(0.05)
                                self.assertIsNotNone(identity, self.session_log())
                                persisted = json.loads(self.record.read_text())
                                during, _ = self.call("status")
                                expected = "running" if (phase, edge) in (("saved", "before"), ("complete", "after")) else "handing-over"
                                self.assertEqual(during["state"], expected)
                                predecessor = previous["process"]
                                old_live = subprocess.run([self.env["JARVIS_TEST_BASH"], str(skills / "jarvis/scripts/lib/session-backend.sh"),
                                                           "worker-live", str(predecessor["pid"]), predecessor["started_at"]],
                                                          capture_output=True, env=self.env, timeout=10)
                                self.assertEqual(old_live.returncode, 0 if phase in ("saved", "waiting") else 1)
                                self.assertEqual(len(self.started()) - native_count,
                                                 1 if phase in ("confirmed", "brief-delivered", "complete") else 0)
                                live = subprocess.run([self.env["JARVIS_TEST_BASH"], str(skills / "jarvis/scripts/lib/session-backend.sh"),
                                                       "worker-live", str(identity["pid"]), identity["started_at"]],
                                                      capture_output=True, env=self.env, timeout=10)
                                self.assertEqual(live.returncode, 0)
                                os.kill(identity["pid"], signal.SIGKILL)
                                request.communicate(timeout=10)
                            pause.unlink()
                            before_end = phase in ("saved", "waiting")
                            completed = (phase, edge) == ("complete", "after")
                            if before_end or completed:
                                settled = self.wait("running")
                                owner = previous if before_end else persisted
                                self.assertEqual(settled["terminal"], owner["terminal"])
                            else:
                                settled = self.wait("failed", "handover-failed")
                                self.assertTrue(settled["detail"])
                                deadline = time.monotonic() + 15
                                while settled["terminal"] is not None and time.monotonic() < deadline:
                                    time.sleep(0.05)
                                    settled, _ = self.call("status")
                                self.assertIsNone(settled["terminal"], self.session_log())
                                # The app's Start/boot path cannot revive old history.
                                start, code = self.call("start", harness=harness)
                                self.assertEqual((start["state"], start["reason"], code), ("failed", "handover-failed", 1))
                            self.assertIn("TASK-ref", (self.home / "state/handoff.md").read_text())
                            self.call("succeed")
                            self.wait()
                            recovered = json.loads(self.record.read_text())
                            self.assertNotEqual(recovered["pending"]["native_session_id"], previous["pending"]["native_session_id"])
                            self.assertIn("TASK-ref", Path(recovered["transfer"]["handoff"]).read_text())
                            self.call("stop")
                            self.wait("stopped", persisted_stop=True)


if __name__ == "__main__":
    with native_launcher() as native:
        session_test.HARNESS = native
        unittest.main(defaultTest=["SuccessionContract.test_succession_contract", "SuccessionContract.test_succession_identity", "SuccessionContract.test_succession_foreign_session", "SuccessionContract.test_succession_recovery"])
