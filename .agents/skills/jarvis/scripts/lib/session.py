"""One controller per home: agent-runtime's controller record holds it."""

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid


BACKEND = Path(__file__).with_name("session-backend.sh")
# The package's own command, which no install puts on PATH.
ENTRY = Path(__file__).resolve().parent.parent / "jarvis-session"
SKILLS = Path(__file__).resolve().parents[3]
AGENT_RUNTIME = SKILLS / "agent-runtime/scripts/agent-runtime"
ORCH_RUNTIME = SKILLS / "orch/scripts/orch-runtime"
LANE_MAIL = SKILLS / "mailbox/scripts/lane-mail"
BASH = os.environ["JARVIS_BASH"]
# VGS bounds each call at 60 seconds. Leave time to print its answer.
CALL_SECONDS = 55
START_BRIEF = (
    "Read .agents/skills/jarvis/SKILL.md. Read and follow the Start section using "
    "`.agents/skills/jarvis/scripts/jarvis-section .agents/skills/jarvis/workflows/session.md 'Start'`. "
    "Read each other named section with `jarvis-section` when its step comes, using its owning file and exact heading."
)
STATE_REASONS = {
    "running": {"resumed", "new-no-record", "new-history-gone", "new-selection-changed", "new-requested", "existing"},
    "starting": {"launching"}, "handing-over": {"succession"}, "stopping": {"stop-requested"},
    "stopped": {"never-started", "stopped", "ended"}, "off": {"app-off"},
    "blocked": {"app-off", "name-conflict", "record-unreadable", "sign-in-required", "selection-conflict", "tmux-missing", "app-missing",
                "trust-required", "home-not-dedicated"},
    "failed": {"launch-failed", "handover-failed"},
}
# The seat the controller record keeps through every hand-over: the turn end
# hands a seat that names it Jarvis's own succession.
SEAT = "jarvis"
# The tmux session and window the seat runs in on the home's private server.
SESSION_NAME = "jarvis"
# What a failed attempt's note tells the person, by agent-runtime's note.
BLOCKED_NOTES = {"successor-not-signed-in": "sign-in-required", "successor-wrong-account": "selection-conflict"}
# Published user-manager policy only; shell-only exports are outside this
# contract. Extend this one list through a package change.
POLICY_NAMES = ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "AGENT_RUNTIME_ACCOUNT_RETIRE", "AGENT_RUNTIME_ACCOUNT_ALIASES",
                "FLEET_USER", "AGENT_TMPDIR", "CLAUDE_CODE_TMPDIR")
# An intent of agent-runtime's open on the controller record, by its op.
OPEN_STATES = {"start-controller": ("starting", "launching"), "request-transfer": ("handing-over", "succession"),
               "stop-controller": ("stopping", "stop-requested")}


class Refusal(Exception):
    def __init__(self, reason, detail="", state="blocked"):
        self.reason, self.detail, self.state = reason, detail, state


def clean(value):
    return isinstance(value, str) and all(c.isprintable() for c in value)


def short(text):
    # The answer holds a detail of at most 200 printable characters.
    return "".join(c for c in text if c.isprintable())[:200]


def start_brief(private):
    return START_BRIEF + " " + private if private else START_BRIEF


def setup_problem(harness, account):
    # Trust preparation writes the onboarding marker. Read it before that
    # write: only the account owner can finish the harness's first-run UI.
    if harness != "claude":
        return None
    path = Path(account) / ".claude.json"
    try:
        ready = json.loads(path.read_text()).get("hasCompletedOnboarding") is True
    except FileNotFoundError:
        ready = False
    except (OSError, ValueError, AttributeError) as failure:
        raise Refusal("record-unreadable", str(path) + ": " + str(failure)) from failure
    if not ready:
        return "open claude once with CLAUDE_CONFIG_DIR=" + shlex.quote(str(account)) + " and finish its first-run setup, then retry"
    return None


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
        names = POLICY_NAMES
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


class Session:
    def __init__(self, home, env=None):
        self.home = str(Path(home).resolve(strict=True))
        state = home_module().home_state(self.home)
        self.path = state / "jarvis-session.json"
        # tmux places its socket in its own runtime root, whose pathname fits
        # Unix socket limits even when XDG_STATE_HOME is a deep directory.
        self.label = "jarvis-" + state.name[:32]
        # Where tmux(1) puts the socket `-L LABEL` names, whether or not its
        # server runs now: a reconcile reads a server that ended there too.
        self.socket = str(Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / ("tmux-" + str(os.getuid())) / self.label)
        self.deadline = time.monotonic() + CALL_SECONDS
        self.env = environment() if env is None else env
        self.emitted = False
        self.fleet_path = None

    def run(self, argv, *, input=None, check=True, env=None, timeout=None, encoding=None):
        remaining = self.deadline - time.monotonic() if timeout is None else timeout
        if remaining <= 0:
            raise subprocess.TimeoutExpired(argv, CALL_SECONDS)
        try:
            result = subprocess.run(argv, input=input, text=True, encoding=encoding, capture_output=True,
                                    cwd=self.home, env=env or self.env, timeout=remaining)
        except subprocess.TimeoutExpired as error:
            # A call past its deadline keeps the stderr it held, such as a
            # runtime wrapper's setup-building line for the build it waited
            # on; the caller's answer stands.
            held = error.stderr or b""
            print("jarvis-session: operation=" + " ".join(map(str, argv[:3])) + " timeout=" + str(error.timeout),
                  file=sys.stderr)
            print(held.decode(errors="backslashreplace") if isinstance(held, bytes) else held, end="",
                  file=sys.stderr)
            raise
        if check and result.returncode:
            print("jarvis-session: operation=" + " ".join(argv[:3]) + " exit=" + str(result.returncode), file=sys.stderr)
            print(result.stderr, end="", file=sys.stderr)
            raise Refusal("launch-failed", "The session operation failed. Check the Jarvis session log.", "failed")
        return result

    def backend(self, verb, *args, check=True, env=None):
        return self.run([BASH, str(BACKEND), verb, *map(str, args)], check=check, env=env)

    def tmux(self, *args, check=True, socket=None, encoding=None):
        # The server this starts reads the user's own tmux config, found by
        # tmux's own search, or runs on tmux's defaults where there is none:
        # the attached session looks and behaves as the user's others do.
        target = ["-S", socket] if socket else ["-L", self.label]
        return self.run(["tmux", *target, *map(str, args)], check=check, encoding=encoding)

    def runtime(self, *args, timeout=None):
        """agent-runtime's reply to ARGS: (result, status, refusal key, stderr).

        The caller's own environment reaches it, since its settings and its
        installed binary are read from there, with the user manager's
        published policy over it; the window a launch opens inherits the
        private server's environment instead."""
        env = dict(os.environ, **{name: self.env[name] for name in POLICY_NAMES if name in self.env})
        result = self.run([str(AGENT_RUNTIME), *map(str, args)], check=False, env=env, timeout=timeout)
        try:
            reply = json.loads(result.stdout.splitlines()[-1])
        except (IndexError, ValueError):
            print("jarvis-session: operation=agent-runtime " + str(args[0]) + " " + str(args[1])
                  + " exit=" + str(result.returncode), file=sys.stderr)
            print(result.stderr, end="", file=sys.stderr)
            raise Refusal("launch-failed", "agent-runtime did not answer. Check the Jarvis session log.", "failed")
        refusal = (reply.get("refusal") or {}).get("key")
        return reply.get("result"), result.returncode, refusal, result.stderr

    def fleet(self):
        """The home's controller record: orch's fleet record under its state directory."""
        if self.fleet_path is None:
            result = self.run([str(ORCH_RUNTIME), "state", "path", "--fleet"], check=False, env=dict(os.environ))
            try:
                self.fleet_path = Path(json.loads(result.stdout.splitlines()[-1])["result"]["path"])
            except (IndexError, KeyError, TypeError, ValueError):
                print("jarvis-session: operation=orch-runtime state path exit=" + str(result.returncode), file=sys.stderr)
                print(result.stderr, end="", file=sys.stderr)
                raise Refusal("record-unreadable")
        return self.fleet_path

    def initialized_fleet(self):
        # A home's first start writes its fleet record, whose owner is orch.
        if not self.fleet().exists():
            result = self.run([str(ORCH_RUNTIME), "state", "init", "--fleet"], check=False, env=dict(os.environ))
            if result.returncode:
                print("jarvis-session: operation=orch-runtime state init exit=" + str(result.returncode), file=sys.stderr)
                print(result.stderr, end="", file=sys.stderr)
                raise Refusal("record-unreadable")

    def reach(self, socket):
        # The owner notice a failed attempt owes lands in this home's
        # overseer mailbox; the windows open on the home's private server.
        return ["--record", self.fleet(), "--mail-program", LANE_MAIL, "--mail-root", self.home, "--socket", socket]

    def read(self):
        try:
            with self.path.open() as stream:
                record = json.load(stream)
            if not isinstance(record, dict) or record.get("v") != 2 or record.get("home") != self.home:
                raise ValueError("record")
            for field in ("private_brief", "reason", "origin", "boot"):
                if record.get(field) is not None and not clean(record[field]):
                    raise ValueError(field)
            failure = record.get("failure")
            if failure is not None and (failure.get("reason") not in STATE_REASONS.get(failure.get("state"), set())
                                        or not clean(failure.get("detail", "")) or len(failure.get("detail", "")) > 200):
                raise ValueError("failure")
            return record
        except FileNotFoundError:
            return None
        except (OSError, ValueError, TypeError, AttributeError):
            raise Refusal("record-unreadable")

    def write(self, record):
        # Exclusive scratch acquisition prevents replacement of another
        # writer's staging file. Every caller holds the record's lock.
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
        with open(str(self.path) + ".lock", "a") as lock:
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= min(self.deadline, time.monotonic() + 12):
                        raise Refusal("record-unreadable")
                    time.sleep(0.05)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def fresh(self, origin, boot):
        return {"v": 2, "home": self.home, "origin": origin, "boot": boot, "app_off": False,
                "report_started_at": None, "private_brief": None, "reason": None, "intent": None, "failure": None}

    def status(self, reconcile=True):
        """agent-runtime's status of the home's controller, its open intents
        reconciled first where any stands: an intent whose owner still runs
        is left as it is. None where the home recorded no controller."""
        result, code, refusal, _ = self.runtime("controller", "status", "--record", self.fleet())
        if refusal == "record-missing":
            return None
        if code:
            raise Refusal("record-unreadable")
        recorded = result.get("recorded") or {}
        if reconcile and result.get("open_intents"):
            self.runtime("controller", "reconcile", *self.reach(recorded.get("server_socket") or self.socket))
            result, code, refusal, _ = self.runtime("controller", "status", "--record", self.fleet())
            if code:
                raise Refusal("record-unreadable")
        return result

    def terminal(self, status):
        """The live controller's pane on its server: its session and window read there."""
        recorded = (status or {}).get("recorded") or {}
        socket, pane = recorded.get("server_socket"), recorded.get("pane")
        if not (status or {}).get("live") or not socket or not pane:
            return None
        if not shutil.which("tmux"):
            raise Refusal("tmux-missing")
        # tmux replaces format tabs with underscores for a non-UTF-8 client.
        read = self.tmux("-u", "display-message", "-p", "-t", pane, "#{session_name}\t#{window_id}\t#{pane_id}",
                         check=False, socket=socket, encoding="utf-8")
        fields = read.stdout.strip().split("\t")
        if read.returncode or len(fields) != 3 or fields[2] != pane:
            return None
        return {"server": socket, "session": fields[0], "window": fields[1], "pane": pane}

    def controller(self):
        """The live controller for a task launched beside it: its terminal and its server's identity."""
        status = self.status()
        terminal = self.terminal(status)
        if not terminal:
            return None
        recorded = status["recorded"]
        return {"terminal": terminal, "server_pid": int(recorded["server"]), "server_started_at": int(recorded["server_start"])}

    def answer(self, record=None, status=None, *, state=None, reason=None, detail=""):
        terminal = None
        recorded = (status or {}).get("recorded") or {}
        if state is None:
            open_ops = [intent["op"] for intent in (status or {}).get("open_intents", [])]
            terminal = self.terminal(status)
            failure = (record or {}).get("failure")
            opened = next((OPEN_STATES[op] for op in open_ops if op in OPEN_STATES), None)
            if opened:
                state, reason = opened
            elif terminal:
                state, reason = "running", (record or {}).get("reason") or "existing"
            elif failure:
                state, reason, detail = failure["state"], failure["reason"], failure["detail"]
            elif record and record.get("app_off"):
                state, reason = "off", "app-off"
            elif not record and not recorded:
                state, reason = "stopped", "never-started"
            else:
                state, reason = "stopped", "stopped" if (record or {}).get("intent") == "stop" else "ended"
        return {"v": 1, "state": state, "reason": reason,
                "home": self.home, "harness": recorded.get("harness"), "account": recorded.get("account"),
                "origin": (record or {}).get("origin"), "boot": (record or {}).get("boot"),
                "terminal": terminal, "detail": detail}

    def attach(self):
        # Lock-free, as status reads: the answer names the live controller,
        # a predecessor's during succession included.
        try:
            terminal = self.terminal(self.status())
        except (OSError, ValueError, subprocess.TimeoutExpired):
            raise Refusal("record-unreadable")
        if not terminal:
            raise Refusal("no-controller")
        argv = ["tmux", "-S", terminal["server"], "attach-session", "-t", "=" + terminal["session"]]
        # The caller's own environment holds its live desktop. A window
        # holding its TMUX or TMUX_PANE reads as a pane of
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
            if opened.returncode == 3:
                raise Refusal("terminal-unresolved", opened.stderr.strip())
            if opened.returncode != 0:
                raise Refusal("terminal-launch-failed", opened.stderr.strip())
            return
        os.execvp("tmux", argv)

    def _emit(self, answer):
        print(json.dumps(answer, separators=(",", ":")), flush=True)
        self.emitted = True

    def report_due(self):
        # The controller owns the session start; orch owns cadence and receipts.
        record = self.read()
        if not record or not record.get("report_started_at"):
            raise Refusal("record-unreadable")
        result = self.run([str(ORCH_RUNTIME), "report", "due", "--session-start", str(record["report_started_at"])],
                          check=False, env=os.environ)
        self.emitted = True
        code, line = result.returncode, None
        try:
            if not code:
                line = json.loads(result.stdout.splitlines()[-1])["result"]["line"]
        except (IndexError, KeyError, TypeError, ValueError):
            code = 1
        if code:
            print("jarvis-session: operation=orch-runtime report due exit=" + str(result.returncode), file=sys.stderr)
            sys.stderr.write(result.stdout + result.stderr)
        elif line:
            print(line)
        return None, code

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
            # A start or a hand-over already holds its delivery text.
            if not record or record.get("app_off"):
                raise Refusal("record-unreadable")
            answer = self.answer(record, self.status())
            if answer["state"] != "running":
                raise Refusal("record-unreadable")
            record["private_brief"] = private
            self.write(record)
            return answer, 0

    def server(self, harness):
        """The home's private tmux server and its one session, made where none
        stands: an idle shell the first start runs its controller in."""
        if not shutil.which("tmux"):
            raise Refusal("tmux-missing")
        read = self.tmux("display-message", "-p", "-t", "=" + SESSION_NAME + ":", "#{socket_path}", check=False)
        if read.returncode == 0 and read.stdout.strip():
            return read.stdout.strip()
        # The server's environment is what every window it opens inherits.
        env = environment(harness, policy=True)
        made = self.run([*self.server_scope(env), "tmux", "-L", self.label, "new-session", "-d", "-s", SESSION_NAME, "-n", SESSION_NAME,
                         "-c", self.home, "-P", "-F", "#{socket_path}"], env=env)
        return made.stdout.strip()

    def server_scope(self, env):
        # A service's stop must not stop the server it started. A login
        # session keeps its own lifetime, independent of the user manager.
        try:
            cgroup = Path("/proc/self/cgroup").read_text()
        except OSError:
            return []
        own = next((line[3:] for line in cgroup.splitlines() if line.startswith("0::")), "")
        parts = own.split("/")
        manager = next((i for i, part in enumerate(parts) if part == "user@" + str(os.getuid()) + ".service"), None)
        if manager is None:
            return []
        slice_name = next((part for part in reversed(parts[manager + 1:]) if part.endswith(".slice")), None)
        if not slice_name:
            return []
        scope = ["systemd-run", "--user", "--scope", "--quiet", "--collect", "--slice=" + slice_name]
        try:
            probe = self.run([*scope, "true"], check=False, env=env)
            cause = None if probe.returncode == 0 else (probe.stderr.strip().split("\n")[0] or "exit=" + str(probe.returncode))
        except OSError as failure:
            cause = type(failure).__name__ + ": " + str(failure)
        if cause is None:
            return scope
        print("jarvis-session: tmux-scope=unavailable slice=" + slice_name + " cause=" + json.dumps(cause), file=sys.stderr)
        return []

    def unattended(self, harness):
        # The home names the harnesses whose managed session runs with nobody
        # at its pane: those launch under the full bypass.
        result = self.backend("unattended", harness, self.home, check=False)
        if result.returncode:
            print(result.stderr, end="", file=sys.stderr)
            raise Refusal("record-unreadable")
        return "named" in result.stdout.split()

    def ready_successor(self, *args, recorded=None):
        words = list(args)
        while True:
            result, code, refusal, errors = self.runtime(*words)
            successor = (result or {}).get("successor")
            if code or not successor:
                return result, code, refusal, errors
            account = successor.get("account") or self.env["HOME"]
            problem = setup_problem(successor["harness"], account)
            if not problem:
                return result, code, refusal, errors
            name = Path(account).name
            excluded = self.env.get("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "").split(",")
            if name in excluded:
                raise Refusal("selection-conflict", "The setup exclusion did not reach " + account + ".")
            self.env["AGENT_RUNTIME_ACCOUNT_EXCLUDE"] = ",".join([*filter(None, excluded), name])
            print("jarvis-session: successor-lane-excluded account=" + account
                  + " reason=harness-setup-pending fix=" + problem, file=sys.stderr)
            # A context mark keeps its caller's account unpicked. An account
            # that cannot finish setup must instead leave that seat.
            if account == (recorded or {}).get("account") and "--mark" in words:
                words[words.index("--mark") + 1] = "headroom"

    def choose(self, args, recorded):
        """The pending a start opens: the recorded launch resumed where the
        person asks for it and states nothing else, else the stated account,
        else the account the controller walk picks for the stated harness."""
        resumable = (args.mode == "resume" and recorded.get("session_id") and recorded.get("harness") == args.harness
                     and (args.account is None or recorded.get("account") == args.account)
                     and (args.model is None or recorded.get("model") == args.model))
        if resumable:
            result, code, refusal, errors = self.runtime("controller", "successor", "--record", self.fleet(), "--resume")
            if not code:
                return result["successor"], "resumed"
            if refusal != "session-missing":
                sys.stderr.write(errors)
                raise Refusal("record-unreadable")
            reason = "new-history-gone"
        elif recorded.get("harness"):
            same = recorded.get("harness") == args.harness and recorded.get("account") in (None, args.account)
            reason = "new-requested" if same or args.account is None else "new-selection-changed"
        else:
            reason = "new-no-record"
        pending = {"harness": args.harness}
        if args.model is not None or args.account is None:
            # The walk is the one judge of an account and the one reader of a
            # model's class; a stated account takes the walk's model alone.
            entry = ":".join([args.harness] + ([args.model, args.effort] if args.model is not None else []))
            chooser = self.ready_successor if args.account is None else self.runtime
            result, code, refusal, errors = chooser("controller", "successor", "--record", self.fleet(),
                                                    "--cwd", self.home, "--preference", entry)
            if code or not result.get("successor"):
                sys.stderr.write(errors)
                print("jarvis-session: selection-failed walk=" + json.dumps((result or {}).get("walk")), file=sys.stderr)
                raise Refusal("selection-conflict")
            pending = result["successor"]
        if args.account is not None:
            pending["account"] = str(Path(args.account).resolve(strict=True))
            pending.pop("home", None)
        pending["cwd"] = self.home
        # The handoff each successor reads; the record keeps it for every
        # later hand-over.
        pending["handoff"] = str(Path(self.home) / "state/handoff.md")
        if self.unattended(args.harness):
            pending.update(permission="bypass", extra_args=[])
        else:
            pending.update(permission="native", extra_args=[])
        return pending, reason

    def start(self, args):
        boot = None
        if args.origin == "boot":
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip() + ":" + os.environ.get("XDG_SESSION_ID", "")
        with self.locked():
            record = self.read()
            if args.origin == "manual" and record is None:
                self.initialize()
            if not shutil.which("tmux"):
                raise Refusal("tmux-missing")
            status = self.status()
            if boot and record and record.get("boot") == boot:
                return self.answer(record, status), 0
            record = record or self.fresh(args.origin, boot)
            if boot:
                record["boot"] = boot
            if args.origin == "app-on":
                record["app_off"] = False
            if record.get("app_off"):
                self.write(record)
                if boot:
                    return self.answer(record, status), 0
                return self.answer(record, status, state="blocked", reason="app-off"), 1
            answer = self.answer(record, status)
            if answer["state"] in ("starting", "handing-over", "stopping"):
                self.write(record)
                return answer, 0
            if not shutil.which(args.harness):
                raise Refusal("app-missing")
            self.env = environment(args.harness, policy=True)
            recorded = (status or {}).get("recorded") or {}
            if args.adopt_pane:
                if answer["state"] == "running":
                    # An adopted session would be a second controller beside this one.
                    raise Refusal("name-conflict")
                return self._adopt(args, record)
            if answer["state"] == "running":
                matching = (recorded.get("harness") == args.harness
                            and args.account in (None, recorded.get("account"))
                            and args.model in (None, recorded.get("model")))
                if matching:
                    record.update(origin=record.get("origin") or args.origin, app_off=False)
                    record.setdefault("report_started_at", int(time.time()))
                    self.write(record)
                    return self.answer(record, status, state="running", reason="existing") | {"terminal": answer["terminal"]}, 0
                # Another selection replaces the running controller: its stop
                # settles before the new start opens.
                self.runtime("controller", "stop", *self.reach(recorded["server_socket"]), "--effect-exit")
                status = self.status()
                recorded = (status or {}).get("recorded") or {}
            self.initialized_fleet()
            pending, reason = self.choose(args, recorded)
            problem = setup_problem(pending["harness"], pending.get("account") or self.env["HOME"])
            if problem:
                raise Refusal("trust-required", problem)
            socket = self.server(pending["harness"])
            private = self.private_brief(args)
            record.update(origin=args.origin, app_off=False, report_started_at=int(time.time()), private_brief=private,
                          reason=reason, intent="start", failure=None)
            self.write(record)
            self.detach(dict(pending, window=SESSION_NAME, seat=SEAT), socket, start_brief(private))
            # The detached start records its outcome under this lock, so until
            # this call returns a start that is not running is still starting.
            answer = self.answer(record, self.status())
            return (answer if answer["state"] == "running" else
                    self.answer(record, state="starting", reason="launching")), 0

    def detach(self, pending, socket, brief):
        # The start runs to its confirmation past this call's bound, so a
        # process of its own runs it and records a failure's words here.
        state = self.path.parent
        brief_file = state / ("start-brief-" + uuid.uuid4().hex + ".txt")
        brief_file.write_text(brief)
        request = state / ("start-request-" + uuid.uuid4().hex + ".json")
        request.write_text(json.dumps({"controller": pending, "brief_file": str(brief_file), "session": SESSION_NAME}))
        record = self.read()
        record["start_request"] = str(request)
        self.write(record)
        with (state / "session.log").open("a") as log:
            subprocess.Popen([sys.executable, "-B", "-c",
                              "import os, runpy, sys; runpy.run_path(sys.argv[1], run_name='jarvis_start')['Session'](sys.argv[2], dict(os.environ)).started(sys.argv[3], sys.argv[4], sys.argv[5])",
                              str(Path(__file__).resolve()), self.home, str(request), str(brief_file), socket],
                             stdin=subprocess.DEVNULL, stdout=log, stderr=log, cwd=self.home,
                             env=dict(os.environ, JARVIS_BASH=BASH), start_new_session=True)
        # The answer reads the start's intent once it stands.
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            status = self.status()
            if status and (status.get("open_intents") or status.get("live")):
                return
            if request.exists() is False:
                return
            time.sleep(0.1)

    def started(self, request, brief_file, socket):
        """The detached start: agent-runtime's start, its failure's words kept for the answer."""
        try:
            self.deadline = time.monotonic() + 3600
            if (self.read() or {}).get("start_request") != request:
                return
            print("jarvis-session: start record=" + str(self.fleet()) + " socket=" + socket, flush=True)
            try:
                result, code, refusal, errors = self.runtime("controller", "start", *self.reach(socket),
                                                             "--request", request, "--effect-exit", timeout=3600)
            except Refusal as failure:
                # A start that ended without its answer is failed all the same.
                print("jarvis-session: start refused " + failure.reason, flush=True)
                self.start_failed(request, {"state": failure.state, "reason": failure.reason,
                                            "detail": short(failure.detail)})
                return
            print("jarvis-session: start exit=" + str(code) + " " + json.dumps(result if result else refusal))
            sys.stdout.write(errors)
            with self.locked():
                record = self.read()
                if (record or {}).get("start_request") != request:
                    if record and record.get("intent") == "stop":
                        status = self.status()
                        if (status or {}).get("live"):
                            _, stopped, _, errors = self.runtime("controller", "stop", *self.reach(socket),
                                                                 "--effect-exit", timeout=3600)
                            if stopped:
                                sys.stderr.write(errors)
                                raise Refusal("record-unreadable")
                    return
            if code == 0:
                return
            settled = (result or {}).get("settled") or {}
            observation = settled.get("observation") or {}
            note = observation.get("note") or refusal or "start-failed"
            if note == "session-missing" and json.loads(Path(request).read_text())["controller"].get("resume"):
                # The recorded session is gone: the start opens a new one.
                body = json.loads(Path(request).read_text())
                for key in ("resume", "resume_file"):
                    body["controller"].pop(key, None)
                Path(request).write_text(json.dumps(body))
                with self.locked():
                    record = self.read()
                    if (record or {}).get("start_request") != request:
                        return
                    record["reason"] = "new-history-gone"
                    self.write(record)
                return self.started(request, brief_file, socket)
            blocked = BLOCKED_NOTES.get(note)
            failure = ({"state": "blocked", "reason": blocked,
                        "detail": short("Sign in to the chosen account and retry Start." if blocked == "sign-in-required" else "")}
                       if blocked else {"state": "failed", "reason": "launch-failed",
                                        "detail": short("Jarvis could not start: " + note + ". Check the Jarvis session log.")})
            if failure["state"] == "blocked" and failure["reason"] == "selection-conflict":
                failure["detail"] = ""
            self.start_failed(request, failure)
        finally:
            for path in (request, brief_file):
                Path(path).unlink(missing_ok=True)

    def start_failed(self, request, failure):
        """Record FAILURE for the start REQUEST names, while the record still asks for that start."""
        with self.locked():
            record = self.read()
            if record and record.get("start_request") == request and record.get("intent") == "start":
                record["failure"] = failure
                self.write(record)

    def _adopt(self, args, record):
        # The session a person runs by hand takes the predecessor's place:
        # the record binds its pane and the posture it was launched under,
        # then the one hand-over opens the managed successor on the home's
        # private server, unattended where the home names its harness, as a
        # fresh start is.
        if not os.environ.get("TMUX"):
            print("jarvis-session: adopt=refused cause=no-tmux pane=" + args.adopt_pane, file=sys.stderr)
            raise Refusal("selection-conflict")
        posture = {"permission": "bypass", "extra_args": []} if self.unattended(args.harness) else {}
        caller_socket = os.environ["TMUX"].split(",")[0]
        self.initialized_fleet()
        argv = ["controller", "adopt", "--record", self.fleet(), "--pane", args.adopt_pane, "--socket", caller_socket,
                "--harness", args.harness]
        if args.account is not None:
            argv += ["--account", str(Path(args.account).resolve(strict=True))]
        result, code, refusal, errors = self.runtime(*argv)
        if code:
            sys.stderr.write(errors)
            print("jarvis-session: adopt=refused cause=" + str(refusal) + " pane=" + args.adopt_pane, file=sys.stderr)
            raise Refusal("selection-conflict")
        record.update(origin=args.origin, app_off=False, report_started_at=int(time.time()),
                      private_brief=self.private_brief(args), reason="new-requested", intent="succeed", failure=None)
        self.write(record)
        return self._hand_over(record, "context", self.server(args.harness), posture)

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

    def succeed(self, account_walled=False, usage_wall=None, reset_passed=False, resume_cursor=None):
        with self.locked():
            record = self.read()
            if not record or record.get("app_off"):
                raise Refusal("app-off" if record and record.get("app_off") else "record-unreadable")
            status = self.status()
            answer = self.answer(record, status)
            if answer["state"] == "handing-over":
                return answer, 0
            if answer["state"] != "running":
                raise Refusal("record-unreadable")
            recorded = status["recorded"]
            self.env = environment(recorded.get("harness"), policy=True)
            choice = None
            if usage_wall:
                if usage_wall != [recorded.get("session_id"), f'{recorded["server"]} {recorded["pane"]}']:
                    raise Refusal("record-unreadable")
                recovery = None
                if resume_cursor is not None:
                    try:
                        recovery = self.resume_wall(recorded, resume_cursor)
                    except (Refusal, OSError, subprocess.SubprocessError) as failure:
                        print("jarvis-session: resume-read=unavailable cause=" + type(failure).__name__, file=sys.stderr)
                        recovery = {"wall_recovery": "pending"}
                    if recovery["wall_recovery"] == "confirmed":
                        return {**answer, **recovery}, 0
                choice = self.wall_choice(recorded, "headroom", Path(self.home) / "state/handoff.md")
                if not choice.get("successor"):
                    if recovery is None:
                        recovery = self.resume_wall(recorded) if reset_passed else {"wall_recovery": "waiting"}
                    return {**answer, **recovery}, 0
            record.update(intent="succeed", failure=None, reason="new-requested")
            self.write(record)
            return self._hand_over(record, "headroom" if account_walled else "context", recorded["server_socket"],
                                   choice=choice)

    def wall_choice(self, recorded, mark, handoff):
        choice, code, refusal, errors = self.ready_successor(
            "controller", "successor", "--record", self.fleet(), "--cwd", self.home,
            "--predecessor", recorded["pane"], "--mark", mark, "--handoff", handoff, recorded=recorded)
        if code:
            sys.stderr.write(errors)
            raise Refusal("handover-failed", "The successor could not be chosen: " + str(refusal) + ".", "failed")
        return choice

    def resume_wall(self, recorded, cursor=None):
        if cursor is None:
            if not recorded.get("account"):
                return {"wall_recovery": "waiting"}
            pick = ["accounts", "pick", "--harness", recorded["harness"], "--account", recorded["account"],
                    "--record", self.fleet(), "--for-controller"]
            if recorded.get("model"):
                pick.extend(("--native-model", recorded["model"]))
            room, code, _, errors = self.runtime(*pick)
            if code:
                sys.stderr.write(errors)
                raise Refusal("record-unreadable")
            if room.get("exit") != 0:
                return {"wall_recovery": "waiting"}
        args = ["deliver", "--line", "Continue your work after the usage limit reset."]
        if cursor is None:
            args.append("--account-room")
        else:
            args.extend(("--no-paste", "--turns-before", cursor, "--bound-secs", "0"))
        for flag, field in (("harness", "harness"), ("socket", "server_socket"), ("server-pid", "server"),
                            ("server-start", "server_start"), ("pane", "pane"), ("cwd", "cwd"),
                            ("pid", "harness_pid"), ("start", "harness_start"), ("session-id", "session_id")):
            if not recorded.get(field):
                raise Refusal("record-unreadable")
            args.extend(("--" + flag, recorded[field]))
        if recorded.get("home"):
            args.extend(("--home", recorded["home"]))
        try:
            result, code, refusal, errors = self.runtime(*args)
        except (Refusal, OSError, subprocess.SubprocessError) as failure:
            print("jarvis-session: resume-answer=unavailable cause=" + type(failure).__name__, file=sys.stderr)
            return {"wall_recovery": "pending"}
        if cursor is not None and (code or result.get("delivery") != "confirmed"):
            if errors:
                sys.stderr.write(errors)
            return {"wall_recovery": "pending"}
        if code or result.get("delivery") not in ("confirmed", "unconfirmed"):
            sys.stderr.write(errors)
            raise Refusal("handover-failed", "The session could not resume: " +
                          str(refusal or (result or {}).get("cause")) + ".", "failed")
        if result["delivery"] == "unconfirmed":
            return {"wall_recovery": "unconfirmed",
                    "wall_resume": {"cause": result["cause"], "turns_before": result["turns_before"]}}
        return {"wall_recovery": "confirmed"}

    def _hand_over(self, record, mark, socket, posture=None, choice=None):
        # Save the handoff, write its generation header, then choose and
        # transfer until an attempt is proved, no account is left, or the
        # outcome is not a failure on a named account. The caller holds the
        # lock. Every successor takes the record's stored private brief, and
        # `posture` over the one the walk carried from its predecessor.
        handoff = Path(self.home) / "state/handoff.md"
        contents = handoff.read_bytes()
        if not contents.strip():
            raise Refusal("record-unreadable")
        archive = handoff.parent / "archive"
        archive.mkdir(exist_ok=True)
        saved = archive / ("handoff-" + uuid.uuid4().hex + ".md")
        with saved.open("xb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        # The header an earlier attempt put on the handoff is agent-runtime's
        # to write again: the body it takes holds none.
        body = self.path.parent / ("succeed-body-" + uuid.uuid4().hex + ".md")
        body.write_text("".join(line for line in contents.decode("utf-8").splitlines(keepends=True)
                                if not line.startswith("Start here:")))
        try:
            _, code, _, errors = self.runtime("controller", "handoff", "--record", self.fleet(), "--body", body,
                                              "--handoff", handoff)
        finally:
            body.unlink(missing_ok=True)
        if code:
            sys.stderr.write(errors)
            raise Refusal("record-unreadable")
        brief = self.path.parent / ("succeed-brief-" + uuid.uuid4().hex + ".txt")
        brief.write_text(start_brief(record.get("private_brief")))
        request = self.path.parent / ("succeed-request-" + uuid.uuid4().hex + ".json")
        # The accounts this call already tried: a mark the walk let expire
        # while later attempts ran must not send it back to one, so each
        # account is tried at most once and the call ends.
        tried = set()
        try:
            while True:
                recorded = self.status(reconcile=False)["recorded"]
                choice = choice or self.wall_choice(recorded, mark, handoff)
                if not choice.get("successor") or choice["successor"].get("account") in tried:
                    unproved = (self.status().get("recorded") or {}).get("unproved") or []
                    named = "; ".join(entry.get("account", "") + " (" + entry.get("note", "") + ")" for entry in unproved)
                    raise Refusal("handover-failed", short("No account is left to take over"
                                                           + (": " + named if named else "") + ". Jarvis keeps running."), "failed")
                # The marks as they stood before this attempt: a failure
                # retries only where it stamped the account it tried, never on
                # an older mark, which the walk may have let expire.
                stamped = {entry.get("account"): entry.get("at") for entry in recorded.get("unproved") or []}
                successor = dict(choice["successor"], window=SESSION_NAME, seat=SEAT, **(posture or {}))
                request.write_text(json.dumps({"expected": choice["expected"], "successor": successor,
                                               "brief_file": str(brief), "session": SESSION_NAME,
                                               "cause": "walled" if mark == "headroom" else "live",
                                               **({"exclude_account": recorded["account"]} if mark == "headroom" else {})}))
                choice = None
                result, code, refusal, errors = self.runtime("controller", "transfer", *self.reach(socket),
                                                             "--request", request, "--effect-exit", timeout=3600)
                print(errors, end="", file=sys.stderr)
                if code == 0:
                    # The runner stands at its composer: the job proves it,
                    # then retires the predecessor, this call's own pane as
                    # often as not.
                    code = self.settled_transfer(recorded.get("generation"))
                if code == 0:
                    return self.answer(record, self.status()), 0
                if code == 75:
                    return self.answer(record, state="handing-over", reason="succession"), 0
                attempted = successor.get("account")
                if attempted:
                    tried.add(attempted)
                unproved = (self.status(reconcile=False).get("recorded") or {}).get("unproved") or []
                marked = {entry.get("account"): entry for entry in unproved}
                if attempted and attempted in marked and marked[attempted].get("at") != stamped.get(attempted):
                    print("jarvis-session: successor-unproved account=" + attempted
                          + " note=" + str(marked[attempted].get("note")), file=sys.stderr)
                    continue
                note = ((((result or {}).get("settled") or {}).get("observation")) or {}).get("note") or refusal
                raise Refusal("handover-failed", short("The successor on " + str(attempted) + " failed"
                                                       + (": " + note if note else "") + ". Jarvis keeps running."), "failed")
        finally:
            for path in (brief, request):
                path.unlink(missing_ok=True)

    def settled_transfer(self, generation):
        """How the transfer the job runs ended: 0 its successor published (a
        new generation), 3 failed with the predecessor in control, 75 still
        open past the bound."""
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            status = self.status(reconcile=False)
            if not any(intent["op"] == "request-transfer" for intent in status.get("open_intents", [])):
                return 0 if (status.get("recorded") or {}).get("generation") != generation else 3
            time.sleep(0.5)
        return 75

    def stop(self, origin):
        with self.locked():
            record = self.read() or self.fresh(None, None)
            record["intent"] = "stop"
            record["start_request"] = None
            record["failure"] = None
            record["app_off"] = origin == "app-off" or record.get("app_off", False)
            self.write(record)
            status = self.status()
            recorded = (status or {}).get("recorded") or {}
            if any(intent["op"] == "start-controller" for intent in (status or {}).get("open_intents", [])):
                return self.answer(record, status, state="stopping", reason="stop-requested"), 0
            if (status or {}).get("live") and recorded.get("server_socket"):
                _, code, refusal, errors = self.runtime("controller", "stop", *self.reach(recorded["server_socket"]))
                if code:
                    sys.stderr.write(errors)
                    raise Refusal("record-unreadable")
                return self.answer(record, status, state="stopping", reason="stop-requested"), 0
            return self.answer(record, status), 0


class Arguments(argparse.ArgumentParser):
    def error(self, message):
        print("jarvis-session: arguments=invalid", file=sys.stderr)
        raise SystemExit(2)


def private_value_problem(value):
    """Why VALUE cannot be written as KEY='VALUE' in the private env file, or None.

    The settings loader reads that file as data: a single-quoted value holds
    every byte but an apostrophe, and one line ends it. The app's credential
    save refuses the same values (crates/core/src/settings_secret/env_file.rs).
    """
    if "\n" in value or "\r" in value:
        return "line-break"
    if "'" in value:
        return "apostrophe"
    if any(unicodedata.category(char) == "Cc" for char in value):
        return "control-character"
    return None


def main_host(args):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import watch

    value = args.set if args.set is not None else ""
    if not args.get and watch.role({"JARVIS_MAIN_HOST": value}).kind == "invalid":
        print("jarvis-session: main-host=refused cause=setting-invalid", file=sys.stderr)
        return 2
    problem = None if args.get else private_value_problem(value)
    if problem:
        print("jarvis-session: main-host=refused cause=value-unwritable key=JARVIS_MAIN_HOST problem=" + problem,
              file=sys.stderr)
        return 2
    # Read the selected path and this one value through the same owner as
    # watch.config. Private-file diagnostics can contain other secret values.
    reader = r'''
source "$1/jarvis-env.sh"
kendex_project_env_supports selected-private-path || exit 1
kendex_load_project_env "$2" _jarvis_selected_private -- JARVIS_MAIN_HOST || exit 1
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
            # A final single-quoted assignment the loader reads as written.
            # Follow the loader's supported file symlink layout.
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with os.fdopen(os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600), "ab") as stream:
                stream.write(("\nJARVIS_MAIN_HOST='" + value + "'\n").encode("utf-8"))
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
                 "forward-wait", "main-host", "init"):
        command = verbs.add_parser(verb)
        command.add_argument("--home", required=True)
        if verb == "status":
            # The default answer's key set is the VGS-1439 contract; --main is a separate shape.
            command.add_argument("--main", action="store_true")
        elif verb == "forward-drain":
            # The watch-loop's own drain, whose reach status --main reports.
            command.add_argument("--collection", action="store_true")
        elif verb == "forward":
            # Text crosses this file, never argv.
            command.add_argument("--record", required=True)
        elif verb == "forward-wait":
            command.add_argument("--key", required=True)
            command.add_argument("--timeout", type=int)
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
            command.add_argument("--usage-wall", nargs=2, metavar=("SESSION", "PANE"))
            command.add_argument("--reset-passed", action="store_true")
            command.add_argument("--resume-cursor", type=int)
    command = verbs.add_parser("owner-asks")
    operations = command.add_subparsers(dest="action", required=True, parser_class=Arguments)
    for action in ("list", "reply", "done", "later"):
        operation = operations.add_parser(action)
        operation.add_argument("--home", required=True)
        if action == "list":
            operation.add_argument("--view", choices=("active", "snoozed"), required=True)
            operation.add_argument("--cursor")
        else:
            operation.add_argument("--id", required=True)
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
    if args.verb == "forward-wait" and not (re.fullmatch(r"forward-[0-9a-f]{64}", args.key, re.ASCII)
                                            and (args.timeout is None or args.timeout > 0)):
        parser.error("wait")
    if args.verb == "main-host":
        return main_host(args)
    if args.verb == "init":
        try:
            Path(args.home).resolve(strict=True)
        except OSError:
            parser.error("home")
        return init_home(args)
    if args.verb == "owner-asks":
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import owner_asks
        return owner_asks.main(args, Session, Refusal)
    if args.verb in ("forward", "forward-drain", "forward-wait") or (args.verb == "status" and args.main):
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import forward
        return forward.main(args, home_module().home_state)
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
            if (args.usage_wall and not args.account_walled) or (args.reset_passed and not args.usage_wall):
                parser.error("usage-wall")
            if args.resume_cursor is not None and (not args.reset_passed or args.resume_cursor < 0):
                parser.error("resume-cursor")
            answer, code = session.succeed(args.account_walled, args.usage_wall, args.reset_passed, args.resume_cursor)
        elif args.verb == "update-brief":
            answer, code = session.update_brief(args)
        elif args.verb == "report-due":
            answer, code = session.report_due()
        else:
            answer, code = session.answer(session.read(), session.status()), 0
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
