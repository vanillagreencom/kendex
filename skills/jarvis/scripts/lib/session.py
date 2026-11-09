"""One controller per home. SessionStart supplies the native identity."""

import argparse
from collections import namedtuple
import errno
from contextlib import contextmanager
import hashlib
import io
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import traceback
import uuid


BACKEND = Path(__file__).with_name("session-backend.sh")
# The package's own command, which no install puts on PATH.
ENTRY = Path(__file__).resolve().parent.parent / "jarvis-session"
BASH = os.environ["JARVIS_BASH"]
# VGS bounds each call at 60 seconds. Leave time to print its answer.
CALL_SECONDS = 55
START_BRIEF = "Read .agents/skills/jarvis/SKILL.md and follow the Start procedure in .agents/skills/jarvis/workflows/session.md."
STATE_REASONS = {
    "running": {"resumed", "new-no-record", "new-history-gone", "new-selection-changed", "new-requested", "existing"},
    "starting": {"launching"}, "handing-over": {"succession"}, "stopping": {"stop-requested"},
    "stopped": {"never-started", "stopped", "ended"}, "off": {"app-off"},
    "blocked": {"app-off", "name-conflict", "record-unreadable", "sign-in-required", "selection-conflict", "tmux-missing", "app-missing",
                "trust-required", "home-not-dedicated"},
    "failed": {"launch-failed", "handover-failed"},
}
# A dialog row as a harness draws it: inside a box border, padded to the pane.
DIALOG_FRAME = re.compile(r"^[\s─-╿]+|[\s─-╿]+$")
# How a record owns its pane (Session.ownership): kind is the backend live
# verb's mode, mark the value that verb binds the pane by, and binding the
# tmux format holding that ownership inside one server command.
Ownership = namedtuple("Ownership", "kind mark binding")


class SessionLog(io.TextIOBase):
    def __init__(self, stream, origin):
        self.stream, self.origin = stream, origin
        self.pending = ""

    @property
    def encoding(self):
        return self.stream.encoding

    def writable(self):
        return True

    def _line(self, text):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        # Append a whole line at once: workers and successor runners share
        # this file, and neither may leave an unprefixed fragment for the other.
        self.stream.write(stamp + " origin=" + self.origin + " " + text + "\n")

    def write(self, text):
        if self.closed:
            raise ValueError("write to closed session log")
        lines = (self.pending + text).split("\n")
        self.pending = lines.pop()
        for line in lines:
            self._line(line)
        return len(text)

    def flush(self):
        if self.pending:
            self._line(self.pending)
            self.pending = ""
        self.stream.flush()

    def close(self):
        if not self.closed:
            try:
                super().close()
            finally:
                self.stream.close()


class Refusal(Exception):
    def __init__(self, reason, detail="", state="blocked"):
        self.reason, self.detail, self.state = reason, detail, state


class Terminated(Exception):
    """A signal stopped the worker; the message names it."""


def clean(value):
    return isinstance(value, str) and all(c.isprintable() for c in value)


def start_brief(private):
    return START_BRIEF + " " + private if private else START_BRIEF


def same_choice(record, requested):
    # A Start that states no model keeps whatever model the session runs.
    if requested is None:
        return True
    choice = (record or {}).get("choice") or {}
    return all(choice.get(key) == requested[key] for key in ("model", "effort"))


def dialog_question(line):
    # The record holds a detail of at most 200 printable characters.
    return "".join(c for c in DIALOG_FRAME.sub("", line) if c.isprintable())[:200]


def environment(harness=None, *, policy=False):
    # Keep desktop and transport access. Credentials and parent harness
    # identity come from the selected account, never the calling session.
    keys = {"PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TERM", "COLORTERM",
            "DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "SSH_AUTH_SOCK",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "CURL_CA_BUNDLE",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy",
            "all_proxy", "no_proxy", "JARVIS_BASH"}
    # Pi's Claude provider home is independent of its selected Pi account.
    if harness == "pi" and os.environ.get("CLAUDE_CONFIG_DIR"):
        keys.add("CLAUDE_CONFIG_DIR")
    selected = {key: value for key, value in os.environ.items()
                if key in keys or key.startswith(("XDG_", "LC_"))}
    if policy:
        # Published user-manager policy only; shell-only exports are outside
        # this contract. Extend this one list through a package change.
        names = ("ORCH_LANE_EXCLUDE", "ORCH_LANE_RETIRE", "ORCH_LANE_ALIASES",
                 "FLEET_USER", "AGENT_TMPDIR", "CLAUDE_CODE_TMPDIR")
        deadline = time.monotonic() + 10
        def read(argv):
            try:
                result = subprocess.run(argv, env=selected, capture_output=True, timeout=max(0.001, deadline - time.monotonic()))
                if result.returncode:
                    raise subprocess.CalledProcessError(result.returncode, argv)
                return result.stdout.decode("utf-8")
            except (OSError, subprocess.SubprocessError, UnicodeError) as failure:
                print("jarvis-session: policy-source=unavailable operation=" + Path(argv[0]).name
                      + " cause=" + type(failure).__name__, file=sys.stderr)
                raise Refusal("launch-failed", "The user-session policy source could not be read.", "failed") from None
        if sys.platform == "darwin":
            for name in names:
                value = read(["launchctl", "getenv", name])
                if value:
                    selected[name] = value[:-1] if value.endswith("\n") else value
        else:
            # systemctl(1) show-environment documents Bash dollar-single-quote
            # assignments. Let Bash decode selected assignments, including NL.
            source = read(["systemctl", "--user", "show-environment"])
            assignments = [line for line in source.split("\n") if line.partition("=")[0] in names]
            present = [line.partition("=")[0] for line in assignments]
            values = read([BASH, "--noprofile", "--norc", "-ec",
                           'eval "$1"; shift; for name; do printf "%s\\0" "${!name}"; done',
                           "policy", "\n".join(assignments), *present]).split("\0")
            selected.update(zip(present, values[:-1]))
    return selected


def home_module():
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import home
    return home


def home_state(home):
    """The private state directory of the resolved HOME: its session record and its forward outbox."""
    key = hashlib.sha256(os.fsencode(home)).hexdigest()
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "kendex/jarvis" / key


class Session:
    def __init__(self, home, env=None):
        self.home = str(Path(home).resolve(strict=True))
        state = home_state(self.home)
        self.path = state / "jarvis-session.json"
        # tmux places its socket in its own runtime root, whose pathname fits
        # Unix socket limits even when XDG_STATE_HOME is a deep directory.
        self.label = "jarvis-" + state.name[:32]
        self.deadline = time.monotonic() + CALL_SECONDS
        self.env = environment() if env is None else env
        self.emitted = False
        self.terminated = None

    def run(self, argv, *, input=None, check=True, env=None):
        self.operation = argv[3] if argv[0] == "tmux" else argv[2] if argv[0] == BASH else Path(argv[0]).name
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
        # A signal's own handler frame names no operation: the frame it interrupted does.
        frame = next(frame for frame in reversed(traceback.extract_tb(failure.__traceback__))
                     if frame.filename == __file__ and frame.name != "_terminate")
        operation = self.operation if frame.name == "run" else frame.line or frame.name
        print(f"jarvis-session: {key} operation={json.dumps(operation)} cause={type(failure).__name__}"
              + (f" errno={errno.errorcode.get(failure.errno, failure.errno)}" if isinstance(failure, OSError) else "")
              + " message=" + json.dumps(str(failure)), file=sys.stderr)

    def backend(self, verb, *args, check=True, env=None):
        return self.run([BASH, str(BACKEND), verb, *map(str, args)], check=check, env=env)

    def tmux(self, *args, check=True, socket=None):
        # The server this starts reads the user's own tmux config, found by
        # tmux's own search, or runs on tmux's defaults where there is none:
        # the attached session looks and behaves as the user's others do. The
        # runtime names windows and panes by id and launches panes by argv, so
        # no user option changes what it owns.
        target = ["-S", socket] if socket else ["-L", self.label]
        return self.run(["tmux", *target, *map(str, args)], check=check)

    @contextmanager
    def pane_command(self, argv):
        # Socket values never enter process arguments or diagnostic command
        # text. A private short directory fits AF_UNIX on Linux and macOS,
        # even when the home/state path exceeds their socket pathname limit.
        receiver = '''import json,os,socket,sys
with socket.socket(socket.AF_UNIX) as channel:
    channel.settimeout(10)
    channel.connect(sys.argv[1])
    with channel.makefile('r') as stream: argv,env=json.loads(stream.readline())
    env.update({key:os.environ[key] for key in ('TERM', 'TMUX', 'TMUX_PANE')})
    channel.sendall(b'1')
os.execvpe(argv[0],argv,env)
'''
        # tempfile's private directory and socket's context own this one-use
        # channel, including a refused tmux call or failed pane connection.
        with tempfile.TemporaryDirectory(prefix="jarvis-pane-", dir="/tmp") as directory, socket.socket(socket.AF_UNIX) as listener:
            address = str(Path(directory) / "channel")
            listener.bind(address)
            listener.listen(1)
            # tmux(1) runs a command given as several arguments directly; a
            # single one would run under the user's default-shell.
            yield [sys.executable, "-B", "-X", "utf8", "-c", receiver, address]
            listener.settimeout(max(0.001, self.deadline - time.monotonic()))
            with listener.accept()[0] as channel:
                channel.settimeout(max(0.001, self.deadline - time.monotonic()))
                channel.sendall((json.dumps([argv, self.env]) + "\n").encode("utf-8"))
                if channel.recv(1) != b"1":
                    raise Refusal("launch-failed", "The pane could not receive its launch environment.", "failed")

    def read(self):
        try:
            with self.path.open() as stream:
                record = json.load(stream)
            if not isinstance(record, dict) or record.get("v") != 1 or record.get("home") != self.home:
                raise ValueError("record")
            if record.get("reason") not in STATE_REASONS.get(record.get("state"), set()):
                raise ValueError("state")
            for field in ("home", "harness", "account", "private_brief"):
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

    @staticmethod
    def ownership(record):
        # An adopted session's pane carries no generation mark and lives in
        # the consumer's session, where a move of the pane keeps its process:
        # that process owns it. A staging pane is its generation's or not yet
        # marked; a native controller's is the generation that launched it.
        if record.get("adopted"):
            pid = record["process"]["pid"]
            return Ownership("adopted", pid, "#{==:#{pane_pid}," + str(pid) + "}")
        generation = (record.get("pending") or {}).get("generation", record["generation"])
        binding = "#{==:#{@jarvis-generation}," + str(generation) + "}"
        if not record.get("process") and not (record.get("pending") or {}).get("started_at"):
            return Ownership("staging", generation, "#{||:" + binding + ",#{==:#{@jarvis-generation},}}")
        return Ownership("native", generation, binding)

    def terminal(self, record):
        terminal = record.get("terminal") if record else None
        if not terminal:
            return None
        if not shutil.which("tmux"):
            raise Refusal("tmux-missing")
        ownership = self.ownership(record)
        live = self.backend("live", terminal["server"], record["server_pid"], record["server_started_at"],
                            terminal["pane"], ownership.mark, terminal["window"], ownership.kind, check=False)
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
                if record.get("intent") == "succeed" and state in ("handing-over", "starting"):
                    if self.worker_live(record):
                        state, reason = "handing-over", "succession"
                    else:
                        # The worker can publish Running and exit while this
                        # lock-free status read still holds its older snapshot.
                        current = self.read()
                        if current != record:
                            return self.answer(current)
                        if self.terminal(record.get("predecessor")):
                            state, reason, detail = "running", "existing", ""
                            view = record["predecessor"]
                            terminal = self.terminal(view)
                        elif self.successor_adopts(record):
                            state, reason = "handing-over", "succession"
                        else:
                            state, reason, detail = "failed", "handover-failed", "Retry jarvis-session succeed for this home."
        return {"v": 1, "state": state, "reason": reason,
                **{key: view.get(key) if view else None for key in ("home", "harness", "account", "origin")},
                "boot": record.get("boot") if record else None,
                "terminal": terminal, "detail": detail}

    def attach(self):
        # Lock-free, as status reads: the answer names the live controller,
        # a predecessor's during succession included.
        try:
            terminal = self.answer(self.read())["terminal"]
        except (OSError, ValueError, subprocess.TimeoutExpired):
            raise Refusal("record-unreadable")
        if not terminal:
            raise Refusal("no-controller")
        argv = ["tmux", "-S", terminal["server"], "attach-session", "-t", "=" + terminal["session"]]
        # The caller's own environment holds its live desktop and its
        # $TERMINAL. A window holding its TMUX or TMUX_PANE reads as a pane of
        # the caller's server, so the terminal starts without them.
        own = {key: value for key, value in os.environ.items() if key not in ("TMUX", "TMUX_PANE")}
        if os.environ.get("TMUX"):
            # A client inside the caller's pane would nest, so the user's
            # terminal opens one in a window of its own and the caller's
            # client stays where it is.
            try:
                opened = self.backend("open-window", terminal["server"], terminal["session"], check=False, env=own)
            except (OSError, subprocess.TimeoutExpired) as failure:
                raise Refusal("terminal-launch-failed", str(failure))
            if opened.returncode == 4:
                raise Refusal("terminal-unresolved", opened.stderr.strip())
            if opened.returncode not in (0, 3):
                raise Refusal("terminal-launch-failed", opened.stderr.strip())
            print(opened.stderr, end="", file=sys.stderr)
            if opened.returncode == 0:
                return
            print("No terminal is set in TERMINAL and xdg-terminal-exec is not on PATH, so Jarvis opens inside this tmux pane.",
                  file=sys.stderr)
        # tmux refuses a client only from a pane of the server it attaches to
        # (server_client_check_nested), so the caller's TMUX stays: the nested
        # client crosses servers, and a pane on the home's own server is
        # refused rather than shown inside itself.
        sys.stderr.flush()
        os.execvp("tmux", argv)

    def _emit(self, answer):
        print(json.dumps(answer, separators=(",", ":")), flush=True)
        self.emitted = True

    def report_due(self):
        # The controller owns the session start; orch owns cadence and receipts.
        record = self.read()
        if not record or not record.get("report_started_at"):
            raise Refusal("record-unreadable")
        result = self.run([BASH, str(BACKEND.parents[3] / "orch/scripts/oversee-report"),
                           "due", "--session-start", str(record["report_started_at"])], check=False, env=os.environ)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        self.emitted = True
        return None, result.returncode

    def _current_request(self, record, generation, intent):
        current = record and record["generation"] == generation and record.get("intent") == intent
        if not current:
            # Operators read session.log to distinguish a cancelled launch
            # from a pending native identity or a failed dependency.
            print("jarvis-session: worker=cancelled generation=" + str(generation), flush=True)
        return current

    def log_output(self, origin):
        # Keep these streams installed through the interpreter's exception
        # hook, so an uncaught worker or runner traceback uses the same writer.
        stream = (self.path.parent / "session.log").open("a", encoding="utf-8", buffering=1)
        sys.stdout = sys.stderr = SessionLog(stream, origin)

    def detach(self, verb, record, *, origin=None):
        generation = record["generation"]
        origin = "succession" if verb == "succeed" else origin or record["origin"]
        log = self.path.parent / "session.log"
        with log.open("a") as stream:
            child = subprocess.Popen([sys.executable, "-B", "-c",
                                      "import os, runpy, sys; runtime = runpy.run_path(sys.argv[1], run_name='jarvis_worker'); session = runtime['Session'](sys.argv[3], dict(os.environ)); session.log_output(sys.argv[5]); session.worker(sys.argv[2], int(sys.argv[4]))",
                                      str(Path(__file__).resolve()), verb, self.home, str(generation), origin],
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

    def successor_adopts(self, record):
        # The one rule that a transfer is the successor runner's to finish,
        # read by status, a succeed retry, the runner and an ending worker: a
        # worker that ended without the failure path that drops its identity,
        # a live successor pane and an ended predecessor terminal. The runner
        # starts the transfer once the predecessor's process, already stopped
        # with its terminal, has exited (successor).
        return "worker" in record and bool(self.terminal(record)) and not self.terminal(record.get("predecessor"))

    def confirmed_history(self, record):
        if not record:
            return None
        pending = record.get("pending") or {}
        if pending.get("started_at") and (record.get("identity_verified") or record.get("state") == "running"):
            return {key: record.get(key) for key in ("harness", "account", "choice", "effective_home", "pending")}
        return record.get("history")

    def retain_live(self, record, live):
        transfer = record.get("transfer") or {}
        # Request flags survive a refusal. Native ownership keeps its original
        # generation, even though the request generation has advanced.
        controller_state = live.get("controller_state", live["state"])
        retained = dict(live, generation=record["generation"], intent=record.get("intent"),
                        app_off=record.get("app_off", False), boot=record.get("boot"),
                        history=self.confirmed_history(live) or record.get("history"))
        retained.update(state="running" if controller_state == "running" else "starting",
                        reason="existing" if controller_state == "running" else "launching", detail="")
        if record.get("intent") == "succeed" and transfer.get("spent_account") and transfer["phase"] != "complete":
            # Consumers use the live controller's native identity; only the
            # unfinished transfer keeps the spent account and saved handoff.
            retained["transfer"] = transfer
        retained.pop("worker", None)
        return retained

    @staticmethod
    def private_brief(args):
        # The record keeps the checked text, not the path: a consumer may
        # remove the file before a later hand-over.
        if not args.brief_file:
            return None
        private = Path(args.brief_file).read_text().strip()
        if not private or not clean(private):
            raise Refusal("record-unreadable")
        return private

    def update_brief(self, args):
        private = self.private_brief(args)
        if private is None:
            raise Refusal("record-unreadable")
        with self.locked():
            record = self.read()
            # Launch and handover workers already hold their delivery text.
            if not record or record["state"] != "running" or record.get("app_off"):
                raise Refusal("record-unreadable")
            answer = self.answer(record)
            if answer["state"] != "running":
                raise Refusal("record-unreadable")
            record["private_brief"] = private
            self.write(record)
            return answer, 0

    def _adopt(self, args, record, choice, stated):
        # The unmanaged session takes the predecessor's place in succession's
        # order: its record is this one entry, read once here.
        if not os.environ.get("TMUX"):
            print("jarvis-session: adopt=refused cause=no-tmux pane=" + args.adopt_pane, file=sys.stderr)
            raise Refusal("selection-conflict")
        read = self.backend("adopt", args.adopt_pane, args.adopt_pid, check=False, env=dict(self.env, TMUX=os.environ["TMUX"]))
        if read.returncode == 3:
            # The backend's one keyed line names which binding refused.
            sys.stderr.write(read.stderr)
            raise Refusal("selection-conflict")
        if read.returncode:
            print("jarvis-session: operation=adopt exit=" + str(read.returncode), file=sys.stderr)
            print(read.stderr, file=sys.stderr)
            raise Refusal("record-unreadable")
        # The state fields serve the answer and Stop's reads of a live entry.
        predecessor = dict(json.loads(read.stdout), adopted=True, home=self.home, account=None, origin=None,
                           state="running", reason="existing")
        private = self.private_brief(args)
        if stated and stated["warning"]:
            print(stated["warning"], file=sys.stderr)
        base = {"generation": record["generation"] if record else 0, "report_started_at": int(time.time()),
                "origin": args.origin, "boot": record.get("boot") if record else None, "private_brief": private}
        return self._hand_over(base, choice, predecessor, None)

    def start(self, args):
        boot = None
        if args.origin == "boot":
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip() + ":" + os.environ.get("XDG_SESSION_ID", "")
        with self.locked():
            record = self.read()
            if args.origin == "manual" and record is None:
                self.initialize()
            if args.adopt_pane and record and (self.terminal(record) or self.worker_live(record)
                                               or self.terminal(record.get("predecessor"))):
                # An adopted session would be a second controller beside this one.
                raise Refusal("name-conflict")
            if record and record.get("intent") == "succeed" and record["state"] != "running":
                # Boot reads the transition, never history from its retired owner.
                answer = self.answer(record)
                return answer, 1 if answer["state"] == "failed" else 0
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
            self.env = environment(args.harness, policy=True)
            if args.account is None:
                # orch's resolver reads the harness's own account variable,
                # such as CODEX_HOME, from the caller's environment.
                args.account = self.backend("account", args.harness, env=dict(os.environ)).stdout.strip()
                if not clean(args.account) or not Path(args.account).is_absolute():
                    raise Refusal("record-unreadable")
            account = str(Path(args.account).resolve(strict=True))
            requested = stated = None
            if args.model is not None:
                stated = json.loads(self.backend("choice", args.harness, args.model, args.effort, self.home).stdout)
                requested = {"harness": args.harness, "account": account, "model": stated["model"], "effort": stated["effort"]}
            if args.adopt_pane:
                return self._adopt(args, record, requested or {"harness": args.harness, "account": account, "model": "", "effort": ""},
                                   stated)
            matching = (record and record.get("harness") == args.harness and record.get("account") == account
                        and same_choice(record, requested))
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
                record.setdefault("report_started_at", int(time.time()))
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
            if predecessor is not record and predecessor and predecessor["state"] == "running" and predecessor["harness"] == args.harness and predecessor["account"] == account and same_choice(predecessor, requested):
                # Requests advance generation. A cancelled replacement keeps
                # the live session's binding in pending.generation.
                restored = dict(predecessor, generation=record["generation"] + 1, intent="start", app_off=False,
                                boot=boot or record.get("boot"))
                self.write(restored)
                return self.answer(restored, state="running", reason="existing"), 0
            private = self.private_brief(args)
            history_record = self.confirmed_history(predecessor or record)
            history_matches = (history_record and history_record.get("harness") == args.harness
                               and history_record.get("account") == account and same_choice(history_record, requested))
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
                           "report_started_at": int(time.time()),
                           "origin": args.origin, "boot": boot or (record.get("boot") if record else None),
                           "generation": generation, "state": "starting", "reason": "launching", "detail": "",
                           "app_off": False, "intent": "start", "terminal": None,
                           "launch": {"id": native_id, "file": file, "reason": reason, "brief": start_brief(private)},
                           "private_brief": private, "predecessor": predecessor, "history": history_record}
            # A resumed session keeps the choice it ran on unless Start states one.
            choice = requested or (history_record.get("choice") if reason == "resumed" else None)
            if choice:
                next_record["choice"] = choice
            if stated and stated["warning"]:
                # kendex's line for the stated model, once per launch
                # (crates/cli tier_model.rs); only a launch runs that model.
                print(stated["warning"], file=sys.stderr)
            self.write(next_record)
            self.detach("start", next_record)
            return self.answer(next_record), 0

    def initialize(self):
        # The first manual Start in a home this machine never recorded writes
        # its missing starting files. Boot and app starts never do: an app
        # calls init itself.
        home = home_module()
        if home.complete(self.home):
            return
        try:
            report = home.init(self.home)
        except home.Refused as refusal:
            print(refusal.line(), file=sys.stderr)
            raise Refusal("home-not-dedicated", home.SEPARATE_FOLDER)
        except home.Failed as failure:
            print(failure.line(), file=sys.stderr)
            raise Refusal("launch-failed", "Jarvis could not set up its starting files. Check the init line in the output.", "failed")
        for line in home.settings_lines(report):
            print(line, file=sys.stderr)

    def succeed(self, account_walled=False):
        if not (BACKEND.parents[3] / "orch/scripts").is_dir():
            # Without the lifecycle owner, refuse before taking or ending control.
            raise Refusal("handover-failed", "Orch is not installed. The recorded account cannot start a successor.", "failed")
        with self.locked():
            record = self.read()
            if not record or record.get("app_off"):
                raise Refusal("app-off" if record and record.get("app_off") else "record-unreadable")
            self.env = environment(record["harness"], policy=True)
            spent_account = ""
            transfer = record.get("transfer") or {}
            if record.get("intent") == "succeed" and transfer.get("phase") != "complete":
                spent_account = transfer.get("spent_account", "")
            if record.get("intent") == "succeed" and record["state"] != "running":
                if self.worker_live(record) or self.successor_adopts(record):
                    return self.answer(record), 0
                # End an abandoned waiting or native successor before retrying.
                # Its predecessor remains the only possible controller.
                self.end_owned(record, window=True)
                predecessor = record.get("predecessor")
                predecessor_live = bool(self.terminal(predecessor))
                if not predecessor_live:
                    self.end_task_session()
                saved_handoff = record["transfer"]["handoff"]
            else:
                if record["state"] != "running" or not self.terminal(record):
                    raise Refusal("record-unreadable")
                predecessor = record
                predecessor_live = True
                saved_handoff = transfer["handoff"] if spent_account else None
            if account_walled and not spent_account:
                wall_controller = predecessor if predecessor_live else record
                spent_account = wall_controller.get("account")
                if not spent_account:
                    raise Refusal("record-unreadable")
            choice = record.get("choice") or {}
            choice = json.loads(self.backend("select", record["harness"], record["account"], self.home,
                                             choice.get("model", ""), choice.get("effort", ""), spent_account).stdout)
            if not shutil.which(choice["harness"]):
                raise Refusal("app-missing")
            self.env.pop("CLAUDE_CONFIG_DIR", None)
            if choice["harness"] == "pi" and os.environ.get("CLAUDE_CONFIG_DIR"):
                self.env["CLAUDE_CONFIG_DIR"] = os.environ["CLAUDE_CONFIG_DIR"]
            return self._hand_over(record, choice, predecessor, saved_handoff)

    def _hand_over(self, record, choice, predecessor, saved_handoff):
        # Save the handoff, record the transition and detach its worker: the
        # one route succession and adoption take. The caller holds the lock.
        # Every successor, a retry included, takes the record's stored private brief.
        generation = record["generation"] + 1
        handoff = Path(self.home) / "state/handoff.md"
        contents = handoff.read_bytes()
        if not contents.strip():
            raise Refusal("record-unreadable")
        archive = handoff.parent / "archive"
        archive.mkdir(exist_ok=True)
        saved = archive / ("handoff-" + str(generation) + "-" + uuid.uuid4().hex + ".md")
        with saved.open("xb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        if saved.read_bytes() != contents:
            raise Refusal("record-unreadable")
        transfer = {"phase": "saved", "handoff": str(saved), "previous_handoff": saved_handoff}
        spent_account = choice.pop("spent_account", "")
        if spent_account:
            transfer["spent_account"] = spent_account
        next_record = {"v": 1, "home": self.home, "harness": choice["harness"], "account": choice["account"], "choice": choice,
                       "report_started_at": record.get("report_started_at", int(time.time())),
                       "origin": record["origin"], "boot": record.get("boot"), "app_off": False,
                       "generation": generation, "intent": "succeed", "state": "handing-over", "reason": "succession", "detail": "",
                       "terminal": None, "predecessor": predecessor, "transfer": transfer,
                       "private_brief": record.get("private_brief"),
                       "launch": {"id": str(uuid.uuid4()), "file": "", "reason": "new-requested",
                                  "brief": start_brief(record.get("private_brief"))}}
        next_record["worker"] = json.loads(self.backend("process", os.getpid()).stdout)
        self.write(next_record)
        self.detach("succeed", next_record)
        return self.answer(next_record), 0

    def successor(self, generation):
        # The native session draws this pane, so the runner's diagnostics
        # join the worker's in the session log; the native child keeps the
        # pane's own descriptors.
        self.log_output("succession")
        # The pane's own binding is the native session's alone: a runner that
        # takes the transfer writes into this pane as the worker does, from
        # outside it (pane-write refuses its own pane).
        native_env = dict(self.env, **{key: os.environ[key] for key in ("TMUX", "TMUX_PANE") if key in os.environ})
        self.env = {key: value for key, value in self.env.items() if key not in ("TMUX", "TMUX_PANE")}
        identity = json.loads(self.backend("process", os.getpid()).stdout)
        owner = None
        # This pane waits on the same record. It cannot start native work
        # until the predecessor has ended.
        while time.monotonic() < self.deadline:
            with self.locked():
                record = self.read()
                if not self._current_request(record, generation, "succeed"):
                    return
                phase = record["transfer"]["phase"]
                if not self.worker_live(record):
                    # Any other end of the worker leaves the predecessor in
                    # control, or a failure the worker already wrote.
                    if not self.successor_adopts(record):
                        return
                    # No native session starts beside the predecessor's.
                    process = record["predecessor"].get("process")
                    if not (process and self.worker_live({"worker": process})):
                        owner = self._take_transfer(record, identity)
                if owner or phase not in ("saved", "waiting"):
                    command = record["launch"]["command"]
                    break
            time.sleep(0.2)
        else:
            return
        # The waiting process is already inside its new pane. The native
        # identity hook needs that pane's tmux binding, not the caller's.
        native = subprocess.Popen([BASH, "--noprofile", "--norc", "-c", command + '; result=$?; exit "$result"'],
                                  cwd=self.home, env=native_env)
        try:
            while not owner and native.poll() is None:
                record = self.read()
                if record["generation"] != generation or record.get("intent") != "succeed" or record["transfer"]["phase"] == "complete":
                    return native.wait()
                if not self.worker_live(record):
                    with self.locked():
                        if self.read() != record:
                            continue
                        if self.successor_adopts(record):
                            owner = self._take_transfer(record, identity)
                            continue
                    # The worker's failure path ended this transfer.
                    self.backend("stop-process", identity["pid"], identity["started_at"], record["harness"])
                    return
                time.sleep(0.2)
            if owner:
                return self._finish_transfer(native, generation, owner)
        finally:
            if native.poll() is None:
                native.terminate()
                try:
                    native.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    native.kill()
                    native.wait(timeout=2)
        return native.returncode

    def _take_transfer(self, record, identity):
        # The worker ended after the predecessor did, so this runner finishes
        # the transfer in its place: no host stop of the caller's scope or
        # process tree can then end a successor. From this write, status,
        # Start and a succeed retry read the runner as the live worker. The
        # caller holds the lock. A worker that caught its stop signal
        # recorded the cause; any other end leaves it unknown. A worker that
        # ended between the brief's paste and its record leaves the brief
        # unrecorded, and this runner pastes it again: a repeated brief costs
        # the session one turn, a brief taken as delivered but never pasted
        # fails the transfer at its bound.
        ended = record.get("worker_ended") or {"pid": record["worker"]["pid"], "cause": "unknown"}
        if record["transfer"]["phase"] == "waiting":
            record["transfer"]["phase"] = "predecessor-ended"
            record.update(state="starting", reason="launching")
        record.update(worker=identity, worker_ended=ended)
        # The runner takes the one launch bound a worker has.
        self.deadline = time.monotonic() + CALL_SECONDS
        self.write(record)
        print("jarvis-session: transfer=adopted generation=" + str(record["generation"])
              + " worker=" + str(ended["pid"]) + " cause=" + ended["cause"], flush=True)
        return record["account_var"], record["launch"]["kickoff"]

    def _finish_transfer(self, native, generation, owner):
        # The runner confirms the Start it took as the worker would. Its
        # failure ends the transfer as the worker's own failure after the
        # predecessor's end does, and this pane closes once the runner returns.
        try:
            while native.poll() is None:
                if self._start_pass("succeed", generation, *owner):
                    return native.wait()
                time.sleep(0.2)
            raise Refusal("launch-failed", "The Jarvis session ended before it accepted its Start procedure.", "failed")
        except (Refusal, OSError, ValueError, subprocess.TimeoutExpired) as failure:
            self.failure_log("transfer-failed", failure)
            self.deadline = time.monotonic() + CALL_SECONDS
            with self.locked():
                record = self.read()
                if self._current_request(record, generation, "succeed"):
                    self._fail_transfer(record)
            return 1

    def _fail_transfer(self, record):
        # A succession that fails after its predecessor ended leaves no
        # controller. The caller holds the lock and has closed every
        # successor window but the one it runs in, a runner's, which the
        # record releases first and which then ends with the task windows.
        window = (record.get("terminal") or {}).get("window")
        record.update(state="failed", reason="handover-failed", history=None, terminal=None,
                      detail="Retry jarvis-session succeed for this home. Check the session log if it fails again.")
        record.pop("worker", None)
        self.write(record)
        self.end_task_session(window)

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
                self.detach("stop", record, origin=origin or "manual")
                answer = self.answer(record, state="stopping", reason="stop-requested")
                # Publish while teardown still waits on this lock. Off and
                # the Stopping answer precede the end of the owned session.
                self._emit(answer)
                return answer, 0
            record.update(state="off" if record["app_off"] else "stopped",
                          reason="app-off" if record["app_off"] else "stopped", detail="")
            self.end_task_session()
            self.write(record)
            return self.answer(record), 0

    def end_task_session(self, ending=None):
        # Task windows open in the controller's session, so once no controller
        # remains they alone hold its name against the next Start. One server
        # command ends the session only while every window in it holds a pane
        # with a task mark, the window task-close ends: a controller window, or
        # a foreign session of that name, keeps it. A pane split into a task
        # window, such as a Pi pane agent's, carries no mark of its own.
        # A session left standing refuses that Start with name-conflict, so a
        # failure here is logged and never fails the controller's own end.
        # ENDING names the window of a controller that ends with the session.
        if not shutil.which("tmux"):
            return
        marked = "#{?#{P:#{?#{@jarvis-task},x,}},,x}"
        if ending:
            marked = "#{?#{==:#{window_id}," + ending + "},," + marked + "}"
        unmarked = "#{W:" + marked + "}"
        try:
            self.tmux("if-shell", "-F", "-t", "=jarvis:", "#{==:" + unmarked + ",}", "kill-session -t =jarvis", check=False)
        except (OSError, subprocess.TimeoutExpired) as failure:
            self.failure_log("task-session-end-failed", failure)

    def _stop_process(self, record):
        # Stops the recorded process by its start-time identity, so a reused
        # PID is never signalled. A stale identity is a stop only once that
        # PID has ended: the process may have exited before this call.
        identity = record["process"]
        stopped = self.backend("stop-process", identity["pid"], identity["started_at"], record["harness"], check=False)
        if stopped.returncode:
            sys.stderr.write(stopped.stderr)
            if stopped.returncode != 3 or self.backend("process-ended", identity["pid"], check=False).returncode != 0:
                raise Refusal("handover-failed", "The owned process could not be stopped. Check the stop-process diagnostic before retrying.", "failed")

    def end_owned(self, record, *, window=False):
        ownership = self.ownership(record) if record else None
        # Every end of an adopted session is succession's: its process by
        # identity whatever its pane answers, then that pane alone, never a
        # window or session of the consumer's own.
        adopted = ownership is not None and ownership.kind == "adopted"
        if adopted:
            self._stop_process(record)
        if self.terminal(record):
            pane = record["terminal"]["pane"]
            # tmux evaluates ownership and closes the pane's session in one
            # server command, before another client can reuse that pane id.
            condition = "#{&&:" + ownership.binding + ",#{==:#{pid}," + str(record["server_pid"]) + "}}"
            if window and not adopted and record.get("process"):
                # The start-time check and pane binding both belong to this
                # controller. A reused PID grants no right to close its pane,
                # and an abandoned successor can end itself after the pane check.
                self._stop_process(record)
                if not self.terminal(record):
                    return
                # tmux clears pane_pid at EOF, while a retained dead pane
                # still has this server and generation's ownership marks.
                process_binding = "#{||:#{pane_dead},#{==:#{pane_pid}," + str(record["process"]["pid"]) + "}}"
                condition = "#{&&:" + condition + "," + process_binding + "}"
            action = "kill-pane" if adopted else "kill-window" if window else "kill-session"
            self.tmux("if-shell", "-F", "-t", pane, condition, action + " -t " + pane, socket=record["terminal"]["server"])
            if (window or adopted) and self.terminal(record):
                raise Refusal("handover-failed", "The predecessor's terminal remains open. Retry jarvis-session succeed for this home.", "failed")
            if (window or adopted) and record.get("process"):
                while self.worker_live({"worker": record["process"]}):
                    time.sleep(0.1)
        elif not window:
            self.end_task_session()

    def _start_pass(self, verb, generation, var, kickoff):
        # One pass of a launch's confirmation, True once the request needs no
        # other: the worker's, or a successor runner's that took the transfer.
        # One bound covers native identity and the taking of the Start brief.
        # Backend operations share it; inspection never renews the launch.
        # The pane is read outside the record lock, which holds only each
        # read, decision and write, the brief's paste among them: a native
        # hook's stamp waits on that lock for SESSION_ROWS_WAIT
        # (orch session-rows.sh), 2 s, far above that hold.
        if time.monotonic() >= self.deadline:
            raise Refusal("launch-failed", "Jarvis did not complete Start within its launch bound.", "failed")
        record = self.read()
        if not self._current_request(record, generation, verb):
            return True
        if not self.terminal(record):
            raise Refusal("launch-failed", "The Jarvis session ended before it accepted its Start procedure.", "failed")
        launch, terminal = record["launch"], record["terminal"]
        identity = record.get("pending") or {}
        # The native hook's stamp at the first tool call, or Claude
        # Code turn end, after the brief: the session's own word that
        # it took it. The pane is still read, so a sign-in wall, a
        # trust question or another account refuses the Start before
        # either stamp counts.
        taken = record.get("brief_delivered") and identity.get("brief_taken")
        observed = self.backend(
            "inspect", terminal["server"], terminal["pane"], record["harness"], var, record["account"],
            "confirmed" if identity.get("started_at") else "pending", identity.get("observed_account", ""),
            "delivered" if record.get("brief_delivered") else "undelivered").stdout
        observed, _, dialog = observed.partition("\n")
        with self.locked():
            inspected = record
            record = self.read()
            if not self._current_request(record, generation, verb):
                return True
            # The pane answered for the record it was read against.
            if any(record.get(key) != inspected.get(key) for key in ("pending", "brief_delivered")):
                return False
            if observed == "auth":
                raise Refusal("sign-in-required", "Sign in to " + record["harness"] + " and retry Start.")
            if observed == "wrong-account":
                raise Refusal("selection-conflict")
            if observed == "trust":
                raise Refusal("trust-required", dialog_question(dialog))
            if identity.get("native_session_id") and identity.get("started_at") and observed in ("idle", "working"):
                if verb == "succeed" and not record.get("identity_verified"):
                    record["transfer"]["phase"] = "confirmed"
                record["identity_verified"] = True
                record["history"] = self.confirmed_history(record)
                self.write(record)
            # Copilot CLI and Codex run their kickoff turn first, and
            # the pane cannot tell that turn's first frames, or
            # Copilot's composer during it, from its end: their brief
            # waits for the native turn-end hook's kickoff_ended stamp
            # (orch session-rows.sh), after identity was verified. A
            # kickoff turn's working pane is no turn on the brief, so
            # only the brief-taken stamp then says it took the brief.
            if identity.get("native_session_id") and identity.get("started_at") and not record.get("brief_delivered") and ((record.get("identity_verified") and identity.get("kickoff_ended")) if kickoff else observed in ("idle", "working")):
                prompt = self.path.parent / ("start-" + str(generation) + ".txt")
                stream = prompt.open("x")
                try:
                    with stream:
                        stream.write(launch["brief"])
                    self.backend("deliver", terminal["server"], terminal["pane"], record["harness"], prompt)
                finally:
                    prompt.unlink()
                record["brief_delivered"] = True
                if verb == "succeed":
                    record["transfer"]["phase"] = "brief-delivered"
                self.write(record)
            elif record.get("brief_delivered") and (taken or (observed == "working" and not kickoff)):
                record.update(state="running", reason=launch["reason"], detail="")
                if verb == "succeed":
                    record["transfer"]["phase"] = "complete"
                record.pop("predecessor", None)
                record.pop("launch", None)
                record.pop("controller_state", None)
                self.write(record)
                return True
        return False

    def _terminate(self, signum, frame):
        # A host stop of the caller's scope or process tree signals the
        # worker; the failure path records that cause before it exits.
        if self.terminated is None:
            self.terminated = signal.Signals(signum).name
            raise Terminated(self.terminated)

    def worker(self, verb, generation):
        if verb == "succeed":
            # A Start worker's abrupt end leaves its launch for the next
            # Start to acquire, so only succession records the stop.
            signal.signal(signal.SIGTERM, self._terminate)
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
            choice = record.get("choice") or {}
            prepared = json.loads(self.backend("prepare", record["harness"], record["account"], self.home,
                                               launch["id"], launch["file"], self.path, generation,
                                               choice.get("model", ""), choice.get("effort", ""),
                                               env=self.env).stdout)
            with self.locked():
                record = self.read()
                if not self._current_request(record, generation, verb):
                    return
                succeeding = verb == "succeed"
                predecessor = record.get("predecessor")
                # An adopted predecessor's pane is on another server, so its
                # successor opens the home's session as a first Start does,
                # once task windows a past controller left no longer hold it.
                adopted = predecessor is not None and self.ownership(predecessor).kind == "adopted"
                if not succeeding:
                    self.end_owned(predecessor)
                elif adopted:
                    self.end_task_session()
                existing = self.tmux("has-session", "-t", "=jarvis", check=False)
                if existing.returncode == 0:
                    if not succeeding or adopted or not self.terminal(predecessor):
                        raise Refusal("name-conflict")
                creation = ["new-window", "-d", "-t", "=jarvis"] if succeeding and existing.returncode == 0 else ["new-session", "-d", "-s", "jarvis"]
                # A first launch runs in the pane it creates, held on a tmux
                # channel until the record owns that pane: replacing the pane
                # would free its pty while opening another, which macOS can
                # refuse with ENXIO. A wait that fails or is killed runs no
                # launch. The account observer reads descendants of the pane
                # shell, so the tail keeps that shell from exec-replacing itself.
                channel = "jarvis-launch-" + str(generation)
                runner = [sys.executable, "-B", "-c", "import os,runpy,sys; sys.exit(runpy.run_path(sys.argv[1],run_name='jarvis_runner')['Session'](sys.argv[2], dict(os.environ)).successor(int(sys.argv[3])))", str(Path(__file__).resolve()), self.home, str(generation)] if succeeding else [
                    BASH, "--noprofile", "--norc", "-c", "tmux wait-for " + channel + " && { " + prepared["line"] + '; }; result=$?; exit "$result"']
                with self.pane_command(runner) as command:
                    created = self.tmux(*creation, "-c", self.home,
                                        "-P", "-F", "#{socket_path}\t#{pid}\t#{start_time}\t#{window_id}\t#{pane_id}", *command)
                    socket, server, started, window, pane = created.stdout.strip().split("\t")
                    record.update(terminal={"server": socket, "session": "jarvis", "window": window, "pane": pane},
                                  server_pid=int(server), server_started_at=int(started), effective_home=prepared["effective_home"], account_var=prepared["var"],
                                  pending={"generation": generation, "server": int(server), "pane": pane,
                                           "native_session_id": launch["id"] if record["harness"] != "codex" or launch["file"] else None})
                    # Own the pane before delivery can fail. The first record
                    # write and later setup remain locally owned until saved.
                    acquired = record
                    # A controller's pane closes when its harness exits, which
                    # status reads as ended, whatever the user's config keeps.
                    # The pane waits on its launch until the record owns it.
                    self.tmux("set-option", "-p", "-t", pane, "remain-on-exit", "off")
                if succeeding:
                    process = self.tmux("display-message", "-p", "-t", pane, "#{pane_pid}").stdout.strip()
                    record["process"] = json.loads(self.backend("process", process).stdout)
                    record["launch"].update(command=prepared["line"], kickoff=prepared["kickoff"])
                    record["transfer"]["phase"] = "waiting"
                self.write(record)
                transferred = True
                self.tmux("set-option", "-p", "-t", pane, "@jarvis-generation", generation)
                if succeeding:
                    self.end_owned(record.get("predecessor"), window=True)
                    record["transfer"]["phase"] = "predecessor-ended"
                    record.update(state="starting", reason="launching")
                    self.write(record)
                else:
                    self.tmux("wait-for", "-S", channel)
                    process = self.tmux("display-message", "-p", "-t", pane, "#{pane_pid}").stdout.strip()
                    record["process"] = json.loads(self.backend("process", process).stdout)
                    self.write(record)
            while not self._start_pass(verb, generation, prepared["var"], prepared["kickoff"]):
                time.sleep(0.2)
        except (Refusal, OSError, ValueError, subprocess.TimeoutExpired, Terminated) as failure:
            self.failure_log("worker-failed", failure)
            if verb == "start" and (isinstance(failure, subprocess.TimeoutExpired) or time.monotonic() >= self.deadline):
                failure = Refusal("launch-failed", "Jarvis did not complete Start within its launch bound.", "failed")
            self.deadline = time.monotonic() + CALL_SECONDS
            with self.locked():
                if acquired and not transferred:
                    try:
                        self.end_owned(acquired, window=verb == "succeed")
                    except (Refusal, OSError, ValueError, subprocess.TimeoutExpired) as teardown:
                        self.failure_log("cleanup-failed", teardown)
                record = self.read()
                if not self._current_request(record, generation, verb):
                    raise
                ended = {"pid": os.getpid(), "cause": self.terminated} if self.terminated else None
                if ended and self.successor_adopts(record):
                    # The successor's runner takes the transfer once this
                    # worker exits.
                    record["worker_ended"] = ended
                    self.write(record)
                    raise
                record["history"] = self.confirmed_history(record)
                if verb in ("start", "succeed") and (not acquired or transferred):
                    try:
                        self.end_owned(acquired or record, window=verb == "succeed")
                    except (Refusal, OSError, ValueError, subprocess.TimeoutExpired) as teardown:
                        self.failure_log("cleanup-failed", teardown)
                if acquired and self.terminal(acquired):
                    record.update({key: acquired[key] for key in
                                   ("terminal", "server_pid", "server_started_at", "pending", "effective_home", "account_var")})
                predecessor = record.get("predecessor")
                # An adopted session never becomes a managed record: its
                # transition stands, as a killed worker's does, and succeed
                # retries it.
                live = record if self.terminal(record) else predecessor if self.terminal(predecessor) else None
                if live and self.ownership(live).kind != "adopted":
                    record = self.retain_live(record, live)
                elif not live and verb != "succeed":
                    self.end_task_session()
                    if verb == "stop":
                        record.update(state="off" if record["app_off"] else "stopped",
                                      reason="app-off" if record["app_off"] else "stopped", detail="", terminal=None)
                    else:
                        record.update(state=failure.state if isinstance(failure, Refusal) else "failed",
                                      reason=failure.reason if isinstance(failure, Refusal) else "launch-failed",
                                      detail=failure.detail if isinstance(failure, Refusal) else "Jarvis could not start. Check the session log.",
                                      terminal=None)
                if ended:
                    record["worker_ended"] = ended
                if not live and verb == "succeed":
                    self._fail_transfer(record)
                else:
                    record.pop("worker", None)
                    self.write(record)
            raise


class Arguments(argparse.ArgumentParser):
    def error(self, message):
        print("jarvis-session: arguments=invalid", file=sys.stderr)
        raise SystemExit(2)


def main_host(args):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import watch

    value = args.set if args.set is not None else ""
    if not args.get and watch.role({"JARVIS_MAIN_HOST": value}).kind == "invalid":
        print("jarvis-session: main-host=refused cause=setting-invalid", file=sys.stderr)
        return 2
    # Read the selected path and this one value through the same owner as
    # watch.config. Private-file diagnostics can contain other secret values.
    reader = r'''
source "$1/jarvis-env.sh"
kendex_project_env_supports selected-private-path || exit 1
kendex_load_project_env "$2" _jarvis_selected_private || exit 1
export JARVIS_MAIN_HOST="${JARVIS_MAIN_HOST:-}"
exec "$3" -c 'import json, os, sys; print(json.dumps([sys.argv[1], os.environ["JARVIS_MAIN_HOST"]]))' "$_jarvis_selected_private"
'''
    cause = "settings-unreadable"
    try:
        home = Path(args.home).resolve(strict=True)
        result = subprocess.run([BASH, "-c", reader, "jarvis-main-host", str(BACKEND.parent), str(home), sys.executable],
                                cwd=home, capture_output=True, text=True, timeout=CALL_SECONDS)
        if result.returncode:
            raise Refusal(cause)
        private, current = json.loads(result.stdout)
        if args.get:
            value = current
        else:
            # A credential save's rule (crates/core/src/settings_secret/
            # destination.rs): git must not carry the private file. A new
            # file gets the exact ignore line first; an existing one refuses.
            cause = "private-file-unwritable"
            path = (home / private).resolve()
            destinations = [(home, os.path.relpath(home / private, home))]
            # Worktree homes share private files through a final file link.
            # Its target's checkout determines whether the written bytes leak.
            if path != home / private:
                destinations.append((path.parent, path.name))
            redirects = home_module().GIT_REDIRECTS
            env = {key: value for key, value in os.environ.items() if key not in redirects}
            env["LC_ALL"] = "C"
            for directory, named in destinations:
                git = {"cwd": directory, "capture_output": True, "timeout": CALL_SECONDS, "env": env}
                check = ["git", "check-ignore", "-q", "--", named]
                cause = "git-unreadable"
                inside = subprocess.run(["git", "rev-parse", "--is-inside-work-tree"], **git)
                if inside.returncode == 0:
                    listed = subprocess.run(["git", "ls-files", "-z", "--", named], **git)
                    ignored = subprocess.run(check, **git).returncode
                    if listed.returncode or ignored not in (0, 1):
                        raise Refusal(cause)
                    pattern = "/" + re.sub(r"([*?\[\]])", r"\\\1", named)
                    pattern = pattern[:-1] + "\\ " if pattern.endswith(" ") else pattern
                    if listed.stdout:
                        raise Refusal("private-file-tracked", "run git rm --cached -- " + named + " and commit that")
                    if ignored and (directory / named).exists():
                        raise Refusal("private-file-unignored", "add " + pattern + " to .gitignore")
                    if ignored:
                        cause = "gitignore-unwritable"
                        ignore = (directory / ".gitignore").resolve()
                        existed = ignore.exists()
                        text = ignore.read_bytes() if existed else b""
                        with open(ignore, "ab") as stream:
                            stream.write((b"\n" if text and not text.endswith(b"\n") else b"") + pattern.encode() + b"\n")
                        try:
                            # Asked again before the write, as the credential save
                            # does: a deeper .gitignore's ! rule, or a .gitignore
                            # git will not read, leaves the line without effect.
                            cause = "git-unreadable"
                            ignored = subprocess.run(check, **git).returncode
                            if ignored not in (0, 1):
                                raise Refusal(cause)
                            if ignored:
                                raise Refusal("private-file-unignored", "make git ignore " + named
                                              + " (git check-ignore -v -n -- " + named + " names the rule that decides it)")
                        except (Refusal, OSError, subprocess.SubprocessError):
                            # A failed check must not leave another ignore line
                            # for each retry, as the credential save rolls back.
                            try:
                                if existed:
                                    os.truncate(ignore, len(text))
                                else:
                                    ignore.unlink()
                            except OSError:
                                raise Refusal("gitignore-unwritable")
                            raise
                # Only Git's normal discovery failures mean there is no repository;
                # a dangling gitdir instead reports "not a git repository: <dir>".
                elif not any(phrase in inside.stderr for phrase in
                             (b"not a git repository (or any ", b"not a working tree")):
                    raise Refusal(cause)
            cause = "private-file-unwritable"
            # A final assignment preserves arbitrary Bash, including multiline
            # secrets. Follow the loader's supported file symlink layout.
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with os.fdopen(os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600), "ab") as stream:
                stream.write(("\nJARVIS_MAIN_HOST=" + shlex.quote(value) + "\n").encode("utf-8"))
        print(json.dumps({"JARVIS_MAIN_HOST": value}))
        return 0
    except Refusal as refusal:
        print("jarvis-session: main-host=refused cause=" + refusal.reason, file=sys.stderr)
        if refusal.detail:
            print("jarvis-session: fix: " + refusal.detail + ", then run main-host again", file=sys.stderr)
        return 2
    except (OSError, ValueError, subprocess.SubprocessError):
        print("jarvis-session: main-host=refused cause=" + cause, file=sys.stderr)
        return 2


def init_home(args):
    home = home_module()
    try:
        report = home.init(args.home)
    except home.Refused as refusal:
        print(refusal.line(), file=sys.stderr)
        print(home.SEPARATE_FOLDER, file=sys.stderr)
        return 1
    except home.Failed as failure:
        print(failure.line(), file=sys.stderr)
        return 1
    for line in home.settings_lines(report):
        print(line, file=sys.stderr)
    print(json.dumps(report, separators=(",", ":")))
    return 0


def main():
    parser = Arguments()
    verbs = parser.add_subparsers(dest="verb", required=True, parser_class=Arguments)
    for verb in ("start", "status", "stop", "succeed", "update-brief", "report-due", "attach", "forward", "forward-drain",
                 "main-host", "init"):
        command = verbs.add_parser(verb)
        command.add_argument("--home", required=True)
        if verb == "status":
            # The default answer's key set is the VGS-1439 contract; --main is a separate shape.
            command.add_argument("--main", action="store_true")
        elif verb == "forward":
            # Text crosses this file, never argv.
            command.add_argument("--record", required=True)
        elif verb == "main-host":
            operation = command.add_mutually_exclusive_group(required=True)
            operation.add_argument("--set")
            operation.add_argument("--clear", action="store_true")
            operation.add_argument("--get", action="store_true")
        elif verb == "update-brief":
            command.add_argument("--brief-file", required=True)
        if verb == "start":
            command.add_argument("--harness", choices=("claude", "codex", "copilot", "pi"), required=True)
            # A person's Start names only the harness; an app states every value.
            command.add_argument("--account")
            command.add_argument("--mode", choices=("resume", "new"), default="new")
            command.add_argument("--origin", choices=("boot", "manual", "app-on"), default="manual")
            command.add_argument("--brief-file")
            command.add_argument("--model")
            command.add_argument("--effort")
            command.add_argument("--adopt-pane")
            command.add_argument("--adopt-pid", type=int)
        elif verb == "stop":
            command.add_argument("--origin", choices=("app-off",))
        elif verb == "succeed":
            command.add_argument("--account-walled", action="store_true")
    args = parser.parse_args()
    if not clean(args.home) or (args.verb == "start" and args.account is not None and not clean(args.account)):
        parser.error("path")
    if args.verb == "start" and ((args.model is None) != (args.effort is None) or not all(
            value is None or clean(value) and value and ":" not in value for value in (args.model, args.effort))):
        # One preference entry carries both, colon-separated.
        parser.error("choice")
    if args.verb == "start" and (args.adopt_pane is None) != (args.adopt_pid is None):
        parser.error("adopt")
    if args.verb == "start" and args.adopt_pane is not None and not (
            clean(args.adopt_pane) and args.adopt_pane and args.adopt_pid > 0 and args.origin == "manual" and args.mode == "new"):
        # Adoption replaces a running session with a new one, at a person's request.
        parser.error("adopt")
    if args.verb == "forward" and not (clean(args.record) and args.record):
        parser.error("record")
    if args.verb == "main-host":
        return main_host(args)
    if args.verb == "init":
        try:
            Path(args.home).resolve(strict=True)
        except OSError:
            parser.error("home")
        return init_home(args)
    if args.verb in ("forward", "forward-drain") or (args.verb == "status" and args.main):
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import forward
        return forward.main(args, home_state)
    try:
        session = Session(args.home)
    except OSError:
        parser.error("home")
    if args.verb == "attach":
        # Attach answers on stderr only: stdout is the terminal it hands over.
        try:
            session.attach()
        except Refusal as failure:
            print("jarvis-session: attach=refused cause=" + failure.reason, file=sys.stderr)
            if failure.detail:
                print(failure.detail, file=sys.stderr)
            return 1
        return 0
    try:
        if args.verb == "start":
            answer, code = session.start(args)
        elif args.verb == "stop":
            answer, code = session.stop(args.origin)
        elif args.verb == "succeed":
            answer, code = session.succeed(args.account_walled)
        elif args.verb == "update-brief":
            answer, code = session.update_brief(args)
        elif args.verb == "report-due":
            answer, code = session.report_due()
        else:
            answer, code = session.answer(session.read()), 0
            if answer["terminal"]:
                print("jarvis-session: attach=" + shlex.quote(str(ENTRY)) + " attach --home " + shlex.quote(session.home),
                      file=sys.stderr)
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
