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

from session import BASH, Refusal, Session


class Task(Session):
    def __init__(self, home, identifier):
        super().__init__(home)
        self.path = self.path.parent / "tasks" / (str(uuid.UUID(identifier)) + ".json")

    def read(self):
        with self.path.open() as stream:
            record = json.load(stream)
        if record["home"] != self.home or record["id"] != self.path.stem:
            raise Refusal("record-unreadable")
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
                      "server_pid": controller["server_pid"],
                      "server_started_at": controller["server_started_at"],
                      "terminal": None, "completion": None, "cleanup": None}
            acquired, recorded = None, False
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
                             + ("Use JARVIS_BROWSER_PROFILE for this task's browser. " if profile else "")
                             + "After writing the result, record completion with "
                             + shlex.join([str(Path(__file__).resolve().parents[1] / "task"), "complete",
                                           "--home", self.home, "--id", self.path.stem,
                                           "--outcome", "succeeded"]) + ".")
                    prepared = json.loads(self.backend("task-prepare", args.harness, args.model, args.effort,
                                                       args.account or "", self.home, brief).stdout)
                    record.update(harness=prepared["harness"], model=prepared["model"],
                                  account=prepared["account"], effort=prepared["effort"])
                    created = self.tmux("new-window", "-d", "-t", "=jarvis", "-n", args.name,
                                        "-c", self.home, "-P", "-F", "#{window_id}\t#{pane_id}",
                                        BASH, "--noprofile", "--norc", socket=terminal["server"])
                    window, pane = created.stdout.strip().split("\t")
                    acquired = {"server": terminal["server"], "session": terminal["session"],
                                "window": window, "pane": pane}
                    record["terminal"] = acquired
                    self.tmux("set-option", "-p", "-t", pane, "@jarvis-task", record["id"],
                              socket=terminal["server"])
                    self.write(record)
                    child_env = ["env", "JARVIS_TASK_ID=" + record["id"],
                                 "JARVIS_TASK_SCRATCH=" + str(scratch),
                                 "JARVIS_BROWSER_PROFILE=" + (str(profile) if profile else "")]
                    self.tmux("respawn-pane", "-k", "-t", pane, "-c", self.home,
                              *child_env, BASH, "--noprofile", "--norc", "-c", prepared["line"],
                              socket=terminal["server"])
                    record.update(state="running", launched_at=time.time())
                    self.write(record)
                    return record
            except BaseException:
                # The acquisition is ours even when its first record write fails.
                if acquired:
                    self.close_window(record, allow_unmarked=True)
                shutil.rmtree(scratch)
                record.update(state="failed", completion={"at": time.time(), "outcome": "failed"},
                              cleanup={"at": time.time(), "state": "done"})
                if recorded:
                    self.write(record)
                raise

    def close_window(self, record, *, allow_unmarked=False):
        terminal = record["terminal"]
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
            if record["cleanup"] is None:
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
    try:
        task = Task(args.home, str(uuid.uuid4()) if args.verb == "launch" else args.id)
        if args.verb == "launch":
            record = task.launch(args)
        elif args.verb == "complete":
            record = task.complete(args.outcome)
        elif args.verb == "cleanup":
            record = task.cleanup()
        else:
            record = task.read()
        print(json.dumps(record, separators=(",", ":")))
        return 0
    except (Refusal, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print("jarvis-task: refused=" + (error.reason if isinstance(error, Refusal) else type(error).__name__), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
