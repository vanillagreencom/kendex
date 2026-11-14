"""Succession over agent-runtime's controller record, with real tmux and the fixture harness."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import time
import unittest
import session_test
from session_test import START_BRIEF, SessionContract
from fixtures.harness import native_launcher


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
        result = subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=300)
        self.stderr = result.stderr
        try:
            answer = session_test.validate(result.stdout, result.returncode, "succeed")
        except AssertionError:
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

    def test_an_adopted_session_is_handed_to_a_managed_successor_on_the_private_server(self):
        # A session a person runs by hand becomes the home's controller: its
        # pane is bound, the managed successor opens on the home's own
        # server, and the person's server keeps everything but that pane.
        owner = self.stand_in("owner", "kept")
        line = ("cd " + shlex.quote(str(self.home)) + " && exec env CLAUDE_CONFIG_DIR=" + shlex.quote(str(self.account))
                + " PATH=" + shlex.quote(self.env["PATH"]) + " claude --session-id adopted-1")
        self.tmux_read(owner, "send-keys", "-t", "=owner:", line, "Enter")
        deadline = time.monotonic() + 30
        while not self.started() and time.monotonic() < deadline:
            time.sleep(0.1)
        adopted = self.started()[-1]
        pane = self.pane_of(owner, "owner")
        env = self.inside_env(owner, "kept")
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
        self.assertEqual(self.controller().get("seat"), "jarvis")
        with self.assertRaises(ProcessLookupError):
            os.kill(adopted["pid"], 0)
        self.assertEqual(self.tmux_read(owner, "has-session", "-t", "=kept").returncode, 0)


if __name__ == "__main__":
    with native_launcher() as native:
        session_test.HARNESS = native
        # The session rows SuccessionContract inherits run in their own suite.
        unittest.main(defaultTest=["SuccessionContract." + name for name in vars(SuccessionContract) if name.startswith("test_")])
