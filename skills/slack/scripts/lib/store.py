"""What one checkout keeps under tmp/slack/: the binding, the journal, the
status record, the relay lock, and the files owners sent.

The journal is a transport ledger of identifiers, one JSON object per line,
replayed into `State` at start and appended to as the relay works. Its line
shapes are schemas/journal.md. Nothing here but an owner's file holds a
message body.
"""

from __future__ import annotations

import contextlib
import datetime
import errno
import fcntl
import json
import os
import re
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import BinaryIO, Callable, Dict, List, Optional, Set

from refusals import Refusal

DIR = "tmp/slack"
BINDING = "binding.json"
JOURNAL = "journal.jsonl"
STATUS = "status.json"
LOCK = "listen.lock"
FILES = "files"
# `<id>-<name>` is cut to this many characters, each ASCII once substituted,
# so it stays inside the 255 bytes a file name may take.
NAME_CHARS = 200
LINE_KINDS = {
    "seen", "start", "hold", "resume", "in", "out", "resolved", "bound", "thread", "mark",
    "connect", "reconnect", "disconnect",
}
# The lines a Socket Mode connection's changes write; replay reads nothing
# from them, and `compact` drops one by its `at`.
CONNECTION_KINDS = {"connect", "reconnect", "disconnect"}
# A directive's receipt marks, the reaction names its `mark` lines carry.
SEEN = "eyes"
READ = "white_check_mark"
AT_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


def parse_at(at: str) -> float:
    """An envelope's `at`, the UTC second lane-mail stamps, as epoch
    seconds; ValueError when it is not one."""
    stamp = datetime.datetime.strptime(at, AT_FORMAT)
    return stamp.replace(tzinfo=datetime.timezone.utc).timestamp()


def format_at(epoch: float) -> str:
    """Epoch seconds as the UTC second lane-mail would stamp them."""
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime(AT_FORMAT)


def root_dir(root: Path) -> Path:
    return root / DIR


@dataclass
class Binding:
    """The channel one checkout is bound to. `bound_at` is the moment of the
    binding as a Slack stamp, the history position a start with no seeds
    begins from."""

    channel: str
    channel_name: str
    bound_at: str
    owners: List[str]
    owner_ids: Dict[str, str]

    def to_json(self) -> Dict:
        return {
            "channel": self.channel,
            "channel_name": self.channel_name,
            "bound_at": self.bound_at,
            "owners": self.owners,
            "owner_ids": self.owner_ids,
        }


def read_binding(root: Path) -> Binding:
    path = root_dir(root) / BINDING
    if not path.is_file():
        raise Refusal("root-unbound", str(root))
    try:
        raw = json.loads(path.read_text())
        float(raw["bound_at"])
        return Binding(
            channel=str(raw["channel"]),
            channel_name=str(raw["channel_name"]),
            bound_at=str(raw["bound_at"]),
            owners=[str(o) for o in raw["owners"]],
            owner_ids={str(k): str(v) for k, v in raw["owner_ids"].items()},
        )
    except (ValueError, KeyError, TypeError, AttributeError) as err:
        raise Refusal("binding-invalid", str(path)) from err


def write_binding(root: Path, binding: Binding) -> None:
    path = root_dir(root) / BINDING
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(binding.to_json(), indent=2) + "\n")
    os.replace(tmp, path)


def save_file(root: Path, file_id: str, name: str, fill: Callable[[BinaryIO], None]) -> Path:
    """An owner's file at tmp/slack/files/<id>-<name>, the directory 700 and
    the file 600. Every character outside [A-Za-z0-9._-] becomes `_`, so the
    name is one path component, cut to NAME_CHARS. `fill` writes a temporary
    beside it, renamed only once `fill` returns, so the path never names part
    of a file: `fill` raises on a download that ended short."""
    directory = root_dir(root) / FILES
    directory.mkdir(parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    target = directory / re.sub(r"[^A-Za-z0-9._-]", "_", f"{file_id}-{name}")[:NAME_CHARS]
    fd, tmp = tempfile.mkstemp(dir=str(directory), prefix=".part-")
    try:
        with os.fdopen(fd, "wb") as out:
            fill(out)
        os.replace(tmp, target)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise
    return target


@dataclass
class Thread:
    """One bound Slack thread: the parent's ts and the envelope it carries."""

    ts: str
    envelope: str
    kind: str
    seen: str = "0"
    open: bool = False


@dataclass
class Window:
    """One closed master hold: from the second of SLACK_MASTER_FILE's mtime
    its first poll read, to the second the hold ended."""

    from_at: str
    at: str


@dataclass
class State:
    """The journal replayed: what was carried, what is bound, where to read."""

    seen_ts: str = "0"
    start_at: str = ""
    # Whether a `start` line was replayed, the last line of the first
    # start's seeds; connection lines alone leave it False.
    seeded: bool = False
    start_ids: Set[str] = field(default_factory=set)
    held: bool = False
    hold_at: str = ""
    holds: List[Window] = field(default_factory=list)
    carried: Set[str] = field(default_factory=set)
    delivered: Dict[str, str] = field(default_factory=dict)
    threads: Dict[str, Thread] = field(default_factory=dict)
    by_envelope: Dict[str, str] = field(default_factory=dict)
    unknown: Dict[str, str] = field(default_factory=dict)
    pending_files: Dict[str, str] = field(default_factory=dict)
    refused: Dict[str, str] = field(default_factory=dict)
    ignored: Set[str] = field(default_factory=set)
    directives: Set[str] = field(default_factory=set)
    marks: Dict[str, str] = field(default_factory=dict)

    def apply(self, line: Dict) -> None:
        kind = line.get("t")
        if kind == "seen":
            self.seen_ts = str(line["ts"])
        elif kind == "start":
            self.start_at = str(line["at"])
            self.start_ids = {str(i) for i in line["ids"]}
            self.seeded = True
        elif kind == "hold":
            self.held = True
            self.hold_at = str(line["at"])
        elif kind == "resume":
            self.held = False
            self.holds.append(Window(str(line["from_at"]), str(line["at"])))
        elif kind == "in":
            ts = str(line["ts"])
            if line["kind"] == "ignored":
                self.ignored.add(ts)
                return
            self.delivered[ts] = str(line["id"])
            self.carried.add(str(line["id"]))
            if line["kind"] == "directive":
                self.directives.add(ts)
            thread_ts = str(line["thread"])
            if thread_ts not in self.threads:
                self.threads[thread_ts] = Thread(ts=thread_ts, envelope=str(line["id"]), kind=line["kind"])
            self.by_envelope[str(line["id"])] = thread_ts
        elif kind == "out":
            env_id = str(line["id"])
            state = line["state"]
            parse_at(str(line["at"]))  # the age `compact` judges the line by
            if state == "unknown":
                self.unknown[env_id] = str(line["kind"])
                self.carried.add(env_id)
                return
            self.unknown.pop(env_id, None)
            self.carried.add(env_id)
            if state == "refused":
                self.refused[env_id] = str(line["reason"])
                return
            if state == "file":
                self.pending_files[str(line["file"])] = env_id
                return
            thread_ts = str(line["thread"])
            if thread_ts not in self.threads:
                self.threads[thread_ts] = Thread(ts=thread_ts, envelope=env_id, kind=line["kind"], open=state == "open")
            self.by_envelope[env_id] = thread_ts
        elif kind == "resolved":
            thread_ts = self.by_envelope.get(str(line["id"]))
            if thread_ts in self.threads:
                self.threads[thread_ts].open = False
        elif kind == "bound":
            env_id = self.pending_files.pop(str(line["file"]), str(line["id"]))
            thread_ts = str(line["ts"])
            self.threads[thread_ts] = Thread(ts=thread_ts, envelope=env_id, kind="notice")
            self.by_envelope[env_id] = thread_ts
        elif kind == "thread":
            thread = self.threads.get(str(line["ts"]))
            if thread is not None:
                thread.seen = str(line["seen"])
        elif kind == "mark":
            self.marks[str(line["ts"])] = str(line["name"])
        elif kind in CONNECTION_KINDS:
            parse_at(str(line["at"]))  # the age `compact` judges the line by
        else:
            raise KeyError(kind)


def journal_exists(root: Path) -> bool:
    return (root_dir(root) / JOURNAL).is_file()


def read_journal(root: Path) -> State:
    state = State()
    path = root_dir(root) / JOURNAL
    if not path.is_file():
        return state
    with path.open() as handle:
        for number, raw in enumerate(handle, 1):
            if not raw.strip():
                continue
            try:
                state.apply(json.loads(raw))
            except (ValueError, KeyError, TypeError) as err:
                raise Refusal("journal-invalid", f"{path}:{number}") from err
    return state


class Journal:
    def __init__(self, root: Path, state: State) -> None:
        self.path = root_dir(root) / JOURNAL
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.state = state

    def append(self, **line: object) -> None:
        if line.get("t") not in LINE_KINDS:
            raise KeyError(line.get("t"))
        with self.path.open("a") as handle:
            handle.write(json.dumps(line, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        self.state.apply(line)


def compact(root: Path, cutoff_ts: float) -> int:
    """Drop resolved and ignored lines older than the cutoff, every report
    upload and receipt mark older than it, every history position but the
    last, every hold line but a standing one, every resume line whose end
    is older than the cutoff, and every connection line older than it; keep every open thread, and the `in` and
    `mark` lines of a directive not yet marked READ, whatever its age: one
    with no mark, which the relay marks SEEN on its next poll, and one
    marked SEEN, which it swaps for READ once the overseer reads it.
    Returns the lines dropped. An `out` line and a `resume` line are judged
    by the `at` they journal, the age `post_events` never posts past, so
    what they name can never post again."""
    path = root_dir(root) / JOURNAL
    state = read_journal(root)
    if not path.is_file():
        return 0
    with path.open() as handle:
        raws = [raw for raw in handle if raw.strip()]
    lines = [json.loads(raw) for raw in raws]
    last_seen = max((i for i, line in enumerate(lines) if line.get("t") == "seen"), default=-1)
    last_hold = max((i for i, line in enumerate(lines) if line.get("t") in ("hold", "resume")), default=-1)
    kept: List[str] = []
    dropped = 0
    for index, (raw, line) in enumerate(zip(raws, lines)):
        kind = line.get("t")
        old = "ts" in line and _ts_float(str(line["ts"])) < cutoff_ts
        aged = (kind in ("out", "resume") or kind in CONNECTION_KINDS) and parse_at(str(line["at"])) < cutoff_ts
        pending = kind in ("in", "mark") and str(line["ts"]) in state.directives and state.marks.get(str(line["ts"])) != READ
        drop = False
        if kind == "seen":
            drop = index != last_seen
        elif kind == "hold":
            drop = index != last_hold
        elif kind == "resume":
            drop = aged
        elif kind in CONNECTION_KINDS:
            drop = aged
        elif kind == "in" and old:
            thread = state.threads.get(str(line.get("thread", "")))
            drop = line["kind"] == "ignored" or not (pending or thread is not None and thread.open)
        elif aged and line["state"] == "file":
            drop = True
        elif aged and line["state"] in ("open", "resolved"):
            thread = state.threads.get(str(line["thread"]))
            drop = thread is None or not thread.open
        elif kind == "resolved":
            thread_ts = state.by_envelope.get(str(line["id"]))
            drop = thread_ts is None or _ts_float(thread_ts) < cutoff_ts
        elif kind in ("bound", "thread") and old:
            thread = state.threads.get(str(line["ts"]))
            drop = thread is None or not thread.open
        elif kind == "mark" and old:
            drop = not pending
        if drop:
            dropped += 1
        else:
            kept.append(raw if raw.endswith("\n") else raw + "\n")
    tmp = path.with_suffix(".jsonl.tmp")
    tmp.write_text("".join(kept))
    os.replace(tmp, path)
    return dropped


def _ts_float(ts: str) -> float:
    try:
        return float(ts)
    except ValueError:
        return 0.0


def read_status(root: Path) -> Optional[Dict]:
    path = root_dir(root) / STATUS
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except ValueError:
        return None


def write_status(root: Path, record: Dict) -> None:
    path = root_dir(root) / STATUS
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(record, sort_keys=True) + "\n")
    os.replace(tmp, path)


class RelayLock:
    """The OS lock one relay holds on a checkout for its lifetime."""

    def __init__(self, root: Path) -> None:
        self.path = root_dir(root) / LOCK
        self.handle = None

    def acquire(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        handle = self.path.open("a+")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as err:
            handle.seek(0)
            holder = handle.read().strip() or "unknown"
            handle.close()
            if err.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                raise Refusal("relay-running", f"{self.path.parent.parent.parent} pid={holder}") from err
            raise Refusal("lock-failed", f"{self.path} ({err.strerror})") from err
        handle.seek(0)
        handle.truncate()
        handle.write(str(os.getpid()))
        handle.flush()
        self.handle = handle
