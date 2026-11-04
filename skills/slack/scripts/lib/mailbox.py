"""Mailbox reads use Slack's installed mailbox dependency; writes use the root's lane-mail.

The public events and drain commands own the output contract. Their per-poll
process starts exceed the relay's polling contract, so reads call that same
mailbox owner's parser and receipt rules inside this process.

The relay keys every owner message it delivers with `--delivery-id
channel:ts`. Its journal skips a stamp it already carried; for any stamp
the journal lost, the crash between the append and the mark, the mailbox's
locked check-and-append is the judge: a repeat of a key that landed is
answered with the envelope it landed as, and the relay records that id
exactly as it records a first landing. A /report directive is keyed
`command:<trigger_id>` and has no journal line, so that check alone judges
its repeat.
"""

from __future__ import annotations

import errno
import importlib.util
import inspect
import json
import os
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

from refusals import Refusal, keyed
from store import parse_at

LANE_MAIL = Path(".agents/skills/mailbox/scripts/lane-mail")
MAILBOX_SCRIPTS = Path(__file__).resolve().parents[3] / "mailbox" / "scripts"
MAILBOX_READ_FILES = (
    MAILBOX_SCRIPTS / "lib" / "lane-mail-store.py",
    MAILBOX_SCRIPTS / "lib" / "mailbox-append.sh",
    MAILBOX_SCRIPTS / "lib" / "common-root.sh",
)
LANE_MAIL_TIMEOUT_SECONDS = 30
LANE_MAIL_CLEANUP_SECONDS = 5
FIELD_CHOICES = {"box": ("to-overseer", "to-lane"), "kind": ("ask", "notice", "answer", "directive", "resolution")}


class LaneMail:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.script = root / LANE_MAIL
        self.reported_fields: Set[Tuple[str, str]] = set()
        self.reader = None
        self.snapshots: Dict = {}
        self.jq_defs = ""
        self.box: Optional[Path] = None
        if not os.access(self.script, os.X_OK):
            raise Refusal("orch-missing", str(root))

    def _run(self, *args: str) -> Tuple[int, str, str]:
        try:
            result = run_bounded([str(self.script), *args], self.root, LANE_MAIL_TIMEOUT_SECONDS)
            return result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired as err:
            raise Refusal("lane-mail-failed", f"timeout={LANE_MAIL_TIMEOUT_SECONDS} command={args[0]}") from err

    def _read_events(self, receipts: bool = False, strict_receipts: bool = False) -> Tuple[List[Dict], Optional[Tuple[int, Set[str]]]]:
        deadline = time.monotonic() + LANE_MAIL_TIMEOUT_SECONDS
        if self.reader is None:
            path = MAILBOX_READ_FILES[0]
            spec = importlib.util.spec_from_file_location("lane_mail_store", path)
            module = importlib.util.module_from_spec(spec)
            try:
                spec.loader.exec_module(module)
            except OSError as error:
                raise Refusal("orch-missing", str(path)) from error
            reader = getattr(module, "read_events", None)
            if not callable(reader):
                raise Refusal("lane-mail-failed", f"reader=read_events file={path}")
            shell = shutil.which("bash")
            if shell is None:
                raise Refusal("lane-mail-failed", "command-missing=bash")
            definitions = subprocess.run(
                [shell, "-c", 'set -euo pipefail; . "$1"; . "$2"; '
                 'mailbox_root="$(mailbox_common_root "$3")"; '
                 'printf "%s\\0%s" "$mailbox_root" "$MAILBOX_CLASS_JQ$OWNER_TRACKER_JQ"',
                 "mailbox-definitions", str(MAILBOX_READ_FILES[1]),
                 str(MAILBOX_READ_FILES[2]), str(self.root)],
                capture_output=True, text=True, timeout=max(0, deadline - time.monotonic()),
            )
            if definitions.returncode != 0:
                raise Refusal("lane-mail-failed", definitions.stderr.strip())
            # Overseer mail belongs to the main checkout; the installed
            # dependency supplies code. NUL preserves paths
            # containing newlines without splitting the shared definitions.
            mailbox_root, self.jq_defs = definitions.stdout.split("\0", 1)
            self.box = Path(mailbox_root) / "tmp" / "lane-mail" / "overseer"
            self.reader = reader
        try:
            options = {}
            if strict_receipts:
                if "strict_receipts" not in inspect.signature(self.reader).parameters:
                    raise Refusal("lane-mail-failed", "reader=read_events capability=strict_receipts unavailable")
                options["strict_receipts"] = True
            return self.reader(self.box, self.jq_defs, self.snapshots,
                               receipts=receipts, timeout=max(0, deadline - time.monotonic()), **options)
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            raise Refusal("lane-mail-failed", str(error)) from error

    def events(self) -> List[Dict]:
        """Validated envelopes from the mailbox store; absent position metadata
        disables Jarvis-read suppression, never delivery of that envelope."""
        rows, _ = self._read_events()
        envelopes = []
        for envelope in rows:
            # lane-mail writes these fields; optional owner-channel fields
            # are checked here before routing or formatting consumes them.
            invalid = False
            for field in (
                "id", "at", "box", "kind", "text", "from", "to", "ref", "re", "by", "attach", "recommend", "deadline", "mail_class"
            ):
                required = field in ("id", "at", "box", "kind", "text") or field == "re" and envelope.get("kind") == "answer"
                value = envelope.get(field)
                if field not in envelope and not required:
                    continue
                if not isinstance(value, str) or (field != "text" and required and not value):
                    self.bad_field(envelope.get("id"), field)
                    invalid = True
                elif field in ("at", "deadline") and value:
                    try:
                        parse_at(value)
                    except ValueError:
                        self.bad_field(envelope.get("id"), field)
                        invalid = True
                elif value not in FIELD_CHOICES.get(field, (value,)):
                    self.bad_field(envelope.get("id"), field)
                    invalid = True
            options = envelope.get("options", [])
            if not isinstance(options, list) or not all(isinstance(option, str) for option in options):
                self.bad_field(envelope.get("id"), "options")
                invalid = True
            draft = envelope.get("draft")
            if "draft" in envelope and not (
                isinstance(draft, dict) and all(isinstance(draft.get(key), str) and draft[key] for key in ("recipient", "medium", "text"))
            ):
                self.bad_field(envelope.get("id"), "draft")
                invalid = True
            if invalid:
                continue
            if "tracker_posted" in envelope and type(envelope["tracker_posted"]) is not bool:
                self.bad_field(envelope.get("id"), "tracker_posted")
                continue
            # events filters invalid JSON rows, so its output index cannot
            # replace a physical line number supplied by lane-mail.
            for field in ("line", "count"):
                value = envelope.get(field)
                if type(value) is not int or value < 1:
                    self.bad_field(envelope["id"], field)
                    envelope[field] = None
            envelopes.append(envelope)
        return envelopes

    def bad_field(self, env_id: object, field: str) -> None:
        """One keyed system journal diagnostic per envelope field per process.
        Envelope bodies never enter the diagnostic."""
        env_id = env_id if isinstance(env_id, str) and env_id else "unknown"
        pair = (env_id, field)
        if pair not in self.reported_fields:
            self.reported_fields.add(pair)
            print(keyed("envelope-field", f"{self.root} id={env_id} field={field}"), file=sys.stderr, flush=True)

    def _text_file(self, text: str) -> str:
        directory = self.root / "tmp" / "slack"
        directory.mkdir(parents=True, exist_ok=True)
        handle = tempfile.NamedTemporaryFile("w", dir=str(directory), prefix="text-", suffix=".txt", delete=False)
        with handle:
            handle.write(text + "\n")
        return handle.name

    def send_directive(self, text: str, delivery_id: str, parent: Optional[Dict] = None) -> str:
        """Append an owner directive with its optional thread pointer.
        Returns the envelope id, including on a repeated delivery; a root
        with no recorded overseer refuses as any other lane-mail refusal."""
        outcome, value = self.directive(text, delivery_id, parent)
        if outcome == "absent":
            raise Refusal("lane-mail-failed", value)
        return value

    def directive(self, text: str, delivery_id: str, parent: Optional[Dict] = None) -> Tuple[str, str]:
        """lane-mail's answer to one directive, classified once: `landed`
        with the envelope id, a repeated delivery's earlier id included, or
        `absent` with lane-mail's refusal where no overseer is recorded at
        the root, which lane-mail refuses before it appends anything. Any
        other refusal raises. The owner form of `send` judges no reader
        pane; only `peer send` prints `no-reader=`."""
        path = self._text_file(text)
        context = None
        try:
            context = self._text_file(json.dumps(parent)) if parent is not None else None
            pointer = ["--thread-ts", parent["ts"], "--parent", context] if parent is not None else []
            code, out, err = self._run(
                "send", "--item", "overseer", "--directive", "--delivery-id", delivery_id, "--file", path, *pointer
            )
        finally:
            os.unlink(path)
            if context is not None:
                os.unlink(context)
        if code == 0:
            return "landed", _field(out, "id=")
        first = _first(err)
        if first.startswith(f"lane-mail: delivery-repeated={delivery_id} id="):
            return "landed", first.rsplit("id=", 1)[1].strip()
        if first.startswith("lane-mail: overseer-absent="):
            return "absent", err.strip()
        raise Refusal("lane-mail-failed", err.strip() or first)

    def read_receipts(self, strict: bool = False) -> Tuple[int, Set[str]]:
        """The mailbox store's read cursor and directives at or below it.
        Directive ids also judge older producers without line metadata.
        A missed cursor has read none unless strict, which refuses it."""
        _, receipts = self._read_events(receipts=True, strict_receipts=strict)
        assert receipts is not None, "the mailbox store must return requested receipts"
        return receipts

    def answer(self, ask_id: str, text: str, delivery_id: str) -> Tuple[str, str]:
        """Deliver an answer without closing; the mailbox judges repeats
        before closure, so a replay never becomes a directive."""
        path = self._text_file(text)
        try:
            code, out, err = self._run(
                "send", "--item", "overseer", "--re", ask_id, "--file", path, "--delivery-id", delivery_id
            )
        finally:
            os.unlink(path)
        if code == 0:
            return "answered", _field(out, "id=")
        first = _first(err)
        if first.startswith(f"lane-mail: delivery-repeated={delivery_id} id="):
            return "answered", first.rsplit("id=", 1)[1].strip()
        if first.startswith(f"lane-mail: resolved-already={ask_id} id="):
            return "resolved-already", first.rsplit("id=", 1)[1].strip()
        raise Refusal("lane-mail-failed", err.strip() or first)


# A fresh interpreter, not preexec_fn: the relay already has a reader thread.
# This phase exec-replaces itself in the owned session. Only these private
# CLOEXEC pipes carry control data; target stdout can never impersonate it.
_COMMAND_BOOTSTRAP = r'''
import errno, os, signal, sys
request_fd, status_fd = map(int, sys.argv[1:])
os.set_inheritable(request_fd, False)
os.set_inheritable(status_fd, False)
operation = "open"
try:
    score = b"N"
    if sys.platform.startswith("linux"):
        try:
            fd = os.open("/proc/self/oom_score_adj", os.O_RDWR)
        except OSError as error:
            if error.errno != errno.ENOENT:
                raise
            score = b"U"
        else:
            try:
                command_score = 1000
                value = (str(command_score) + "\n").encode("ascii")
                operation = "write"
                if os.write(fd, value) != len(value):
                    raise OSError(errno.EIO, "short score write")
                operation = "seek"
                os.lseek(fd, 0, os.SEEK_SET)
                operation = "read"
                if int(os.read(fd, 32)) != command_score:
                    raise OSError(errno.EIO, "score readback")
                score = b"A"
            finally:
                os.close(fd)
    operation = "protocol"
    os.write(status_fd, b"P" + score)
    import json
    with os.fdopen(request_fd, "rb") as request:
        argv, env = json.load(request)
    for name in ("SIGPIPE", "SIGXFZ", "SIGXFSZ"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), signal.SIG_DFL)
    operation = "exec"
    os.execvpe(argv[0], argv, env)
except BaseException as error:
    code = getattr(error, "errno", None) or errno.EIO
    os.write(status_fd, ("E%s:%d" % (operation, code)).encode("ascii"))
    os._exit(1)
'''


@dataclass
class RunResult:
    returncode: int
    stdout: str
    stderr: str
    stdout_cut: bool = False
    stderr_cut: bool = False
    scoring: str = "not-requested"


class RunTimeout(subprocess.TimeoutExpired):
    def __init__(self, argv: List[str], timeout: float, result: RunResult) -> None:
        super().__init__(argv, timeout, output=result.stdout, stderr=result.stderr)
        self.result = result


class CommandSetupError(OSError):
    def __init__(self, operation: str, code: int, result: RunResult) -> None:
        super().__init__(code, operation)
        self.operation = operation
        self.result = result


class _Capture:
    def __init__(self, limit: Optional[int]) -> None:
        self.limit = limit
        self.data = bytearray(limit or 0)
        self.used = 0
        self.cut = False

    def add(self, chunk: bytes) -> None:
        if self.limit is None:
            self.data.extend(chunk)
        else:
            size = min(len(chunk), self.limit - self.used)
            memoryview(self.data)[self.used:self.used + size] = memoryview(chunk)[:size]
            self.used += size
            self.cut = self.cut or size < len(chunk)

    def text(self) -> str:
        data = self.data if self.limit is None else memoryview(self.data)[:self.used]
        text = bytes(data).decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", "\n")
        del data
        self.data = bytearray()
        return text


def run_bounded(argv: List[str], cwd: Path, timeout: Optional[float], env: Optional[Dict[str, str]] = None,
                *, command_output_limit: Optional[int] = None) -> RunResult:
    """Own one session from acquisition through bounded TERM/KILL cleanup.

    Command mode retains at most command_output_limit bytes per stream and
    drains the rest; direct LaneMail calls retain whole output for parsing.
    One entry deadline includes bootstrap setup and pipe traffic. Cleanup
    adds at most three LANE_MAIL_CLEANUP_SECONDS waits, reusing the buffers.
    Detached descendants and uninterruptible kernel operations are not a
    containment guarantee. UTF-8 replacement and universal newlines match
    the text-mode contract, including decoded TimeoutExpired streams.
    """
    deadline = None if timeout is None else time.monotonic() + timeout
    command = command_output_limit is not None
    capture = {"stdout": _Capture(command_output_limit), "stderr": _Capture(command_output_limit)}
    selector = selectors.DefaultSelector()
    private_fds: Set[int] = set()
    proc = None
    streams = {}
    request = None
    status = bytearray()
    timed_out = False

    def close(fd: int) -> None:
        selector.unregister(fd)
        # Popen owns its file objects; closing them here avoids double closes
        # when another thread allocates an fd with the same number.
        if fd in streams:
            streams.pop(fd).close()
        else:
            os.close(fd)
            private_fds.discard(fd)

    def pump(until: Optional[float]) -> bool:
        nonlocal request
        while selector.get_map():
            remaining = None if until is None else until - time.monotonic()
            if remaining is not None and remaining <= 0:
                return False
            for key, _ in selector.select(remaining):
                fd, kind = key.fd, key.data
                try:
                    if kind == "request":
                        try:
                            size = os.write(fd, request[:4096])
                            request = request[size:]
                        except BrokenPipeError:
                            request = memoryview(b"")
                        if not request:
                            close(fd)
                            request = None
                    else:
                        chunk = os.read(fd, 4096 if kind != "status" else 32 - len(status))
                        if not chunk:
                            close(fd)
                        elif kind == "status":
                            status.extend(chunk)
                            if len(status) == 32:
                                close(fd)
                        else:
                            capture[kind].add(chunk)
                except BlockingIOError:
                    continue
        return True

    def finish(until: Optional[float]) -> bool:
        if not pump(until):
            return False
        remaining = None if until is None else until - time.monotonic()
        if remaining is not None and remaining <= 0:
            return False
        try:
            proc.wait(timeout=remaining)
            return True
        except subprocess.TimeoutExpired:
            return False

    def cleanup() -> None:
        # Never reap the leader before the last group signal: its unreaped
        # PID keeps the process-group identity owned while pipes are held.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                pass
            if finish(time.monotonic() + LANE_MAIL_CLEANUP_SECONDS):
                return
        # Pipes may be held by descendants outside our session. Close them
        # in finally rather than allocate or wait forever in communicate.
        try:
            proc.wait(timeout=LANE_MAIL_CLEANUP_SECONDS)
        except subprocess.TimeoutExpired:
            pass

    try:
        launch = argv
        inherited = ()
        if command:
            request_read, request_write = os.pipe()
            private_fds.update((request_read, request_write))
            status_read, status_write = os.pipe()
            private_fds.update((status_read, status_write))
            request = memoryview(json.dumps([argv, dict(os.environ) if env is None else env], ensure_ascii=True).encode("ascii"))
            launch = [sys.executable, "-I", "-S", "-c", _COMMAND_BOOTSTRAP, str(request_read), str(status_write)]
            inherited = (request_read, status_write)
        proc = subprocess.Popen(launch, cwd=str(cwd), env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
                                close_fds=True, pass_fds=inherited, start_new_session=True)
        for fd in inherited:
            os.close(fd)
            private_fds.remove(fd)
        for stream, kind in ((proc.stdout, "stdout"), (proc.stderr, "stderr")):
            streams[stream.fileno()] = stream
            os.set_blocking(stream.fileno(), False)
            selector.register(stream.fileno(), selectors.EVENT_READ, kind)
        if command:
            for fd, event, kind in ((request_write, selectors.EVENT_WRITE, "request"),
                                    (status_read, selectors.EVENT_READ, "status")):
                os.set_blocking(fd, False)
                selector.register(fd, event, kind)
        if not finish(deadline):
            timed_out = True
            cleanup()
        result = RunResult(proc.returncode, capture["stdout"].text(), capture["stderr"].text(),
                           capture["stdout"].cut, capture["stderr"].cut)
        prepared = bytes(status[:2])
        if command and prepared in (b"PA", b"PN", b"PU"):
            result.scoring = {b"PA": "applied", b"PN": "not-linux", b"PU": "absent"}[prepared]
            del status[:2]
        if timed_out:
            raise RunTimeout(argv, timeout, result)
        if command:
            if status or result.scoring == "not-requested":
                try:
                    operation, code = bytes(status[1:]).decode("ascii").split(":")
                    if status[:1] != b"E":
                        raise ValueError("status")
                    code = int(code)
                except ValueError:
                    operation, code = "protocol", errno.EIO
                raise CommandSetupError(operation, code, result)
        return result
    except BaseException:
        if proc is not None and proc.returncode is None and not timed_out:
            cleanup()
        raise
    finally:
        selector.close()
        for fd in private_fds:
            os.close(fd)
        if proc is not None:
            proc.stdout.close()
            proc.stderr.close()


def _first(text: str) -> str:
    return text.splitlines()[0] if text.strip() else "(no output)"


def _field(receipt: str, marker: str) -> str:
    for word in receipt.split():
        if word.startswith(marker):
            return word[len(marker):]
    raise Refusal("lane-mail-failed", f"receipt without {marker}: {_first(receipt)}")
