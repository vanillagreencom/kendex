"""Observe owner ask and close writes against a refusing, stateful tracker."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


TRACKER = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["TRACKER_CASE"])
args = sys.argv[1:]
state = root / "item.json"
item = json.loads(state.read_text())
with (root / "calls.jsonl").open("a") as out:
    out.write(json.dumps(args) + "\n")
row = os.environ["TRACKER_ROW"]
comments_path = root / "comments.json"
comments = json.loads(comments_path.read_text())
if args[:2] == ["users", "list"]:
    print(json.dumps([{"id": "owner", "name": "Owner Person", "email": "owner@example.test"}]))
elif args[:2] == ["issues", "get"]:
    print(json.dumps(item))
elif args[:2] == ["comments", "create"]:
    if row == "comment-failed" and not (root / "closing").exists():
        sys.exit(1)
    comment_id = "comment-" + str(len(comments))
    comments[comment_id] = Path(args[args.index("--body-file") + 1]).read_text()
    comments_path.write_text(json.dumps(comments))
    print(json.dumps({"success": True, "data": {"comment": {"id": comment_id}}}))
elif args[:2] == ["comments", "delete"]:
    if row == "cancel-failed":
        print("tracker: refused=comment-delete", file=sys.stderr)
        sys.exit(1)
    if row == "cancel-refused":
        print(json.dumps({"success": False}))
    else:
        del comments[args[2]]
        comments_path.write_text(json.dumps(comments))
        print(json.dumps({"success": True}))
elif args[:2] == ["issues", "update"]:
    if not (root / "closing").exists() and (
        (row in ("label-failed", "description-failed", "cancel-failed", "cancel-refused") and "--labels" in args)
        or (row == "description-failed" and "--description" in args)
    ):
        print("tracker: refused=write", file=sys.stderr)
        sys.exit(1)
    for flag, field in (("--description", "description"), ("--assignee", "assignee")):
        if flag in args:
            item[field] = args[args.index(flag) + 1]
    if "--assignee" in args:
        item["assignee"] = "Owner Person"
    if "--clear-assignee" in args:
        item["assignee"] = ""
    if "--labels" in args:
        item["labels"] = args[args.index("--labels") + 1].split(",")
    if "--clear-labels" in args:
        item["labels"] = []
    state.write_text(json.dumps(item))
    print("{}")
else:
    sys.exit(1)
'''


def run(source, scratch, bash):
    facts = {"unposted": True, "notice": True, "posted": True, "edited": True,
             "retained_error": True, "comments": True, "cancel_notice": True}
    for row, posted in (("description-failed", False), ("comment-failed", False),
                        ("posted", True), ("label-failed", False), ("edited", True),
                        ("cancel-failed", False), ("cancel-refused", False)):
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            scripts = root / ".agents/skills/mailbox/scripts"
            shutil.copytree(source / "scripts", scripts)
            tracker = root / ".agents/skills/linear/scripts/linear.sh"
            tracker.parent.mkdir(parents=True)
            tracker.write_text(TRACKER)
            tracker.chmod(0o755)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            for key, value in (("gc.auto", "0"), ("maintenance.auto", "false")):
                subprocess.run(["git", "-C", str(root), "config", key, value], check=True)
            # A previous ask can already own the same formatted action line.
            body = "The issue keeps its purpose.\r\n\r\nOriginal body.\n\n"
            original = "**Owner, what you do:** Approve change\n\n" + body if not posted else body
            labels = ["skills"] if posted else ["owner-gated", "skills"]
            item = {"description": original, "labels": labels, "assignee": "Owner Person"}
            state = root / "item.json"
            state.write_text(json.dumps(item))
            comments_path = root / "comments.json"
            previous_comments = {"previous": "An existing comment stays."}
            comments_path.write_text(json.dumps(previous_comments))
            message = root / "question"
            message.write_text("Approve the change?\n")
            env = {"PATH": os.environ["PATH"], "HOME": str(root), "TMPDIR": str(root),
                   "TRACKER_CASE": str(root), "TRACKER_ROW": row,
                   "ORCH_OWNER_EMAIL": "owner@example.test", "ORCH_OWNER_ASK_LABEL": "owner-gated"}
            mail = [bash, str(scripts / "lane-mail")]

            def invoke(*args):
                return subprocess.run([*mail, *args], cwd=root, env=env, capture_output=True,
                                      text=True, check=True, timeout=10)

            ask = invoke("ask", "--item", "overseer", "--to", "owner", "--issue", "KEN-7",
                         "--do", "Approve change", "--wait", "5", "--options", "approve,hold",
                         "--recommend", "approve", "--file", str(message))
            ask_id = ask.stdout.strip().split("=", 1)[1]
            pending = json.loads(invoke("pending", "--item", "overseer", "--to", "owner").stdout)
            after_ask = json.loads(state.read_text())
            after_comments = json.loads(comments_path.read_text())
            cancellations = [args for args in map(json.loads, (root / "calls.jsonl").read_text().splitlines())
                             if args[:2] == ["comments", "delete"]]
            if posted or row in ("cancel-failed", "cancel-refused"):
                facts["comments"] &= (after_comments.get("previous") == previous_comments["previous"]
                    and set(after_comments) == {"previous", "comment-1"}
                    and ("ask=" + ask_id) in after_comments["comment-1"])
            else:
                facts["comments"] &= after_comments == previous_comments
            facts["comments"] &= cancellations == ([] if posted or row == "comment-failed" else
                                                    [["comments", "delete", "comment-1"]])
            if row in ("cancel-failed", "cancel-refused"):
                diagnostics = ask.stderr.splitlines()
                retained = {}
                for line in diagnostics:
                    if "error-file=" in line:
                        category = line.split("cause=", 1)[1].split(" ", 1)[0]
                        retained[category] = Path(line.split("error-file=", 1)[1]).read_bytes()
                facts["cancel_notice"] &= (retained.get("label") == b"tracker: refused=write\n"
                    and retained.get("comment-cancel") == (b"tracker: refused=comment-delete\n"
                        if row == "cancel-failed" else b'{"success": false}\n'))
            if not posted:
                facts["unposted"] &= pending["tracker_posted"] is False and after_ask == item
                facts["notice"] &= "tracker-unwritten issue=KEN-7 cause=" in ask.stderr
            else:
                facts["posted"] &= pending["tracker_posted"] is True
            if row == "label-failed":
                error_path = ask.stderr.partition("error-file=")[2].strip()
                error_file = Path(error_path) if error_path else None
                facts["retained_error"] &= (error_file is not None and error_file.is_file()
                    and error_file.read_bytes() == b"tracker: refused=write\n")
            if row == "edited":
                after_ask["description"] = "**Other, what you do:** Keep this later action\n\n" + body
                state.write_text(json.dumps(after_ask))
            before_close = json.loads(state.read_text())
            calls = (root / "calls.jsonl").read_bytes()
            (root / "closing").touch()
            invoke("resolve", "--item", "overseer", "--id", ask_id, "--text", str(message))
            after_close = json.loads(state.read_text())
            if row == "label-failed":
                facts["retained_error"] &= (error_file is not None and error_file.is_file()
                    and error_file.read_bytes() == b"tracker: refused=write\n")
            if not posted:
                facts["unposted"] &= (after_close == before_close == item
                    and (root / "calls.jsonl").read_bytes() == calls)
            elif row == "edited":
                facts["edited"] &= after_close["description"] == before_close["description"]
            else:
                facts["posted"] &= (after_close["description"] == body
                    and after_close["labels"] == ["skills"] and after_close["assignee"] == "")
    return facts


if __name__ == "__main__":
    print(json.dumps(run(Path(sys.argv[1]), sys.argv[2], sys.argv[3])))
