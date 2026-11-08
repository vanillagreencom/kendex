"""Exercise queue dispatch and its wait bound with an injected clock."""

import contextlib
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])

from inbound import drain, submit
from refusals import Refusal
from relay import RootRelay
from settings import load, load_presence
from store import write_status
from verbs import api_for

root = Path(sys.argv[2])
mode = sys.argv[3]
settings = load()
listener = RootRelay(root, settings, load_presence(root), api_for(settings), lambda: 0)
listener.lock.acquire()
write_status(root, {"inbound": "queue"})
event = {"type": "message", "channel": listener.channel, "ts": "1794111600.000001",
         "user": "U001", "text": "Injected queue delivery."}
event.update({"not-owner": {"user": "U404"}, "no-text": {"text": ""},
              "bot": {"user": "UBOT", "bot_id": "B001"},
              "edit": {"subtype": "message_changed"}}.get(mode, {}))
now = [0.0]


def advance(seconds):
    now[0] += seconds
    if mode != "timeout":
        drain(listener, "UBOT")


try:
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            result = submit(root, event, 20, clock=lambda: now[0], sleep=advance)
            if mode == "repeat":
                result = submit(root, event, 20, clock=lambda: now[0], sleep=advance)
    except Refusal as err:
        result = {"key": err.key, "value": err.value}
    result["elapsed"] = now[0]
    result["pending"] = len(list((root / "tmp/slack/inbox").glob("*.json")))
    print(json.dumps(result))
finally:
    listener.lock.release()
