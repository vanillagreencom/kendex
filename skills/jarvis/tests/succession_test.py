"""Succession over agent-runtime's controller record, with real tmux and the fixture harness."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import session_test
from session_test import START_BRIEF, SessionContract
from fixtures.harness import native_launcher
from fixtures.tmux_scope import SCOPE


class SuccessionContract(SessionContract):
    def running(self):
        """The controller started on the home's first account, running, and its record."""
        self.call("start")
        self.wait(reason="new-no-record")
        return self.controller()

    def succeed(self, **kwargs):
        argv = [str(session_test.SCRIPT), "succeed", "--home", str(self.home)]
        if kwargs.get("account_walled"):
            argv.append("--account-walled")
        before = kwargs.get("usage_wall")
        if before:
            argv += ["--usage-wall", before["session_id"], f'{before["server"]} {before["pane"]}']
            if kwargs.get("reset_passed"):
                argv.append("--reset-passed")
        result = subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=300)
        self.stderr = result.stderr
        try:
            output, recovery = result.stdout, None
            if before:
                fields = json.loads(output)
                recovery = fields.pop("wall_recovery", None)
                output = json.dumps(fields)
            answer = session_test.validate(output, result.returncode, "succeed")
            if recovery is not None:
                answer["wall_recovery"] = recovery
        except (AssertionError, ValueError):
            self.fail("succeed exit=" + str(result.returncode) + " answered " + result.stdout + result.stderr
                      + "\n" + self.diagnostics())
        return answer, result.returncode

    def handed_over(self, before):
        """The controller after the hand-over from `before` settles."""
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            answer, _ = self.call("status")
            controller = self.controller()
            if answer["state"] == "running" and controller.get("generation") != before.get("generation"):
                return controller
            time.sleep(0.2)
        self.fail("the hand-over did not settle\n" + self.diagnostics())

    def sign_out(self, account):
        self.fixture["unsigned"].append(str(account))
        self.write_fixture()

    def test_a_context_succession_keeps_the_account_and_retires_the_predecessor_after_its_proof(self):
        # The failure it stops: a hand-over that leaves the home without a
        # controller, ends the predecessor before the successor proved
        # itself, changes the account a context mark keeps, or drops the
        # Jarvis seat and with it Jarvis's own succession.
        before = self.running()
        predecessor = self.started()[-1]
        brief = self.root / "brief.md"
        brief.write_text("Watch the release.\n")
        self.assertEqual(self.call("update-brief", brief=brief)[1], 0, self.stderr)
        answer, code = self.succeed()
        self.assertEqual((answer["state"], answer["reason"], code), ("running", "new-requested", 0), self.stderr)
        after = self.handed_over(before)
        successor = self.started()[-1]
        self.assertNotEqual(successor["id"], predecessor["id"])
        self.assertEqual((after["account"], after.get("seat")), (str(self.account), "jarvis"))
        self.assertEqual(after["pane"] != before["pane"], True)
        with self.assertRaises(ProcessLookupError):
            os.kill(predecessor["pid"], 0)
        prompts = [json.loads(line) for line in self.rows.read_text().splitlines() if "prompt" in json.loads(line)]
        self.assertEqual([row["prompt"] for row in prompts if row["id"] == successor["id"]],
                         [START_BRIEF + " Watch the release."], "the successor missed the updated private brief")
        archived = list((self.home / "state/archive").glob("handoff-*.md"))
        self.assertEqual([path.read_text() for path in archived], ["# Handoff\nWhere the work stands.\n"])

    def test_usage_wall_with_no_alternative_resumes_the_same_session_after_reset(self):
        before = self.running()
        self.assertEqual(len(self.started()), 1)
        prompts = self.prompts()
        for reset_passed, expected in ((False, "waiting"), (True, "confirmed")):
            answer, code = self.succeed(account_walled=True, usage_wall=before, reset_passed=reset_passed)
            self.assertEqual((answer.get("wall_recovery"), code), (expected, 0), self.stderr + self.diagnostics())
            self.assertEqual(self.controller()["session_id"], before["session_id"])
            self.assertEqual(len(self.started()), 1)
            self.assertEqual(len(self.prompts()), len(prompts) + int(reset_passed))
            self.assertEqual(list((self.home / "state/archive").glob("handoff-*.md")), [])

    def test_usage_wall_hands_over_to_a_free_account_before_reset(self):
        alternative = self.plant_account("claude-b", 20)
        before = self.running()
        answer, code = self.succeed(account_walled=True, usage_wall=before)
        self.assertEqual((answer["state"], answer["account"], code), ("running", str(alternative), 0), self.stderr)
        self.assertNotEqual(self.handed_over(before)["session_id"], before["session_id"])

    def test_live_window_stays_in_front_through_handover(self):
        before = self.running()
        server = before["server_socket"]
        helper = self.tmux_read(server, "new-window", "-d", "-t", "=jarvis:", "-n", "helper", "-P", "-F",
                                "#{window_id}", self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc").stdout.strip()
        self.assertTrue(helper)
        for shown in ("live", "live", "helper"):
            with self.subTest(shown=shown):
                if shown == "helper":
                    self.assertEqual(self.tmux_read(server, "select-window", "-t", helper).returncode, 0)
                answer, code = self.succeed()
                self.assertEqual((answer["state"], code), ("running", 0), self.stderr)
                after = self.handed_over(before)
                front = self.tmux_read(server, "display-message", "-p", "-t", "=jarvis:",
                                       "#{window_id}\t#{window_name}").stdout.strip()
                window = self.tmux_read(server, "display-message", "-p", "-t", after["pane"], "#{window_id}").stdout.strip()
                self.assertEqual(front, window + "\tjarvis" if shown == "live" else helper + "\thelper")
                before = after

    def test_successor_setup_readiness(self):
        # A walled succession, the one the watch loop starts for a wall of
        # either kind, briefs its successor with the home's stored Start brief.
        brief = self.root / "brief.md"
        brief.write_text("Watch the release.\n")
        for runner_up in (False, True):
            with self.subTest(runner_up=runner_up):
                pending = self.plant_account("pending-" + str(runner_up), 1)
                ready = self.plant_account("ready-" + str(runner_up), 20) if runner_up else self.account
                self.call("start", brief=brief)
                self.wait()
                before = self.controller()
                config = pending / ".claude.json"
                config.write_text("{}")
                # The caller's own entry walks accounts in room order.
                answer, code = self.succeed(account_walled=True)
                if not runner_up:
                    self.assertEqual((answer["state"], code), ("failed", 1), self.stderr)
                    self.assertEqual(self.controller()["pane"], before["pane"])
                else:
                    self.assertEqual((answer["state"], answer["account"], code), ("running", str(ready), 0), self.stderr)
                    successor = self.started()[-1]
                    prompts = [json.loads(line) for line in self.rows.read_text().splitlines() if "prompt" in json.loads(line)]
                    self.assertEqual([row["prompt"] for row in prompts if row["id"] == successor["id"]],
                                     [START_BRIEF + " Watch the release."])
                self.assertIn("reason=harness-setup-pending", self.stderr)
                self.assertIn("fix=", self.stderr)
                self.assertEqual(config.read_text(), "{}")
                self.assertNotIn(str(pending), [row["account"] for row in self.started()])
                self.call("stop")
                self.settled()
                self.accounts.remove(str(pending))
                if runner_up:
                    self.accounts.remove(str(ready))

    def test_a_successor_that_cannot_sign_in_is_passed_for_the_next_account(self):
        # Wanted outcome 2: the first successor account cannot be proved, so
        # the one command goes on to another eligible account, never needing
        # a person, and the failed account is not picked again.
        second = self.plant_account("claude-b", 20)
        before = self.running()
        self.sign_out(self.account)
        answer, code = self.succeed()
        self.assertEqual((answer["state"], answer["account"], code), ("running", str(second), 0),
                         self.stderr + self.diagnostics())
        self.assertIn("jarvis-session: successor-unproved account=" + str(self.account), self.stderr)
        after = self.handed_over(before)
        self.assertEqual((after["account"], after.get("seat")), (str(second), "jarvis"))
        self.assertEqual([row["account"] for row in self.started()], [str(self.account), str(self.account), str(second)])

    def test_with_no_account_left_the_answer_names_each_unproved_account_and_jarvis_keeps_running(self):
        # Wanted outcome 2's other half, and a walled account's refusal: with
        # no eligible account left the answer names the account and its
        # cause, and the predecessor still runs.
        before = self.running()
        answer, code = self.succeed(account_walled=True)
        self.assertEqual((answer["state"], answer["reason"], code), ("failed", "handover-failed", 1))
        self.assertEqual(answer["detail"], "No account is left to take over. Jarvis keeps running.")
        self.assertEqual(self.call("status")[0]["state"], "running")
        self.sign_out(self.account)
        answer, code = self.succeed()
        self.assertEqual((answer["state"], answer["reason"], code), ("failed", "handover-failed", 1), self.stderr)
        self.assertEqual(answer["detail"], "No account is left to take over: " + str(self.account)
                         + " (successor-not-signed-in). Jarvis keeps running.")
        status = self.call("status")[0]
        self.assertEqual((status["state"], status["account"]), ("running", str(self.account)))
        self.assertEqual(self.controller()["pane"], before["pane"])

    def test_an_older_unproved_entry_on_the_attempted_account_does_not_retry_it(self):
        # The failure it stops: a mark from an earlier attempt, which the
        # walk let expire, read as this attempt's, so a failure that marks
        # nothing relaunches onto the same account without end.
        before = self.running()
        fleet = json.loads(self.fleet.read_text())
        fleet["controller"]["unproved"] = [{"account": str(self.account), "note": "successor-not-ready",
                                            "cause": None, "at": "2026-01-01T00:00:00Z"}]
        self.fleet.write_text(json.dumps(fleet))
        self.fixture["asking"].append(str(self.account))
        self.write_fixture()
        answer, code = self.succeed()
        self.assertEqual((answer["state"], answer["reason"], code), ("failed", "handover-failed", 1), self.stderr)
        self.assertIn("successor-asking", answer["detail"])
        self.assertNotIn("successor-unproved", self.stderr)
        self.assertEqual([row["account"] for row in self.started()], [str(self.account)] * 2)
        self.assertEqual(self.controller()["pane"], before["pane"])

    def test_an_adopted_session_is_handed_to_a_managed_successor_on_the_private_server(self):
        # A session a person runs by hand becomes the home's controller: its
        # pane is bound, the managed successor opens on the home's own server
        # under the posture the adopted session was started under, never the
        # runtime's bypass default, or unattended where the home names its
        # harness, and the person's server keeps everything but that pane.
        settings = self.home / "kendex.settings.toml"
        base = settings.read_text()
        rows = (("", "native", set()),
                ('JARVIS_UNATTENDED_HARNESSES = "claude"\n', "bypass", session_test.PERMISSION_WORDS["claude"]))
        for setting, permission, words in rows:
            with self.subTest(setting=setting):
                settings.write_text(base + setting)
                try:
                    name = "owner-" + permission
                    owner = self.stand_in(name, "kept-" + permission)
                    line = ("cd " + shlex.quote(str(self.home)) + " && exec env CLAUDE_CONFIG_DIR="
                            + shlex.quote(str(self.account)) + " PATH=" + shlex.quote(self.env["PATH"])
                            + " claude --session-id adopted-" + permission)
                    launched = len(self.started())
                    self.tmux_read(owner, "send-keys", "-t", "=" + name + ":", line, "Enter")
                    deadline = time.monotonic() + 30
                    while len(self.started()) == launched and time.monotonic() < deadline:
                        time.sleep(0.1)
                    adopted = self.started()[-1]
                    pane = self.pane_of(owner, name)
                    env = self.inside_env(owner, "kept-" + permission)
                    argv = [str(session_test.SCRIPT), "start", "--home", str(self.home), "--harness", "claude",
                            "--account", str(self.account), "--adopt-pane", pane, "--adopt-pid", str(adopted["pid"])]
                    result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=300)
                    answer = session_test.validate(result.stdout, result.returncode, "start", adopt=True)
                    self.assertEqual(answer["state"], "running", result.stderr)
                    deadline = time.monotonic() + 120
                    while time.monotonic() < deadline:
                        status = self.call("status")[0]
                        if status["state"] == "running" and status["terminal"] and status["terminal"]["server"] != owner:
                            break
                        time.sleep(0.2)
                    else:
                        self.fail("the adoption did not settle\n" + self.diagnostics())
                    controller = self.controller()
                    self.assertEqual((controller.get("seat"), controller.get("permission")), ("jarvis", permission))
                    successor = self.started()[-1]
                    self.assertEqual(set(successor["argv"]) & session_test.ANY_PERMISSION_WORD, words, successor["argv"])
                    with self.assertRaises(ProcessLookupError):
                        os.kill(adopted["pid"], 0)
                    self.assertEqual(self.tmux_read(owner, "has-session", "-t", "=kept-" + permission).returncode, 0)
                finally:
                    # Each row adopts into a home with no running controller.
                    self.call("stop")
                    self.settled()


class HandOverBound(unittest.TestCase):
    """The hand-over loop over agent-runtime's replies stood in for: the
    walk offers one account on every call and each failed attempt on it
    stamps a fresh mark, as when a mark the walk let expire during a long
    round of attempts sends the walk back to an account already tried.
    A transfer can report the failure itself or leave it for Jarvis to read."""

    FINISHED_FAILURE = ({"settled": {"outcome": "failed", "observation": {"note": "successor-not-ready"}}}, 3, None, "")

    def test_an_account_already_tried_in_the_call_ends_it(self):
        self.assert_failed_hand_over(self.FINISHED_FAILURE, pin_unfinished=False)

    def test_an_unfinished_transfer_that_fails_does_not_count_as_a_hand_over(self):
        self.assert_failed_hand_over(self.FINISHED_FAILURE, pin_unfinished=True)

    def assert_failed_hand_over(self, transfer_reply, *, pin_unfinished):
        path = session_test.SKILLS / "jarvis/scripts/lib/session.py"
        spec = importlib.util.spec_from_file_location("jarvis_session_bound", path)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, {"JARVIS_BASH": os.environ.get("JARVIS_TEST_BASH", "bash")}):
            spec.loader.exec_module(module)
        test, account = self, "/accounts/.bclaude"

        class World(module.Session):
            def __init__(self, home):
                self.home, self.path, self.transfers = str(home), home / "jarvis-session.json", 0
                self.unproved = []

            def fleet(self):
                return self.path.with_name("fleet.json")

            def reach(self, socket):
                return []

            def status(self, reconcile=True):
                return {"recorded": {"pane": "%1", "account": "/accounts/.aclaude", "generation": 1,
                                     "unproved": self.unproved}}

            def ready_successor(self, *args, recorded=None):
                return {"successor": {"harness": "claude", "account": account}, "expected": {}}, 0, None, ""

            def runtime(self, *args, timeout=None):
                if args[:2] != ("controller", "transfer"):
                    return None, 0, None, ""
                self.transfers += 1
                if self.transfers > 2:
                    test.fail("the walk's offer of an account already tried relaunched onto it")
                result, code, refusal, errors = transfer_reply
                note = result["settled"]["observation"]["note"]
                self.unproved = [{"account": account, "note": note, "at": str(self.transfers)}]
                if pin_unfinished and self.transfers == 1 and code == 3:
                    # agent-runtime's Settled::status can report the failed job
                    # in this reply. Expose it as unfinished first so Jarvis
                    # must read the settled failure from the controller status.
                    return {"settled": {"outcome": "unconfirmed"}}, 0, refusal, errors
                return transfer_reply

        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            (home / "state").mkdir()
            (home / "state/handoff.md").write_text("handoff\n")
            world = World(home)
            with self.assertRaises(module.Refusal) as refused:
                world._hand_over({}, "context", "socket")
        self.assertEqual((refused.exception.reason, world.transfers), ("handover-failed", 1))


class SuiteStop(unittest.TestCase):
    """A succession suite stopped mid-run, as the battery runner stops an
    overdue suite: its tmux server and fake harness must not outlive it,
    since a lane's park reads a live fake harness as a live session."""

    ROW = "SuccessionContract.test_a_context_succession_keeps_the_account_and_retires_the_predecessor_after_its_proof"

    @staticmethod
    def launches(run):
        rows = [json.loads(line) for path in run.glob("*/rows.jsonl")
                for line in path.read_text().splitlines(keepends=True) if line.endswith("\n")]
        return [row for row in rows if "pid" in row]

    def test_a_suite_stopped_by_term_leaves_no_process_of_its_run(self):
        scope = Path(os.environ[SCOPE])
        env = {key: value for key, value in os.environ.items() if key not in (SCOPE, "TMUX_TMPDIR", "TMUX", "TMUX_PANE")}
        env["PATH"] = os.pathsep.join(entry for entry in env["PATH"].split(os.pathsep) if Path(entry).parent != scope)
        tmux = shutil.which("tmux", path=env["PATH"])
        with tempfile.TemporaryDirectory() as scratch:
            run = Path(scratch).resolve()
            env |= {"TMPDIR": str(run), "JARVIS_TEST_NATIVE": str(session_test.HARNESS)}
            suite = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), self.ROW], env=env,
                                     start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # The child's session is outside this suite's group: a TERM that
            # ends this suite stops the child first, then takes its own route.
            previous = signal.getsignal(signal.SIGTERM)

            def stopped(signum, frame):
                if suite.poll() is None:
                    os.killpg(suite.pid, signal.SIGTERM)
                    suite.wait(timeout=60)
                signal.signal(signum, previous)
                os.kill(os.getpid(), signum)
            signal.signal(signal.SIGTERM, stopped)
            try:
                deadline = time.monotonic() + 120
                while not self.launches(run):
                    self.assertIsNone(suite.poll(), "the suite ended before its fake harness started")
                    self.assertLess(time.monotonic(), deadline, "the fake harness never started")
                    time.sleep(0.1)
                os.killpg(suite.pid, signal.SIGTERM)
                self.assertEqual(suite.wait(timeout=60), -signal.SIGTERM)
                # A process of the run names its folder, a harness session id or
                # its home's tmux server label. The runtime's own controller job
                # ends by itself once its server is gone, hence the wait.
                marks = [str(run)] + [mark for row in self.launches(run) for mark in (row["id"], self.label(row))]
                deadline = time.monotonic() + 30
                while True:
                    table = subprocess.run(["ps", "-A", "-ww", "-o", "pid=,args="], capture_output=True, text=True,
                                           check=True).stdout
                    left = [line for line in table.splitlines() if any(mark in line for mark in marks)]
                    if not left:
                        break
                    self.assertLess(time.monotonic(), deadline, "left running:\n" + "\n".join(left))
                    time.sleep(0.2)
            finally:
                signal.signal(signal.SIGTERM, previous)
                if suite.poll() is None:
                    os.killpg(suite.pid, signal.SIGKILL)
                    suite.wait()
                # A failed row stops a server the child left outside any scope
                # before its scratch goes; the child's own shutdown owns the
                # servers in its scope folder.
                for row in self.launches(run):
                    subprocess.run([tmux, "-L", self.label(row), "kill-server"], env=env, capture_output=True, timeout=10)

    @staticmethod
    def label(row):
        return "jarvis-" + hashlib.sha256(os.fsencode(row["cwd"])).hexdigest()[:32]

if __name__ == "__main__":
    with native_launcher() as native:
        session_test.HARNESS = native
        # The session rows SuccessionContract inherits run in their own suite.
        unittest.main(defaultTest=["SuccessionContract." + name for name in vars(SuccessionContract) if name.startswith("test_")]
                      + ["HandOverBound.test_an_account_already_tried_in_the_call_ends_it",
                         "HandOverBound.test_an_unfinished_transfer_that_fails_does_not_count_as_a_hand_over",
                         "SuiteStop.test_a_suite_stopped_by_term_leaves_no_process_of_its_run"])
