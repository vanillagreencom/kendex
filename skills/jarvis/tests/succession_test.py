"""Succession uses real tmux and native identity hooks with deterministic CLI fixtures."""
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import time
import unittest
from unittest.mock import patch
import session_test
from session_test import ANY_PERMISSION_WORD, PERMISSION_WORDS, SessionContract, SKILLS
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
if "--lane" in args and "read_rc" in row:
    print(json.dumps({"config_dir": row["account"]}) if row["read_rc"] == 0 else "{}")
    sys.exit(row["read_rc"])
# A failing dependency answers every walk pick with an error exit.
if row["harness"] == "fail" and "--lane" not in args:
    print("lanes: usage fetch failed", file=sys.stderr)
    sys.exit(2)
floor = float(args[args.index("--min-headroom-pct") + 1])
if row.get("shared") and "--for-overseer" not in args:
    floor = max(floor, 50)
model_wall = harness == "claude" and "--binding-floor" in args
# The recorded account's own reading judges its headroom alone; a walk's pick
# finds an account only on the fixture's harness.
walled = row["headroom"] <= floor if "--lane" in args else harness != row["harness"] or model_wall
if walled:
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
        # Every harness is named unattended, so each successor launch line
        # carries its own harness's permission words. A briefed row removes
        # the consumer's brief file once Start runs; an unbriefed row starts
        # without one on a home whose last Start had one.
        (self.home / "kendex.settings.toml").write_text('[env]\nJARVIS_UNATTENDED_HARNESSES = "claude,codex,copilot,pi"\n')
        for harness, briefed in (("claude", True), ("codex", False), ("copilot", True), ("pi", False)):
            with self.subTest(harness=harness):
                brief, start_brief, private = self.private_brief()
                self.call("start", harness=harness, mode="new", brief=brief if briefed else None)
                self.wait()
                brief.unlink()
                predecessor = json.loads(self.record.read_text())
                self.assertIsInstance(predecessor.get("report_started_at"), int)
                predecessor["report_started_at"] = 1000
                self.record.write_text(json.dumps(predecessor))
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
                self.assertEqual(successor["report_started_at"], predecessor["report_started_at"])
                self.assertEqual(Path(successor["transfer"]["handoff"]).read_text(), contents)
                self.assertEqual((self.home / "state/handoff.md").read_text(), contents)
                self.assertEqual(len(self.started()), native_count + 1)
                self.assertEqual(set(self.started()[-1]["argv"]) & ANY_PERMISSION_WORD, PERMISSION_WORDS[harness])
                expected = private if briefed else start_brief
                self.assertEqual(self.prompts(successor["pending"]["native_session_id"]), [expected])
                self.handoff()
                self.call("succeed")
                self.wait()
                second = json.loads(self.record.read_text())
                self.assertEqual(self.prompts(second["pending"]["native_session_id"]), [expected])
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
        # The preference walks claude, codex, then copilot, and the recorded
        # account comes last: kept as it is when it has room, and otherwise
        # replaced by another account of its harness, or none, which refuses
        # before the predecessor ends. target is the one harness with an
        # account the walk can pick; none names no such harness, and fail a
        # walk whose every reading fails, which refuses even an account with
        # room since the walk stops at its first entry unjudged. A Copilot
        # account whose owner turned extensions off stays untouched when it is
        # kept, since its session already runs there. The recorded account has
        # room above the trigger, 5%, and below the work-item reserve, 50%,
        # that an overseer reading does not take. unattended is the home's
        # setting: a successor carries its own harness's permission words only
        # when the setting names it, and every successor Start's brief file.
        brief, _, private = self.private_brief()
        for state, start, headroom, target, unattended in (
                ("walled", "claude", 0, "claude", ""), ("walled", "claude", 0, "codex", "codex"),
                ("low", "claude", 4, "codex", "claude"), ("walled", "claude", 0, "copilot", "copilot"),
                ("room-first-entry", "codex", 20, "claude", ""), ("room-no-entry", "claude", 20, "none", ""),
                ("room-no-entry", "copilot", 20, "none", ""), ("walled-no-entry", "claude", 0, "none", ""),
                ("pick-fails", "claude", 20, "fail", ""), ("app-missing", "claude", 0, "codex", "")):
            with self.subTest(state=state, start=start, target=target):
                self.call("start", harness=start, mode="new", brief=brief)
                previous = self.wait()
                before = json.loads(self.record.read_text())
                native_count = len(self.started())
                predecessor_argv = self.started()[-1]["argv"]
                contents = self.handoff()
                account = self.root / ("next-" + state + "-" + start + "-" + target)
                account.mkdir()
                calls = self.root / ("picks-" + state + "-" + start + "-" + target)
                (self.home / ".lane-fixture.json").write_text(json.dumps({"harness": target, "account": str(account), "calls": str(calls), "headroom": headroom,
                                                                          "shared": True}))
                (self.home / "kendex.settings.toml").write_text('[env]\nORCH_OVERSEER_PREFERENCE = "claude:standard:high,codex:standard:high,copilot:standard:high"\n'
                                                                'JARVIS_UNATTENDED_HARNESSES = "' + unattended + '"\n')
                self.model_classes()
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
                kept = target == "none"
                refused = headroom <= 5
                order = ["claude", "codex", "copilot"]
                settings = self.account / "settings.json"
                if start == "copilot":
                    settings.write_text('{"enabledFeatureFlags":{"EXTENSIONS":false}}\n')
                failed = target == "fail"
                if kept and refused or failed:
                    saved = self.record.read_bytes()
                    answer, code = self.call("succeed")
                    self.assertEqual((answer["state"], code), ("failed", 1))
                    self.assertEqual(self.record.read_bytes(), saved)
                    self.assertEqual(self.call("status")[0]["terminal"], previous["terminal"])
                    self.assertEqual(len(self.started()), native_count)
                    queries = [json.loads(line) for line in calls.read_text().splitlines()]
                    walked = [query[query.index("--harness") + 1] for query in queries[1:]]
                    if failed:
                        # The first failed reading stops the walk.
                        self.assertEqual(walked, order[:1])
                    else:
                        # The caller entry's own pick leaves the spent account out.
                        self.assertEqual(walked, order + [start])
                        self.assertEqual(queries[-1][queries[-1].index("--exclude-lane") + 1], str(self.account))
                    self.call("stop")
                    self.wait("stopped", persisted_stop=True)
                    (self.home / ".lane-fixture.json").unlink()
                    continue
                self.call("succeed")
                current = self.wait()
                after = json.loads(self.record.read_text())
                if start == "copilot":
                    self.assertEqual(settings.read_text(), '{"enabledFeatureFlags":{"EXTENSIONS":false}}\n')
                    self.assertFalse((self.account / "extensions").exists())
                    settings.unlink()
                self.assertEqual((current["home"], current["harness"], current["account"]),
                                 (str(self.home), start if kept else target, str(self.account if kept else account)))
                self.assertNotEqual(current["terminal"]["window"], previous["terminal"]["window"])
                self.assertEqual(Path(after["transfer"]["handoff"]).read_text(), contents)
                self.assertEqual((self.home / "state/handoff.md").read_text(), contents)
                queries = [json.loads(line) for line in calls.read_text().splitlines()]
                self.assertIn(str(self.account), queries[0])
                self.assertIn("--for-overseer", queries[0])
                # Every named entry is asked, in order, until one qualifies.
                walked = [query[query.index("--harness") + 1] for query in queries[1:]]
                self.assertEqual(walked, order if kept else order[:order.index(target) + 1])
                for query in queries[1:]:
                    self.assertEqual("--exclude-lane" in query and query[query.index("--exclude-lane") + 1], str(self.account) if refused else False)
                    if query[query.index("--harness") + 1] == "claude":
                        self.assertNotIn("--binding-floor", query)
                argv = self.started()[-1]["argv"]
                self.assertEqual(set(argv) & ANY_PERMISSION_WORD, PERMISSION_WORDS[target] if unattended == target else set())
                if kept:
                    self.assertEqual([word for word in argv if word in ("--model", "--effort", "-m")], [])
                else:
                    if target == "claude":
                        self.assertIn("--model", argv)
                        self.assertIn("--effort", argv)
                        self.assertEqual(argv[argv.index("--model") + 1], "sonnet")
                        self.assertEqual(argv[argv.index("--effort") + 1], "high")
                        if start == "claude":
                            self.assertEqual([word for word in argv if word.startswith("--settings")],
                                             [word for word in predecessor_argv if word.startswith("--settings")])
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
                self.assertEqual(after["transfer"]["phase"], "complete")
                self.assertNotEqual(after["pending"]["native_session_id"], before["pending"]["native_session_id"])
                self.assertEqual(self.prompts(after["pending"]["native_session_id"]), [private])
                self.call("stop")
                self.wait("stopped", persisted_stop=True)
                (self.home / ".lane-fixture.json").unlink()

    def test_started_choice_survives_succession(self):
        # No account reading and no preference keep the recorded account, and
        # with it the model and effort Start stated.
        self.model_classes()
        self.handoff()
        self.call("start", mode="new", model="standard", effort="low")
        self.wait()
        started = json.loads(self.record.read_text())["choice"]
        self.assertEqual(started, {"harness": "claude", "account": str(self.account), "model": "sonnet", "effort": "low"})
        self.call("succeed")
        self.wait()
        self.assertEqual(json.loads(self.record.read_text())["choice"], started)
        argv = self.started()[-1]["argv"]
        self.assertEqual((argv[argv.index("--model") + 1], argv[argv.index("--effort") + 1]), ("sonnet", "low"))

    def test_known_wall_selection(self):
        # A separately established wall overrides room and both unavailable
        # reading categories. An inventory returning A or its private launch
        # home still reaches the native identity backstop.
        self.model_classes()
        brief, _, private = self.private_brief()
        alternative = self.root / "alternative"
        alternative.mkdir()
        alias = self.account / "lane-launch/fixture/home"
        alias.mkdir(parents=True)
        for reading, target, picked, succeeds in (
                (0, "none", alternative, False),
                (0, "codex", alternative, True), (4, "codex", alternative, True),
                (5, "codex", alternative, True), (0, "claude", self.account, False),
                (0, "codex", alias, False),
                (2, "codex", alternative, False)):
            with self.subTest(reading=reading, target=target, picked=picked):
                self.call("start", mode="new", brief=brief)
                previous = self.wait()
                contents = self.handoff()
                saved = self.record.read_bytes()
                count = len(self.started())
                calls = self.root / "wall-picks"
                calls.unlink(missing_ok=True)
                (self.home / ".lane-fixture.json").write_text(json.dumps({
                    "harness": target, "account": str(picked), "calls": str(calls), "headroom": 20, "read_rc": reading}))
                (self.home / "kendex.settings.toml").write_text('[env]\nORCH_OVERSEER_PREFERENCE = "codex:standard:high,claude:standard:high"\n')
                answer, code = self.call("succeed", account_walled=True)
                self.assertEqual(code, 0 if succeeds else 1, self.stderr)
                queries = [json.loads(line) for line in calls.read_text().splitlines()]
                for query in queries[1:]:
                    self.assertIn("--exclude-lane", query)
                    self.assertEqual(query[query.index("--exclude-lane") + 1], str(self.account))
                if succeeds:
                    current = self.wait()
                    after = json.loads(self.record.read_text())
                    self.assertEqual((current["home"], current["account"], current["harness"]),
                                     (str(self.home), str(alternative), "codex"))
                    self.assertTrue(after["identity_verified"])
                    self.assertEqual(after["transfer"]["spent_account"], str(self.account))
                    self.assertNotIn("spent_account", after["choice"])
                    self.assertEqual(Path(after["transfer"]["handoff"]).read_text(), contents)
                    self.assertEqual(self.prompts(after["pending"]["native_session_id"]), [private])
                    self.assertEqual(len(self.started()), count + 1)
                    # Completed A-to-B exclusion expires. Ordinary B keeps its
                    # choice, and a new explicit wall binds B rather than A.
                    if reading == 0:
                        (self.home / "kendex.settings.toml").write_text('[env]\nORCH_OVERSEER_PREFERENCE = ""\n')
                        self.call("succeed")
                        self.wait()
                        ordinary = json.loads(self.record.read_text())
                        self.assertEqual(ordinary["choice"], after["choice"])
                        self.assertNotIn("spent_account", ordinary["transfer"])
                        calls.write_text("")
                        original = self.record.read_bytes()
                        self.assertEqual(self.call("succeed", account_walled=True)[1], 1)
                        self.assertEqual(self.record.read_bytes(), original)
                        fresh = [json.loads(line) for line in calls.read_text().splitlines()]
                        self.assertEqual(fresh[-1][fresh[-1].index("--exclude-lane") + 1], str(alternative))
                else:
                    self.assertEqual(self.record.read_bytes(), saved)
                    self.assertEqual(self.call("status")[0]["terminal"], previous["terminal"])
                    self.assertEqual(len(self.started()), count)
                self.call("stop")
                self.wait("stopped", persisted_stop=True)
                (self.home / ".lane-fixture.json").unlink()

    def test_pi_known_wall_selection(self):
        self.model_classes()
        alternative = self.root / "alternative"
        alternative.mkdir()
        for model in (None, "openai/gpt-5.5"):
            for eligible in (True, False):
                with self.subTest(model=model, eligible=eligible):
                    choice = {"model": model, "effort": "high"} if model else {}
                    self.call("start", harness="pi", mode="new", **choice)
                    self.wait()
                    self.handoff()
                    (self.home / "kendex.settings.toml").write_text('[env]\nORCH_OVERSEER_PREFERENCE = ""\n')
                    self.call("succeed")
                    self.assertEqual(self.wait()["account"], str(self.account))
                    original = self.record.read_bytes()
                    count = len(self.started())
                    calls = self.root / "pi-wall-picks"
                    calls.unlink(missing_ok=True)
                    (self.home / ".lane-fixture.json").write_text(json.dumps({
                        "harness": "pi" if eligible else "none", "account": str(alternative),
                        "calls": str(calls), "headroom": 20}))
                    (self.home / "kendex.settings.toml").write_text('[env]\nORCH_OVERSEER_PREFERENCE = "pi:github-copilot/gpt-5.5:high,pi:openai/gpt-5.5:high"\n')
                    self.assertEqual(self.call("succeed", account_walled=True)[1], 0 if eligible else 1, self.stderr)
                    if eligible:
                        current = self.wait()
                        self.assertEqual((current["harness"], current["account"]), ("pi", str(alternative)))
                    else:
                        self.assertEqual(self.record.read_bytes(), original)
                        self.assertEqual(len(self.started()), count)
                    queries = [json.loads(line) for line in calls.read_text().splitlines()]
                    self.assertTrue(queries)
                    for query in queries:
                        self.assertEqual(query[query.index("--exclude-lane") + 1], str(self.account))
                    self.call("stop")
                    self.wait("stopped", persisted_stop=True)
                    (self.home / ".lane-fixture.json").unlink()

    def test_known_wall_retry(self):
        self.model_classes()
        skills = self.instrumented()
        script = skills / "jarvis/scripts/jarvis-session"
        pause = self.home / ".succession-pause.json"
        alternative = self.root / "alternative"
        alternative.mkdir()
        brief, _, private = self.private_brief()
        with patch.object(session_test, "SCRIPT", script):
            for phase, repeated, worker_failure in (("saved", False, ""), ("predecessor-ended", True, ""),
                                                     ("waiting", True, "identity"), ("saved", False, "trust")):
                with self.subTest(phase=phase, repeated=repeated, worker_failure=worker_failure):
                    self.call("start", mode="new", brief=brief)
                    previous = self.wait()
                    original = json.loads(self.record.read_text())
                    owned_identity = dict(original["process"])
                    if worker_failure == "identity":
                        # A stale recorded start refuses before signalling A.
                        original["process"]["started_at"] = "a different start time"
                        self.record.write_text(json.dumps(original))
                    self.handoff()
                    calls = self.root / "retry-picks"
                    calls.write_text("")
                    target = "claude" if worker_failure == "trust" else "codex"
                    trust = alternative / ".claude.json"
                    if worker_failure == "trust":
                        trust.write_text(json.dumps({"projects": {str(self.home): {"hasTrustDialogAccepted": False}}}))
                    fixture = {"harness": target, "account": str(alternative), "calls": str(calls), "headroom": 20, "read_rc": 0}
                    (self.home / ".lane-fixture.json").write_text(json.dumps(fixture))
                    (self.home / "kendex.settings.toml").write_text('[env]\nORCH_OVERSEER_PREFERENCE = "' + target + ':standard:high"\n')
                    identity, request = self.paused([str(script), "succeed", "--home", str(self.home), "--account-walled"],
                                                    pause, phase, "after", self.env)
                    with request:
                        transfer = json.loads(self.record.read_text())
                        self.assertEqual((transfer["account"], transfer["transfer"]["spent_account"]),
                                         (str(alternative), str(self.account)))
                        if worker_failure:
                            (self.root / "release").touch()
                            request.communicate(timeout=10)
                        else:
                            os.kill(identity["pid"], signal.SIGKILL)
                            request.communicate(timeout=10)
                    pause.unlink()
                    if worker_failure:
                        retained = self.await_worker_result()
                        self.assertEqual(retained["transfer"]["spent_account"], str(self.account))
                        self.assertEqual((retained["state"], retained["account"], retained["terminal"]),
                                         ("running", str(self.account), previous["terminal"]))
                        self.assertEqual(self.call("status")[0]["terminal"], previous["terminal"])
                        self.assertTrue(self.process_live(owned_identity))
                        retained["process"] = owned_identity
                        self.record.write_text(json.dumps(retained))
                        (self.root / "release").unlink()
                        # These shipped consumers read the persisted owner,
                        # rather than status's view of a live predecessor.
                        native = subprocess.run([self.env["JARVIS_TEST_BASH"], "-c",
                            'source "$1"; session_rows_jarvis_identity "$2" "$3" "$4" "$5"', "identity",
                            str(skills / "orch/scripts/lib/session-rows.sh"), str(self.home), original["harness"],
                            original["pending"]["native_session_id"], previous["terminal"]["pane"]],
                            env=self.env | {"JARVIS_RECORD": str(self.record),
                                "JARVIS_GENERATION": str(original["pending"]["generation"]),
                                "TMUX": previous["terminal"]["server"] + ",0,0"},
                            capture_output=True, text=True, timeout=15)
                        self.assertEqual(native.returncode, 0, native.stderr)
                        self.assertEqual(json.loads(native.stdout)["state"], "running")
                        task_file = self.home / "task.md"
                        task_file.write_text("Inspect the handoff.\n")
                        # The session CLI fixture requires a controller hook;
                        # a task's native CLI has no controller identity.
                        task_bin = self.root / "task-bin"
                        task_bin.mkdir(exist_ok=True)
                        task_cli = task_bin / "codex"
                        task_cli.write_text("#!/usr/bin/env python3\nimport signal\nwhile True: signal.pause()\n")
                        task_cli.chmod(0o755)
                        task = subprocess.run([str(skills / "jarvis/scripts/task"), "launch", "--home", str(self.home),
                            "--name", "Refusal recovery", "--harness", "codex", "--model", "standard",
                            "--account", str(alternative), "--task-file", str(task_file),
                            "--result-file", str(self.home / "task-result.md")],
                            env=self.env | {"PATH": str(task_bin) + os.pathsep + self.env["PATH"]},
                            capture_output=True, text=True, timeout=60)
                        self.assertEqual(task.returncode, 0, task.stderr)
                        launched = json.loads(task.stdout)
                        self.assertEqual((launched["state"], launched["terminal"]["server"]),
                                         ("running", previous["terminal"]["server"]))
                        for verb, arguments in (("complete", ["--outcome", "failed"]), ("cleanup", [])):
                            closed = subprocess.run([str(skills / "jarvis/scripts/task"), verb, "--home", str(self.home),
                                "--id", launched["id"], *arguments], env=self.env, capture_output=True, text=True, timeout=60)
                            self.assertEqual(closed.returncode, 0, closed.stderr)
                        if worker_failure == "trust":
                            self.assertEqual(retained["transfer"]["phase"], "saved")
                            trust.unlink()
                    elif phase == "predecessor-ended":
                        self.wait("failed", "handover-failed")
                        self.successor_ended()
                    else:
                        self.wait("running")
                    # B's own reader now reports walled: retained A still owns
                    # the exclusion, and a qualifying B must remain eligible.
                    fixture["read_rc"] = 3
                    (self.home / ".lane-fixture.json").write_text(json.dumps(fixture))
                    calls.write_text("")
                    self.assertEqual(self.call("succeed", account_walled=repeated)[1], 0, self.stderr)
                    self.assertEqual(self.wait()["account"], str(alternative))
                    recovered = json.loads(self.record.read_text())
                    self.assertEqual(recovered["transfer"]["spent_account"], str(self.account))
                    if worker_failure:
                        self.assertEqual(recovered["transfer"]["previous_handoff"], retained["transfer"]["handoff"])
                    self.assertEqual(self.prompts(recovered["pending"]["native_session_id"]), [private])
                    queries = [json.loads(line) for line in calls.read_text().splitlines()]
                    for query in queries[1:]:
                        self.assertEqual(query[query.index("--exclude-lane") + 1], str(self.account))
                    self.call("stop")
                    self.wait("stopped", persisted_stop=True)
                    (self.home / ".lane-fixture.json").unlink()

    def test_pi_successor_skips_unlaunchable_entry(self):
        # A pi-claude/ entry's pick names a Claude account, which a Jarvis pi
        # session cannot run on, so the walk passes it by although that
        # account has room, and the recorded pi account stays.
        self.handoff()
        model = "github-copilot/gpt-5.5"
        self.call("start", harness="pi", mode="new", model=model, effort="high")
        self.wait()
        claude = self.root / "claude-account"
        claude.mkdir()
        calls = self.root / "picks"
        (self.home / ".lane-fixture.json").write_text(json.dumps({"harness": "claude", "account": str(claude), "calls": str(calls), "headroom": 20}))
        (self.home / "kendex.settings.toml").write_text('[env]\nORCH_OVERSEER_PREFERENCE = "pi:pi-claude/claude-sonnet-4-5:high"\n')
        self.call("succeed")
        current = self.wait()
        self.assertEqual((current["harness"], current["account"]), ("pi", str(self.account)))
        self.assertEqual(json.loads(self.record.read_text())["choice"]["model"], model)
        self.assertEqual([json.loads(line)[json.loads(line).index("--harness") + 1] for line in calls.read_text().splitlines()], ["pi"])

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

    def launched(self):
        # Native launches so far; the fixture creates its row file at the first.
        return len(self.started()) if self.rows.exists() else 0

    def unmanaged(self, harness, bridge=False):
        # A Jarvis session started outside the package: the native fixture
        # binary under the consumer's shell, on the consumer's own tmux
        # server. The shell keeps the pane open after the harness ends. A
        # harness of None leaves the shell alone in its pane. A bridge runs a
        # process named codex below the harness, as pi-codex-bridge runs
        # `codex app-server` below pi. The consumer's other shells, one beside
        # the pane and one in another window, are no part of the session.
        self.consumers = getattr(self, "consumers", 0) + 1
        folder = self.root / ("unmanaged-" + str(self.consumers))
        folder.mkdir()
        script = "import sys\nsys.stdin.read()\n"
        if bridge:
            shutil.copyfile(shutil.which("sleep"), folder / "codex")
            (folder / "codex").chmod(0o755)
            # Hangup and terminate end the bridge child with its parent.
            script = ("import signal, subprocess, sys\n"
                      "child = subprocess.Popen([" + repr(str(folder / "codex")) + ", '120'], stdin=subprocess.DEVNULL)\n"
                      "for number in (signal.SIGHUP, signal.SIGTERM):\n"
                      "    signal.signal(number, lambda *_: sys.exit(0))\n"
                      "try:\n    sys.stdin.read()\nfinally:\n    child.terminate()\n    child.wait()\n")
        (folder / ".fixture-harness.py").write_text(script)
        command = ":"
        if harness:
            shutil.copyfile(session_test.HARNESS, folder / harness)
            (folder / harness).chmod(0o755)
            command = "./" + harness
        label = "consumer-" + self.label[-12:] + "-" + str(self.consumers)
        self.addCleanup(subprocess.run, ["tmux", "-L", label, "kill-server"], capture_output=True, env=self.env)
        created = subprocess.run(["tmux", "-L", label, "-f", os.devnull, "new-session", "-d", "-s", "consumer", "-c", str(folder),
                                  "-P", "-F", "#{socket_path}\t#{pid}\t#{pane_id}\t#{pane_pid}",
                                  self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc", "-c", command + "; read -r _"],
                                 capture_output=True, text=True, env=self.env, timeout=10, check=True)
        socket, server, pane, pid = created.stdout.strip().split("\t")
        shell = [self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc"]
        siblings = [subprocess.run(["tmux", "-L", label, *opening, "-d", "-P", "-F", "#{pane_id}", *shell],
                                   capture_output=True, text=True, env=self.env, timeout=10, check=True).stdout.strip()
                    for opening in (["split-window", "-t", pane], ["new-window", "-t", "=consumer"])]
        consumer = {"label": label, "socket": socket, "pane": pane, "siblings": siblings,
                    "env": self.env | {"TMUX": socket + "," + server + ",0"}, "process": self.identity(pid), "harness": None}
        deadline = time.monotonic() + 10
        while harness and consumer["harness"] is None:
            self.assertLess(time.monotonic(), deadline, "the unmanaged harness did not start")
            table = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "comm="], capture_output=True, text=True, check=True).stdout
            for row in table.splitlines():
                child, parent, name = row.split(None, 2)
                if parent == pid and Path(name).name == harness:
                    consumer["harness"] = self.identity(child)
            time.sleep(0.05)
        return consumer

    def identity(self, pid):
        result = subprocess.run([self.env["JARVIS_TEST_BASH"], str(SKILLS / "jarvis/scripts/lib/session-backend.sh"), "process", str(pid)],
                                capture_output=True, text=True, env=self.env, timeout=10, check=True)
        return json.loads(result.stdout)

    def consumer_panes(self, consumer):
        result = subprocess.run(["tmux", "-L", consumer["label"], "list-panes", "-a", "-F", "#{pane_id}"],
                                capture_output=True, text=True, env=self.env, timeout=10)
        return result.stdout.split() if result.returncode == 0 else []

    def adopt(self, consumer, harness="claude", pid=None, brief=None):
        return self.call("start", harness=harness, mode="new", env=consumer["env"], brief=brief,
                         adopt=(consumer["pane"], pid or consumer["process"]["pid"]))

    def adoption_ended(self, consumer):
        # One controller remains: the unmanaged harness, its shell and its
        # pane ended, and the consumer's other shells left as they were.
        self.assertFalse(self.process_live(consumer["harness"]))
        self.assertFalse(self.process_live(consumer["process"]))
        panes = self.consumer_panes(consumer)
        self.assertNotIn(consumer["pane"], panes)
        for sibling in consumer["siblings"]:
            self.assertIn(sibling, panes)

    def private_brief(self):
        path = self.root / "private-brief.txt"
        path.write_text("Consumer private line.\n")
        with patch.dict(os.environ, {"JARVIS_BASH": self.env["JARVIS_TEST_BASH"]}):
            start_brief = runpy.run_path(str(SKILLS / "jarvis/scripts/lib/session.py"))["START_BRIEF"]
        return path, start_brief, start_brief + " Consumer private line."

    def prompts(self, native_id):
        rows = [json.loads(line) for line in self.rows.read_text().splitlines()]
        return [row["prompt"] for row in rows if "prompt" in row and row["id"] == native_id]

    def test_adoption_contract(self):
        # The unmanaged session's harness is detected at the call; Start's own
        # arguments choose the successor, which launches in the home's
        # session. Each row's Start names another harness than the adopted.
        brief, start_brief, private = self.private_brief()
        rows = (
            # unmanaged, bridge child, Start's harness, brief file, task window left in jarvis
            ("claude", False, "codex", False, False),
            ("codex", False, "copilot", True, False),
            ("copilot", False, "pi", False, True),
            ("pi", False, "claude", False, False),
            ("pi", True, "codex", False, False),
        )
        for harness, bridge, successor, briefed, task in rows:
            with self.subTest(harness=harness, bridge=bridge, successor=successor):
                contents = self.handoff()
                consumer = self.unmanaged(harness, bridge)
                if task:
                    # A task window task.py left, remain-on-exit, after a
                    # managed controller ended on its own.
                    left = subprocess.run(["tmux", "-L", self.label, "-f", os.devnull, "new-session", "-d", "-s", "jarvis",
                                           "-P", "-F", "#{pane_id}", self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc"],
                                          capture_output=True, text=True, env=self.env, timeout=10, check=True).stdout.strip()
                    subprocess.run(["tmux", "-L", self.label, "set-option", "-p", "-t", left, "@jarvis-task", "task-1"],
                                   capture_output=True, env=self.env, timeout=10, check=True)
                native_count = self.launched()
                answer, code = self.adopt(consumer, successor, brief=brief if briefed else None)
                self.assertEqual(code, 0)
                # Start answers from the predecessor, whose harness is the
                # one detected at the call and the one its stop is keyed to.
                self.assertEqual((answer["state"], answer["harness"]), ("handing-over", harness))
                current = self.wait()
                record = json.loads(self.record.read_text())
                self.assertEqual((current["home"], current["harness"], current["account"]), (str(self.home), successor, str(self.account)))
                self.assertEqual(current["terminal"]["session"], "jarvis")
                self.assertNotEqual(current["terminal"]["server"], consumer["socket"])
                self.assertEqual(record["transfer"]["phase"], "complete")
                self.assertEqual(Path(record["transfer"]["handoff"]).read_text(), contents)
                self.assertTrue(record["identity_verified"])
                self.assertEqual(self.launched(), native_count + 1)
                self.assertEqual(self.started()[-1]["harness"], successor)
                self.assertEqual(self.prompts(record["pending"]["native_session_id"]), [private if briefed else start_brief])
                self.adoption_ended(consumer)
                self.call("stop")
                self.wait("stopped", persisted_stop=True)

    def test_adoption_refusals(self):
        # Each refusal precedes any save or stop: the record, the handoff
        # archive and the unmanaged session stay as they were.
        self.handoff()
        # The keyed cause each selection refusal names; the others are Start's own.
        causes = {"other-pid": "pid-mismatch", "no-harness": "no-harness", "missing-pane": "pane-missing"}
        for row in ("other-pid", "no-harness", "missing-pane", "running", "starting"):
            with self.subTest(row=row):
                consumer = self.unmanaged(None if row == "no-harness" else "claude")
                pid = worker = None
                named = consumer
                if row == "missing-pane":
                    # A pane id the consumer's server does not hold.
                    named = dict(consumer, pane="%" + str(10 ** 6))
                    self.assertNotIn(named["pane"], self.consumer_panes(consumer))
                elif row == "other-pid":
                    # A live harness session, but not the named pane's.
                    pid = self.unmanaged("claude")["process"]["pid"]
                elif row == "running":
                    self.call("start", mode="new")
                    self.wait()
                elif row == "starting":
                    # A Start whose worker has not yet recorded its pane:
                    # only that live worker answers for the controller.
                    worker = subprocess.Popen(["sleep", "60"])
                    self.addCleanup(worker.wait)
                    self.addCleanup(worker.kill)
                    self.record.parent.mkdir(parents=True, exist_ok=True)
                    self.record.write_text(json.dumps({
                        "v": 1, "home": str(self.home), "harness": "claude", "account": str(self.account), "origin": "manual",
                        "boot": None, "generation": 1, "intent": "start", "state": "starting", "reason": "launching", "detail": "",
                        "terminal": None, "worker": self.identity(worker.pid)}))
                    self.assertEqual(self.call("status")[0]["state"], "starting")
                saved = self.record.read_bytes() if self.record.exists() else None
                native_count = self.launched()
                answer, code = self.adopt(named, pid=pid)
                expected = "selection-conflict" if row in causes else "name-conflict"
                self.assertEqual((answer["state"], answer["reason"], code), ("blocked", expected, 1))
                if row in causes:
                    # The keyed refusal line operators read names the binding.
                    self.assertIn("jarvis-session: adopt=refused cause=" + causes[row] + " ", self.stderr)
                self.assertEqual(self.record.read_bytes() if self.record.exists() else None, saved)
                self.assertFalse((self.home / "state/archive").exists())
                self.assertEqual(self.launched(), native_count)
                self.assertTrue(self.process_live(consumer["process"]))
                if consumer["harness"]:
                    self.assertTrue(self.process_live(consumer["harness"]))
                self.assertIn(consumer["pane"], self.consumer_panes(consumer))
                if row in ("running", "starting"):
                    self.call("stop")
                    self.wait("stopped", persisted_stop=True)

    def test_adoption_recovery(self):
        # Before the unmanaged process ends, an interruption leaves it the
        # only controller; after its end, the transfer fails and succeed
        # completes it. The transition writes are succession's, one code path
        # for every harness, so one launch shape reaches each. A retry after a
        # refusal before the end follows the consumer's pane when the consumer
        # moves it, and a retry after the end keeps the brief Start named.
        brief, _, private = self.private_brief()
        skills = self.instrumented()
        script = skills / "jarvis/scripts/jarvis-session"
        pause = self.home / ".succession-pause.json"
        phases = ("saved", "waiting", "predecessor-ended", "confirmed", "brief-delivered", "complete")
        with patch.object(session_test, "SCRIPT", script):
            for phase in phases:
                for edge in ("before", "after"):
                    with self.subTest(phase=phase, edge=edge):
                        print("adoption-row: phase=" + phase + " edge=" + edge, flush=True)
                        contents = self.handoff()
                        consumer = self.unmanaged("claude")
                        native_count = self.launched()
                        argv = [str(script), "start", "--home", str(self.home), "--harness", "claude", "--account", str(self.account),
                                "--mode", "new", "--origin", "manual", "--adopt-pane", consumer["pane"], "--adopt-pid", str(consumer["process"]["pid"])]
                        briefed = (phase, edge) == ("predecessor-ended", "after")
                        if briefed:
                            argv += ["--brief-file", str(brief)]
                        identity, request = self.paused(argv, pause, phase, edge, consumer["env"])
                        with request:
                            persisted = json.loads(self.record.read_text()) if self.record.exists() else None
                            during, _ = self.call("status")
                            unrecorded = (phase, edge) == ("saved", "before")
                            completed = (phase, edge) == ("complete", "after")
                            before_end = phase in ("saved", "waiting")
                            self.assertEqual(during["state"], "stopped" if unrecorded else "running" if completed else "handing-over")
                            self.assertEqual(self.process_live(consumer["harness"]), before_end)
                            self.assertEqual(self.launched() - native_count,
                                             1 if phase in ("confirmed", "brief-delivered", "complete") else 0)
                            self.assertTrue(self.process_live(identity))
                            os.kill(identity["pid"], signal.SIGKILL)
                            request.communicate(timeout=10)
                        pause.unlink()
                        if unrecorded:
                            self.assertEqual(self.call("status")[0]["state"], "stopped")
                            self.assertTrue(self.process_live(consumer["harness"]))
                            answer, code = self.adopt(consumer)
                            self.assertEqual(code, 0, json.dumps(answer) + "\n" + self.stderr + "\n" + self.session_log())
                        elif before_end:
                            settled = self.wait("running")
                            self.assertEqual(settled["terminal"]["pane"], consumer["pane"])
                            self.assertTrue(self.process_live(consumer["harness"]))
                            self.successor_ended()
                            if edge == "after":
                                # A move keeps the pane and its process but gives it another window.
                                subprocess.run(["tmux", "-L", consumer["label"], "break-pane", "-d", "-s", consumer["pane"]],
                                               capture_output=True, env=self.env, timeout=10, check=True)
                                self.assertEqual((self.call("status")[0]["terminal"] or {}).get("pane"), consumer["pane"])
                            self.retry()
                        elif completed:
                            self.assertEqual(self.wait("running")["terminal"], persisted["terminal"])
                        else:
                            settled = self.wait("failed", "handover-failed")
                            self.assertTrue(settled["detail"])
                            failed = json.loads(self.record.read_text())
                            self.assertEqual(failed["transfer"]["handoff"], persisted["transfer"]["handoff"])
                            self.assertEqual(Path(failed["transfer"]["handoff"]).read_text(), contents)
                            self.successor_ended()
                            self.retry()
                        if not completed:
                            self.wait()
                        recovered = json.loads(self.record.read_text())
                        self.assertEqual(recovered["transfer"]["phase"], "complete")
                        self.adoption_ended(consumer)
                        if briefed:
                            self.assertEqual(self.prompts(recovered["pending"]["native_session_id"]), [private])
                        self.call("stop")
                        self.wait("stopped", persisted_stop=True)

    def successor_ended(self):
        # The abandoned successor's pane follows its worker, and the home's
        # session and server end with it. A retry inside that end can read
        # the pane and then find no server, which refuses as record-unreadable.
        deadline = time.monotonic() + 10
        while subprocess.run(["tmux", "-L", self.label, "has-session", "-t", "=jarvis"], capture_output=True,
                             env=self.env).returncode == 0:
            self.assertLess(time.monotonic(), deadline, "a managed controller outlived its worker")
            time.sleep(0.05)

    def retry(self):
        # The retry's own answer and stderr name the operation it refused; a
        # later status read reports only the generic handover-failed.
        answer, code = self.call("succeed")
        self.assertEqual((answer["state"], answer["reason"], code), ("handing-over", "succession", 0),
                         json.dumps(answer) + "\n" + self.stderr + "\n" + self.session_log())

    def instrumented(self):
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
        return skills

    def paused(self, argv, pause, phase, edge, env):
        # Start the request and return the identity of the process its
        # checkpoint holds, with the running request.
        event = self.root / "checkpoint.json"
        event.unlink(missing_ok=True)
        pause.write_text(json.dumps({"phase": phase, "edge": edge, "event": str(event), "release": str(self.root / "release")}))
        request = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if event.exists():
                try:
                    return json.loads(event.read_text()), request
                except json.JSONDecodeError:
                    pass
            if request.poll() is not None and request.returncode:
                self.fail("succession request refused: " + str(request.communicate()))
            time.sleep(0.05)
        request.kill()
        request.communicate()
        self.fail("no checkpoint was reached\n" + self.session_log())

    def process_live(self, identity):
        result = subprocess.run([self.env["JARVIS_TEST_BASH"], str(SKILLS / "jarvis/scripts/lib/session-backend.sh"),
                                 "worker-live", str(identity["pid"]), identity["started_at"]],
                                capture_output=True, env=self.env, timeout=10)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.returncode == 0

    def test_succession_recovery(self):
        skills = self.instrumented()
        script = skills / "jarvis/scripts/jarvis-session"
        pause = self.home / ".succession-pause.json"
        phases = ("saved", "waiting", "predecessor-ended", "confirmed", "brief-delivered", "complete")
        # The transition writes are one code path for every harness. One
        # harness per launch shape, without and with a kickoff turn before
        # the brief, reaches each write; test_succession_contract launches
        # every harness. Each successor, a retry's included, takes Start's
        # brief file.
        brief, _, private = self.private_brief()
        with patch.object(session_test, "SCRIPT", script):
            for harness in ("claude", "codex"):
                for phase in phases:
                    for edge in ("before", "after"):
                        with self.subTest(harness=harness, phase=phase, edge=edge):
                            print("succession-row: harness=" + harness + " phase=" + phase + " edge=" + edge, flush=True)
                            self.handoff()
                            self.call("start", harness=harness, mode="new", brief=brief)
                            self.wait()
                            previous = json.loads(self.record.read_text())
                            native_count = len(self.started())
                            identity, request = self.paused([str(script), "succeed", "--home", str(self.home)], pause, phase, edge, self.env)
                            with request:
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
                            self.retry()
                            self.wait()
                            recovered = json.loads(self.record.read_text())
                            self.assertNotEqual(recovered["pending"]["native_session_id"], previous["pending"]["native_session_id"])
                            self.assertIn("TASK-ref", Path(recovered["transfer"]["handoff"]).read_text())
                            self.assertEqual(self.prompts(recovered["pending"]["native_session_id"]), [private])
                            self.call("stop")
                            self.wait("stopped", persisted_stop=True)


if __name__ == "__main__":
    with native_launcher() as native:
        session_test.HARNESS = native
        unittest.main(defaultTest=["SuccessionContract.test_succession_contract", "SuccessionContract.test_succession_identity", "SuccessionContract.test_succession_foreign_session", "SuccessionContract.test_succession_recovery", "SuccessionContract.test_account_succession", "SuccessionContract.test_started_choice_survives_succession", "SuccessionContract.test_pi_successor_skips_unlaunchable_entry", "SuccessionContract.test_missing_orch_keeps_predecessor",
                                   "SuccessionContract.test_known_wall_selection", "SuccessionContract.test_pi_known_wall_selection", "SuccessionContract.test_known_wall_retry",
                                   "SuccessionContract.test_adoption_contract", "SuccessionContract.test_adoption_refusals", "SuccessionContract.test_adoption_recovery"])
