"""Task-owned records and windows within the managed Jarvis session."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

from session import BASH, SESSION_NAME, Refusal, Session


# A pane agent-runtime reads under this cause stands on no server the task's
# launch recorded: the server ended, or another one answers its socket.
SERVER_ENDED = {"server-gone", "server-replaced"}
# The desktop's display names, which agent-runtime clears from every launch
# but a controller's: a task opens its browser and the desktop tools on the
# owner's screen, so it keeps the ones its caller holds.
DESKTOP_DISPLAY = ("WAYLAND_DISPLAY", "DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE")


class Task(Session):
    def __init__(self, home, identifier):
        super().__init__(home)
        self.path = self.path.parent / "tasks" / (str(uuid.UUID(identifier)) + ".json")
        # agent-runtime's record of the task's window and harness.
        self.launched = self.path.parent / "launches" / self.path.name

    def inspected(self):
        """agent-runtime's reading of the task's pane and harness."""
        seen, code, _, errors = self.runtime("inspect", "--record", self.launched)
        if code:
            raise Refusal("terminal-unread", errors.strip())
        return seen

    @staticmethod
    def ended(seen):
        """Whether the task's window is gone: its harness ended and the
        window closed with it, or its server ended."""
        pane = seen["pane"]
        return pane["reading"] == "gone" or pane.get("cause") in SERVER_ENDED

    def read(self):
        # Callers hold this task's lock: an ended controller is recorded here,
        # so status, completion and cleanup read one verdict.
        with self.path.open() as stream:
            record = json.load(stream)
        if record["home"] != self.home or record["id"] != self.path.stem:
            raise Refusal("record-unreadable")
        if record["completion"] is None and record["terminal"]:
            try:
                ended = self.ended(self.inspected())
            except Refusal as unread:
                # Unread evidence ends nothing; the record keeps its state.
                print(unread.detail, file=sys.stderr)
                ended = False
            if ended:
                # The task ran in that window. Its harness or its server has
                # ended, so nothing remains to complete it.
                record.update(state="failed", completion={"at": time.time(), "outcome": "failed"},
                              failure={"reason": "controller-ended", "detail": ""})
                self.write(record)
        return record

    def launch(self, args):
        # The window list tells the live session from a helper by this name.
        if args.name.casefold() == SESSION_NAME:
            raise Refusal("name-reserved", "fix=launch the task under another --name")
        parent = Session(self.home)
        with parent.locked():
            controller = parent.controller()
            if not controller:
                raise Refusal("session-not-running")
            terminal = controller["terminal"]
            task_file = str(Path(args.task_file).resolve(strict=True))
            result = Path(args.result_file).resolve()
            inputs = [str(Path(path).resolve(strict=True)) for path in args.input]
            try:
                cwd = str(Path(args.cwd).resolve(strict=True)) if args.cwd else self.home
            except OSError as error:
                raise Refusal("cwd-unavailable", "resolve cwd " + repr(args.cwd) + ": " + str(error)) from error
            if args.cwd == "" or not Path(cwd).is_dir() or not os.access(cwd, os.X_OK):
                raise Refusal("cwd-unavailable", cwd)
            # Results outlive scratch cleanup; the caller selects their home.
            scratch_root = Path(self.home) / "tmp/scratch"
            scratch_root.mkdir(parents=True, exist_ok=True)
            scratch_root = scratch_root.resolve(strict=True)
            if result == scratch_root or scratch_root in result.parents:
                raise Refusal("result-in-scratch")
            scratch = Path(tempfile.mkdtemp(prefix="task-", dir=scratch_root)).resolve()
            profile = scratch / "browser" if args.browser else None
            record = {"v": 1, "id": self.path.stem, "home": self.home, "name": args.name,
                      "state": "launching", "task_file": task_file, "cwd": cwd,
                      "inputs": inputs,
                      "result_path": str(result), "scratch": str(scratch),
                      "browser_profile": str(profile) if profile else None,
                      "browser_port": 0 if profile else None,
                      "server_pid": controller["server_pid"],
                      "server_started_at": controller["server_started_at"],
                      "terminal": None, "completion": None, "cleanup": None}
            recorded = False
            try:
                self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with self.path.open("x") as stream:
                    recorded = True
                    json.dump(record, stream)
                if profile:
                    profile.mkdir(mode=0o700)
                with self.locked():
                    brief = ("Read the task file " + json.dumps(task_file) + ". Write the requested Output to "
                             + json.dumps(str(result)) + ". Your absolute scratch directory is "
                             + json.dumps(str(scratch)) + ". "
                             + "Additional inputs: " + json.dumps(inputs) + ". "
                             + ("Use JARVIS_BROWSER_PROFILE and JARVIS_BROWSER_PORT with jarvis-browser for this task's browser. " if profile else "")
                             + "After writing the result, record completion with "
                             + shlex.join([str(Path(__file__).resolve().parents[1] / "task"), "complete",
                                           "--home", self.home, "--id", self.path.stem,
                                           "--outcome", "succeeded"]) + ".")
                    chosen = json.loads(self.backend("task-model", args.harness, args.model, args.effort,
                                                     self.home).stdout)
                    account = self.account(chosen, args, parent.fleet())
                    record.update(harness=chosen["harness"], model=chosen["model"] or "native-default",
                                  account=account, effort=chosen["effort"])
                    if not shutil.which(chosen["harness"], path=self.env["PATH"]):
                        raise Refusal("app-missing", chosen["harness"])
                    env = {"JARVIS_TASK_ID": record["id"], "JARVIS_BASH": BASH, "JARVIS_TASK_SCRATCH": str(scratch),
                           "JARVIS_BROWSER_PROFILE": str(profile) if profile else ""}
                    if profile:
                        env["JARVIS_BROWSER_PORT"] = "0"
                    env.update({name: os.environ[name] for name in DESKTOP_DISPLAY if name in os.environ})
                    brief_file = scratch / "brief.txt"
                    brief_file.write_text(brief)
                    # Nobody is at the pane: the task runs at the full bypass
                    # with no question tool, its account's home trusting its
                    # directory before the window opens.
                    intent = {"harness": chosen["harness"], "account": account, "cwd": cwd,
                              "model": chosen["model"] or None, "effort": chosen["effort"] or None,
                              "permission": "bypass", "question_tool": "off",
                              "brief": {"kind": "file", "path": str(brief_file)}, "env": env}
                    intent_file = scratch / "intent.json"
                    intent_file.write_text(json.dumps(intent))
                    self.launched.parent.mkdir(mode=0o700, exist_ok=True)
                    opened, code, _, errors = self.runtime(
                        "launch", "--intent", intent_file, "--record", self.launched, "--socket", terminal["server"],
                        "--session", SESSION_NAME, "--window-name", args.name)
                    if code:
                        raise Refusal("launch-refused", errors.strip())
                    pane = opened["pane"]
                    record["terminal"] = {"server": terminal["server"], "session": pane["session"],
                                          "window": pane["window"], "pane": pane["id"]}
                    self.write(record)
                    # A started harness can still stop on a first-run, trust
                    # or selection dialog, or a sign-in or usage wall, or end
                    # before it draws. A reading that failed decides nothing
                    # and is taken again. The last read must finish inside the
                    # bound, so the refusal keeps its screen.
                    while True:
                        try:
                            seen, unread = self.inspected(), ""
                        except Refusal as failed:
                            seen, unread = None, failed.detail
                        if seen:
                            state = seen["state"]["state"]
                            if self.ended(seen) or (state == "exited" and seen.get("harness_process")):
                                raise Refusal("native-exited", "\n".join(seen["screen_tail"]))
                            if seen["pane"]["reading"] != "live":
                                seen, unread = None, seen["pane"].get("cause", "")
                            elif state in ("idle", "working"):
                                break
                        if self.deadline - time.monotonic() < 1:
                            if not seen:
                                raise Refusal("terminal-unread", unread)
                            raise Refusal("harness-not-ready", "fix=open " + chosen["harness"] + " once on account "
                                          + account + ", finish the screen below, then launch the task again\n"
                                          + "\n".join(seen["screen_tail"]))
                        time.sleep(0.1)
                    record.update(state="running", launched_at=time.time())
                    self.write(record)
                    return record
            except BaseException as failure:
                record.update(state="failed", completion={"at": time.time(), "outcome": "failed"},
                              failure={"reason": failure.reason if isinstance(failure, Refusal) else type(failure).__name__,
                                       "detail": failure.detail if isinstance(failure, Refusal) else str(failure)},
                              cleanup={"state": "pending"})
                # Rollback owns a separate cleanup budget. Unknown ownership
                # keeps scratch.
                self.deadline = time.monotonic() + 3
                try:
                    if recorded:
                        self.write(record)
                    if self.launched.exists():
                        self.close_window(record)
                        self.launched.unlink()
                    shutil.rmtree(scratch)
                    record["cleanup"] = {"at": time.time(), "state": "done"}
                except (Refusal, OSError, ValueError, subprocess.TimeoutExpired) as teardown:
                    record["cleanup"]["reason"] = type(teardown).__name__
                if recorded:
                    try:
                        self.write(record)
                    except OSError as write_error:
                        print("jarvis-task: record=write-failed id=" + self.path.stem
                              + " cause=" + type(write_error).__name__, file=sys.stderr)
                raise

    def account(self, chosen, args, fleet):
        """The account the task spends: agent-runtime's one judge asked once."""
        pick = ["accounts", "pick", "--harness", chosen["harness"], "--record", fleet]
        if chosen["model"]:
            pick += ["--native-model", chosen["model"]]
        if args.account:
            pick += ["--account", args.account]
        # A short task admits an account's room up to its wall, and on a named
        # account is judged on its projected wall, as the chooser judges every
        # account; a full task on a named account is judged on its reading.
        if args.short:
            pick += ["--max-pct", "100"] + (["--projected"] if args.account else [])
        result, code, refusal, errors = self.runtime(*pick)
        if code or (result or {}).get("answer") != "lane":
            sys.stderr.write(errors)
            answer = (result or {}).get("answer") or refusal or "unjudged"
            raise Refusal("account-" + answer, json.dumps((result or {}).get("record"), separators=(",", ":")))
        return result["record"]["config_dir"]

    def in_front(self, record):
        """Whether RECORD's window is the current window of its tmux session."""
        # Only a closed current window leaves tmux to pick the next one; any
        # other the owner chose stays. Focus is presentation, so an unread
        # answer moves nothing.
        terminal = record["terminal"]
        if not terminal:
            return False
        shown = self.tmux("display-message", "-p", "-t", terminal["pane"], "#{window_active}",
                          socket=terminal["server"], check=False)
        return shown.returncode == 0 and shown.stdout.strip() == "1"

    def close_window(self, record):
        """The task's harness ended and its window closed by agent-runtime's
        stop, where its window still stands on its server."""
        if self.ended(self.inspected()):
            return
        front = self.in_front(record)
        stopped, code, _, errors = self.runtime("stop", "--record", self.launched)
        if code or stopped["window"]["close"] == "unreadable":
            raise Refusal("terminal-unread", errors.strip() or json.dumps(stopped["window"]))
        # A closed current window leaves tmux to pick the next one, which can
        # be another task's: the live controller's window takes the front.
        # Focus is presentation, so an unread controller closes the task all
        # the same and selects nothing.
        if not front:
            return
        terminal = record["terminal"]
        try:
            controller = Session(self.home).controller()
        except (Refusal, OSError, ValueError, subprocess.TimeoutExpired):
            return
        live = (controller or {}).get("terminal")
        if live and live["server"] == terminal["server"] and controller["server_pid"] == record["server_pid"]:
            self.tmux("select-window", "-t", live["window"], socket=terminal["server"], check=False)

    def complete(self, outcome):
        with self.locked():
            record = self.read()
            if record["completion"] is None:
                if outcome == "succeeded" and not Path(record["result_path"]).is_file():
                    raise Refusal("result-missing")
                record.update(state="completed", completion={"at": time.time(), "outcome": outcome})
                self.write(record)
            return record

    def cleanup(self):
        with self.locked():
            record = self.read()
            if record["completion"] is None:
                raise Refusal("task-not-completed")
            if not record["cleanup"] or record["cleanup"]["state"] != "done":
                if self.launched.exists():
                    self.close_window(record)
                    self.launched.unlink()
                scratch = Path(record["scratch"])
                if scratch.exists():
                    shutil.rmtree(scratch)
                record["cleanup"] = {"at": time.time(), "state": "done"}
                self.write(record)
            return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    verbs = parser.add_subparsers(dest="verb", required=True)
    launch = verbs.add_parser("launch")
    launch.add_argument("--name", required=True)
    launch.add_argument("--task-file", required=True)
    launch.add_argument("--result-file", required=True)
    launch.add_argument("--input", action="append", default=[])
    launch.add_argument("--cwd", help="Existing task working directory; defaults to Jarvis home")
    launch.add_argument("--harness", choices=("claude", "codex", "copilot", "pi"), required=True)
    launch.add_argument("--model", required=True)
    launch.add_argument("--effort", default="high")
    launch.add_argument("--account")
    launch.add_argument("--browser", action="store_true")
    launch.add_argument("--short", action="store_true",
                        help="A task of a few minutes: the account pick admits room up to the wall"
                             " (accounts pick --max-pct 100). The seat reserve and the projected wall still apply.")
    complete = verbs.add_parser("complete")
    complete.add_argument("--outcome", choices=("succeeded", "failed"), required=True)
    for verb in (launch, complete, verbs.add_parser("cleanup"), verbs.add_parser("status")):
        verb.add_argument("--home", required=True)
        if verb != launch:
            verb.add_argument("--id", required=True)
    args = parser.parse_args()
    task = None
    try:
        task = Task(args.home, str(uuid.uuid4()) if args.verb == "launch" else args.id)
        if args.verb == "launch":
            record = task.launch(args)
        elif args.verb == "complete":
            record = task.complete(args.outcome)
        elif args.verb == "cleanup":
            record = task.cleanup()
        else:
            with task.locked():
                record = task.read()
        print(json.dumps(record, separators=(",", ":")))
        return 0
    except (Refusal, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print("jarvis-task: refused=" + (error.reason if isinstance(error, Refusal) else type(error).__name__)
              + (" id=" + task.path.stem if task else ""), file=sys.stderr)
        if isinstance(error, Refusal) and error.detail:
            print(error.detail, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
