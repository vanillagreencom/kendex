"""Task-owned records and windows within the managed Jarvis session."""
import argparse
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
import uuid

from session import BASH, CALL_SECONDS, Refusal, Session


def native(line, receipt):
    """Observe early termination of the shared command before acknowledging it."""
    # The foreground CLI owns terminal interrupts. Caught handlers reset on
    # exec, unlike SIG_IGN, so the child keeps its native dispositions.
    for signum in (signal.SIGINT, signal.SIGQUIT):
        if signal.getsignal(signum) != signal.SIG_IGN:
            signal.signal(signum, lambda _signum, _frame: None)
    child = subprocess.Popen([BASH, "--noprofile", "--norc", "-c", line])
    try:
        code = child.wait(timeout=0.5)
        answer = {"state": "exited", "exit": code}
    except subprocess.TimeoutExpired:
        answer = {"state": "started"}
    path = Path(receipt)
    with path.with_suffix(".writing").open("x") as stream:
        json.dump(answer, stream)
    os.replace(path.with_suffix(".writing"), path)
    return child.wait()


class Task(Session):
    def __init__(self, home, identifier):
        super().__init__(home)
        self.path = self.path.parent / "tasks" / (str(uuid.UUID(identifier)) + ".json")

    def read(self):
        # Callers hold this task's lock: an ended controller is recorded here,
        # so status, completion and cleanup read one verdict.
        with self.path.open() as stream:
            record = json.load(stream)
        if record["home"] != self.home or record["id"] != self.path.stem:
            raise Refusal("record-unreadable")
        terminal = record["terminal"]
        if record["completion"] is None and terminal:
            live = self.backend("task-live", terminal["server"], record["server_pid"], record["server_started_at"],
                                terminal["pane"], check=False)
            if live.returncode == 1:
                # The task ran in that window. Its controller's session or
                # server has ended, so nothing remains to complete it.
                record.update(state="failed", completion={"at": time.time(), "outcome": "failed"},
                              failure={"reason": "controller-ended", "detail": ""})
                self.write(record)
            elif live.returncode:
                # Unread evidence ends nothing; the record keeps its state.
                print(live.stderr, end="", file=sys.stderr)
        return record

    def launch(self, args):
        parent = Session(self.home)
        with parent.locked():
            controller = parent.read()
            terminal = parent.terminal(controller)
            if not controller or controller["state"] != "running" or not terminal:
                raise Refusal("session-not-running")
            task_file = str(Path(args.task_file).resolve(strict=True))
            result = Path(args.result_file).resolve()
            inputs = [str(Path(path).resolve(strict=True)) for path in args.input]
            # Results outlive scratch cleanup; the caller selects their home.
            scratch_root = Path(self.home) / "tmp/scratch"
            scratch_root.mkdir(parents=True, exist_ok=True)
            scratch_root = scratch_root.resolve(strict=True)
            if result == scratch_root or scratch_root in result.parents:
                raise Refusal("result-in-scratch")
            scratch = Path(tempfile.mkdtemp(prefix="task-", dir=scratch_root)).resolve()
            profile = scratch / "browser" if args.browser else None
            record = {"v": 1, "id": self.path.stem, "home": self.home, "name": args.name,
                      "state": "launching", "task_file": task_file,
                      "inputs": inputs,
                      "result_path": str(result), "scratch": str(scratch),
                      "browser_profile": str(profile) if profile else None,
                      "browser_port": 0 if profile else None,
                      "server_pid": controller["server_pid"],
                      "server_started_at": controller["server_started_at"],
                      "terminal": None, "completion": None, "cleanup": None}
            acquired, recorded, startup = None, False, None
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
                    prepared = json.loads(self.backend("task-prepare", args.harness, args.model, args.effort,
                                                       args.account or "", self.home, brief).stdout)
                    record.update(harness=prepared["harness"], model=prepared["model"],
                                  account=prepared["account"], effort=prepared["effort"])
                    if not shutil.which(prepared["harness"], path=self.env["PATH"]):
                        raise Refusal("app-missing", prepared["harness"])
                    created = self.tmux("new-window", "-d", "-t", "=jarvis", "-n", args.name,
                                        "-c", self.home, "-P", "-F", "#{window_id}\t#{pane_id}",
                                        BASH, "--noprofile", "--norc", socket=terminal["server"])
                    window, pane = created.stdout.strip().split("\t")
                    acquired = {"server": terminal["server"], "session": terminal["session"],
                                "window": window, "pane": pane, "marked": False}
                    record["terminal"] = acquired
                    self.write(record)
                    self.tmux("set-option", "-p", "-t", pane, "@jarvis-task", record["id"],
                              socket=terminal["server"])
                    acquired["marked"] = True
                    self.write(record)
                    self.tmux("set-option", "-w", "-t", window, "remain-on-exit", "on",
                              socket=terminal["server"])
                    child_env = ["env", "JARVIS_TASK_ID=" + record["id"],
                                 "JARVIS_BASH=" + BASH,
                                 "JARVIS_TASK_SCRATCH=" + str(scratch),
                                 "JARVIS_BROWSER_PROFILE=" + (str(profile) if profile else "")]
                    if profile:
                        child_env.append("JARVIS_BROWSER_PORT=0")
                    receipt = scratch / "startup.json"
                    self.tmux("respawn-pane", "-k", "-t", pane, "-c", self.home,
                              *child_env, sys.executable, "-B", "-c",
                              "import runpy,sys; sys.path.insert(0,sys.argv[1]); sys.exit(runpy.run_path(sys.argv[1]+'/task.py',run_name='task_native')['native'](sys.argv[2],sys.argv[3]))",
                              str(Path(__file__).resolve().parent), prepared["line"], str(receipt),
                              socket=terminal["server"])
                    while not receipt.exists():
                        if time.monotonic() >= self.deadline:
                            raise subprocess.TimeoutExpired("task-startup", CALL_SECONDS)
                        time.sleep(0.02)
                    startup = json.loads(receipt.read_text())
                    if startup["state"] != "started":
                        screen = self.tmux("capture-pane", "-p", "-t", pane, socket=terminal["server"]).stdout
                        raise Refusal("native-exited", "exit=" + str(startup["exit"]) + "\n" + screen.strip())
                    record.update(state="running", launched_at=time.time())
                    self.write(record)
                    return record
            except BaseException as failure:
                record.update(state="failed", completion={"at": time.time(), "outcome": "failed"},
                              failure={"reason": failure.reason if isinstance(failure, Refusal) else type(failure).__name__,
                                       "detail": failure.detail if isinstance(failure, Refusal) else str(failure)},
                              cleanup={"state": "pending"})
                if startup and startup["state"] == "exited":
                    record["failure"]["exit"] = startup["exit"]
                # Rollback owns a separate cleanup budget. Unknown ownership
                # keeps scratch.
                self.deadline = time.monotonic() + 3
                try:
                    if recorded:
                        self.write(record)
                    if acquired:
                        self.close_window(record, allow_unmarked=True)
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

    def close_window(self, record, *, allow_unmarked=False):
        terminal = record["terminal"]
        allow_unmarked = allow_unmarked or not terminal.get("marked", True)
        self.backend("task-close", terminal["server"], record["server_pid"], record["server_started_at"],
                     terminal["pane"], terminal["window"], self.path.stem, str(allow_unmarked).lower())

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
                if record["terminal"]:
                    self.close_window(record)
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
    launch.add_argument("--harness", choices=("claude", "codex", "copilot", "pi"), required=True)
    launch.add_argument("--model", required=True)
    launch.add_argument("--effort", default="high")
    launch.add_argument("--account")
    launch.add_argument("--browser", action="store_true")
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
