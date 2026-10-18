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
    def setUp(self):
        super().setUp()
        self.skills = self.root / "installed/skills"
        for package in ("jarvis", "orch", "mailbox"):
            shutil.copytree(SKILLS / package / "scripts", self.skills / package / "scripts")
        # The dependency answers account readings. The production walk decides
        # which entry to try, its exclusion, and the resulting launch identity.
        lanes = self.skills / "orch/scripts/lanes"
        lanes.write_text('''#!/usr/bin/env python3
import json, sys
from pathlib import Path
args = sys.argv[1:]
config = Path(".lane-fixture.json")
if not config.exists():
    print("{}")
    sys.exit(5)
row = json.loads(config.read_text())
with Path(row["calls"]).open("a") as stream:
    stream.write(json.dumps(args) + "\\n")
harness = args[args.index("--harness") + 1]
floor = float(args[args.index("--min-headroom-pct") + 1])
if row.get("shared") and "--for-overseer" not in args:
    floor = max(floor, 50)
model_wall = harness == "claude" and "--binding-floor" in args
if ("--lane" in args and row["headroom"] <= floor) or harness != row["harness"] or model_wall:
    print('{"walled":1,"unmeasured":0}')
    sys.exit(3)
print(json.dumps({"config_dir": row["account"]}))
''')
        self.script_patch = patch.object(session_test, "SCRIPT", self.skills / "jarvis/scripts/jarvis-session")
        self.script_patch.start()
        self.addCleanup(self.script_patch.stop)

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

    def test_account_succession(self):
        for state, headroom, target in (("walled", 0, "claude"), ("walled", 0, "codex"), ("low", 4, "codex"),
                                        ("walled", 0, "copilot"), ("shared-reserve", 20, "claude"), ("app-missing", 0, "codex")):
            with self.subTest(state=state, target=target):
                self.call("start", mode="new")
                previous = self.wait()
                before = json.loads(self.record.read_text())
                native_count = len(self.started())
                contents = self.handoff()
                account = self.root / ("next-" + state + "-" + target)
                account.mkdir()
                calls = self.root / ("picks-" + state + "-" + target)
                (self.home / ".lane-fixture.json").write_text(json.dumps({"harness": target, "account": str(account), "calls": str(calls), "headroom": headroom,
                                                                          "shared": state == "shared-reserve"}))
                (self.home / "kendex.settings.toml").write_text('[env]\nORCH_OVERSEER_PREFERENCE = "claude:standard:high,codex:standard:high,copilot:standard:high"\n')
                # Model classification is kendex's external boundary. Preserve
                # native defaults for these class entries, as its protocol does.
                kendex = self.root / "bin/kendex"
                kendex.write_text('#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps({"protocol":"model-resolution-v1","request":{"tag":"class","class":"standard"},"resolution":{"diagnostics":[],"native_selector":"sonnet" if sys.argv[2] == "claude" else None}}))\n')
                kendex.chmod(0o755)
                if state == "app-missing":
                    missing = self.root / "bin" / target
                    missing.unlink()
                    # Keep native tooling, but remove every installed spelling
                    # of the selected harness from this request's PATH.
                    limited = self.root / "limited-bin"
                    limited.mkdir()
                    for folder in self.env["PATH"].split(os.pathsep):
                        if not Path(folder).is_dir():
                            continue
                        for tool in Path(folder).iterdir():
                            if tool.name != target and tool.is_file() and os.access(tool, os.X_OK) and not (limited / tool.name).exists():
                                (limited / tool.name).symlink_to(tool.resolve())
                    saved = self.record.read_bytes()
                    answer, code = self.call("succeed", env=self.env | {"PATH": str(limited)})
                    self.assertEqual((answer["state"], answer["reason"], code), ("blocked", "app-missing", 1))
                    self.assertEqual(self.record.read_bytes(), saved)
                    self.assertEqual(self.call("status")[0]["terminal"], previous["terminal"])
                    self.assertEqual(len(self.started()), native_count)
                    shutil.copyfile(session_test.HARNESS, missing)
                    missing.chmod(0o755)
                    self.call("stop")
                    self.wait("stopped", persisted_stop=True)
                    (self.home / ".lane-fixture.json").unlink()
                    continue
                self.call("succeed")
                current = self.wait()
                after = json.loads(self.record.read_text())
                kept = state == "shared-reserve"
                self.assertEqual((current["home"], current["harness"], current["account"]), (str(self.home), target, str(self.account if kept else account)))
                self.assertNotEqual(current["terminal"]["window"], previous["terminal"]["window"])
                self.assertEqual(Path(after["transfer"]["handoff"]).read_text(), contents)
                self.assertEqual((self.home / "state/handoff.md").read_text(), contents)
                queries = [json.loads(line) for line in calls.read_text().splitlines()]
                self.assertIn(str(self.account), queries[0])
                self.assertIn("--for-overseer", queries[0])
                for query in queries[1:]:
                    self.assertEqual(query[query.index("--exclude-lane") + 1], str(self.account))
                    if query[query.index("--harness") + 1] == "claude":
                        self.assertNotIn("--binding-floor", query)
                self.assertEqual(queries[-1][queries[-1].index("--harness") + 1], target)
                argv = self.started()[-1]["argv"]
                if not kept:
                    if target == "claude":
                        self.assertIn("--model", argv)
                        self.assertIn("--effort", argv)
                        self.assertEqual(argv[argv.index("--model") + 1], "sonnet")
                        self.assertEqual(argv[argv.index("--effort") + 1], "high")
                        self.assertFalse(any(word.startswith("--settings") for word in argv))
                    elif target == "codex":
                        self.assertIn("model_reasoning_effort=high", argv)
                        self.assertNotIn("-m", argv)
                        self.assertNotIn("--model", argv)
                        self.assertEqual(argv.count("--dangerously-bypass-hook-trust"), 1)
                        for setting in ("check_for_update_on_startup=false", "features.daemon_auto_start=false", "notice.hide_rate_limit_model_nudge=true",
                                        "model_auto_compact_token_limit=9223372036854775807", "model_auto_compact_token_limit_scope=body_after_prefix",
                                        "model_post_turn_compact_threshold_percent=0"):
                            self.assertEqual(argv.count(setting), 1)
                    elif target == "copilot":
                        self.assertIn("--reasoning-effort", argv)
                        self.assertEqual(argv[argv.index("--reasoning-effort") + 1], "high")
                        self.assertNotIn("--model", argv)
                        self.assertTrue(set(argv).isdisjoint({"--autopilot", "--max-autopilot-continues", "--context", "--no-auto-update"}))
                else:
                    self.assertEqual(len(queries), 1)
                self.assertEqual(after["transfer"]["phase"], "complete")
                self.assertNotEqual(after["pending"]["native_session_id"], before["pending"]["native_session_id"])
                self.call("stop")
                self.wait("stopped", persisted_stop=True)
                (self.home / ".lane-fixture.json").unlink()

    def test_missing_orch_keeps_predecessor(self):
        self.call("start")
        self.wait()
        before = self.record.read_bytes()
        predecessor = json.loads(before)
        self.handoff()
        orch = self.skills / "orch"
        moved = self.skills / "orch-absent"
        orch.rename(moved)
        try:
            answer, code = self.call("succeed")
            self.assertEqual((answer["state"], answer["reason"], code), ("failed", "handover-failed", 1))
            self.assertEqual(answer["account"], str(self.account))
            self.assertEqual(self.record.read_bytes(), before)
            pid = predecessor["process"]
            result = subprocess.run([self.env["JARVIS_TEST_BASH"], str(SKILLS / "jarvis/scripts/lib/session-backend.sh"),
                                     "worker-live", str(pid["pid"]), pid["started_at"]],
                                    capture_output=True, env=self.env, timeout=10)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(self.started()), 1)
        finally:
            moved.rename(orch)

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
            shutil.copytree(self.skills / package / "scripts", skills / package / "scripts")
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
        unittest.main(defaultTest=["SuccessionContract.test_succession_contract", "SuccessionContract.test_succession_identity", "SuccessionContract.test_succession_foreign_session", "SuccessionContract.test_succession_recovery", "SuccessionContract.test_account_succession", "SuccessionContract.test_missing_orch_keeps_predecessor"])
