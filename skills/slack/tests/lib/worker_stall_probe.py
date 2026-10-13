#!/usr/bin/env python3
"""Bound real listener calls in a child, including resolver entry points."""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path


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
    if mode == "reconnect":
        assert child.returncode == 0, (child.returncode, err)
        assert len(rows) == 1 and rows[0]["polls"] >= 4 and rows[0]["attempts"] >= 3, rows
        assert rows[0]["elapsed"] > 2 * rows[0]["bound"], rows
        assert "slack: worker-stalled=" not in err, err
    else:
        assert rows == [{"blocked": mode}], rows
        assert child.returncode == 2, (child.returncode, err)
        stage = "startup" if mode.startswith("startup") else "connect" if mode.startswith("connect") else "poll"
        lines = [line for line in err.splitlines() if line.startswith("slack: worker-stalled=")]
        assert len(lines) == 1, err
        match = re.fullmatch(r"slack: worker-stalled=(\S+) age=([0-9.]+)s bound=([0-9.]+)s", lines[0])
        assert match and match[1] == stage, lines
        assert float(match[2]) >= float(match[3]), lines
    sys.exit(0)

del sys.argv[1]
sys.path.insert(0, sys.argv[1])
import relay
from api import Slack
from refusals import Refusal
from settings import load

root, mode = Path(sys.argv[2]), sys.argv[3]
settings = load()
# Shorten existing figures only inside this child. This tests timer wiring,
# not the duration of the production deadline.
settings.poll_seconds = 0.2
relay.RECONNECT_BOUND_SECONDS = 1
relay.RETRY_FIRST_SECONDS = 0.4
relay.RETRY_MAX_SECONDS = 0.8
bound = 1.2
started = time.monotonic()
polls, attempts = [], []
original_get, original_post = Slack.get, Slack.post
original_poll = relay.RootRelay.poll


def block(*args, **kwargs):
    print(json.dumps({"blocked": mode}), flush=True)
    threading.Event().wait()


class Finished(Exception):
    pass


def get(self, method, **params):
    if mode == "startup-api" and method == "auth.test":
        block()
    return original_get(self, method, **params)


def post(self, method, **body):
    if method == "apps.connections.open":
        if mode == "connect-api":
            block()
        if mode == "reconnect":
            attempts.append(time.monotonic() - started)
            if attempts[-1] > 3:
                raise Finished
            raise Refusal("slack-unreachable", "fixture-outage")
    answer = original_post(self, method, **body)
    if mode == "connect-dns" and method == "apps.connections.open":
        socket.getaddrinfo = block
    return answer


def poll(self, bot_user):
    if mode == "poll-api":
        self.api.get("conversations.history", channel=self.channel)
    result = original_poll(self, bot_user)
    polls.append(time.monotonic() - started)
    return result


if mode == "poll-api":
    def get(self, method, **params):
        if method == "conversations.history":
            block()
        return original_get(self, method, **params)
if mode == "startup-dns":
    socket.getaddrinfo = block
Slack.get, Slack.post = get, post
relay.RootRelay.poll = poll
try:
    sys.exit(relay.listen([root], settings, Slack(settings.token, settings.api_url), mode == "poll-api"))
except Finished:
    print(json.dumps({"polls": len(polls), "attempts": len(attempts),
                      "elapsed": time.monotonic() - started, "bound": bound}))
