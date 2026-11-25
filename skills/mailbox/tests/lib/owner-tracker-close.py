"""Observe owner ask and close writes against a refusing, stateful tracker.

A comment create the tracker accepts runs the real linear package against a
fake Linear endpoint, so the stored comment is the body that package sends.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parents[4]
# What the linear package prints for a delete Linear answers success:false.
DELETE_REFUSED = {"success": False, "identifier": None, "url": None, "data": {"success": False}}

TRACKER = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(os.environ["TRACKER_CASE"])
args = sys.argv[1:]
DELETE_REFUSED = json.loads(os.environ["TRACKER_DELETE_REFUSED"])
state = root / "item.json"
item = json.loads(state.read_text())
with (root / "calls.jsonl").open("a") as out:
    out.write(json.dumps(args) + "\n")
row = os.environ["TRACKER_ROW"]
comments_path = root / "comments.json"
comments = json.loads(comments_path.read_text())
question_id = root / "question-id"
if args[:2] == ["users", "list"]:
    print(json.dumps([{"id": "owner", "name": "Owner Person", "email": "owner@example.test",
                       "display_name": "owner.person"}]))
elif args[:2] == ["teams", "keys"]:
    print(json.dumps({"urlKey": "workspace", "keys": ["KEN"]}))
elif args[:2] == ["graphql", "--query"] and args[2].startswith("query OwnerTracker("):
    if row == "rollback-read" and (root / "comment-attempted").exists():
        print("tracker: refused=rollback-read", file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"issue": {
        "description": item["description"],
        "assignee": {"name": item["assignee"]} if item["assignee"] else None,
        "labels": {"pageInfo": {"hasNextPage": False},
                   "nodes": [{"name": label} for label in item["labels"]]}}}))
elif args[:2] in (["comments", "create"], ["comments", "owner-questions"]):
    if args[1] == "create" and row in ("comment-failed", "comment-refused", "comment-preexisting", "comment-label-edit", "comment-edited", "rollback-read", "rollback-failed") and not (root / "closing").exists():
        (root / "comment-attempted").touch()
        if row == "comment-edited":
            item["description"] = json.loads((root / "later-description.json").read_text())
            state.write_text(json.dumps(item))
        if row == "comment-label-edit":
            item["labels"].remove("removed-later")
            item["labels"].append("added-later")
            state.write_text(json.dumps(item))
        if row == "comment-refused":
            print(json.dumps({"success": False, "data": {"success": False, "comment": None}}))
            sys.exit(0)
        print("tracker: refused=comment", file=sys.stderr)
        sys.exit(1)
    sent = subprocess.run([os.environ["TRACKER_BASH"], os.environ["TRACKER_LINEAR"], *args],
                          capture_output=True, text=True,
                          env={"PATH": os.environ["TRACKER_CURL_DIR"] + os.pathsep + os.environ["PATH"],
                               "HOME": str(root), "TRACKER_CASE": str(root),
                               "LINEAR_API_KEY_OVERRIDE": "stub", "KENDEX_USER_EMAIL": "",
                               "LINEAR_REQUIRE_REACH": ""})
    if args[1] == "owner-questions" and sent.returncode == 0:
        question_id.write_text(sent.stdout.strip())
    sys.stdout.write(sent.stdout)
    sys.stderr.write(sent.stderr)
    sys.exit(sent.returncode)
elif args[:2] == ["graphql", "--query"] and args[2].startswith("query OwnerTrackerComment("):
    if row == "mention-unread":
        print("tracker: refused=mention-read", file=sys.stderr)
        sys.exit(1)
    # Only the saved comment exists: any other id reads as Linear's null.
    if json.loads(args[args.index("--variables") + 1]) != {"id": question_id.read_text()}:
        print(json.dumps({"comment": None}))
        sys.exit(0)
    # Linear's bodyData for the saved comment: the owner's mention is a
    # suggestion_userMentions node carrying the owner's user id.
    node = {"type": "suggestion_userMentions", "attrs": {"id": "owner", "label": "owner.person"}}
    if row in ("mention-missing", "delete-refused"):
        node = {"type": "text", "text": comments[-1].splitlines()[0]}
    elif row == "mention-other":
        node = {"type": "suggestion_userMentions", "attrs": {"id": "someone-else", "label": "someone.else"}}
    doc = {"type": "doc", "content": [{"type": "paragraph", "content": [node]}]}
    print(json.dumps({"comment": {"bodyData": json.dumps(doc)}}))
elif args[:2] == ["comments", "delete"] and args[2] == question_id.read_text():
    # The linear package exits 0 on a refused delete and prints the answer.
    if row == "delete-refused":
        print(json.dumps(DELETE_REFUSED))
        sys.exit(0)
    comments.pop()
    comments_path.write_text(json.dumps(comments))
    print(json.dumps({"success": True, "identifier": None, "url": None, "data": {"success": True}}))
elif args[:2] == ["issues", "update"]:
    if row == "label-failed" and "--labels" in args and not (root / "closing").exists():
        print("tracker: refused=write", file=sys.stderr)
        sys.exit(1)
    if row == "rollback-failed" and (root / "comment-attempted").exists() and not (root / "closing").exists():
        print("tracker: refused=rollback-update", file=sys.stderr)
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
elif args[:2] == ["issues", "bulk-get"]:
    print(json.dumps([{"id": ref, "uuid": "uuid-" + ref} for ref in args[2:] if not ref.startswith("--")]))
else:
    sys.exit(1)
'''

# Linear's GraphQL endpoint as the real package reaches it through curl: a
# comment create stores the body it was sent.
CURL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

data = next(line[len("data = "):] for line in sys.stdin.read().splitlines() if line.startswith("data = "))
payload = json.loads(json.loads(data))
if not payload["query"].lstrip().startswith("mutation CreateComment"):
    print(json.dumps({"errors": [{"message": "unexpected fixture query"}]}) + "___HTTP_CODE___200", end="")
    sys.exit(0)
root = Path(os.environ["TRACKER_CASE"])
comments_path = root / "comments.json"
question = payload["variables"]["input"]
body = question["body"]
(root / "question-id").write_text(question["id"])
comments_path.write_text(json.dumps(json.loads(comments_path.read_text()) + [body]))
comment = {"id": question["id"], "body": body, "createdAt": "2026-11-22T00:00:00Z",
           "updatedAt": "2026-11-22T00:00:00Z", "user": {"name": "App", "email": "app@example.test"},
           "issue": {"identifier": "KEN-7", "updatedAt": "2026-11-22T00:00:00Z"}}
print(json.dumps({"data": {"commentCreate": {"success": True, "comment": comment}}}) + "___HTTP_CODE___200", end="")
'''


def run(source, scratch, bash):
    facts = {"unposted": True, "notice": True, "posted": True, "close_untracked": True,
             "retained_error": True, "comments": True, "rollback_owned": True,
             "rollback_unowned": True, "rollback_notice": True, "comment_refused": True,
             "rollback_labels": True, "comment_form": True, "mention": True,
             "comment_delete": True}
    # One copy of the real linear scripts, with no orch beside it, so its
    # attribution line reads unknown rather than this checkout's session.
    linear = Path(tempfile.mkdtemp(dir=scratch)) / "linear"
    shutil.copytree(REPO / "skills/linear/scripts", linear / "scripts")
    curl_dir = linear / "bin"
    curl_dir.mkdir()
    (curl_dir / "curl").write_text(CURL)
    (curl_dir / "curl").chmod(0o755)
    for row, posted in (("label-failed", False), ("comment-failed", False),
                        ("comment-edited", False), ("rollback-read", False),
                        ("rollback-failed", False), ("posted", True), ("edited", True),
                        ("comment-refused", False), ("comment-preexisting", False),
                        ("comment-label-edit", False), ("mention-missing", False),
                        ("mention-other", False), ("mention-unread", False),
                        ("delete-refused", False)):
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
            # A previous ask can own the opening formatted action.
            body = "The issue keeps its purpose.\r\n\r\nOriginal body.\n\n"
            original = "**Outcome, what you do:** Preserve the original purpose\n\n" + body if not posted else body
            if row == "edited":
                original = ("**Owner, what you do:** Older action.\n\nOlder second paragraph.\n\n"
                            "`Owner question: a54c6f77-50d1-4001-8000-000000000001`\n\n" + body)
            later = "A later edit keeps its own purpose.\r\n\r\nKeep these bytes.\n\n"
            (root / "later-description.json").write_text(json.dumps(later))
            labels = ["owner-gated", "skills"] if row in ("label-failed", "comment-preexisting") else ["skills"]
            if row == "comment-label-edit":
                labels.append("removed-later")
            item = {"description": original, "labels": labels, "assignee": "Owner Person"}
            state = root / "item.json"
            state.write_text(json.dumps(item))
            comments_path = root / "comments.json"
            previous_comments = ["An existing comment stays."]
            comments_path.write_text(json.dumps(previous_comments))
            message = root / "question"
            message.write_text("Approve the change?\n")
            env = {"PATH": os.environ["PATH"], "HOME": str(root), "TMPDIR": str(root),
                   "TRACKER_CASE": str(root), "TRACKER_ROW": row, "TRACKER_BASH": bash,
                   "TRACKER_LINEAR": str(linear / "scripts/linear.sh"), "TRACKER_CURL_DIR": str(curl_dir),
                   "TRACKER_DELETE_REFUSED": json.dumps(DELETE_REFUSED),
                   "ORCH_OWNER_EMAIL": "owner@example.test", "ORCH_OWNER_ASK_LABEL": "owner-gated"}
            mail = [bash, str(scripts / "lane-mail")]

            def invoke(*args):
                return subprocess.run([*mail, *args], cwd=root, env=env, capture_output=True,
                                      text=True, check=True, timeout=10)

            ask = invoke("ask", "--item", "overseer", "--to", "owner", "--issue", "KEN-7",
                         "--do", "Approve change", "--wait", "5", "--options", "approve,hold",
                         "--recommend", "approve", "--effect", "none", "--file", str(message))
            ask_id = ask.stdout.strip().split("=", 1)[1]
            question_id = (root / "question-id").read_text()
            written = f"**Owner, what you do:** Approve change\n\n`Owner question: {question_id}`\n\n" + body
            pending = json.loads(invoke("pending", "--item", "overseer", "--to", "owner").stdout)
            after_ask = json.loads(state.read_text())
            after_comments = json.loads(comments_path.read_text())
            if posted:
                facts["comments"] &= after_comments[:1] == previous_comments and len(after_comments) == 2
                facts["posted"] &= after_ask["description"] == written and pending["tracker_comment"] == question_id
                lines = after_comments[-1].splitlines()
                # Linear turns the profile URL into a mention of the owner.
                facts["comment_form"] &= (len(after_comments) == 2
                    and lines[0] == "https://linear.app/workspace/profiles/owner.person"
                    and "Approve the change?" in lines and pending["deadline"] in after_comments[-1]
                    and any(line.startswith("Reply to this comment") for line in lines)
                    and lines[-1] == "Requested by the " + root.name + " overseer"
                    and ask_id not in after_comments[-1] and "ask=" not in after_comments[-1])
            elif row == "delete-refused":
                # A refused delete leaves the question comment the ask could
                # not take down.
                facts["comments"] &= after_comments[:1] == previous_comments and len(after_comments) == 2
            else:
                facts["comments"] &= after_comments == previous_comments
            if row in ("comment-failed", "comment-refused", "comment-preexisting", "comment-label-edit",
                       "mention-missing", "mention-other", "mention-unread", "delete-refused"):
                facts["rollback_owned"] &= original != written and after_ask["description"] == original
                expected_labels = ["added-later", "skills"] if row == "comment-label-edit" else labels
                facts["rollback_labels"] &= after_ask["labels"] == expected_labels
                if row == "comment-refused":
                    response_file = Path(ask.stderr.partition("error-file=")[2].strip())
                    facts["comment_refused"] &= (pending["tracker_posted"] is False
                        and "cause=comment" in ask.stderr and response_file.is_file()
                        and json.loads(response_file.read_text()) == {"success": False,
                            "data": {"success": False, "comment": None}})
                if row.startswith("mention-"):
                    # A saved comment that does not show the owner's mention
                    # is refused by its key, recorded failed and taken down.
                    cause = "mention-read" if row == "mention-unread" else "mention"
                    keyed = "lane-mail: tracker-unwritten issue=KEN-7 cause=" + cause
                    diagnostics = ask.stderr.splitlines()
                    if row != "mention-unread":
                        refused = keyed in diagnostics
                    else:
                        retained = [Path(line.split("error-file=", 1)[1]) for line in diagnostics
                                    if line.startswith(keyed + " error-file=")]
                        refused = (len(retained) == 1
                                   and retained[0].read_bytes() == b"tracker: refused=mention-read\n")
                    box = (root / "tmp/lane-mail/overseer/to-overseer.jsonl").read_text().splitlines()
                    facts["mention"] &= (refused and pending["tracker_posted"] is False
                        and pending.get("tracker_cause") == cause
                        and not any(json.loads(line).get("kind") == "tracker-posted" for line in box))
                if row == "delete-refused":
                    # The refused delete reports by its key and keeps the
                    # answer the tracker gave.
                    keyed = "lane-mail: tracker-unwritten issue=KEN-7 cause=comment-delete error-file="
                    retained = [Path(line[len(keyed):]) for line in ask.stderr.splitlines()
                                if line.startswith(keyed)]
                    facts["comment_delete"] &= (len(retained) == 1
                        and json.loads(retained[0].read_text()) == DELETE_REFUSED
                        and "lane-mail: tracker-unwritten issue=KEN-7 cause=mention" in ask.stderr.splitlines()
                        and pending["tracker_posted"] is False)
            elif row == "comment-edited":
                facts["rollback_unowned"] &= (after_ask["description"] == later
                    and after_ask["labels"] == ["owner-gated", "skills"]
                    and "cause=rollback-unowned" in ask.stderr)
            elif row in ("rollback-read", "rollback-failed"):
                diagnostics = ask.stderr.splitlines()
                retained = {}
                for line in diagnostics:
                    if "error-file=" in line:
                        category = line.split("cause=", 1)[1].split(" ", 1)[0]
                        retained[category] = Path(line.split("error-file=", 1)[1]).read_bytes()
                cause = "rollback-read" if row == "rollback-read" else "rollback-update"
                facts["rollback_notice"] &= (after_ask["description"] == written
                    and retained.get("comment") == b"tracker: refused=comment\n"
                    and retained.get(cause) == ("tracker: refused=" + cause + "\n").encode())
            if not posted:
                facts["unposted"] &= pending["tracker_posted"] is False
                if row in ("label-failed", "comment-failed"):
                    facts["unposted"] &= after_ask == item
                facts["notice"] &= "tracker-unwritten issue=KEN-7 cause=" in ask.stderr
            else:
                facts["posted"] &= pending["tracker_posted"] is True
            if row == "label-failed":
                error_path = ask.stderr.partition("error-file=")[2].strip()
                error_file = Path(error_path) if error_path else None
                facts["retained_error"] &= (error_file is not None and error_file.is_file()
                    and error_file.read_bytes() == b"tracker: refused=write\n")
            before_close = json.loads(state.read_text())
            calls = (root / "calls.jsonl").read_bytes()
            (root / "closing").touch()
            invoke("resolve", "--item", "overseer", "--id", ask_id, "--text", str(message))
            after_close = json.loads(state.read_text())
            if row == "label-failed":
                facts["retained_error"] &= (error_file is not None and error_file.is_file()
                    and error_file.read_bytes() == b"tracker: refused=write\n")
            # The asking overseer's watch owns a closed ask's tracker marks:
            # the close itself calls no tracker, posted or not.
            facts["close_untracked"] &= (after_close == before_close
                and (root / "calls.jsonl").read_bytes() == calls)
    return facts


if __name__ == "__main__":
    print(json.dumps(run(Path(sys.argv[1]), sys.argv[2], sys.argv[3])))
