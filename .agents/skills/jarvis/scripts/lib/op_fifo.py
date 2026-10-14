"""Private FIFO transport for the optional 1Password read route on Linux/macOS."""
import argparse
import base64
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


class Refusal(Exception):
    pass


class Cancelled(Exception):
    def __init__(self, signum):
        self.signum = signum


def open_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    info = os.fstat(fd)
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        os.close(fd)
        raise Refusal("directory=private-owner-required")
    return fd


def open_fifo(directory, name, flags):
    fd = os.open(name, flags | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
    info = os.fstat(fd)
    if not stat.S_ISFIFO(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        os.close(fd)
        raise Refusal("fifo=private-owner-required")
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
        result = call_op([op, "signin", "--raw"], env, interactive=True)
        if result.returncode or not result.stdout.strip():
            raise Refusal("session=signin-failed")
        token = result.stdout.decode().strip()
    env["OP_SESSION"] = token
    result = call_op([op, "whoami"], env)
    if result.returncode:
        raise Refusal("session=unavailable")
    return env


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


def answer(directory, line, op, env):
    try:
        request = json.loads(line)
    except (ValueError, UnicodeError):
        return
    if not isinstance(request, dict):
        return
    reply = request.get("reply")
    # opq produces one basename. Requests never select a filesystem path.
    if not isinstance(reply, str) or not re.fullmatch(r"[0-9a-f]{32}\.reply", reply):
        return
    try:
        fd = open_fifo(directory, reply, os.O_WRONLY)
    except (OSError, Refusal):
        return
    try:
        reference = request.get("reference")
        if request.get("verb") != "read" or not isinstance(reference, str) or not reference.startswith("op://"):
            response = {"status": "invalid-request"}
        else:
            try:
                result = call_op([op, "read", "--no-newline", reference], env)
                response = ({"status": "ok", "value": base64.b64encode(result.stdout).decode()}
                            if result.returncode == 0 else {"status": "read-failed"})
            except (OSError, subprocess.TimeoutExpired):
                response = {"status": "read-failed"}
        try:
            send(fd, json.dumps(response).encode() + b"\n", time.monotonic() + CALL_SECONDS)
        except (OSError, Refusal):
            pass  # A departed client receives no secret and cannot hold the broker.
    finally:
        os.close(fd)


def broker(args):
    op = shutil.which("op")
    if op is None:
        raise Refusal("optional-dependency=op\nThe 1Password route is optional. Install op before starting it.")
    os.mkdir(args.directory, 0o700)
    directory = None
    fifo = None
    created_fifo = False
    try:
        directory = open_directory(args.directory)
        env = session(op, args.account or os.environ.get("OP_ACCOUNT"))
        create_fifo(directory, args.directory, "requests")
        created_fifo = True
        fifo = open_fifo(directory, "requests", os.O_RDWR)
        print("op-broker: state=ready", flush=True)
        pending = bytearray()
        while True:
            select.select([fifo], [], [])
            pending.extend(os.read(fifo, 4096))
            while b"\n" in pending:
                line, _, rest = pending.partition(b"\n")
                pending = bytearray(rest)
                answer(directory, line, op, env)
            # opq writes at most PIPE_BUF bytes atomically, including the newline.
            if len(pending) >= os.fpathconf(fifo, "PC_PIPE_BUF"):
                pending.clear()
    finally:
        if fifo is not None:
            os.close(fifo)
        if directory is not None:
            if created_fifo:
                os.unlink("requests", dir_fd=directory)
            os.close(directory)
        # Live clients own their reply FIFOs. Leave the directory if one remains.
        try:
            args.directory.rmdir()
        except OSError:
            pass


def client(args):
    directory = open_directory(args.directory)
    name = uuid.uuid4().hex + ".reply"
    created = False
    reply = None
    output = None
    created_output = False
    success = False
    try:
        output = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        created_output = True
        create_fifo(directory, args.directory, name)
        created = True
        reply = open_fifo(directory, name, os.O_RDWR)
        request = json.dumps({"verb": "read", "reference": args.reference, "reply": name}).encode() + b"\n"
        fifo = open_fifo(directory, "requests", os.O_WRONLY)
        try:
            if len(request) > os.fpathconf(fifo, "PC_PIPE_BUF"):
                raise Refusal("request=too-large")
            # A single nonblocking write up to PIPE_BUF is atomic across clients.
            if os.write(fifo, request) != len(request):
                raise Refusal("request=incomplete")
        finally:
            os.close(fifo)
        response = receive(reply, time.monotonic() + CLIENT_SECONDS)
        if response.get("status") != "ok":
            raise Refusal("read=failed")
        with os.fdopen(output, "wb") as stream:
            output = None
            stream.write(base64.b64decode(response["value"], validate=True))
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


def main(kind):
    parser = argparse.ArgumentParser(description="Optional 1Password FIFO read route. Platform: Linux and macOS.",
        epilog="The broker retains OP_SESSION in memory or starts op signin --raw in its terminal. "
               "Reads disable desktop integration and never print secrets. Clients need Python 3, not op. "
               "Stop clients before Ctrl-C stops the broker and removes its owned directory.")
    parser.add_argument("--directory", type=Path, required=True, help="absolute private FIFO directory; broker creates it exclusively")
    if kind == "broker":
        parser.add_argument("--account", help="1Password account, otherwise OP_ACCOUNT")
    else:
        parser.add_argument("verb", choices=("read",))
        parser.add_argument("reference")
        parser.add_argument("--output", type=Path, required=True, help="absolute mode-600 output file, created exclusively")
    args = parser.parse_args()
    if sys.platform not in ("linux", "darwin"):
        parser.exit(2, "op-" + kind + ": platform=unsupported\n")
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
