"""Drive the production owner-ask writer across a tracker-call barrier.

The shell suite owns assertions. This driver returns observations from real
mailbox reads. The parent bounds the driver and each writer is reaped before
its case directory is removed.
"""

import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile


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
  users:list) printf '[{"id":"person","name":"Owner Person","email":"owner@example.test"}]\n' ;;
  issues:get)
    if [[ "$TRACKER_ROW" == prepare ]]; then printf '{"labels":"invalid"}\n'
    else printf '{"labels":["skills"],"description":"Item body"}\n'; fi ;;
  issues:update|comments:create) printf '{}\n' ;;
  *) exit 1 ;;
esac
'''


def run(source, scratch, bash):
    facts = {"pending": True, "terminal": True, "projection": True}
    for row in ("posted", "owner-read", "assign", "labels-read", "label", "comment", "prepare"):
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
            mail = [bash, str(scripts / "lane-mail")]
            reached, release = root / "reached", root / "release"
            for pipe in (reached, release):
                os.mkfifo(pipe)
            ready_fd = os.open(reached, os.O_RDWR)
            release_fd = os.open(release, os.O_RDWR)
            writer = subprocess.Popen([*mail, "ask", "--item", "overseer", "--to", "owner",
                "--issue", "KEN-7", "--do", "Approve change", "--wait", "5", "--options", "approve,hold",
                "--recommend", "approve", "--file", str(message)], cwd=root, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)

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
                facts["pending"] &= (len(before) == 1 and ask["kind"] == "ask"
                    and ask["issue"] == "KEN-7" and ask.get("tracker_pending") is True)
                for verb, args in (("events", ()), ("pending", ()), ("drain", ("--after", "0"))):
                    pending = read(verb, *args)
                    facts["pending"] &= (len(pending) == 1 and pending[0].get("tracker_pending") is True
                                         and pending[0]["tracker_posted"] is False)
                os.write(release_fd, b"release\n")
                out, err = writer.communicate(timeout=10)
                if writer.returncode:
                    raise RuntimeError(f"writer exit={writer.returncode}: {err}")
                after = [json.loads(line) for line in box.read_text().splitlines()]
                posted = row == "posted"
                outcome = after[-1]
                facts["terminal"] &= (len(after) == 2 and after[0] == ask
                    and outcome["kind"] == ("tracker-posted" if posted else "tracker-failed")
                    and outcome.get("re") == ask["id"] and outcome.get("issue") == "KEN-7"
                    and (outcome.get("tracker_label") == "owner-gated" if posted else outcome.get("cause") == row)
                    and out.strip() == "id=" + ask["id"])
                for verb, args in (("events", ()), ("pending", ()), ("drain", ("--after", "0"))):
                    envelopes = read(verb, *args)
                    facts["projection"] &= (len(envelopes) == 1 and envelopes[0]["id"] == ask["id"]
                        and envelopes[0]["tracker_posted"] is posted and "tracker_pending" not in envelopes[0])
                events = read("events")
                facts["projection"] &= events[0]["line"] == 1 and events[0]["count"] == 2
                facts["projection"] &= read("drain", "--after", "1") == []
            finally:
                if writer.poll() is None:
                    os.killpg(writer.pid, 9)
                writer.communicate(timeout=10)
                os.close(ready_fd)
                os.close(release_fd)
    return facts


if __name__ == "__main__":
    print(json.dumps(run(Path(sys.argv[1]), sys.argv[2], sys.argv[3])))
