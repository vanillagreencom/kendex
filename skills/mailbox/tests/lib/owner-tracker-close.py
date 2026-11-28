"""Observe owner ask and close writes against a refusing, stateful tracker.

A comment create the tracker accepts runs the real linear package against a
fake Linear endpoint, so the stored comment is the body that package sends.
"""

import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parents[4]
Overseer = runpy.run_path(str(Path(__file__).with_name("owner-replace.py")))["Overseer"]
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
surviving_id = root / "surviving-id"
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
        "assignee": {"id": "owner" if item["assignee"] == "Owner Person" else "someone-else",
                     "name": item["assignee"]} if item["assignee"] else None,
        "labels": {"pageInfo": {"hasNextPage": False},
                   "nodes": [{"name": label} for label in item["labels"]]}}}))
elif args[:3] == ["comments", "owner-questions", "--id"]:
    # The real package reserves the ID; the case keeps it to build the
    # description the ask writes.
    sent = subprocess.run([os.environ["TRACKER_BASH"], os.environ["TRACKER_LINEAR"], *args],
                          capture_output=True, text=True, env={"PATH": os.environ["PATH"], "HOME": str(root)})
    if sent.returncode == 0:
        (root / "reserved-id").write_text(json.loads(sent.stdout))
    sys.stdout.write(sent.stdout)
    sys.stderr.write(sent.stderr)
    sys.exit(sent.returncode)
elif args[:2] == ["comments", "owner-questions"]:
    # The watch writes the successful question's ruling before calling the gate.
    standing = ([surviving_id.read_text()] if surviving_id.exists() else [])
    if question_id.exists() and len(comments) > 1 and not (root / "ruled").exists():
        standing.append(question_id.read_text())
    print(json.dumps([{"id": key, "reserved": True, "legacy_asks": []} for key in dict.fromkeys(standing)]))
elif args[:2] == ["comments", "create"]:
    if row in ("comment-failed", "comment-refused", "comment-preexisting", "comment-label-edit", "comment-edited", "rollback-read", "rollback-failed") and not (root / "closing").exists():
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
                               "HOME": str(root), "TRACKER_CASE": str(root), "TRACKER_ROW": row,
                               "LINEAR_API_KEY_OVERRIDE": "stub", "KENDEX_USER_EMAIL": "",
                               "LINEAR_REQUIRE_REACH": ""})
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
    if row == "mention-missing" or (row.startswith("delete-") and not (root / "closing").exists()):
        node = {"type": "text", "text": comments[-1].splitlines()[0]}
    elif row == "mention-other":
        node = {"type": "suggestion_userMentions", "attrs": {"id": "someone-else", "label": "someone.else"}}
    doc = {"type": "doc", "content": [{"type": "paragraph", "content": [node]}]}
    print(json.dumps({"comment": {"bodyData": json.dumps(doc)}}))
elif args[:2] == ["comments", "delete"]:
    # The linear package exits 0 on a refused delete and prints the answer.
    if row.startswith("delete-") and not (root / "cleanup-allowed").exists():
        surviving_id.write_text(args[2])
        print(json.dumps(DELETE_REFUSED))
        sys.exit(0)
    if surviving_id.exists():
        assert args[2] == surviving_id.read_text()
        surviving_id.unlink()
        del comments[1]
    else:
        assert args[2] == question_id.read_text()
        comments.pop()
    comments_path.write_text(json.dumps(comments))
    if row == "delete-refused":
        print("tracker: write=unconfirmed", file=sys.stderr)
        sys.exit(1)
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
    print(json.dumps([{"id": "KEN-7", "uuid": "uuid-KEN-7"}]
                     if any(ref in ("KEN-7", "OLD-7") for ref in args[2:]) else []))
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
if payload["query"].lstrip().startswith("query OwnerRuling"):
    print("___HTTP_CODE___403", end="")
    sys.exit(0)
if not payload["query"].lstrip().startswith("mutation CreateComment"):
    print(json.dumps({"errors": [{"message": "unexpected fixture query"}]}) + "___HTTP_CODE___200", end="")
    sys.exit(0)
root = Path(os.environ["TRACKER_CASE"])
comments_path = root / "comments.json"
question = payload["variables"]["input"]
body = question["body"]
row = os.environ["TRACKER_ROW"]
lost = row.startswith("create-lost") and not (root / "closing").exists()
partial = row == "create-partial" and not (root / "closing").exists()
if not lost or row != "create-lost-absent":
    (root / "question-id").write_text(question["id"])
    comments_path.write_text(json.dumps(json.loads(comments_path.read_text()) + [body]))
    if lost or partial:
        (root / "surviving-id").write_text(question["id"])
if lost:
    print("___HTTP_CODE___500", end="")
    sys.exit(0)
comment = {"id": question["id"], "body": body, "createdAt": "2026-11-22T00:00:00Z",
           "updatedAt": "2026-11-22T00:00:00Z", "user": {"name": "App", "email": "app@example.test"},
           "issue": {"identifier": "KEN-7", "updatedAt": "2026-11-22T00:00:00Z"}}
reply = {"data": {"commentCreate": {"success": True, "comment": comment}}}
if partial:
    comment["user"] = None
    reply["errors"] = [{"message": "AUTHOR_READ_FAILED", "path": ["commentCreate", "comment", "user"]}]
print(json.dumps(reply) + "___HTTP_CODE___200", end="")
'''


RECOVERY = {
    "delete-refused": (False, "mention", 3),
    "delete-compacted": (True, "mention", 2),
    "create-lost": (True, "comment", 1),
    "create-lost-absent": (True, "comment", 0),
    "create-partial": (True, "comment", 1),
}


def run(source, scratch, bash):
    facts = {"unposted": True, "notice": True, "posted": True, "close_untracked": True,
             "retained_error": True, "comments": True, "rollback_owned": True,
             "rollback_unowned": True, "rollback_notice": True, "comment_refused": True,
             "rollback_labels": True, "comment_form": True, "mention": True,
             "comment_delete": True, "rollback_pair": True, "survivor_removed": False,
             "delete-compacted": False, "create-lost": False, "create-lost-absent": False, "create-partial": False}
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
                        *((case, False) for case in RECOVERY)):
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
            later = "A later edit keeps its own purpose.\r\n\r\nKeep these bytes.\n\n"
            (root / "later-description.json").write_text(json.dumps(later))
            # A preexisting owner label stands with no ask open on the item.
            labels = ["owner-gated", "skills"] if row == "comment-preexisting" else ["skills"]
            if row == "comment-label-edit":
                labels.append("removed-later")
            item = {"description": original, "labels": labels, "assignee": ""}
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

            ask_args = ("ask", "--item", "overseer", "--to", "owner", "--do", "Approve change",
                        "--wait", "5", "--options", "approve,hold", "--file", str(message))
            approval = ("--reserved",) if row in RECOVERY else ("--recommend", "approve", "--effect", "none")
            ask = invoke(*ask_args, "--issue", "KEN-7", *approval)
            ask_id = ask.stdout.strip().split("=", 1)[1]
            reserved = (root / "reserved-id").read_text()
            written = ("**Owner, what you do:** Approve change `Owner question: " + reserved + "`\n\n"
                       + body)
            pending = json.loads(invoke("pending", "--item", "overseer", "--to", "owner").stdout)
            after_ask = json.loads(state.read_text())
            after_comments = json.loads(comments_path.read_text())
            if posted:
                facts["comments"] &= after_comments[:1] == previous_comments and len(after_comments) == 2
                lines = after_comments[-1].splitlines()
                # Linear turns the profile URL into a mention of the owner.
                facts["comment_form"] &= (len(after_comments) == 2
                    and lines[0] == "https://linear.app/workspace/profiles/owner.person"
                    and "Approve the change?" in lines and pending["deadline"] in after_comments[-1]
                    and any(line.startswith("Reply to this comment") for line in lines)
                    and lines[-1] == "Requested by the " + root.name + " overseer"
                    and ask_id not in after_comments[-1] and "ask=" not in after_comments[-1])
            elif row in RECOVERY and row != "create-lost-absent":
                facts["comments"] &= after_comments[:1] == previous_comments and len(after_comments) == 2
            else:
                facts["comments"] &= after_comments == previous_comments
            if row in ("comment-failed", "comment-refused", "comment-preexisting", "comment-label-edit",
                       "mention-missing", "mention-other", "mention-unread", "delete-refused"):
                facts["rollback_owned"] &= original != written and after_ask["description"] == original
                expected_labels = ["added-later", "skills"] if row == "comment-label-edit" else ["skills"]
                facts["rollback_labels"] &= after_ask["labels"] == expected_labels
                if row == "comment-refused":
                    response_file = Path(ask.stderr.partition("error-file=")[2].strip())
                    facts["comment_refused"] &= (pending["tracker_posted"] is False and "tracker_comment" not in pending
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
                        and pending.get("tracker_cause") == cause and "tracker_comment" not in pending
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
                    and after_ask["labels"] == ["skills"]
                    and "cause=rollback-unowned" in ask.stderr)
            elif row in ("rollback-read", "rollback-failed"):
                diagnostics = ask.stderr.splitlines()
                retained = {}
                for line in diagnostics:
                    if "error-file=" in line:
                        category = line.split("cause=", 1)[1].split(" ", 1)[0]
                        retained[category] = Path(line.split("error-file=", 1)[1]).read_bytes()
                cause = "rollback-read" if row == "rollback-read" else "rollback-update"
                # The owner gate's refused rollback is the one notice that the
                # item still carries the owner label and assignee.
                gate = "rollback-labels-read" if row == "rollback-read" else "rollback-assign"
                facts["rollback_notice"] &= (after_ask["description"] == written
                    and retained.get("comment") == b"tracker: refused=comment\n"
                    and retained.get(cause) == ("tracker: refused=" + cause + "\n").encode()
                    and retained.get(gate) == ("tracker: refused=" + cause + "\n").encode())
            # A failed post whose rollback the tracker takes leaves the item
            # with neither the owner label nor the owner assignee, a question
            # comment it could not delete included.
            if row in ("comment-failed", "comment-refused", "comment-preexisting", "comment-label-edit",
                       "comment-edited", "mention-missing", "mention-other", "mention-unread", "delete-refused"):
                facts["rollback_pair"] &= ("owner-gated" not in after_ask["labels"]
                                           and after_ask["assignee"] == "")
            if not posted:
                facts["unposted"] &= pending["tracker_posted"] is False
                if row in ("label-failed", "comment-failed"):
                    facts["unposted"] &= after_ask == item
                facts["notice"] &= "tracker-unwritten issue=KEN-7 cause=" in ask.stderr
            else:
                # The action line names the question the ask posted under.
                facts["posted"] &= (pending["tracker_posted"] is True and after_ask["description"] == written
                    and pending["tracker_comment"] == reserved
                    and after_ask["labels"] == ["owner-gated", "skills"] and after_ask["assignee"] == "Owner Person")
            if row == "label-failed":
                error_path = ask.stderr.partition("error-file=")[2].strip()
                error_file = Path(error_path) if error_path else None
                facts["retained_error"] &= (error_file is not None and error_file.is_file()
                    and error_file.read_bytes() == b"tracker: refused=write\n")
            (root / "closing").touch()
            to_close = ask_id
            if row in RECOVERY:
                expire, cause, attempts = RECOVERY[row]
                overseer = Overseer(root, env, mail)
                outcome = next(record for record in overseer.rows("to-overseer.jsonl")
                    if record.get("re") == ask_id and record["kind"] == "tracker-failed")
                if row.startswith("create-"):
                    error_file = Path(ask.stderr.partition("error-file=")[2].strip())
                    failure = error_file.read_text()
                    cause_marker = "AUTHOR_READ_FAILED" if row == "create-partial" else "linear-http: write=unconfirmed code=500"
                    facts["notice"] &= (cause_marker in failure
                                        and json.loads(failure.splitlines()[-1])["error"] == "HTTP error: 403")
                if expire:
                    # A chat close and cursor acknowledgment make this exchange
                    # eligible for expiry before a later tracker ask exists.
                    overseer.resolve(ask_id)
                    overseer.compact()
                retained = overseer.asks().get(ask_id, {})
                message.write_text("Approve the revised change?\n")
                later = invoke(*ask_args, "--issue", "OLD-7", "--reserved")
                to_close = later.stdout.strip().split("=", 1)[1]
                current = json.loads(invoke("pending", "--item", "overseer", "--to", "owner").stdout)
                latest_body = json.loads(comments_path.read_text())[-1]
                survived = (outcome.get("tracker_comment") == reserved and pending.get("tracker_comment") == reserved
                    and outcome.get("cause") == cause and retained.get("tracker_comment") == reserved
                    and pending.get("reserved") is True and pending.get("tracker_posted") is False
                    and current["id"] == to_close and current["tracker_posted"] is True
                    and current["identity"]["uuid"] == pending["identity"]["uuid"]
                    and current.get("replaces", []) == ([] if expire else [{"id": ask_id, "identity": current["identity"]}]))
            before_close = json.loads(state.read_text())
            calls = (root / "calls.jsonl").read_bytes()
            close_args = ("resolve", "--item", "overseer", "--id", to_close)
            invoke(*close_args, *(("--text", str(message)) if row not in RECOVERY else ()))
            after_close = json.loads(state.read_text())
            if row == "label-failed":
                facts["retained_error"] &= (error_file is not None and error_file.is_file()
                    and error_file.read_bytes() == b"tracker: refused=write\n")
            # The asking overseer's watch owns a closed ask's tracker marks:
            # the close writes no description, label or question comment,
            # posted or not. Its only tracker calls are the comments read of
            # the ask's item and an eyes mark per owner comment it marks.
            closing = [json.loads(line) for line in (root / "calls.jsonl").read_bytes()[len(calls):].splitlines()]
            facts["close_untracked"] &= (after_close == before_close
                and all(args[:3] == ["comments", "bulk-list", "KEN-7"] or args[:2] == ["comments", "react"]
                        for args in closing))
            if row in RECOVERY:
                (root / "ruled").touch()
                gate = (*mail, "owner-gate", "--item", "overseer", "--id", to_close)
                def reconcile():
                    return subprocess.run(gate, cwd=root, env=env, capture_output=True, text=True, timeout=10)

                if row == "delete-refused":
                    refused = reconcile()
                    still_held = json.loads(state.read_text())
                (root / "cleanup-allowed").touch()
                if row == "delete-refused":
                    lost = reconcile()
                    survived &= (refused.returncode == lost.returncode == 2
                        and "cause=comment-delete" in refused.stderr and json.dumps(DELETE_REFUSED) in refused.stderr
                        and "tracker: write=unconfirmed" in lost.stderr
                        and still_held["assignee"] == "Owner Person" and "owner-gated" in still_held["labels"])
                retried = reconcile()
                cleared = json.loads(state.read_text())
                delete_calls = [call[2] for call in map(json.loads, (root / "calls.jsonl").read_text().splitlines())
                                if call[:2] == ["comments", "delete"]]
                settled = overseer.asks().get(ask_id, {})
                passed = (survived and settled.get("tracker_cause") == cause and settled.get("tracker_posted") is False
                    and "tracker_comment" not in settled and delete_calls == [reserved] * attempts and retried.returncode == 0
                    and retried.stdout.strip() == "owner-gate: held=false"
                    and json.loads(comments_path.read_text()) == previous_comments + [latest_body]
                    and cleared["assignee"] == "" and cleared["labels"] == ["skills"])
                if expire:
                    overseer.compact()
                    passed &= not any(record.get("id") == ask_id or record.get("re") == ask_id
                                      for box in ("to-overseer.jsonl", "to-lane.jsonl") for record in overseer.rows(box))
                facts["survivor_removed" if row == "delete-refused" else row] = passed
    return facts


if __name__ == "__main__":
    print(json.dumps(run(Path(sys.argv[1]), sys.argv[2], sys.argv[3])))
