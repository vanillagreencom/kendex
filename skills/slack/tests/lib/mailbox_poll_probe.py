#!/usr/bin/env python3
"""Run the production worker loop for one minute with an injected clock."""

import json
import subprocess
import sys
import time
from pathlib import Path

if sys.argv[1] != "--child":
    result = subprocess.run([sys.executable, __file__, "--child", *sys.argv[1:]], timeout=60)
    sys.exit(result.returncode)
del sys.argv[1]

sys.path.insert(0, sys.argv[1])
from api import Slack
from relay import Relay
from settings import load

root = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else "idle"
assert mode in ("idle", "reconnect", "eyes")
settings = load()
start = time.time()
now = start
starts = []
polls = []
per_poll = []
connections = 0
original_popen = subprocess.Popen


def traced_popen(args, *positional, **keywords):
    if isinstance(args, (list, tuple)) and Path(args[0]).name == "lane-mail":
        starts.append(args[1])
    return original_popen(args, *positional, **keywords)


class Finished(Exception):
    pass


def advance(seconds):
    global now
    assert seconds > 0, "worker must advance the injected clock"
    now += seconds
    if now >= start + 60:
        raise Finished


class DisconnectedRelay(Relay):
    def open(self, app_api):
        global connections
        if mode == "reconnect":
            self.socket = object()
            connections += 1
            for bound in self.roots:
                bound.due = set()
            return True
        return False

    def listen_until(self, deadline):
        # A transport fixture drops after one fake second. The production
        # worker decides when the successful reconnect makes a poll due.
        advance(1)
        self.socket = None

    def poll_once(self):
        before = len(starts)
        result = super().poll_once()
        assert result, "the real mailbox poll must pass"
        polls.append(now - start)
        per_poll.append(len(starts) - before)
        return result


subprocess.Popen = traced_popen
relay = DisconnectedRelay([root], settings, Slack(settings.token, settings.api_url), lambda: now, advance)
try:
    relay.run_connected(relay.api, now, now, 1)
except Finished:
    pass
finally:
    for bound in relay.roots:
        bound.lock.release()
        bound.hold_lock.release()
    subprocess.Popen = original_popen
assert now - start == 60, "the workload must cover a complete fake minute"
assert len(polls) == (60 if mode == "reconnect" else 60 // settings.poll_seconds), polls
assert sum(per_poll) == len(starts), "mailbox commands must belong to scheduled polls"
if mode != "eyes":
    assert not relay.roots[0].state.delivered and not relay.roots[0].state.carried, "the mailbox must stay idle"
else:
    assert relay.roots[0].state.delivered and set(relay.roots[0].state.marks.values()) == {"eyes"}
print(json.dumps({"seconds": now - start, "poll_seconds": settings.poll_seconds,
                  "polls": len(polls), "lane_mail_starts": len(starts),
                  "events_starts": starts.count("events"), "commands": starts,
                  "starts_per_poll": per_poll, "connections": connections, "mode": mode}))
