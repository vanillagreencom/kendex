#!/usr/bin/env python3
"""Exercise the real relay with failed storage, a process stop, live retries
or Slack's rate limit.
The shell harness supplies a private root, API, environment and runtime copy.
"""

import http.client
import io
import json
import os
import sys
import time
import urllib.request
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
injected = []
try:
    if mode == "journal":
        pass
    elif mode == "positions":
        original = api.get
        calls = []
        def traced(method, **params):
            if method in ("conversations.history", "conversations.replies"):
                calls.append({"method": method, "oldest": params.get("oldest"), "ts": params.get("ts")})
            return original(method, **params)
        api.get = traced
        for index in range(2):
            relay.due = set()
            relay.poll("UBOT")
            polls.append(calls[:])
            calls.clear()
            if index == 0 and sys.argv[4]:
                # The fake emits the first replies with no socket consumer.
                for message in json.loads(Path(sys.argv[4]).read_text()):
                    injected.append(api.post("_test/message", **message)["ts"])
    elif mode == "catchup-retry":
        for _ in range(2):
            relay.poll("UBOT")
            polls.append({"caught_up": relay.due is None, "delivered": sorted(relay.state.delivered),
                          "carried": sorted(relay.state.carried)})
    elif mode == "allowance":
        # Slack lets the given count of conversations.replies calls through
        # per window, then answers 429 with a 60-second Retry-After. A second
        # poll falls 30 seconds into it; the relay's clock then moves past it.
        # A running relay's reconnect reads history from the saved position.
        relay.discovered = True
        skew = 0.0
        relay.clock = lambda: time.time() + skew
        slept, replies = [], []
        api.sleep = slept.append
        original = api.get
        def counted(method, **params):
            if method == "conversations.replies":
                replies.append(params.get("ts"))
            return original(method, **params)
        api.get = counted
        fault = {"method": "conversations.replies", "status": 429, "retry_after": 60, "after": int(sys.argv[4])}
        for _ in range(8):
            for path, body in (("faults-reset", {}), ("fault", fault)):
                urllib.request.urlopen(urllib.request.Request(f"{settings.api_url}/_test/{path}", json.dumps(body).encode()))
            for wait in (0, 30):
                skew += wait
                relay.poll("UBOT")
                polls.append({"caught_up": relay.due is None, "delivered": sorted(relay.state.delivered),
                              "replies": len(replies), "slept": slept[:]})
                replies.clear()
                slept.clear()
            if relay.due is None:
                break
            skew += 31
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
print(json.dumps({"error": error, "caught_up": relay.due is None, "pending": len(relay.pending_live),
                  "unknown": sorted(relay.state.unknown), "polls": polls, "injected": injected}))
