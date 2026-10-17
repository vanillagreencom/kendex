"""One controller per home. SessionStart supplies the native identity."""

import argparse
import errno
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
import uuid


BACKEND = Path(__file__).with_name("session-backend.sh")
BASH = os.environ["JARVIS_BASH"]
# VGS bounds each call at 60 seconds. Leave time to print its answer.
CALL_SECONDS = 55
START_BRIEF = "Read .agents/skills/jarvis/SKILL.md and follow the Start procedure in .agents/skills/jarvis/workflows/session.md."
STATE_REASONS = {
    "running": {"resumed", "new-no-record", "new-history-gone", "new-selection-changed", "new-requested", "existing"},
    "starting": {"launching"}, "handing-over": {"succession"}, "stopping": {"stop-requested"},
    "stopped": {"never-started", "stopped", "ended"}, "off": {"app-off"},
    "blocked": {"app-off", "name-conflict", "record-unreadable", "sign-in-required", "selection-conflict", "tmux-missing", "app-missing",
                "trust-required"},
    "failed": {"launch-failed", "handover-failed"},
}
# A dialog row as a harness draws it: inside a box border, padded to the pane.
DIALOG_FRAME = re.compile(r"^[\s─-╿]+|[\s─-╿]+$")


class Refusal(Exception):
    def __init__(self, reason, detail="", state="blocked"):
        self.reason, self.detail, self.state = reason, detail, state


def clean(value):
    return isinstance(value, str) and all(c.isprintable() for c in value)


def dialog_question(line):
    # The record holds a detail of at most 200 printable characters.
    return "".join(c for c in DIALOG_FRAME.sub("", line) if c.isprintable())[:200]


def environment():
    # Keep desktop and transport access. Credentials and parent harness
    # identity come from the selected account, never the calling session.
    keys = {"PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TERM", "COLORTERM",
            "DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "SSH_AUTH_SOCK",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "CURL_CA_BUNDLE",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy",
            "all_proxy", "no_proxy", "JARVIS_BASH"}
    return {key: value for key, value in os.environ.items()
            if key in keys or key.startswith(("XDG_", "LC_"))}


class Session:
    def __init__(self, home):
        self.home = str(Path(home).resolve(strict=True))
        key = hashlib.sha256(os.fsencode(self.home)).hexdigest()
        state = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
        self.path = state / "kendex/jarvis" / key / "jarvis-session.json"
        # tmux places its socket in its own runtime root, whose pathname fits
        # Unix socket limits even when XDG_STATE_HOME is a deep directory.
        self.label = "jarvis-" + key[:32]
        self.deadline = time.monotonic() + CALL_SECONDS
        self.env = environment()
        self.emitted = False

    def run(self, argv, *, input=None, check=True, env=None):
        self.operation = argv[5] if argv[0] == "tmux" else argv[2] if argv[0] == BASH else Path(argv[0]).name
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(argv, CALL_SECONDS)
        result = subprocess.run(argv, input=input, text=True, capture_output=True,
                                cwd=self.home, env=env or self.env, timeout=remaining)
        if check and result.returncode:
            print("jarvis-session: operation=" + self.operation + " exit=" + str(result.returncode), file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            raise Refusal("launch-failed", "The session operation failed. Check the Jarvis session log.", "failed")
        return result

    def failure_log(self, key, failure):
        frame = next(frame for frame in reversed(traceback.extract_tb(failure.__traceback__)) if frame.filename == __file__)
        operation = self.operation if frame.name == "run" else frame.line or frame.name
        print(f"jarvis-session: {key} operation={json.dumps(operation)} cause={type(failure).__name__}"
              + (f" errno={errno.errorcode.get(failure.errno, failure.errno)}" if isinstance(failure, OSError) else "")
              + " message=" + json.dumps(str(failure)), file=sys.stderr)

    def backend(self, verb, *args, check=True):
        return self.run([BASH, str(BACKEND), verb, *map(str, args)], check=check)

    def tmux(self, *args, check=True, socket=None):
        target = ["-S", socket] if socket else ["-L", self.label]
        return self.run(["tmux", *target, "-f", os.devnull, *map(str, args)], check=check)

    def read(self):
        try:
            with self.path.open() as stream:
                record = json.load(stream)
            if not isinstance(record, dict) or record.get("v") != 1 or record.get("home") != self.home:
                raise ValueError("record")
            if record.get("reason") not in STATE_REASONS.get(record.get("state"), set()):
                raise ValueError("state")
            for field in ("home", "harness", "account"):
                if record.get(field) is not None and not clean(record[field]):
                    raise ValueError(field)
            detail = record.get("detail", "")
            if not clean(detail) or len(detail) > 200:
                raise ValueError("detail")
            return record
        except FileNotFoundError:
            return None
        except (OSError, ValueError, TypeError):
            raise Refusal("record-unreadable")

    def write(self, record):
        # Exclusive scratch acquisition prevents replacement of another
        # writer's staging file. Every caller holds the carrier's lock.
        fd, name = tempfile.mkstemp(dir=self.path.parent, prefix=".session-")
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(record, stream, separators=(",", ":"))
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    @contextmanager
    def locked(self):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock = subprocess.Popen([BASH, str(BACKEND), "lock", str(self.path)],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, cwd=self.home, env=self.env)
        try:
            ready, _, _ = select.select([lock.stdout], [], [], min(12, max(0, self.deadline - time.monotonic())))
            if not ready or lock.stdout.readline() != "locked\n":
                raise Refusal("record-unreadable")
            yield
        finally:
            lock.stdin.close()
            try:
                lock.wait(timeout=2)
            except subprocess.TimeoutExpired:
                lock.terminate()
                lock.wait(timeout=2)
            lock.stdout.close()
            lock.stderr.close()

    def terminal(self, record):
        terminal = record.get("terminal") if record else None
        if not terminal:
            return None
        if not shutil.which("tmux"):
            raise Refusal("tmux-missing")
        native_generation = (record.get("pending") or {}).get("generation", record["generation"])
        live = self.backend("live", terminal["server"], record["server_pid"], record["server_started_at"],
                            terminal["pane"], native_generation, terminal["window"],
                            "staging" if not record.get("process") and not (record.get("pending") or {}).get("started_at") else "native", check=False)
        if live.returncode == 1:
            return None
        if live.returncode:
            raise Refusal("record-unreadable")
        return json.loads(live.stdout)

    def answer(self, record=None, *, state=None, reason=None, detail=""):
        try:
            terminal = self.terminal(record)
            view = record
            if not terminal and record and self.terminal(record.get("predecessor")):
                view = record["predecessor"]
                terminal = self.terminal(view)
        except (Refusal, subprocess.TimeoutExpired):
            if state is None:
                raise
            terminal = None
            view = record
        if state is None:
            if not record:
                state, reason = "stopped", "never-started"
            else:
                state, reason = record["state"], record["reason"]
                detail = record.get("detail", "")
                if terminal and state == "stopping" and not self.worker_live(record):
                    retained = self.retain_live(record, view)
                    state, reason, detail = retained["state"], retained["reason"], ""
                if not terminal and state in ("running", "stopping"):
                    state = "off" if record.get("app_off") else "stopped"
                    reason = "app-off" if state == "off" else ("stopped" if record.get("intent") == "stop" else "ended")
        return {"v": 1, "state": state, "reason": reason,
                **{key: view.get(key) if view else None for key in ("home", "harness", "account", "origin")},
                "boot": record.get("boot") if record else None,
                "terminal": terminal, "detail": detail}

    def _emit(self, answer):
        print(json.dumps(answer, separators=(",", ":")), flush=True)
        self.emitted = True

    def _current_request(self, record, generation, intent):
        current = record and record["generation"] == generation and record.get("intent") == intent
        if not current:
            # Operators read session.log to distinguish a cancelled launch
            # from a pending native identity or a failed dependency.
            print("jarvis-session: worker=cancelled generation=" + str(generation), flush=True)
        return current

    def detach(self, verb, record):
        generation = record["generation"]
        log = self.path.parent / "session.log"
        with log.open("a") as stream:
            child = subprocess.Popen([sys.executable, "-B", "-c",
                                      "import runpy, sys; runtime = runpy.run_path(sys.argv[1], run_name='jarvis_worker'); runtime['Session'](sys.argv[3]).worker(sys.argv[2], int(sys.argv[4]))",
                                      str(Path(__file__).resolve()), verb, self.home, str(generation)],
                                     stdin=subprocess.DEVNULL, stdout=stream, stderr=stream,
                                     env=dict(self.env, JARVIS_BASH=BASH), start_new_session=True)
        try:
            identity = json.loads(self.backend("process", child.pid).stdout)
            record["worker"] = identity
            self.write(record)
            return identity
        except (Refusal, OSError, ValueError, subprocess.TimeoutExpired):
            # The lock prevents the child from acquiring a terminal until its
            # process identity is saved. Its handle remains ours on refusal.
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=2)
            raise

    def worker_live(self, record):
        identity = record.get("worker") if record else None
        if not identity:
            return False
        result = self.backend("worker-live", identity["pid"], identity["started_at"], check=False)
        if result.returncode > 1:
            raise Refusal("record-unreadable")
        return result.returncode == 0

    def confirmed_history(self, record):
        if not record:
            return None
        pending = record.get("pending") or {}
        if pending.get("started_at") and (record.get("identity_verified") or record.get("state") == "running"):
            return {key: record.get(key) for key in ("harness", "account", "effective_home", "pending")}
        return record.get("history")

    def retain_live(self, record, live):
        # Request flags survive a refusal. Native ownership keeps its original
        # generation, even though the request generation has advanced.
        controller_state = live.get("controller_state", live["state"])
        retained = dict(live, generation=record["generation"], intent=record.get("intent"),
                        app_off=record.get("app_off", False), boot=record.get("boot"),
                        history=self.confirmed_history(live) or record.get("history"))
        retained.update(state="running" if controller_state == "running" else "starting",
                        reason="existing" if controller_state == "running" else "launching", detail="")
        retained.pop("worker", None)
        return retained

    def start(self, args):
        boot = None
        if args.origin == "boot":
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip() + ":" + os.environ.get("XDG_SESSION_ID", "")
        with self.locked():
            record = self.read()
            if boot and record and record.get("boot") == boot:
                try:
                    return self.answer(record), 0
                except Refusal as failure:
                    return self.answer(record, state=failure.state, reason=failure.reason, detail=failure.detail), 0
            # Boot and app-on requests are handled even when launch is refused.
            # The locked record owns these flags independently of the launch.
            if boot or args.origin == "app-on":
                if record is None:
                    record = {"v": 1, "home": self.home, "harness": None, "account": None,
                              "origin": None, "generation": 0, "terminal": None,
                              "state": "stopped", "reason": "never-started", "detail": ""}
                if boot:
                    record["boot"] = boot
                if args.origin == "app-on":
                    record["app_off"] = False
                    if record["state"] == "off":
                        record.update(state="stopped", reason="stopped", detail="")
                self.write(record)
            if record and record.get("app_off") and args.origin != "app-on":
                if boot:
                    record["boot"] = boot
                    self.write(record)
                    return self.answer(record), 0
                return self.answer(record, state="blocked", reason="app-off"), 1
            if not shutil.which("tmux"):
                raise Refusal("tmux-missing")
            if not shutil.which(args.harness):
                raise Refusal("app-missing")
            account = str(Path(args.account).resolve(strict=True))
            matching = record and record.get("harness") == args.harness and record.get("account") == account
            if record and record["state"] == "starting" and not self.worker_live(record):
                # A completed worker no longer owns a launch. Release only its
                # recorded terminal before retrying, and retain confirmed history.
                try:
                    self.end_owned(record)
                except (Refusal, OSError, ValueError, subprocess.TimeoutExpired) as failure:
                    self.failure_log("abandoned-cleanup-failed", failure)
                    if not self.terminal(record):
                        raise
                    record = self.retain_live(record, record)
                    self.write(record)
                    return self.answer(record), 0
                record.update(history=self.confirmed_history(record), terminal=None,
                              state="failed", reason="launch-failed",
                              detail="Jarvis's launch worker ended before Start completed.")
                self.write(record)
            if matching and record["state"] in ("starting", "running") and (self.worker_live(record) if record["state"] == "starting" else self.terminal(record)):
                record["app_off"] = False
                if boot:
                    record["boot"] = boot
                self.write(record)
                if record["state"] == "running":
                    return self.answer(record, state="running", reason="existing"), 0
                return self.answer(record), 0
            predecessor = record if self.terminal(record) else (record.get("predecessor") if record else None)
            if predecessor and not self.terminal(predecessor):
                predecessor = None
            if predecessor is not record and predecessor and predecessor["state"] == "running" and predecessor["harness"] == args.harness and predecessor["account"] == account:
                # Requests advance generation. A cancelled replacement keeps
                # the live session's binding in pending.generation.
                restored = dict(predecessor, generation=record["generation"] + 1, intent="start", app_off=False,
                                boot=boot or record.get("boot"))
                self.write(restored)
                return self.answer(restored, state="running", reason="existing"), 0
            brief = START_BRIEF
            if args.brief_file:
                private = Path(args.brief_file).read_text().strip()
                if not private or not clean(private):
                    raise Refusal("record-unreadable")
                brief += " " + private
            history_record = self.confirmed_history(predecessor or record)
            history_matches = history_record and history_record.get("harness") == args.harness and history_record.get("account") == account
            confirmed = history_record and (history_record.get("pending") or {}).get("started_at")
            reason = "new-no-record" if not confirmed else "new-requested"
            file, native_id = "", str(uuid.uuid4())
            if history_record and history_record.get("harness") and not history_matches:
                reason = "new-selection-changed"
            elif confirmed and history_matches and args.mode == "resume":
                pending = history_record.get("pending") or {}
                history = self.backend("history", args.harness, history_record.get("effective_home", account),
                                       pending.get("native_session_id", ""), pending.get("session_file", ""), check=False)
                if history.returncode == 0:
                    file, native_id, reason = history.stdout.strip(), pending["native_session_id"], "resumed"
                elif history.returncode == 1:
                    reason = "new-history-gone"
                else:
                    raise Refusal("record-unreadable")
            generation = int(record.get("generation", 0)) + 1 if record else 1
            next_record = {"v": 1, "home": self.home, "harness": args.harness, "account": account,
                           "origin": args.origin, "boot": boot or (record.get("boot") if record else None),
                           "generation": generation, "state": "starting", "reason": "launching", "detail": "",
                           "app_off": False, "intent": "start", "terminal": None,
                           "launch": {"id": native_id, "file": file, "reason": reason, "brief": brief},
                           "predecessor": predecessor, "history": history_record}
            self.write(next_record)
            self.detach("start", next_record)
            return self.answer(next_record), 0

    def stop(self, origin):
        with self.locked():
            record = self.read()
            if not record:
                record = {"v": 1, "home": self.home, "harness": None, "account": None, "origin": None,
                          "boot": None, "generation": 0, "terminal": None,
                          "state": "stopped", "reason": "never-started", "detail": ""}
            # Each request owns its generation. Native terminal ownership
            # stays bound to pending.generation until that controller ends.
            record["generation"] += 1
            record["history"] = self.confirmed_history(record)
            if record.get("state") in ("running", "starting"):
                record["controller_state"] = record["state"]
            record["intent"] = "stop"
            record["app_off"] = origin == "app-off" or record.get("app_off", False)
            self.write(record)
            if self.terminal(record) or self.terminal(record.get("predecessor")) or record.get("state") == "starting":
                record.update(state="stopping", reason="stop-requested", detail="")
                self.write(record)
                self.detach("stop", record)
                answer = self.answer(record, state="stopping", reason="stop-requested")
                # Publish while teardown still waits on this lock. Off and
                # the Stopping answer precede the end of the owned session.
                self._emit(answer)
                return answer, 0
            record.update(state="off" if record["app_off"] else "stopped",
                          reason="app-off" if record["app_off"] else "stopped", detail="")
            self.write(record)
            return self.answer(record), 0

    def end_owned(self, record):
        if self.terminal(record):
            pane = record["terminal"]["pane"]
            # tmux evaluates ownership and closes the pane's session in one
            # server command, before another client can reuse that pane id.
            native_generation = (record.get("pending") or {}).get("generation", record["generation"])
            binding = "#{==:#{@jarvis-generation}," + str(native_generation) + "}"
            if not record.get("process") and not (record.get("pending") or {}).get("started_at"):
                binding = "#{||:" + binding + ",#{==:#{@jarvis-generation},}}"
            condition = "#{&&:" + binding + ",#{==:#{pid}," + str(record["server_pid"]) + "}}"
            self.tmux("if-shell", "-F", "-t", pane, condition, "kill-session -t " + pane, socket=record["terminal"]["server"])

    def worker(self, verb, generation):
        self.deadline = time.monotonic() + CALL_SECONDS
        acquired = None
        transferred = False
        try:
            record = self.read()
            if not self._current_request(record, generation, verb):
                return
            if verb == "stop":
                with self.locked():
                    record = self.read()
                    if not self._current_request(record, generation, "stop"):
                        return
                    self.end_owned(record)
                    self.end_owned(record.get("predecessor"))
                    record.update(state="off" if record["app_off"] else "stopped",
                                  reason="app-off" if record["app_off"] else "stopped", terminal=None)
                    self.write(record)
                return
            launch = record["launch"]
            prepared = json.loads(self.backend("prepare", record["harness"], record["account"], self.home,
                                               launch["id"], launch["file"], self.path, generation).stdout)
            with self.locked():
                record = self.read()
                if not self._current_request(record, generation, "start"):
                    return
                self.end_owned(record.get("predecessor"))
                existing = self.tmux("has-session", "-t", "=jarvis", check=False)
                if existing.returncode == 0:
                    raise Refusal("name-conflict")
                # A prompt-free shell keeps the pane alive before SessionStart.
                created = self.tmux("new-session", "-d", "-s", "jarvis", "-c", self.home,
                                    "-P", "-F", "#{socket_path}\t#{pid}\t#{start_time}\t#{window_id}\t#{pane_id}", BASH, "--noprofile", "--norc")
                socket, server, started, window, pane = created.stdout.strip().split("\t")
                record.update(terminal={"server": socket, "session": "jarvis", "window": window, "pane": pane},
                              server_pid=int(server), server_started_at=int(started), effective_home=prepared["effective_home"], account_var=prepared["var"],
                              pending={"generation": generation, "server": int(server), "pane": pane,
                                       "native_session_id": launch["id"] if record["harness"] != "codex" or launch["file"] else None})
                # The acquisition remains locally owned until saved, including
                # failures of the first ownership write or later setup writes.
                acquired = record
                self.write(record)
                transferred = True
                self.tmux("set-option", "-t", pane, "@jarvis-generation", generation)
                command = prepared["line"]
                # The account observer reads descendants of the pane shell.
                # A tail keeps that shell from exec-replacing itself.
                self.tmux("respawn-pane", "-k", "-t", pane, "-c", self.home,
                          BASH, "--noprofile", "--norc", "-c", command + '; result=$?; exit "$result"')
                process = self.tmux("display-message", "-p", "-t", pane, "#{pane_pid}").stdout.strip()
                record["process"] = json.loads(self.backend("process", process).stdout)
                self.write(record)
            # One bound covers native identity and the taking of the Start brief.
            # Backend operations share it; inspection never renews the launch.
            # The pane is read outside the record lock, which holds only each
            # read, decision and write, the brief's paste among them: a native
            # hook's brief-taken stamp waits on that lock for SESSION_ROWS_WAIT
            # (orch session-rows.sh), 2 s, far above that hold.
            while True:
                if time.monotonic() >= self.deadline:
                    raise Refusal("launch-failed", "Jarvis did not complete Start within its launch bound.", "failed")
                record = self.read()
                if not self._current_request(record, generation, "start"):
                    return
                if not self.terminal(record):
                    raise Refusal("launch-failed", "The Jarvis session ended before it accepted its Start procedure.", "failed")
                identity = record.get("pending") or {}
                # The native hook's stamp at the first tool call, or Claude
                # Code turn end, after the brief: the session's own word that
                # it took it. The pane is still read, so a sign-in wall or
                # another account refuses the Start before the stamp counts.
                taken = record.get("brief_delivered") and identity.get("brief_taken")
                observed = self.backend(
                    "inspect", socket, pane, record["harness"], prepared["var"], record["account"],
                    "confirmed" if identity.get("started_at") else "pending", identity.get("observed_account", ""),
                    "delivered" if record.get("brief_delivered") else "undelivered").stdout
                observed, _, dialog = observed.partition("\n")
                with self.locked():
                    inspected = record
                    record = self.read()
                    if not self._current_request(record, generation, "start"):
                        return
                    # The pane answered for the record it was read against.
                    if any(record.get(key) != inspected.get(key) for key in ("pending", "brief_delivered")):
                        continue
                    if observed == "auth":
                        raise Refusal("sign-in-required", "Sign in to " + record["harness"] + " and retry Start.")
                    if observed == "wrong-account":
                        raise Refusal("selection-conflict")
                    if observed == "trust":
                        raise Refusal("trust-required", dialog_question(dialog))
                    if identity.get("native_session_id") and identity.get("started_at") and observed in ("idle", "working"):
                        record["identity_verified"] = True
                        record["history"] = self.confirmed_history(record)
                        self.write(record)
                    # A kickoff turn's working pane is no turn on the brief: the
                    # brief waits for that turn to end, and only the session's
                    # brief-taken stamp then says it took the brief.
                    if identity.get("native_session_id") and identity.get("started_at") and not record.get("brief_delivered") and observed in (("idle",) if prepared["kickoff"] else ("idle", "working")):
                        prompt = self.path.parent / ("start-" + str(generation) + ".txt")
                        stream = prompt.open("x")
                        try:
                            with stream:
                                stream.write(launch["brief"])
                            self.backend("deliver", socket, pane, record["harness"], prompt)
                        finally:
                            prompt.unlink()
                        record["brief_delivered"] = True
                        self.write(record)
                    elif record.get("brief_delivered") and (taken or (observed == "working" and not prepared["kickoff"])):
                        record.update(state="running", reason=launch["reason"], detail="")
                        record.pop("predecessor", None)
                        record.pop("launch", None)
                        record.pop("controller_state", None)
                        self.write(record)
                        return
                time.sleep(0.2)
        except (Refusal, OSError, ValueError, subprocess.TimeoutExpired) as failure:
            self.failure_log("worker-failed", failure)
            if verb == "start" and (isinstance(failure, subprocess.TimeoutExpired) or time.monotonic() >= self.deadline):
                failure = Refusal("launch-failed", "Jarvis did not complete Start within its launch bound.", "failed")
            self.deadline = time.monotonic() + CALL_SECONDS
            with self.locked():
                if acquired and not transferred:
                    try:
                        self.end_owned(acquired)
                    except (Refusal, OSError, ValueError, subprocess.TimeoutExpired) as teardown:
                        self.failure_log("cleanup-failed", teardown)
                record = self.read()
                if not self._current_request(record, generation, verb):
                    raise
                record["history"] = self.confirmed_history(record)
                if verb == "start" and (not acquired or transferred):
                    try:
                        self.end_owned(acquired or record)
                    except (Refusal, OSError, ValueError, subprocess.TimeoutExpired) as teardown:
                        self.failure_log("cleanup-failed", teardown)
                if acquired and self.terminal(acquired):
                    record.update({key: acquired[key] for key in
                                   ("terminal", "server_pid", "server_started_at", "pending", "effective_home", "account_var")})
                predecessor = record.get("predecessor")
                live = record if self.terminal(record) else predecessor if self.terminal(predecessor) else None
                if live:
                    record = self.retain_live(record, live)
                elif verb == "stop":
                    record.update(state="off" if record["app_off"] else "stopped",
                                  reason="app-off" if record["app_off"] else "stopped", detail="", terminal=None)
                else:
                    record.update(state=failure.state if isinstance(failure, Refusal) else "failed",
                                  reason=failure.reason if isinstance(failure, Refusal) else "launch-failed",
                                  detail=failure.detail if isinstance(failure, Refusal) else "Jarvis could not start. Check the session log.",
                                  terminal=None)
                record.pop("worker", None)
                self.write(record)
            raise


class Arguments(argparse.ArgumentParser):
    def error(self, message):
        print("jarvis-session: arguments=invalid", file=sys.stderr)
        raise SystemExit(2)


def main():
    parser = Arguments()
    verbs = parser.add_subparsers(dest="verb", required=True, parser_class=Arguments)
    for verb in ("start", "status", "stop"):
        command = verbs.add_parser(verb)
        command.add_argument("--home", required=True)
        if verb == "start":
            command.add_argument("--harness", choices=("claude", "codex", "copilot", "pi"), required=True)
            command.add_argument("--account", required=True)
            command.add_argument("--mode", choices=("resume", "new"), required=True)
            command.add_argument("--origin", choices=("boot", "manual", "app-on"), required=True)
            command.add_argument("--brief-file")
        elif verb == "stop":
            command.add_argument("--origin", choices=("app-off",))
    args = parser.parse_args()
    if not clean(args.home) or (args.verb == "start" and not clean(args.account)):
        parser.error("path")
    try:
        session = Session(args.home)
    except OSError:
        parser.error("home")
    try:
        if args.verb == "start":
            answer, code = session.start(args)
        elif args.verb == "stop":
            answer, code = session.stop(args.origin)
        else:
            answer, code = session.answer(session.read()), 0
    except Refusal as failure:
        try:
            record = session.read()
        except Refusal:
            record = None
        answer = session.answer(record, state=failure.state, reason=failure.reason, detail=failure.detail)
        code = 0 if args.verb == "status" else 1
    except (OSError, ValueError, subprocess.TimeoutExpired):
        answer = session.answer(state="blocked", reason="record-unreadable")
        code = 0 if args.verb == "status" else 1
    if not session.emitted:
        session._emit(answer)
    return code


if __name__ == "__main__":
    sys.exit(main())
