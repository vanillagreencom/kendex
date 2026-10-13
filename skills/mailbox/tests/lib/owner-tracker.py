"""Drive the production owner-ask writer across a tracker-call barrier.

The shell suite owns assertions. This driver returns observations from real
mailbox reads. The parent bounds the driver and each writer is reaped before
its case directory is removed.
"""

import json
from datetime import datetime, timezone
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO / "skills/slack/scripts/lib"))
from relay import RootRelay
from settings import Presence, Settings
from store import Binding, write_binding


STUB = r'''#!/usr/bin/env bash
set -euo pipefail
if [[ "$1:$2" == users:list ]]; then
  printf 'reached\n' > "$TRACKER_CASE/reached"
  read -r release < "$TRACKER_CASE/release"
fi
case "$TRACKER_ROW:$1:$2:${4:-}" in
  owner-read:users:list:*|assign:issues:update:--assignee|labels-read:issues:get:*|label:issues:update:--labels|comment:comments:create:*) exit 1 ;;
esac
case "$1:$2" in
  teams:keys) printf '{"urlKey":"workspace","keys":["KEN"]}\n' ;;
  users:list) printf '[{"id":"person","name":"Owner Person","email":"owner@example.test"}]\n' ;;
  issues:get)
    if [[ "$TRACKER_ROW" == prepare ]]; then printf '{"labels":"invalid"}\n'
    else printf '{"labels":["skills"],"description":"Item body"}\n'; fi ;;
  issues:update|comments:create) printf '{}\n' ;;
  *) exit 1 ;;
esac
'''


def run(source, scratch, bash):
    facts = {"pending": True, "terminal": True, "projection": True, "delivery": True, "bound": True}
    os.environ["SLACK_ORCH_DIR"] = str(REPO / "skills/orch")
    for row in ("posted", "owner-read", "assign", "labels-read", "label", "comment", "prepare", "missing"):
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            scripts = root / ".agents/skills/mailbox/scripts"
            shutil.copytree(source / "scripts", scripts)
            tracker = root / ".agents/skills/linear/scripts/linear.sh"
            tracker.parent.mkdir(parents=True)
            tracker.write_text(STUB)
            tracker.chmod(0o755)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            for key in ("gc.auto", "maintenance.auto"):
                subprocess.run(["git", "-C", str(root), "config", key, "false"], check=True)
            message = root / "question"
            message.write_text("Approve this change?\nMore detail.\n")
            env = {"PATH": os.environ["PATH"], "HOME": str(root),
                   "ORCH_OWNER_EMAIL": "owner@example.test", "ORCH_OWNER_ASK_LABEL": "owner-gated",
                   "TRACKER_CASE": str(root), "TRACKER_ROW": row}
            clock = root / "clock"
            clock.write_text(str(int(time.time())))
            bin_dir = root / "bin"
            bin_dir.mkdir()
            date = bin_dir / "date"
            date.write_text(f'''#!{bash}
set -euo pipefail
if [[ "$*" == '-u +%s' ]]; then cat '{clock}'
else exec '{shutil.which("date")}' "$@"; fi
''')
            date.chmod(0o755)
            env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
            os.environ.update(env)
            os.environ["SLACK_LINEAR_DIR"] = str(tracker.parent.parent)
            mail = [bash, str(scripts / "lane-mail")]
            reached, release = root / "reached", root / "release"
            for pipe in (reached, release):
                os.mkfifo(pipe)
            ready_fd = os.open(reached, os.O_RDWR)
            release_fd = os.open(release, os.O_RDWR)
            writer = subprocess.Popen([*mail, "ask", "--item", "overseer", "--to", "owner",
                "--issue", "KEN-7", "--do", "Approve change", "--wait", "5", "--options", "approve,hold",
                "--recommend", "approve", "--file", str(message)], cwd=root, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

            def read(verb, *args):
                result = subprocess.run([*mail, verb, "--item", "overseer", *args],
                                        cwd=root, env=env, capture_output=True, text=True, check=True, timeout=10)
                return [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]

            try:
                if not select.select([ready_fd], [], [], 10)[0]:
                    raise RuntimeError("tracker barrier not reached")
                os.read(ready_fd, 4096)
                box = root / "tmp/lane-mail/overseer/to-overseer.jsonl"
                before = [json.loads(line) for line in box.read_text().splitlines()]
                ask = before[0]
                at = int(datetime.strptime(ask["at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())
                clock.write_text(str(at))

                class RecordingSlack:
                    def __init__(self):
                        self.messages = []

                    def post(self, method, **body):
                        if method != "chat.postMessage":
                            return {"ok": True}
                        self.messages.append(body)
                        return {"ts": f"{at}.{len(self.messages):06d}"}

                    def paged(self, *args, **kwargs):
                        return []

                api = RecordingSlack()
                owner = "owner@example.test"
                write_binding(root, Binding("COWNER", "owner", str(at), [owner], {owner: "UOWNER"}))
                relay = RootRelay(root, Settings("fixture", "fixture", [owner], 15, 7, "fixture"),
                                  Presence("", 600), api, lambda: int(clock.read_text()))
                relay.poll("UBOT")
                held = len(api.messages) == 0
                message.write_text("Later notice.\n")
                subprocess.run([*mail, "notice", "--item", "overseer", "--to", "owner", "--file", str(message)],
                               cwd=root, env=env, capture_output=True, check=True, timeout=10)
                relay.poll("UBOT")
                held &= len(api.messages) == 1 and "Later notice." in api.messages[0].get("markdown_text", "")
                held &= ask["id"] not in relay.skipped and ask["id"] not in relay.state.carried
                facts["delivery"] &= held
                facts["pending"] &= (len(before) == 1 and ask["kind"] == "ask"
                    and ask["issue"] == "KEN-7" and ask.get("tracker_pending") is True)
                for verb, args in (("events", ()), ("pending", ()), ("drain", ("--after", "0"))):
                    pending = read(verb, *args)
                    if verb == "events":
                        facts["pending"] &= all(e["id"] != ask["id"] for e in pending)
                        continue
                    pending = [e for e in pending if e["kind"] == "ask"]
                    facts["pending"] &= (len(pending) == 1 and pending[0].get("tracker_pending") is True
                                         and pending[0]["tracker_posted"] is False)
                cursored = read("events", "--box", "to-overseer", "--after", "0")
                facts["pending"] &= any(e["id"] == ask["id"] and e.get("tracker_pending") is True for e in cursored)
                if row == "missing":
                    writer.kill()
                    os.write(release_fd, b"release\n")
                    writer.communicate(timeout=10)
                    clock.write_text(str(at + 299))
                    relay.poll("UBOT")
                    facts["bound"] &= len(api.messages) == 1
                    clock.write_text(str(at + 300))
                    released = [e for e in read("events") if e["id"] == ask["id"]]
                    facts["bound"] &= (len(released) == 1 and released[0]["tracker_posted"] is False
                                       and "tracker_pending" not in released[0])
                    relay.poll("UBOT")
                    relay.poll("UBOT")
                    facts["bound"] &= len(api.messages) == 2 and "More detail." in api.messages[-1].get("markdown_text", "")
                    continue
                os.write(release_fd, b"release\n")
                out, err = writer.communicate(timeout=10)
                if writer.returncode:
                    raise RuntimeError(f"writer exit={writer.returncode}: {err}")
                after = [json.loads(line) for line in box.read_text().splitlines()]
                posted = row == "posted"
                outcome = after[-1]
                facts["terminal"] &= (len(after) == 3 and after[0] == ask
                    and outcome["kind"] == ("tracker-posted" if posted else "tracker-failed")
                    and outcome.get("re") == ask["id"] and outcome.get("issue") == "KEN-7"
                    and (outcome.get("tracker_label") == "owner-gated" if posted else outcome.get("cause") == row)
                    and out.strip() == "id=" + ask["id"])
                for verb, args in (("events", ()), ("pending", ()), ("drain", ("--after", "0"))):
                    envelopes = [e for e in read(verb, *args) if e["kind"] == "ask"]
                    facts["projection"] &= (len(envelopes) == 1 and envelopes[0]["id"] == ask["id"]
                        and envelopes[0]["tracker_posted"] is posted and "tracker_pending" not in envelopes[0])
                events = [e for e in read("events") if e["kind"] == "ask"]
                facts["projection"] &= len(events) == 1 and events[0]["line"] == 1 and events[0]["count"] == 3
                facts["projection"] &= all(e["kind"] != "ask" for e in read("drain", "--after", "1"))
                relay.poll("UBOT")
                relay.poll("UBOT")
                expected = "Approve this change? [KEN-7](https://linear.app/workspace/issue/KEN-7)"
                delivered = api.messages[-1].get("markdown_text", "")
                facts["delivery"] &= (len(api.messages) == 2 and (delivered == expected if posted else
                    "More detail." in delivered and "approve, hold" in delivered))
            finally:
                if writer.poll() is None:
                    writer.kill()
                    os.write(release_fd, b"cleanup\n")
                writer.communicate(timeout=10)
                os.close(ready_fd)
                os.close(release_fd)
    return facts


if __name__ == "__main__":
    print(json.dumps(run(Path(sys.argv[1]), sys.argv[2], sys.argv[3])))
