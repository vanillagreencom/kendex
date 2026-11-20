"""Private Unix socket transport and per-caller allow list for the optional 1Password broker on Linux/macOS."""
import argparse
import base64
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
import uuid

# The session record's owner, session.py, needs the session launcher's environment; home.py keeps its location.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from home import home_state

CALL_SECONDS = 30
CLIENT_SECONDS = 60
# opq sends its request line as it connects; a silent connection holds the one-at-a-time broker no longer than this.
REQUEST_SECONDS = 5
# The longest request line opq sends, its newline included.
REQUEST_BYTES = 4096
# The tail of op's stderr the journal keeps for a read or renewal that never finished.
STDERR_BYTES = 4096
TTY_LEADER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "op_tty.py")
SOCKET = "requests.sock"
# sockaddr_un's sun_path bytes on macOS, its terminating NUL included: sys/un.h.
SUN_PATH = 104
# The only entries a broker leaves in its directory, with their file types.
OWN_ENTRIES = {"lock": stat.S_ISREG, SOCKET: stat.S_ISSOCK}
# The FIFO broker this one replaced can leave its request FIFO after a crash, and a killed client its reply FIFO.
# A restart removes them. A refresh restarts no broker unit, so opq also speaks that broker's protocol while one
# still serves (fifo_exchange). Drop both once every consumer's broker has restarted onto the socket transport.
LEGACY_FIFOS = r"requests|[0-9a-f]{32}\.reply"
# Each verb's request field, which its allow-list entry lists and its log line names as the reference.
SUBJECTS = {"read": "reference", "op": "args", "script": "path"}
# The characters systemd.unit(5) allows in a unit name, with @ for a template instance.
UNIT_NAME = r"[A-Za-z0-9:_.@\\-]+"
# The caller the Jarvis session's recorded process and its descendants are.
SESSION_CALLER = "jarvis-session"
# An allow-list key: the Jarvis session, or a service unit name that may hold one * for a generated part.
CALLER_KEY = SESSION_CALLER + r"|[A-Za-z0-9:_.@\\-]*\*?[A-Za-z0-9:_.@\\-]*\.service"
# Broker statuses for the op and script verbs, as the client reports them.
RECORD_REFUSALS = {"invalid-request": "request=invalid", "script-refused": "script=private-owner-required",
                   "script-missing": "script=not-found", "run-failed": "run=failed",
                   "platform-unsupported": "platform=unsupported"}
# The cause each status's log line names; a not-allowed reply names its own.
STATUS_CAUSES = dict(RECORD_REFUSALS, **{"ok": "listed", "read-failed": "read=failed"})


class Refusal(Exception):
    pass


class Cancelled(Exception):
    def __init__(self, signum):
        self.signum = signum


def owned(info, kind, mode):
    """Return whether the file is of that kind, owned by this user, with exactly that mode."""
    return kind(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == mode


def private(fd, kind, mode, refusal):
    if not owned(os.fstat(fd), kind, mode):
        os.close(fd)
        raise Refusal(refusal)
    return fd


def open_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    return private(fd, stat.S_ISDIR, 0o700, "directory=private-owner-required")


def open_fifo(directory, name, flags):
    fd = os.open(name, flags | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
    return private(fd, stat.S_ISFIFO, 0o600, "fifo=private-owner-required")


def check_socket(directory):
    """Refuse a request socket entry that is not this user's mode-600 socket."""
    if not owned(os.stat(SOCKET, dir_fd=directory, follow_symlinks=False), stat.S_ISSOCK, 0o600):
        raise Refusal("socket=private-owner-required")


def open_script(path):
    # The broker runs this descriptor, so the file checked is the file run.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    return private(fd, stat.S_ISREG, 0o700, "script=private-owner-required")


def entry_kind(name):
    """Return the file type test of an entry a broker may leave by that name, or None."""
    return stat.S_ISFIFO if re.fullmatch(LEGACY_FIFOS, name) else OWN_ENTRIES.get(name)


def check_own_entries(directory):
    """Refuse a reused directory holding anything a broker did not leave."""
    for name in os.listdir(directory):
        kind = entry_kind(name)
        if kind is None or not kind(os.stat(name, dir_fd=directory, follow_symlinks=False).st_mode):
            raise Refusal("directory=foreign")


def remove_legacy_fifos(directory):
    """Behind the lock, remove the FIFOs the FIFO broker and its clients left."""
    for name in os.listdir(directory):
        if re.fullmatch(LEGACY_FIFOS, name) and stat.S_ISFIFO(os.stat(name, dir_fd=directory,
                                                                        follow_symlinks=False).st_mode):
            os.unlink(name, dir_fd=directory)


def lock_directory(directory):
    fd = os.open("lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory)
    private(fd, stat.S_ISREG, 0o600, "lock=private-owner-required")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # A stopping broker unlinks its lock; holding that unlinked file guards nothing.
        if os.stat("lock", dir_fd=directory, follow_symlinks=False).st_ino != os.fstat(fd).st_ino:
            raise BlockingIOError
    except (BlockingIOError, FileNotFoundError):
        os.close(fd)
        raise Refusal("directory=busy")
    return fd


def socket_address(directory, root):
    """Name the request socket in the opened directory for bind and connect.

    On Linux the name goes through the directory's descriptor, so a deep directory meets no sun_path limit; on
    macOS, which has no such name, it is the path, which main bounds for the broker that binds it."""
    return "/proc/self/fd/%d/%s" % (directory, SOCKET) if sys.platform == "linux" else str(root / SOCKET)


def listen(directory, root):
    """Bind the request socket in the opened broker directory and return it listening, nonblocking."""
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        mask = os.umask(0o177)
        try:
            listener.bind(socket_address(directory, root))
        finally:
            os.umask(mask)
        # On macOS bind resolves the path again, so the entry checked is the one in the directory the broker opened.
        check_socket(directory)
        listener.listen()
        listener.setblocking(False)
    except BaseException:
        listener.close()
        raise
    return listener


def send(fd, data, deadline):
    while data:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([], [fd], [], remaining)[1]:
            raise Refusal("request=timeout")
        try:
            written = os.write(fd, data)
        except BlockingIOError:
            continue
        data = data[written:]


def receive(fd, deadline, bound=None):
    """Return one line, without its newline, read within the deadline; refuse one whose newline lies past bound."""
    data = bytearray()
    while b"\n" not in data:
        if bound is not None and len(data) >= bound:
            raise Refusal("request=too-large")
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise Refusal("request=timeout")
        try:
            block = os.read(fd, 65536 if bound is None else bound - len(data))
        except BlockingIOError:
            continue
        if not block:
            raise Refusal("response=incomplete")
        data.extend(block)
    return bytes(data[:data.index(b"\n")])


def stat_fields(text):
    """Return a /proc/PID/stat line's parent id and start time in clock ticks, proc(5) fields 4 and 22."""
    # The command name, field 2, can hold spaces and parentheses, so the fields after it start at its last ")".
    fields = text.rpartition(")")[2].split()
    return int(fields[1]), int(fields[19])


def process_chain(pid, read):
    """Return (pid, start ticks, cgroup text) for the process and each parent up to the root of the tree.

    read(NAME) returns the text of /proc/NAME. Each process's stat is read again after its parent's, so a link
    that changed meanwhile refuses: a process whose parent exits is given a new parent, and a reused id a new start."""
    chain = []
    parent, started = stat_fields(read("%d/stat" % pid))
    while True:
        cgroup = read("%d/cgroup" % pid)
        above = stat_fields(read("%d/stat" % parent)) if parent else None
        if stat_fields(read("%d/stat" % pid)) != (parent, started):
            raise Refusal("caller=unverified")
        chain.append((pid, started, cgroup))
        if not parent:
            return chain
        pid, (parent, started) = parent, above


def start_text(ticks, boot):
    """Name a start time as the session record's started_at does: ps -o lstart= in the C locale and UTC, blanks
    squeezed, which procps computes as the boot time plus the start ticks in whole seconds."""
    # Python sets no LC_TIME locale unless asked, so %a and %b are the C locale's names.
    moment = time.gmtime(boot + ticks // os.sysconf("SC_CLK_TCK"))
    return time.strftime("%a %b ", moment) + str(moment.tm_mday) + time.strftime(" %H:%M:%S %Y", moment)


def boot_time(text):
    """Return the boot time in /proc/stat text, its btime line."""
    return int(next(line for line in text.split("\n") if line.startswith("btime ")).split()[1])


def cgroup_unit(text):
    """Return the service unit that /proc/PID/cgroup text names as the cgroup v2 path's last component, or None."""
    paths = [line[3:] for line in text.split("\n") if line.startswith("0::")]
    unit = paths[0].rpartition("/")[2] if len(paths) == 1 else ""
    return unit if unit.endswith(".service") and re.fullmatch(UNIT_NAME, unit) else None


def chain_caller(pid, session, read):
    """Name the caller of process pid from its parent chain; session is the recorded Jarvis process, or None."""
    try:
        chain = process_chain(pid, read)
        boot = None if session is None else boot_time(read("stat"))
    except (OSError, ValueError, IndexError, StopIteration):
        raise Refusal("caller=unverified")
    if session is not None and any((step, start_text(ticks, boot)) == session for step, ticks, _ in chain):
        return SESSION_CALLER
    # systemd-run --scope leaves a helper agent the child of its unit's wrapper shell, so a helper and every
    # process it starts name that unit.
    for _, _, cgroup in chain:
        unit = cgroup_unit(cgroup)
        if unit is not None:
            return unit
    raise Refusal("caller=unverified")


def session_process(home):
    """Return the (pid, started_at) the home's Jarvis session record names, or None when it names no process."""
    if home is None:
        return None
    try:
        record = home_state(str(Path(home).resolve(strict=True))) / "jarvis-session.json"
    except OSError:
        raise Refusal("home=unreadable")
    try:
        with open(record, "rb") as stream:
            process = json.load(stream).get("process")
    except FileNotFoundError:
        return None
    except (OSError, ValueError, AttributeError):
        raise Refusal("record=unreadable")
    if process is None:
        return None
    if not isinstance(process, dict) or type(process.get("pid")) is not int \
            or not isinstance(process.get("started_at"), str):
        raise Refusal("record=unreadable")
    return process["pid"], process["started_at"]


def proc_read(name):
    with open("/proc/" + name, encoding="ascii", errors="replace") as stream:
        return stream.read()


def peer_caller(connection, home):
    """Linux: return (caller, None) for the peer its kernel credentials prove, or (None, the refusal's cause)."""
    pid, uid, _ = struct.unpack("iII", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                                             struct.calcsize("iII")))
    try:
        if uid != os.getuid() or pid <= 0:
            raise Refusal("caller=unverified")
        return chain_caller(pid, session_process(home), proc_read), None
    except Refusal as refusal:
        return None, str(refusal)


def protection(allow_list):
    """Name what the allow list protects: nothing when none is set, each verified caller on Linux, any caller of a
    listed reference on macOS."""
    if allow_list is None:
        return "none"
    return "unit" if sys.platform == "linux" else "listed-any-caller"


def granted(allow_list):
    """Return the cause a served request's log line names."""
    # A broker with no list serves every request, as it did before the list existed, so a refresh that brings the
    # list never stops a working broker.
    return STATUS_CAUSES["ok"] if allow_list is not None else "list=unset"


def valid_entry(entry):
    def listed(items, accepts):
        return isinstance(items, list) and all(accepts(item) for item in items)

    def word(item):
        return isinstance(item, str)

    return (isinstance(entry, dict) and set(entry) <= set(SUBJECTS)
            and listed(entry.get("read", []), lambda item: word(item) and item.startswith("op://"))
            and listed(entry.get("op", []), lambda item: listed(item, word) and bool(item))
            and listed(entry.get("script", []), lambda item: word(item) and os.path.isabs(item)))


def read_allow_list(path):
    """Read the allow list's callers, caller key to verb to listed items; a list it cannot use refuses."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise Refusal("list=missing")
    except OSError as error:
        raise Refusal("list=not-private" if error.errno == errno.ELOOP else "list=unreadable")
    try:
        if not owned(os.fstat(fd), stat.S_ISREG, 0o600):
            raise Refusal("list=not-private")
        data = bytearray()
        while True:
            block = os.read(fd, 65536)
            if not block:
                break
            data.extend(block)
    except OSError:
        raise Refusal("list=unreadable")
    finally:
        os.close(fd)
    try:
        document = json.loads(bytes(data))
    except (ValueError, UnicodeError):
        raise Refusal("list=invalid")
    callers = document.get("callers") if isinstance(document, dict) and set(document) == {"callers"} else None
    if not isinstance(callers, dict) or not all(key and re.fullmatch(CALLER_KEY, key) and valid_entry(entry)
                                                for key, entry in callers.items()):
        raise Refusal("list=invalid")
    return callers


def caller_entry(callers, caller):
    """Return the caller's entry: its exact key, otherwise the one pattern that matches it."""
    if caller in callers:
        return callers[caller]

    def matches(key):
        prefix, _, suffix = key.partition("*")
        return len(caller) > len(prefix) + len(suffix) and caller.startswith(prefix) and caller.endswith(suffix)

    keys = [key for key in callers if "*" in key and matches(key)]
    if len(keys) > 1:
        raise Refusal("caller=ambiguous")
    if not keys:
        raise Refusal("caller=unlisted")
    return callers[keys[0]]


def authorize(verb, subject, identity, allow_list):
    """Return the cause that refuses the request, or None when the allow list names it for this caller.

    identity is peer_caller's answer: the caller and None, or None and the cause that refused the peer."""
    if allow_list is None:
        return None
    caller, unverified = identity
    try:
        callers = read_allow_list(allow_list)
        if sys.platform == "linux":
            if caller is None:
                return unverified
            listed = caller_entry(callers, caller).get(verb, [])
        else:
            # macOS proves no caller, so a reference any entry lists serves every caller.
            listed = [item for entry in callers.values() for item in entry.get(verb, [])]
    except Refusal as refusal:
        return str(refusal)
    return None if subject in listed else "reference=unlisted"


# The op arguments that renew each route's approval. The vendor names op vault list as a call the app
# integration approves; op whoami can report no signed-in account there.
RENEWALS = {"session": ["whoami"], "app-integration": ["vault", "list"]}


def app_integration():
    """Return whether the home selected the desktop app integration route."""
    value = os.environ.get("JARVIS_OP_APP_INTEGRATION")
    if value not in (None, "", "1"):
        raise Refusal("setting=JARVIS_OP_APP_INTEGRATION")
    return value == "1"


def session(op, account):
    """Return the call environment and its route, session or app-integration."""
    # Only these values configure op. A child's unrelated credentials stay out.
    keys = ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "OP_CONFIG_DIR")
    env = {key: os.environ[key] for key in keys if key in os.environ}
    env["OP_DEBUG"] = "false"
    if account:
        env["OP_ACCOUNT"] = account
    token = os.environ.get("OP_SESSION")
    if app_integration():
        if token:
            raise Refusal("session=route-conflict\nOP_SESSION and JARVIS_OP_APP_INTEGRATION=1 each select a route. "
                          "Set one of them.")
        # The desktop app approves the calls, so no session exists to check at startup.
        env["OP_BIOMETRIC_UNLOCK_ENABLED"] = "true"
        return env, "app-integration"
    env["OP_BIOMETRIC_UNLOCK_ENABLED"] = "false"
    if not token:
        # A service has no terminal for a person to approve a sign-in.
        if not os.isatty(0):
            raise Refusal("session=OP_SESSION-required")
        result = call_op([op, "signin", "--raw"], env, interactive=True)
        if result.returncode or not result.stdout.strip():
            raise Refusal("session=signin-failed")
        token = result.stdout.decode().strip()
    env["OP_SESSION"] = token
    result = call_op([op, "whoami"], env)
    if result.returncode:
        raise Refusal("session=unavailable")
    return env, "session"


def keepalive_seconds():
    """Return the renewal interval, or None when the home has not asked for renewal."""
    value = os.environ.get("JARVIS_OP_KEEPALIVE_SECS")
    if not value:
        return None
    if not value.isascii() or not value.isdecimal() or int(value) < 1:
        raise Refusal("setting=JARVIS_OP_KEEPALIVE_SECS")
    return int(value)


def keep_session(op, env, route):
    """Renew the session, log a failed renewal, and return whether it succeeded."""
    # The renewal contacts the server, so a failed run, an unreachable server included, says nothing about the session.
    try:
        status = call([op, *RENEWALS[route]], env, route).returncode
    except (OSError, subprocess.TimeoutExpired):
        print("op-broker: keepalive=failed", file=sys.stderr, flush=True)
        return False
    if status:
        print("op-broker: keepalive=failed exit=%d" % status, file=sys.stderr, flush=True)
    return status == 0


def call_op(argv, env, interactive=False):
    process = subprocess.Popen(argv, env=env, stdin=None if interactive else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=None if interactive else subprocess.DEVNULL)
    try:
        stdout, _ = process.communicate(timeout=None if interactive else CALL_SECONDS)
        return subprocess.CompletedProcess(argv, process.returncode, stdout)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def journal(cause, stderr):
    """Log why a call never finished, then the last of its stderr; the client's reply carries neither."""
    print("op-broker: run=failed " + cause, file=sys.stderr, flush=True)
    for line in stderr.decode(errors="backslashreplace").splitlines():
        print("op-broker: stderr=" + line, file=sys.stderr, flush=True)


def spawn_failed(error, stderr):
    journal("cause=spawn errno=" + errno.errorcode.get(error.errno, str(error.errno)), stderr)


def read_streams(streams, seconds):
    """Read what each open stream holds within seconds and return whether any was ready.

    streams maps a descriptor to its buffer and byte bound; a stream leaves at its end, and a None buffer discards."""
    if not streams:
        time.sleep(seconds)
        return False
    ready = select.select(list(streams), [], [], seconds)[0]
    for fd in ready:
        try:
            block = os.read(fd, 65536)
        except OSError as error:
            # A pty master reads EIO once no process holds its terminal.
            if error.errno != errno.EIO:
                raise
            block = b""
        buffer, bound = streams[fd]
        if not block:
            del streams[fd]
        elif buffer is not None:
            buffer.extend(block)
            if bound is not None:
                del buffer[:-bound]
    return bool(ready)


def run_work(argv, env, pass_fds=(), *, stderr, terminal):
    """Linux: run work as a session leader and end its process group when the leader exits or at the deadline.

    stderr keeps the work's last STDERR_BYTES of stderr for the journal of a call that never finished. terminal
    gives the session a new pty, led by op_tty.py with the work as its child."""
    errors = bytearray()
    master = report = None
    try:
        try:
            if terminal:
                master, slave = os.openpty()
                # From the start on, the leader holds the terminal and the status pipe's write end.
                try:
                    report, status = os.pipe()
                    try:
                        process = subprocess.Popen([sys.executable, "-I", TTY_LEADER, str(status), *argv], env=env,
                            stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE if stderr else subprocess.DEVNULL,
                            pass_fds=(*pass_fds, status), start_new_session=True)
                    finally:
                        os.close(status)
                finally:
                    os.close(slave)
            else:
                process = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE if stderr else subprocess.DEVNULL, pass_fds=pass_fds, start_new_session=True)
        except OSError as error:
            spawn_failed(error, errors)
            raise
        return collect(process, argv, master, report, errors)
    finally:
        for fd in (master, report):
            if fd is not None:
                os.close(fd)


def collect(process, argv, master, report, errors):
    """Collect the work's output until its leader exits, then end its process group."""
    deadline = time.monotonic() + CALL_SECONDS
    output = bytearray()
    streams = {process.stdout.fileno(): (output, None)}
    if process.stderr is not None:
        streams[process.stderr.fileno()] = (errors, STDERR_BYTES)
    if master is not None:
        # What the work writes to its terminal is discarded, so a full pty never blocks it.
        streams[master] = (None, None)
    try:
        # The group is signalled only while the unreaped leader keeps its id from reuse.
        while os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                # One read takes what a pipe buffers; a process that left the group cannot hold the broker longer.
                read_streams(streams, 0)
                journal("cause=deadline seconds=%s" % CALL_SECONDS, errors)
                raise subprocess.TimeoutExpired(argv, CALL_SECONDS)
            # Python 3.8 has no pidfd, so the leader's exit is polled between reads.
            read_streams(streams, min(remaining, 0.05))
        os.killpg(process.pid, signal.SIGKILL)
        streams.pop(master, None)
        while streams and time.monotonic() < deadline:
            read_streams(streams, deadline - time.monotonic())
        # op_tty.py has exited, so its status pipe holds an errno or has reached its end.
        failure = b"" if report is None else os.read(report, 32)
        if failure:
            error = OSError(int(failure), os.strerror(int(failure)))
            spawn_failed(error, errors)
            raise error
        return subprocess.CompletedProcess(argv, process.wait(), bytes(output))
    finally:
        if process.returncode is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()


def needs_terminal(route):
    """Return whether the route's calls run under a terminal leader."""
    # On Linux the desktop app names the call's top-level process in its approval prompt and aborts a call with none.
    return route == "app-integration" and sys.platform == "linux"


def call(argv, env, route):
    """Run the op call of a read request or a renewal."""
    if needs_terminal(route):
        return run_work(argv, env, stderr=True, terminal=True)
    return call_op(argv, env)


def encoded(data):
    return base64.b64encode(data).decode()


def status(name):
    """Return a reply that carries only its status, and the cause its log line names."""
    return {"status": name}, STATUS_CAUSES[name]


def respond(request, identity, allow_list, op, env, route):
    """Answer one request; return the reply and the cause its log line names."""
    verb = request.get("verb")
    if verb == "read":
        reference = request.get("reference")
        if not isinstance(reference, str) or not reference.startswith("op://"):
            return status("invalid-request")
        refusal = authorize(verb, reference, identity, allow_list)
        if refusal is not None:
            return {"status": "not-allowed"}, refusal
        try:
            result = call([op, "read", "--no-newline", reference], env, route)
        except (OSError, subprocess.TimeoutExpired):
            return status("read-failed")
        if result.returncode:
            return status("read-failed")
        return {"status": "ok", "value": encoded(result.stdout)}, granted(allow_list)
    if verb not in ("op", "script"):
        return status("invalid-request")
    # On macOS an inherited ACL can open a mode-700 directory to another user.
    if sys.platform != "linux":
        return status("platform-unsupported")
    subject = request.get(SUBJECTS[verb])
    if verb == "op":
        if not isinstance(subject, list) or not subject or not all(isinstance(word, str) for word in subject):
            return status("invalid-request")
    elif not isinstance(subject, str) or not os.path.isabs(subject):
        return status("invalid-request")
    refusal = authorize(verb, subject, identity, allow_list)
    if refusal is not None:
        return {"status": "not-allowed"}, refusal
    script = None
    if verb == "op":
        argv = [op, *subject]
    else:
        try:
            script = open_script(subject)
        except FileNotFoundError:
            return status("script-missing")
        except (OSError, Refusal):
            return status("script-refused")
        argv = ["/dev/fd/%d" % script]
    try:
        # The caller chooses what writes this stderr, a script or a program op run or op plugin run starts, and it
        # may print a secret there; only read and the renewal, whose arguments the broker chooses, journal stderr.
        result = run_work(argv, env, () if script is None else (script,), stderr=False,
                          terminal=needs_terminal(route))
    except (OSError, subprocess.TimeoutExpired):
        return status("run-failed")
    finally:
        if script is not None:
            os.close(script)
    return {"status": "ok", "exit": result.returncode, "stdout": encoded(result.stdout)}, granted(allow_list)


def log_field(value):
    """Encode a request field as JSON with no space, so each log field stays one token and no field adds a line."""
    return json.dumps(value, separators=(",", ":")).replace(" ", "\\u0020")


def log_request(caller, request, reply, cause, allow_list):
    """Write the request's one log line: never a value or a reply body."""
    verb = request.get("verb")
    # The verb is the client's JSON, which can be a list or an object that no dict lookup accepts.
    known = isinstance(verb, str) and verb in SUBJECTS
    print("op-broker: request time=%s protection=%s caller=%s verb=%s reference=%s outcome=%s cause=%s" % (
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), protection(allow_list), caller or "unverified",
        verb if known else "invalid", log_field(request.get(SUBJECTS[verb]) if known else None), reply["status"],
        cause), file=sys.stderr, flush=True)


def answer(connection, op, env, route, allow_list, home):
    """Answer one connection's request, log it, and return whether it was a successful call."""
    # The peer's credentials are read first, while the peer still waits on its reply.
    identity = peer_caller(connection, home) if sys.platform == "linux" else (None, None)
    connection.setblocking(False)
    try:
        request = json.loads(receive(connection.fileno(), time.monotonic() + REQUEST_SECONDS, REQUEST_BYTES))
    except (OSError, Refusal, ValueError, UnicodeError):
        request = None
    if isinstance(request, dict):
        reply, cause = respond(request, identity, allow_list, op, env, route)
    else:
        request = {}
        reply, cause = status("invalid-request")
    log_request(identity[0], request, reply, cause, allow_list)
    try:
        send(connection.fileno(), json.dumps(reply).encode() + b"\n", time.monotonic() + CALL_SECONDS)
    except (OSError, Refusal):
        pass  # A departed client receives no secret and cannot hold the broker.
    return reply["status"] == "ok" and reply.get("exit", 0) == 0


def broker(args):
    op = shutil.which("op")
    if op is None:
        raise Refusal("optional-dependency=op\nThe 1Password route is optional. Install op before starting it.")
    keepalive = keepalive_seconds()
    try:
        os.mkdir(args.directory, 0o700)
        reused = False
    except FileExistsError:
        # On macOS an inherited ACL can open a mode-700 directory to another user.
        if sys.platform != "linux":
            raise Refusal("directory=exists\nOn macOS the broker never reuses a directory. "
                          "Remove the leftover directory or choose a new path.")
        reused = True  # A restart reuses its own private directory behind the lock.
    directory = None
    lock = None
    listener = None
    try:
        directory = open_directory(args.directory)
        if reused:
            check_own_entries(directory)
        lock = lock_directory(directory)
        if reused:
            remove_legacy_fifos(directory)
        env, route = session(op, args.account or os.environ.get("OP_ACCOUNT"))
        if keepalive is not None and route == "app-integration":
            # Each app call leads its own terminal session, which needs its own native authorization.
            raise Refusal("keepalive=unsupported cause=per-terminal-authorization\n"
                          "JARVIS_OP_KEEPALIVE_SECS cannot renew app integration authorization: "
                          "each call has its own terminal session. Leave the setting unset for this route.")
        try:
            os.unlink(SOCKET, dir_fd=directory)
        except FileNotFoundError:
            pass
        listener = listen(directory, args.directory)
        print("op-broker: state=ready protection=" + protection(args.allow_list), flush=True)
        renewing = False
        while True:
            # After a successful call, an idle broker renews the session before it expires.
            if not select.select([listener], [], [], keepalive if renewing else None)[0]:
                # A failed whoami asks nobody, so the session route stays armed. Under the app integration a
                # failure can mean the app locked, and each retry would raise an approval prompt with no request
                # pending, so only a caller's successful call arms it again.
                renewing = keep_session(op, env, route) or route == "session"
                continue
            try:
                connection, _ = listener.accept()
            except BlockingIOError:
                continue  # The client left before the broker accepted it.
            with connection:
                renewing = answer(connection, op, env, route, args.allow_list, args.home) or renewing
    finally:
        if listener is not None:
            listener.close()
            os.unlink(SOCKET, dir_fd=directory)
        if lock is not None:
            os.unlink("lock", dir_fd=directory)
            os.close(lock)
            try:
                args.directory.rmdir()
            except OSError:
                pass
        if directory is not None:
            os.close(directory)


def record(verb, response):
    """Narrow a broker response to the bytes the client writes to its output file."""
    status = response.get("status")
    if status == "not-allowed":
        raise Refusal(verb + "=not-allowed")
    if status != "ok":
        raise Refusal("read=failed" if verb == "read" else RECORD_REFUSALS.get(status, "response=invalid"))
    if verb == "read":
        return base64.b64decode(response["value"], validate=True)
    exit_status, stdout = response.get("exit"), response.get("stdout")
    if type(exit_status) is not int or not isinstance(stdout, str):
        raise Refusal("response=invalid")
    base64.b64decode(stdout, validate=True)
    return json.dumps({"exit": exit_status, "stdout": stdout}).encode() + b"\n"


def socket_exchange(directory, root, request, deadline):
    """Send one request over the broker's socket and return its reply."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(CLIENT_SECONDS)
        connection.connect(socket_address(directory, root))
        connection.setblocking(False)
        send(connection.fileno(), json.dumps(request).encode() + b"\n", deadline)
        return json.loads(receive(connection.fileno(), deadline))


def fifo_exchange(directory, root, request, deadline):
    """Send one request through a running FIFO broker's request FIFO and return its reply (see LEGACY_FIFOS)."""
    name = uuid.uuid4().hex + ".reply"
    line = json.dumps(dict(request, reply=name)).encode() + b"\n"
    # A single nonblocking write up to PIPE_BUF is atomic across clients.
    if len(line) > os.fpathconf(directory, "PC_PIPE_BUF"):
        raise Refusal("request=too-large")
    # Held before the reply FIFO exists, so a directory with no FIFO broker gains no entry.
    fifo = open_fifo(directory, "requests", os.O_WRONLY)
    reply = None
    try:
        # Python builds without mkfifoat still support exclusive absolute creation.
        if os.mkfifo in os.supports_dir_fd:
            os.mkfifo(name, 0o600, dir_fd=directory)
        else:
            os.mkfifo(root / name, 0o600)
        try:
            reply = open_fifo(directory, name, os.O_RDWR)
            if os.write(fifo, line) != len(line):
                raise Refusal("request=incomplete")
            return json.loads(receive(reply, deadline))
        finally:
            if reply is not None:
                os.close(reply)
            os.unlink(name, dir_fd=directory)
    finally:
        os.close(fifo)


def client(args):
    directory = open_directory(args.directory)
    output = None
    created_output = False
    success = False
    try:
        request = json.dumps(args.request).encode() + b"\n"
        if len(request) > REQUEST_BYTES:
            raise Refusal("request=too-large")
        output = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        created_output = True
        deadline = time.monotonic() + CLIENT_SECONDS
        try:
            check_socket(directory)
            exchange = socket_exchange
        except FileNotFoundError:
            exchange = fifo_exchange
        content = record(args.request["verb"], exchange(directory, args.directory, args.request, deadline))
        with os.fdopen(output, "wb") as stream:
            output = None
            stream.write(content)
        success = True
    finally:
        if output is not None:
            os.close(output)
        os.close(directory)
        if not success and created_output:
            args.output.unlink()


def client_request(parser, words):
    if words[0] == "read" and len(words) == 2:
        return {"verb": "read", "reference": words[1]}
    if words[0] == "op" and len(words) > 1:
        return {"verb": "op", "args": words[1:]}
    if len(words) == 1 and words[0].startswith("@"):
        if not os.path.isabs(words[0][1:]):
            parser.exit(2, "op-client: path=absolute-required\n")
        return {"verb": "script", "path": words[0][1:]}
    parser.error("expected read op://REF, op -- ARG... or @/absolute/script")


def main(kind):
    parser = argparse.ArgumentParser(description="Optional 1Password broker on a private Unix socket. Platform: "
        "Linux and macOS. Linux only: the op and @SCRIPT requests, a broker whose directory comes from "
        "JARVIS_OP_DIRECTORY, and a broker that reuses an existing directory.",
        epilog="The broker takes OP_SESSION from its environment, or starts op signin --raw when its stdin is a "
               "terminal; those calls disable desktop integration, so they raise no desktop approval prompt. With "
               "JARVIS_OP_APP_INTEGRATION=1 and no OP_SESSION, calls go through the 1Password desktop app instead: "
               "each call keeps its native approval route. On Linux each call has its own terminal session, "
               "which needs its own authorization. Setting both refuses. Calls never print secrets. "
               "When JARVIS_OP_KEEPALIVE_SECS is set, the "
               "broker renews whenever it has been idle that many seconds after a successful call, with op whoami "
               "for OP_SESSION; unset, it never renews. App integration with a selected keepalive refuses at "
               "startup with keepalive=unsupported cause=per-terminal-authorization. "
               "Without an allow list the broker serves every request and logs protection=none. "
               "The broker reads its allow list again for each request. On Linux it serves only what the "
               "caller's entry lists: jarvis-session for the process the --home session record names and its "
               "descendants, otherwise the first systemd service in the caller's parent chain. On macOS, which "
               "proves no caller, it serves a read of a reference any entry lists. Anything else replies not-allowed. Each request writes one op-broker: request line "
               "to stderr, never a value. "
               "Clients need Python 3, not op. read writes the raw value to --output; op and @SCRIPT write one "
               "JSON record {\"exit\": N, \"stdout\": BASE64}. After an op or @SCRIPT request was sent, "
               "request=timeout or request=cancelled leaves its outcome unknown: check before retrying a write. "
               "Stop clients before stopping the broker, which removes its directory.")
    parser.add_argument("--directory", type=Path,
                        help="absolute private directory dedicated to the broker, otherwise JARVIS_OP_DIRECTORY; "
                             "the broker reuses an existing one only when it holds nothing but its own lock and "
                             "request socket, or the FIFOs a FIFO broker left, which it removes; on macOS the "
                             "socket path must stay under " + str(SUN_PATH) + " bytes")
    if kind == "broker":
        parser.add_argument("--account", help="1Password account, otherwise OP_ACCOUNT")
        parser.add_argument("--allow-list", type=Path,
                            help="absolute mode-600 JSON allow list outside the directory, otherwise "
                                 "JARVIS_OP_ALLOW_LIST: {\"callers\": {CALLER: {\"read\": [REF], \"op\": [[ARG]], "
                                 "\"script\": [PATH]}}}, where CALLER is jarvis-session or a NAME.service unit that "
                                 "may hold one * for a generated part; unset, every request is served")
        parser.add_argument("--home", type=Path,
                            help="Linux: absolute Jarvis home whose session record names the jarvis-session "
                                 "caller, otherwise JARVIS_OP_HOME; unset, no caller is jarvis-session")
    else:
        parser.usage = "opq [--directory DIR] --output FILE (read op://REF | op -- ARG... | @/absolute/script)"
        parser.add_argument("request", nargs="+", help="read op://REF, op -- ARG..., or @ and a private mode-700 script")
        parser.add_argument("--output", type=Path, required=True, help="absolute mode-600 output file, created exclusively")
    args = parser.parse_intermixed_args()
    if sys.platform not in ("linux", "darwin"):
        parser.exit(2, "op-" + kind + ": platform=unsupported\n")
    configured = args.directory is None
    if configured:
        if not os.environ.get("JARVIS_OP_DIRECTORY"):
            parser.exit(2, "op-" + kind + ": setting=JARVIS_OP_DIRECTORY\n")
        args.directory = Path(os.environ["JARVIS_OP_DIRECTORY"])
    if kind == "broker" and configured and sys.platform != "linux":
        parser.exit(2, "op-broker: platform=unsupported\n")
    if kind == "client":
        args.request = client_request(parser, args.request)
    if not args.directory.is_absolute() or (kind == "client" and not args.output.is_absolute()):
        parser.exit(2, "op-" + kind + ": path=absolute-required\n")
    if kind == "broker":
        # Only the broker binds the socket. opq refuses nothing here: a running FIFO broker has no socket path to bound.
        if sys.platform != "linux" and len(os.fsencode(args.directory / SOCKET)) >= SUN_PATH:
            parser.exit(2, "op-broker: directory=path-too-long\n")
        if args.allow_list is None and os.environ.get("JARVIS_OP_ALLOW_LIST"):
            args.allow_list = Path(os.environ["JARVIS_OP_ALLOW_LIST"])
        if args.home is None and os.environ.get("JARVIS_OP_HOME"):
            args.home = Path(os.environ["JARVIS_OP_HOME"])
        if any(path is not None and not path.is_absolute() for path in (args.allow_list, args.home)):
            parser.exit(2, "op-broker: path=absolute-required\n")
        # A list inside the directory would be a foreign entry there, and a restart would refuse the directory.
        inside = os.path.realpath(args.directory)
        if args.allow_list is not None and os.path.commonpath([inside, os.path.realpath(args.allow_list)]) == inside:
            parser.exit(2, "op-broker: allow-list=inside-directory\n")
    def cancel(signum, _frame):
        raise Cancelled(signum)

    try:
        signal.signal(signal.SIGTERM, cancel)
        signal.signal(signal.SIGINT, cancel)
        (broker if kind == "broker" else client)(args)
    except Cancelled as cancelled:
        if kind == "broker":
            return
        parser.exit(128 + cancelled.signum, "op-client: request=cancelled\n")
    except (Refusal, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        diagnostic = str(error) if isinstance(error, Refusal) else "operation=failed"
        parser.exit(2, "op-" + kind + ": " + diagnostic + "\n")
