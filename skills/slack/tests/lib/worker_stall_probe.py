#!/usr/bin/env python3
"""Drive the public listen command with bounded stalls and moving work."""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path
from types import SimpleNamespace


if sys.argv[1] != "--child":
    mode = sys.argv[3]
    with subprocess.Popen([sys.executable, __file__, "--child", *sys.argv[1:]],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          env=dict(os.environ)) as child:
        try:
            out, err = child.communicate(timeout=12)
        except subprocess.TimeoutExpired:
            child.kill()
            child.communicate()
            raise AssertionError("listener did not exit within the parent deadline")
    rows = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
    if mode in ("reconnect", "connected", "api-progress", "download"):
        assert child.returncode == 0, (child.returncode, err)
        assert len(rows) == 1 and rows[0]["elapsed"] > 2 * rows[0]["bound"], rows
        if mode == "reconnect":
            assert rows[0]["polls"] >= 4 and rows[0]["attempts"] >= 3, rows
        elif mode == "connected":
            assert rows[0]["polls"] >= 4 and rows[0]["attempts"] == 1, rows
            assert rows[0]["api_after_first_poll"] == 0, rows
        elif mode == "api-progress":
            assert rows[0]["api_calls"] >= 8 and rows[0]["polls"] == 1, rows
        else:
            assert rows[0]["file_bytes"] == "moving-file-" * 8, rows
            assert rows[0]["delivered"] and rows[0]["chunks"] >= 8, rows
        assert "slack: worker-stalled=" not in err, err
    else:
        assert rows == [{"blocked": mode}], rows
        assert child.returncode == 2, (child.returncode, err)
        stages = {"startup-api": "startup", "startup-api-once": "startup",
                  "startup-dns": "api:auth.test", "connect-api": "connect",
                  "connect-dns": "connect", "poll-api": "poll", "download-stall": "download"}
        lines = [line for line in err.splitlines() if line.startswith("slack: worker-stalled=")]
        assert len(lines) == 1, err
        match = re.fullmatch(r"slack: worker-stalled=(\S+) age=([0-9.]+)s bound=([0-9.]+)s", lines[0])
        assert match and match[1] == stages[mode], lines
        assert float(match[2]) >= float(match[3]), lines
    sys.exit(0)

del sys.argv[1]
sys.path.insert(0, sys.argv[1])
import api
import main
import relay
from api import Slack
from refusals import Refusal
from settings import load

root, mode, file_path = Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
settings = load()
# Shorten existing figures inside this child. The connected clock advances
# only at polls, so reader shutdown cannot age with runner scheduling delays.
settings.poll_seconds = 0.2
relay.RECONNECT_BOUND_SECONDS = 1
relay.RETRY_FIRST_SECONDS = 0.4
relay.RETRY_MAX_SECONDS = 0.8
main.load = lambda **kwargs: settings
bound = 1.2
clock = time.monotonic
connected_time = 0.0
if mode == "connected":
    clock = lambda: connected_time
    relay.time = SimpleNamespace(monotonic=clock, time=time.time, sleep=time.sleep)
started = clock()
polls, attempts, api_calls, chunks = [], [], [], []
original_get, original_post, original_open = Slack.get, Slack.post, Slack._open
original_poll = relay.RootRelay.poll
original_poll_once = relay.Relay.poll_once
original_urlopen = urllib.request.urlopen
saved_bytes, delivered = "", False
once = mode in ("startup-api-once", "poll-api", "api-progress", "download", "download-stall")


def block(*args, **kwargs):
    print(json.dumps({"blocked": mode}), flush=True)
    threading.Event().wait()


class Finished(Exception):
    pass


def get(self, method, **params):
    if mode.startswith("startup-api") and method == "auth.test" or mode == "poll-api" and method == "conversations.history":
        block()
    return original_get(self, method, **params)


def post(self, method, **body):
    if method == "apps.connections.open":
        if mode == "connect-api":
            block()
        attempts.append(clock() - started)
        if mode == "reconnect":
            if attempts[-1] > 3:
                raise Finished
            raise Refusal("slack-unreachable", "fixture-outage")
    answer = original_post(self, method, **body)
    if mode == "connect-dns" and method == "apps.connections.open":
        socket.getaddrinfo = block
    return answer


def opened(self, *args, **kwargs):
    result = original_open(self, *args, **kwargs)
    api_calls.append(clock() - started)
    return result


class MovingResponse:
    """Delay a real download's reads while keeping its bytes and headers."""

    def __init__(self, response):
        self.response = response
        self.headers = response.headers
        self.status = response.status

    def __enter__(self):
        self.response.__enter__()
        return self

    def __exit__(self, *args):
        return self.response.__exit__(*args)

    def read(self, count):
        if mode == "download-stall" and chunks:
            block()
        # This delay models a link that delivers chunks within the deadline
        # while the whole file takes longer than the deadline.
        time.sleep(0.3)
        chunk = self.response.read(count)
        if chunk:
            chunks.append(chunk)
        return chunk


def urlopen(request, *args, **kwargs):
    response = original_urlopen(request, *args, **kwargs)
    return MovingResponse(response) if "/_files/" in request.full_url else response


def poll(self, bot_user):
    global saved_bytes, delivered
    if mode == "poll-api":
        self.api.get("conversations.history", channel=self.channel)
    elif mode == "api-progress":
        for _ in range(8):
            self.api.get("auth.test")
            time.sleep(0.4)
    elif mode in ("download", "download-stall"):
        stamp = f"{time.time():.6f}"
        self.on_message({"ts": stamp, "user": "U001", "text": "Moving file.",
                         "files": [json.loads(file_path.read_text())]}, bot_user)
        saved_bytes = (root / "tmp/slack/files/FWORKER-worker.txt").read_text()
        delivered = stamp in self.state.delivered
    result = original_poll(self, bot_user)
    polls.append(clock() - started)
    return result


def polled(self):
    global connected_time
    if mode == "connected":
        connected_time += settings.poll_seconds
    result = original_poll_once(self)
    if mode == "connected" and polls[-1] > 3:
        raise Finished
    return result


if mode == "startup-dns":
    socket.getaddrinfo = block
if mode in ("download", "download-stall"):
    api.COPY_BYTES = 8
    urllib.request.urlopen = urlopen
Slack.get, Slack.post, Slack._open = get, post, opened
relay.RootRelay.poll = poll
relay.Relay.poll_once = polled
argv = ["listen", "--root", str(root), *(["--once"] if once else [])]
try:
    result = main.run(argv)
except Finished:
    result = 0
if mode in ("reconnect", "connected", "api-progress", "download"):
    print(json.dumps({"polls": len(polls), "attempts": len(attempts), "api_calls": len(api_calls),
                      "api_after_first_poll": sum(at > polls[0] for at in api_calls) if polls else 0,
                      "elapsed": clock() - started, "bound": bound,
                      "file_bytes": saved_bytes, "delivered": delivered, "chunks": len(chunks)}))
sys.exit(result)
