"""Local queue transport between a hosted receiver's worker and the relay.

Only the listener handles events and writes outcomes. A timed-out caller
leaves its request queued: delivery can still finish, and channel:ts judges
the worker's retry through the existing journal and mailbox.
"""

from __future__ import annotations

import json
import math
import os
import tempfile
import time
import uuid
from pathlib import Path
from typing import Callable, Dict, TextIO

from refusals import Refusal
from store import RelayLock, read_status, root_dir


def read_event(stream: TextIO) -> Dict:
    """The hosted receiver authenticates and unwraps callbacks. Its worker
    passes only the inner message event to this local delivery boundary."""
    try:
        event = json.load(stream)
    except ValueError as err:
        raise Refusal("event-invalid", "json") from err
    if not isinstance(event, dict) or event.get("type") != "message":
        raise Refusal("event-invalid", "type")
    if not isinstance(event.get("channel"), str) or not event["channel"]:
        raise Refusal("event-invalid", "channel")
    for name in ("ts", "thread_ts"):
        if name == "thread_ts" and not event.get(name):
            continue
        stamp = event.get(name)
        try:
            valid = isinstance(stamp, str) and math.isfinite(float(stamp)) and float(stamp) > 0
        except ValueError:
            valid = False
        if not valid:
            raise Refusal("event-invalid", name)
    if event.get("text") is not None and not isinstance(event["text"], str):
        raise Refusal("event-invalid", "text")
    files = event.get("files") or []
    if not isinstance(files, list) or any(not isinstance(item, dict) or not isinstance(item.get("id"), str)
                                          or not item["id"] for item in files):
        raise Refusal("event-invalid", "files")
    return event


def directory(root: Path, name: str) -> Path:
    path = root_dir(root) / name
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)
    return path


def write(path: Path, value: Dict) -> None:
    """Publish a complete private request or outcome before readers see it."""
    fd, temporary = tempfile.mkstemp(prefix=".part-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def submit(root: Path, event: Dict, seconds: int, clock: Callable[[], float] = time.monotonic,
           sleep: Callable[[float], None] = time.sleep) -> Dict:
    """Wait for this attempt alone; a stopped listener cannot accept work."""
    lock = RelayLock(root)
    if not lock.held():
        raise Refusal("relay-absent", str(root))
    mode = (read_status(root) or {}).get("inbound", "socket")
    if mode != "queue":
        raise Refusal("inbound-mode", mode)
    name = f"{time.time_ns():020d}-{uuid.uuid4().hex}.json"
    try:
        inbox = directory(root, "inbox")
        target = directory(root, "outcomes") / name
        write(inbox / name, event)
        deadline = clock() + seconds
        while True:
            if target.exists():
                return json.loads(target.read_text())
            if not lock.held():
                raise Refusal("relay-absent", str(root))
            remaining = deadline - clock()
            if remaining <= 0:
                raise Refusal("delivery-timeout", f"{root} request={name}")
            sleep(min(0.1, remaining))
    except OSError as err:
        raise Refusal("queue-unavailable", f"{root} ({err})") from err


def outcome(root, event: Dict, bot_user: str) -> Dict:
    if event["channel"] != root.channel:
        raise Refusal("channel-mismatch", str(event["channel"]))
    ts = event["ts"]
    if ts in root.state.delivered:
        raise Refusal("delivery-repeated", f"{root.channel}:{ts}")
    if ts in root.state.ignored:
        raise Refusal(root.state.ignored[ts], f"{root.channel}:{ts}")
    # Bot-upload events complete the existing outbound file binding before
    # the owner-message handler discards bot text.
    bound = [root.state.pending_files[item["id"]] for item in event.get("files") or []
             if item.get("id") in root.state.pending_files]
    root.on_message(event, bot_user, path="queue")
    envelope = root.state.delivered.get(ts) or next(
        (item for item in bound if root.state.by_envelope.get(item) == ts), "")
    if envelope:
        return {"key": "delivered", "value": f"ts={ts} id={envelope} path=queue"}
    if ts in root.state.ignored:
        raise Refusal(root.state.ignored[ts], f"{root.channel}:{ts}")
    raise Refusal("event-ignored", f"{root.channel}:{ts}")


def drain(root, bot_user: str) -> None:
    inbox = directory(root.path, "inbox")
    outcomes = directory(root.path, "outcomes")
    for request in sorted(inbox.glob("*.json")):
        target = outcomes / request.name
        failure = None
        if not target.exists():
            try:
                event = json.loads(request.read_text())
                result = outcome(root, event, bot_user)
            except Refusal as err:
                result = {"key": err.key, "value": err.value}
                if err.key == "slack-auth-failed":
                    failure = err
            write(target, result)
        request.unlink()
        if failure is not None:
            raise failure
