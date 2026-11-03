#!/usr/bin/env python3
"""Unread page contract through the producer, canonical mailbox and relay."""

import importlib.util
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.request

if sys.argv[1] != "--child":
    result = subprocess.run([sys.executable, __file__, "--child", *sys.argv[1:]], timeout=60)
    sys.exit(result.returncode)
del sys.argv[1]
sys.path.insert(0, sys.argv[1])
import relay as relay_module
from api import Slack
from relay import Relay
from settings import load
from store import read_status

root, mode, producer = Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
spec = importlib.util.spec_from_file_location("watch", producer)
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)
settings = load()
now = time.time() + 1200
relay = Relay([root], settings, Slack(settings.token, settings.api_url), lambda: now)
bound = relay.roots[0]
box = root / "tmp/lane-mail/overseer"
script = root / ".agents/skills/mailbox/scripts/lane-mail"


def command(*args, env=None):
    return subprocess.run([str(script), *args], cwd=root, capture_output=True,
                          text=True, check=True, timeout=30, env=env).stdout


def directive(text, key):
    path = root / "tmp/page-input"
    path.write_text(text)
    command("send", "--item", "overseer", "--directive", "--delivery-id", key, "--file", str(path))


def posts():
    with urllib.request.urlopen(settings.api_url + "/_test/state", timeout=10) as response:
        rows = json.load(response)["messages"].get(bound.channel, [])
    return [row for row in rows if row.get("user") == "UBOT"]


def poll(ok=True, count=0, cause=""):
    assert relay.poll_once() is ok
    status = read_status(root)
    assert status["last_poll_ok"] is ok, status
    if cause:
        assert cause in status["last_error"], status
    assert len(posts()) == count, ("page-count", mode, len(posts()), count)


try:
    if mode != "seed":
        poll()
    directive("Owner request.", "page-original")
    if mode == "compacted-read":
        # A running relay keeps its startup thread horizon when the mailbox's
        # retention setting changes. The original remains inside that horizon.
        path = box / "to-lane.jsonl"
        rows = [json.loads(raw) for raw in path.read_text().splitlines()]
        rows[-1]["at"] = datetime.fromtimestamp(now - 6 * 86400, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
    original = next(row for row in bound.mail.events() if row.get("delivery_id") == "page-original")
    blocks = []
    watch.owner_unread(shutil.which("bash"), root, 0, original["count"], now, set(), blocks)
    assert len(blocks) == 1
    body = watch.pass_output("local", [str(root)], [(str(root), blocks[0])]).split("cursor:", 1)[0]
    if mode == "foreign":
        body = body.replace("destination=local", "destination=ssh:other")
    elif mode == "same-basename":
        body = body.replace("root=" + watch.line_value(root, True), "root=/foreign/" + root.name)
    elif mode == "legacy":
        body = blocks[0]
    elif mode == "unanswered":
        body = body.replace("EVENT owner-unread", "EVENT owner-unanswered")
    if mode == "compacted-read":
        command("inbox", "--item", "overseer")
    if mode != "no-event":
        directive(body, "ordinary" if mode == "ordinary" else "jarvis-" + "a" * 64)
    if mode == "read":
        command("inbox", "--item", "overseer")
    if mode == "horizon":
        now += 366 * 86400
    if mode in ("hold-read", "hold-release"):
        presence = root / "tmp/page-presence"
        presence.touch()
        os.utime(presence, (now, now))
        poll()
        if mode == "hold-read":
            command("inbox", "--item", "overseer")
        presence.unlink()
    if mode == "read-during-prepare":
        outbound = relay_module.outbound

        def prepared(*args, **kwargs):
            result = outbound(*args, **kwargs)
            command("inbox", "--item", "overseer")
            return result

        relay_module.outbound = prepared
    if mode == "compacted-read":
        receipts = bound.mail.read_receipts

        def compacted(*args, **kwargs):
            bound.mail.read_receipts = receipts
            output = command("compact", "--item", "overseer", env=dict(
                os.environ, ORCH_RECORD_RETENTION_DAYS="5", SLACK_THREAD_DAYS="1"))
            assert "to-lane=1" in output, output
            rows = bound.mail.events()
            assert original["id"] not in {row["id"] for row in rows}
            assert any(row.get("delivery_id") == "jarvis-" + "a" * 64 for row in rows)
            cursor, read = receipts(*args, **kwargs)
            assert original["line"] <= cursor and original["id"] not in read
            return cursor, read

        bound.mail.read_receipts = compacted
    if mode in ("refusal-accepted", "refusal-read", "unknown"):
        fault = {"method": "chat.postMessage", "cut": "chunked"} if mode == "unknown" else {
            "method": "chat.postMessage", "error": "not_in_channel", "times": 1}
        request = urllib.request.Request(settings.api_url + "/_test/fault", data=json.dumps(fault).encode(),
                                         headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=10) as response:
            response.read()
        poll(mode == "unknown", 1 if mode == "unknown" else 0)
        page = "owner-unread:" + original["id"]
        if mode == "unknown":
            assert read_status(root)["unknown"] == [page]
        elif mode == "refusal-read":
            command("inbox", "--item", "overseer")
        poll(count=0 if mode == "refusal-read" else 1)
    elif mode in ("missed", "invalid", "capability"):
        bound.mail.events()
        reader = bound.mail.reader
        cursor = box / "to-lane.cursor"
        lock = box / "to-lane.cursor.lock"
        if mode == "missed":
            lock.touch()
            cause = "receipt-missed="
            # Existing callers keep the legacy fallback.
            assert bound.mail.read_receipts() == (0, set())
        elif mode == "invalid":
            cursor.write_text("invalid\n")
            cause = "cursor-invalid="
        else:
            def old_reader(box, jq_defs, previous, receipts=False, timeout=30):
                return reader(box, jq_defs, previous, receipts=receipts, timeout=timeout)
            bound.mail.reader = old_reader
            cause = "capability=strict_receipts"
        poll(False, cause=cause)
        assert "owner-unread:" + original["id"] not in bound.state.carried
        assert any(row.get("delivery_id") == "jarvis-" + "a" * 64 for row in bound.mail.events())
        if mode == "missed":
            lock.unlink()
        elif mode == "invalid":
            cursor.unlink()
        else:
            bound.mail.reader = reader
        poll(count=1)
    else:
        expected = 1 if mode in ("accepted", "hold-release") else 0
        poll(count=expected)
    expected = 1 if mode in ("accepted", "hold-release", "missed", "invalid", "capability", "refusal-accepted", "unknown") else 0
    if expected:
        page = "owner-unread:" + original["id"]
        assert page in bound.state.carried
        lines = [json.loads(raw) for raw in (root / "tmp/slack/journal.jsonl").read_text().splitlines()]
        assert {row["at"] for row in lines if row.get("id") == page} == {original["at"]}
        directive(body, "jarvis-" + "b" * 64)
    poll(count=expected)
finally:
    for bound in relay.roots:
        bound.lock.release()
        bound.hold_lock.release()
