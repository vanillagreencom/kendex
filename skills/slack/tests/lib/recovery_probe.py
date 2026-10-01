#!/usr/bin/env python3
"""Exercise the real relay with failed storage, a process stop, or live retries.
The shell harness supplies a private root, API, environment and runtime copy.
"""

import http.client
import io
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from api import Slack
from refusals import Refusal
from relay import RootRelay
from settings import load, load_presence
from store import Journal

mode, root = sys.argv[2], Path(sys.argv[3])
settings = load()


class StopAfterPost(Slack):
    """Stop after Slack accepts the message, before the relay gets its ts."""

    def post(self, method, **body):
        answer = super().post(method, **body)
        if method == "chat.postMessage":
            os._exit(9)
        return answer


class FullJournal(Journal):
    """Simulate disk full before the in-flight line reaches disk."""

    def append(self, **line):
        if line.get("t") == "out" and line.get("state") == "inflight":
            raise OSError("disk full")
        super().append(**line)


client = StopAfterPost if mode == "kill" else Slack
api = client(settings.token, settings.api_url)
relay = RootRelay(root, settings, load_presence(root), api, time.time)
if mode == "append-fail":
    relay.journal = FullJournal(root, relay.state)
error = ""
polls = []
try:
    if mode == "journal":
        pass
    elif mode == "catchup-retry":
        for _ in range(2):
            relay.poll("UBOT")
            polls.append({"caught_up": relay.caught_up, "delivered": sorted(relay.state.delivered),
                          "carried": sorted(relay.state.carried)})
    elif mode == "download":
        api.download(sys.argv[4], None, io.BytesIO())
    else:
        if mode == "pending":
            message = json.loads(Path(sys.argv[4]).read_text())
            try:
                relay.on_message(message, "UBOT")
            except Refusal:
                pass
        relay.poll("UBOT")
        if mode == "pending":
            relay.poll("UBOT")
except (Refusal, OSError, http.client.HTTPException) as err:
    error = err.key if isinstance(err, Refusal) else type(err).__name__
print(json.dumps({"error": error, "caught_up": relay.caught_up, "pending": len(relay.pending_live),
                  "unknown": sorted(relay.state.unknown), "polls": polls}))
