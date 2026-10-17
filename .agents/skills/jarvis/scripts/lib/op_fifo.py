"""Private FIFO transport for the optional 1Password broker on Linux/macOS."""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid

CALL_SECONDS = 30
CLIENT_SECONDS = 60
# Broker statuses for the op and script verbs, as the client reports them.
RECORD_REFUSALS = {"invalid-request": "request=invalid", "script-refused": "script=private-owner-required",
                   "script-missing": "script=not-found", "run-failed": "run=failed",
                   "platform-unsupported": "platform=unsupported"}
# opq names each reply FIFO with one such basename.
REPLY_NAME = r"[0-9a-f]{32}\.reply"
# The only entries a broker or its clients leave in the directory, with their file types.
OWN_ENTRIES = {"lock": stat.S_ISREG, "requests": stat.S_ISFIFO}


class Refusal(Exception):
    pass


class Cancelled(Exception):
    def __init__(self, signum):
        self.signum = signum


def private(fd, kind, mode, refusal):
    info = os.fstat(fd)
    if not kind(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != mode:
        os.close(fd)
        raise Refusal(refusal)
    return fd


def open_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    return private(fd, stat.S_ISDIR, 0o700, "directory=private-owner-required")


def open_fifo(directory, name, flags):
    fd = os.open(name, flags | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
    return private(fd, stat.S_ISFIFO, 0o600, "fifo=private-owner-required")


def open_script(path):
    # The broker runs this descriptor, so the file checked is the file run.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    return private(fd, stat.S_ISREG, 0o700, "script=private-owner-required")


def check_own_entries(directory):
    """Refuse a reused directory holding anything a broker or its clients did not leave."""
    for name in os.listdir(directory):
        kind = stat.S_ISFIFO if re.fullmatch(REPLY_NAME, name) else OWN_ENTRIES.get(name)
        if kind is None or not kind(os.stat(name, dir_fd=directory, follow_symlinks=False).st_mode):
            raise Refusal("directory=foreign")


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


def create_fifo(directory, root, name):
    # Python builds without mkfifoat still support exclusive absolute creation.
    if os.mkfifo in os.supports_dir_fd:
        os.mkfifo(name, 0o600, dir_fd=directory)
    else:
        os.mkfifo(root / name, 0o600)


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


def receive(fd, deadline):
    data = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise Refusal("request=timeout")
        block = os.read(fd, 65536)
        if not block:
            raise Refusal("response=incomplete")
        data.extend(block)
        if b"\n" in block:
            return json.loads(data)


def session(op, account):
    # Only these values configure op. A child's unrelated credentials stay out.
    keys = ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "OP_CONFIG_DIR")
    env = {key: os.environ[key] for key in keys if key in os.environ}
    env.update(OP_BIOMETRIC_UNLOCK_ENABLED="false", OP_DEBUG="false")
    if account:
        env["OP_ACCOUNT"] = account
    token = os.environ.get("OP_SESSION")
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
    return env


def keepalive_seconds():
    """Return the renewal interval, or None when the home has not asked for renewal."""
    value = os.environ.get("JARVIS_OP_KEEPALIVE_SECS")
    if not value:
        return None
    if not value.isascii() or not value.isdecimal() or int(value) < 1:
        raise Refusal("setting=JARVIS_OP_KEEPALIVE_SECS")
    return int(value)


def keep_session(op, env):
    """Renew the session and log a failed renewal; the keepalive stays armed either way."""
    # op whoami contacts the server, so a failed run, an unreachable server included, says nothing about the session.
    try:
        status = call_op([op, "whoami"], env).returncode
    except (OSError, subprocess.TimeoutExpired):
        print("op-broker: keepalive=failed", file=sys.stderr, flush=True)
        return
    if status:
        print("op-broker: keepalive=failed exit=%d" % status, file=sys.stderr, flush=True)


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


def read_some(stream, output, seconds):
    """Collect output for at most seconds; return False at end of output."""
    if not select.select([stream], [], [], seconds)[0]:
        return True
    block = os.read(stream.fileno(), 65536)
    output.extend(block)
    return bool(block)


def run_work(argv, env, pass_fds=()):
    """Linux: run caller-chosen work and end its process group when it exits or at the deadline."""
    process = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, pass_fds=pass_fds, start_new_session=True)
    deadline = time.monotonic() + CALL_SECONDS
    output = bytearray()
    reading = True
    try:
        # The group is signalled only while the unreaped leader keeps its id from reuse.
        while os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(argv, CALL_SECONDS)
            # Python 3.8 has no pidfd, so the leader's exit is polled between reads.
            if reading:
                reading = read_some(process.stdout, output, min(remaining, 0.05))
            else:
                time.sleep(min(remaining, 0.05))
        os.killpg(process.pid, signal.SIGKILL)
        while reading and time.monotonic() < deadline:
            reading = read_some(process.stdout, output, deadline - time.monotonic())
        return subprocess.CompletedProcess(argv, process.wait(), bytes(output))
    finally:
        if process.returncode is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        process.stdout.close()


def encoded(data):
    return base64.b64encode(data).decode()


def respond(request, op, env):
    verb = request.get("verb")
    if verb == "read":
        reference = request.get("reference")
        if not isinstance(reference, str) or not reference.startswith("op://"):
            return {"status": "invalid-request"}
        try:
            result = call_op([op, "read", "--no-newline", reference], env)
        except (OSError, subprocess.TimeoutExpired):
            return {"status": "read-failed"}
        return {"status": "ok", "value": encoded(result.stdout)} if result.returncode == 0 else {"status": "read-failed"}
    if verb not in ("op", "script"):
        return {"status": "invalid-request"}
    # On macOS an inherited ACL can open a mode-700 directory to another user.
    if sys.platform != "linux":
        return {"status": "platform-unsupported"}
    script = None
    if verb == "op":
        args = request.get("args")
        if not isinstance(args, list) or not args or not all(isinstance(word, str) for word in args):
            return {"status": "invalid-request"}
        argv = [op, *args]
    else:
        path = request.get("path")
        if not isinstance(path, str) or not os.path.isabs(path):
            return {"status": "invalid-request"}
        try:
            script = open_script(path)
        except FileNotFoundError:
            return {"status": "script-missing"}
        except (OSError, Refusal):
            return {"status": "script-refused"}
        argv = ["/dev/fd/%d" % script]
    try:
        result = run_work(argv, env, () if script is None else (script,))
    except (OSError, subprocess.TimeoutExpired):
        return {"status": "run-failed"}
    finally:
        if script is not None:
            os.close(script)
    return {"status": "ok", "exit": result.returncode, "stdout": encoded(result.stdout)}


def answer(directory, line, op, env):
    """Answer one request and return whether it was a successful call."""
    try:
        request = json.loads(line)
    except (ValueError, UnicodeError):
        return False
    if not isinstance(request, dict):
        return False
    reply = request.get("reply")
    # Requests never select a filesystem path.
    if not isinstance(reply, str) or not re.fullmatch(REPLY_NAME, reply):
        return False
    try:
        fd = open_fifo(directory, reply, os.O_WRONLY)
    except (OSError, Refusal):
        return False
    try:
        response = respond(request, op, env)
        try:
            send(fd, json.dumps(response).encode() + b"\n", time.monotonic() + CALL_SECONDS)
        except (OSError, Refusal):
            pass  # A departed client receives no secret and cannot hold the broker.
    finally:
        os.close(fd)
    return response["status"] == "ok" and response.get("exit", 0) == 0


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
    fifo = None
    created_fifo = False
    try:
        directory = open_directory(args.directory)
        if reused:
            check_own_entries(directory)
        lock = lock_directory(directory)
        env = session(op, args.account or os.environ.get("OP_ACCOUNT"))
        try:
            os.unlink("requests", dir_fd=directory)
        except FileNotFoundError:
            pass
        create_fifo(directory, args.directory, "requests")
        created_fifo = True
        fifo = open_fifo(directory, "requests", os.O_RDWR)
        print("op-broker: state=ready", flush=True)
        pending = bytearray()
        renewing = False
        while True:
            # After a successful call, an idle broker renews the session before it expires.
            if not select.select([fifo], [], [], keepalive if renewing else None)[0]:
                keep_session(op, env)
                continue
            pending.extend(os.read(fifo, 4096))
            while b"\n" in pending:
                line, _, rest = pending.partition(b"\n")
                pending = bytearray(rest)
                renewing = answer(directory, line, op, env) or renewing
            # opq writes at most PIPE_BUF bytes atomically, including the newline.
            if len(pending) >= os.fpathconf(fifo, "PC_PIPE_BUF"):
                pending.clear()
    finally:
        if fifo is not None:
            os.close(fifo)
        if lock is not None:
            if created_fifo:
                os.unlink("requests", dir_fd=directory)
            os.unlink("lock", dir_fd=directory)
            os.close(lock)
            # Live clients own their reply FIFOs. Leave the directory if one remains.
            try:
                args.directory.rmdir()
            except OSError:
                pass
        if directory is not None:
            os.close(directory)


def record(verb, response):
    """Narrow a broker response to the bytes the client writes to its output file."""
    status = response.get("status")
    if status != "ok":
        raise Refusal("read=failed" if verb == "read" else RECORD_REFUSALS.get(status, "response=invalid"))
    if verb == "read":
        return base64.b64decode(response["value"], validate=True)
    exit_status, stdout = response.get("exit"), response.get("stdout")
    if type(exit_status) is not int or not isinstance(stdout, str):
        raise Refusal("response=invalid")
    base64.b64decode(stdout, validate=True)
    return json.dumps({"exit": exit_status, "stdout": stdout}).encode() + b"\n"


def client(args):
    directory = open_directory(args.directory)
    name = uuid.uuid4().hex + ".reply"
    created = False
    reply = None
    output = None
    created_output = False
    success = False
    try:
        request = json.dumps(dict(args.request, reply=name)).encode() + b"\n"
        # A single nonblocking write up to PIPE_BUF is atomic across clients.
        if len(request) > os.fpathconf(directory, "PC_PIPE_BUF"):
            raise Refusal("request=too-large")
        output = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        created_output = True
        create_fifo(directory, args.directory, name)
        created = True
        reply = open_fifo(directory, name, os.O_RDWR)
        fifo = open_fifo(directory, "requests", os.O_WRONLY)
        try:
            if os.write(fifo, request) != len(request):
                raise Refusal("request=incomplete")
        finally:
            os.close(fifo)
        content = record(args.request["verb"], receive(reply, time.monotonic() + CLIENT_SECONDS))
        with os.fdopen(output, "wb") as stream:
            output = None
            stream.write(content)
        success = True
    finally:
        if output is not None:
            os.close(output)
        if reply is not None:
            os.close(reply)
        if created:
            os.unlink(name, dir_fd=directory)
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
    parser = argparse.ArgumentParser(description="Optional 1Password FIFO broker. Platform: Linux and macOS. "
        "Linux only: the op and @SCRIPT requests, a broker whose directory comes from JARVIS_OP_DIRECTORY, "
        "and a broker that reuses an existing directory.",
        epilog="The broker takes OP_SESSION from its environment, or starts op signin --raw when its stdin is a "
               "terminal. Calls disable desktop integration and never print secrets. When JARVIS_OP_KEEPALIVE_SECS "
               "is set, the broker runs op whoami whenever it has been idle that many seconds after a successful "
               "call, which keeps the session past 1Password's idle expiry; unset, it never renews. "
               "Clients need Python 3, not op. read writes the raw value to --output; op and @SCRIPT write one "
               "JSON record {\"exit\": N, \"stdout\": BASE64}. After an op or @SCRIPT request was sent, "
               "request=timeout or request=cancelled leaves its outcome unknown: check before retrying a write. "
               "Stop clients before stopping the broker; it removes its directory when no reply pipe remains.")
    parser.add_argument("--directory", type=Path,
                        help="absolute private FIFO directory dedicated to the broker, otherwise JARVIS_OP_DIRECTORY; "
                             "the broker reuses an existing one only when it holds nothing but its own lock, "
                             "requests and reply pipes")
    if kind == "broker":
        parser.add_argument("--account", help="1Password account, otherwise OP_ACCOUNT")
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
