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
from uuid import UUID


REPO = Path(__file__).resolve().parents[4]


def ruling_id(question):
    return str(UUID(int=UUID(question).int ^ (1 << 127)))


def tracker_reply(id, parent, body):
    return {"id": id, "parent_id": parent, "body": body, "user_email": "owner@example.test",
            "created_at": "2026-11-22T23:59:00Z"}


def mailbox_rows(result):
    return [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]


TRACKER = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
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
question_id = root / "question-id"
threads_path = root / "threads.json"
threads = json.loads(threads_path.read_text())
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
elif args[:3] in (["comments", "owner-questions", "--id"], ["comments", "owner-questions", "--prefix"]):
    # The real package reserves the ID; the case keeps it to build the
    # description the ask writes.
    sent = subprocess.run([os.environ["TRACKER_BASH"], os.environ["TRACKER_LINEAR"], *args],
                          capture_output=True, text=True, env={"PATH": os.environ["PATH"], "HOME": str(root)})
    if sent.returncode == 0 and args[2] == "--id":
        (root / "reserved-id").write_text(json.loads(sent.stdout))
    sys.stdout.write(sent.stdout)
    sys.stderr.write(sent.stderr)
    sys.exit(sent.returncode)
elif args[:2] == ["comments", "owner-questions"]:
    ruled = {row["parent_id"] for row in threads if row.get("ruling")}
    print(json.dumps([{"id": row["id"], "reserved": True, "legacy_asks": []}
                      for row in threads if row.get("ruling") is False and row["id"] not in ruled]))
elif args[:2] == ["comments", "create"]:
    if "--owner-ruling" in args and (root / "settlement-blocked").exists():
        print("tracker: refused=settlement", file=sys.stderr)
        sys.exit(1)
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
                               "HOME": str(root), "TRACKER_CASE": str(root),
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
    if row in ("mention-missing", "settlement-retried"):
        node = {"type": "text", "text": comments[-1].splitlines()[0]}
    elif row == "mention-other":
        node = {"type": "suggestion_userMentions", "attrs": {"id": "someone-else", "label": "someone.else"}}
    doc = {"type": "doc", "content": [{"type": "paragraph", "content": [node]}]}
    print(json.dumps({"comment": {"bodyData": json.dumps(doc)}}))
elif args[:2] == ["issues", "update"]:
    if "--description" in args and (root / "synced").exists():
        print("linear: refused=synced-description issue=KEN-7 github=acme/app#7 override=--synced-description", file=sys.stderr)
        sys.exit(1)
    if row == "label-failed" and "--labels" in args and not (root / "closing").exists():
        print("tracker: refused=write", file=sys.stderr)
        sys.exit(1)
    if row == "rollback-failed" and (root / "comment-attempted").exists() and not (root / "closing").exists():
        print("tracker: refused=rollback-update", file=sys.stderr)
        sys.exit(1)
    hook = root / "before-clear.json"
    if hook.exists() and json.loads(hook.read_text())["flag"] in args:
        child = json.loads(hook.read_text())
        hook.unlink()
        published = subprocess.run(child["args"], cwd=child["cwd"], env=child["env"],
                                   capture_output=True, text=True, check=True, timeout=15)
        (root / "new-ask-id").write_text(published.stdout.split("=", 1)[1].strip())
        item = json.loads(state.read_text())
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
elif args[:2] == ["issues", "list"]:
    print(json.dumps([dict(id="KEN-7", uuid="uuid-KEN-7", **item)]
                     if item["assignee"] == "Owner Person" and "owner-gated" in item["labels"] else []))
elif args[:2] == ["comments", "bulk-list"]:
    print(json.dumps({"KEN-7": threads}))
elif args[:2] == ["comments", "react"]:
    print(json.dumps({"success": True, "data": {"reaction": {"emoji": "eyes"}}}))
elif args[:2] == ["graphql", "--query"] and args[2].startswith(("query OwnerItem(", "query OwnerAskItem(")):
    print(json.dumps({"issue": {"identifier": "KEN-7", "description": item["description"],
                               "assignee": {"name": item["assignee"]} if item["assignee"] else None}}))
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
root = Path(os.environ["TRACKER_CASE"])
if payload["query"].startswith("query GetIssue("):
    print(json.dumps({"data": {"issue": {"id": "uuid-KEN-7"}}}) + "___HTTP_CODE___200", end="")
    sys.exit(0)
if not payload["query"].lstrip().startswith("mutation CreateComment"):
    print(json.dumps({"errors": [{"message": "unexpected fixture query"}]}) + "___HTTP_CODE___200", end="")
    sys.exit(0)
comments_path = root / "comments.json"
threads_path = root / "threads.json"
threads = json.loads(threads_path.read_text())
question = payload["variables"]["input"]
body = question["body"]
parent = question.get("parentId")
if parent is None:
    (root / "question-id").write_text(question["id"])
    comments_path.write_text(json.dumps(json.loads(comments_path.read_text()) + [body]))
threads.append({"id": question["id"], "parent_id": parent, "body": body,
                "ruling": parent is not None, "user_email": "app@example.test",
                "created_at": f"2026-11-22T00:{len(threads):02}:00Z"})
threads_path.write_text(json.dumps(threads))
comment = {"id": question["id"], "body": body, "createdAt": "2026-11-22T00:00:00Z",
           "updatedAt": "2026-11-22T00:00:00Z", "user": {"name": "App", "email": "app@example.test"},
           "issue": {"identifier": "KEN-7", "updatedAt": "2026-11-22T00:00:00Z"}}
print(json.dumps({"data": {"commentCreate": {"success": True, "comment": comment}}}) + "___HTTP_CODE___200", end="")
'''


def run(source, scratch, bash, only=None):
    facts = {"unposted": True, "notice": True, "posted": True, "close_untracked": True,
             "retained_error": True, "comments": True, "rollback_owned": True,
             "rollback_unowned": True, "rollback_notice": True, "comment_refused": True,
             "rollback_labels": True, "comment_form": True, "mention": True,
             "settlement": True, "rollback_pair": True, "cross_project": True}
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
                        ("rollback-failed", False), ("posted", True), ("publish-first", True),
                        ("late-label", True), ("late-assignee", True), ("late-synced", True),
                        ("comment-refused", False), ("comment-preexisting", False),
                        ("comment-label-edit", False), ("mention-missing", False),
                        ("mention-other", False), ("mention-unread", False),
                        ("settlement-retried", False)):
        if only is not None and row != only:
            continue
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
            (root / "threads.json").write_text("[]")
            if row == "settlement-retried":
                (root / "settlement-blocked").touch()
            message = root / "question"
            message.write_text("Approve the change?\n")
            env = {"PATH": os.environ["PATH"], "HOME": str(root), "TMPDIR": str(root),
                   "TRACKER_CASE": str(root), "TRACKER_ROW": row, "TRACKER_BASH": bash,
                   "TRACKER_LINEAR": str(linear / "scripts/linear.sh"), "TRACKER_CURL_DIR": str(curl_dir),
                   "ORCH_OWNER_EMAIL": "owner@example.test", "ORCH_OWNER_ASK_LABEL": "owner-gated"}
            env.update({key: str(root / key) for key in
                        ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME")})
            mail = [bash, str(scripts / "lane-mail")]

            def invoke(*args):
                result = subprocess.run([*mail, *args], cwd=root, env=env, capture_output=True,
                                        text=True, timeout=15)
                assert result.returncode == 0, (row, args, result.stderr)
                return result

            ask = invoke("ask", "--item", "overseer", "--to", "owner", "--issue", "KEN-7",
                         "--do", "Approve change", "--wait", "5", "--options", "approve,hold",
                         "--recommend", "approve", "--effect", "none", "--file", str(message))
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
            elif row.startswith("mention-") or row == "settlement-retried":
                facts["comments"] &= after_comments[:1] == previous_comments and len(after_comments) == 2
            else:
                facts["comments"] &= after_comments == previous_comments
            if row in ("comment-failed", "comment-refused", "comment-preexisting", "comment-label-edit",
                       "mention-missing", "mention-other", "mention-unread", "settlement-retried"):
                facts["rollback_owned"] &= original != written and after_ask["description"] == original
                expected_labels = ["added-later", "skills"] if row == "comment-label-edit" else ["skills"]
                if row != "settlement-retried":
                    facts["rollback_labels"] &= after_ask["labels"] == expected_labels
                if row == "comment-refused":
                    response_file = Path(ask.stderr.partition("error-file=")[2].strip())
                    facts["comment_refused"] &= (pending["tracker_posted"] is False
                        and "cause=comment" in ask.stderr and response_file.is_file()
                        and json.loads(response_file.read_text()) == {"success": False,
                            "data": {"success": False, "comment": None}})
                if row.startswith("mention-"):
                    # A saved comment that does not show the owner's mention
                    # is refused by its key, recorded failed and settled in place.
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
                if row.startswith("mention-"):
                    threads = json.loads((root / "threads.json").read_text())
                    facts["settlement"] &= (pending.get("failed_question") == reserved
                        and [thread["parent_id"] for thread in threads] == [None, reserved])
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
                       "comment-edited", "mention-missing", "mention-other", "mention-unread"):
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
            if row == "settlement-retried":
                threads_path = root / "threads.json"
                failed_root = json.loads(threads_path.read_text())[0]
                reply = tracker_reply("failed-question-reply", reserved, "Answer the original question")
                flat = tracker_reply("unbound-answer", None, "Unrelated item comment")
                threads_path.write_text(json.dumps([failed_root, reply, flat]))
                orch = root / ".agents/skills/orch/scripts"
                orch.mkdir(parents=True)
                for name, script in (
                    ("orch-env", 'printf "%s\\n" "$2"'),
                    ("orch-runtime", """printf '%s\\n' '{"ok":true,"result":{"archive":null}}'"""),
                ):
                    (orch / name).write_text("#!/bin/sh\n" + script + "\n")
                    (orch / name).chmod(0o755)
                invoke("compact", "--item", "overseer")
                folded = mailbox_rows(invoke("pending", "--item", "overseer", "--to", "owner"))
                read = mailbox_rows(invoke("owner-answers", "--item", "overseer"))
                retained = (
                    folded[0].get("failed_question") == reserved
                    and [(r["comment"], r["ask"]) for r in read if r["kind"] == "delivered"]
                    == [(reply["id"], ask_id)])
                if not retained:
                    print(f"{row}: reply proof failed: {folded[0].get('failed_question')!r}, {read!r}", file=sys.stderr)
                facts["settlement"] &= retained
            before_close = json.loads(state.read_text())
            calls = (root / "calls.jsonl").read_bytes()
            (root / "closing").touch()
            invoke("resolve", "--item", "overseer", "--id", ask_id, "--text", str(message))
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
            if row == "settlement-retried":
                (root / "settlement-blocked").unlink()
                env["TRACKER_ROW"] = "posted"
                later_ask = invoke("ask", "--item", "overseer", "--to", "owner", "--issue", "KEN-7",
                                   "--do", "Approve the later change", "--wait", "5",
                                   "--options", "approve,hold", "--recommend", "approve",
                                   "--effect", "none", "--file", str(message))
                later_id = later_ask.stdout.strip().split("=", 1)[1]
                later_question = (root / "question-id").read_text()
                invoke("resolve", "--item", "overseer", "--id", later_id, "--text", str(message))
                subprocess.run([str(tracker), "comments", "create", "KEN-7", "--parent", later_question,
                                "--owner-ruling", "--no-attribution", "--body", "This question closed with no answer."],
                               env=env, check=True, capture_output=True, text=True, timeout=15)
                first_close = invoke("owner-gate", "--item", "overseer", "--id", later_id)
                second_close = invoke("owner-gate", "--item", "overseer", "--id", later_id)
                threads = json.loads(threads_path.read_text())
                settled = (
                    first_close.stdout == second_close.stdout == "owner-gate: held=false\n"
                    and threads[:3] == [failed_root, reply, flat]
                    and [(r["id"], r["parent_id"]) for r in threads if r["parent_id"] == reserved]
                    == [(reply["id"], reserved), (ruling_id(reserved), reserved)]
                    and json.loads(state.read_text())["labels"] == ["skills"]
                    and json.loads(state.read_text())["assignee"] == "")
                if not settled:
                    print(f"{row}: close proof failed: {first_close.stdout!r}, {threads!r}, {state.read_text()}", file=sys.stderr)
                facts["settlement"] &= settled
            if row == "publish-first" or row.startswith("late-"):
                facts["cross_project"] &= cross_project(
                    root, mail, env, tracker, message, row, ask_id, reserved, body)
    return facts


def cross_project(root, mail, env, tracker, message, order, old_ask, old_question, body):
    """Publish on the same tracker from a second Git root during the old close."""
    state = root / "item.json"
    threads_path = root / "threads.json"
    before = json.loads(threads_path.read_text())
    older_reply = tracker_reply("older-reply", old_question, "Prior clarification")
    threads_path.write_text(json.dumps([*before, older_reply]))
    subprocess.run([str(tracker), "comments", "create", "KEN-7", "--parent", old_question,
                    "--owner-ruling", "--no-attribution", "--body", "This question closed with no answer."],
                   env=env, check=True, capture_output=True, text=True, timeout=15)
    other = root / "other-project"
    subprocess.run(["git", "init", "-q", str(other)], check=True)
    for key, value in (("gc.auto", "0"), ("maintenance.auto", "false")):
        subprocess.run(["git", "-C", str(other), "config", key, value], check=True)
    other_env = {**env, "HOME": str(other), "TMPDIR": str(other)}
    other_env.update({key: str(other / key) for key in
                      ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME")})
    synced = order == "late-synced"
    if synced:
        (root / "synced").touch()
    new_ask = [*mail, "ask", "--item", "overseer", "--to", "owner", "--issue", "KEN-7",
               "--do", "Review the newer change", "--wait", "5", "--options", "approve,hold",
               "--recommend", "approve", "--effect", "none", "--file", str(message)]
    if order == "publish-first":
        posted = subprocess.run(new_ask, cwd=other, env=other_env, check=True, capture_output=True,
                                text=True, timeout=15)
        new_ask_id = posted.stdout.strip().split("=", 1)[1]
    else:
        (root / "before-clear.json").write_text(json.dumps(
            {"flag": "--clear-assignee" if order == "late-assignee" else "--labels",
             "args": new_ask, "cwd": str(other), "env": other_env}))
    gate = subprocess.run([*mail, "owner-gate", "--item", "overseer", "--id", old_ask],
                          cwd=root, env=env, check=True, capture_output=True, text=True, timeout=20)
    if order != "publish-first":
        new_ask_id = (root / "new-ask-id").read_text()
    question = (root / "question-id").read_text()
    new_reply = tracker_reply("newer-reply", question, "Answer only the new question")
    threads = json.loads(threads_path.read_text())
    threads_path.write_text(json.dumps([*threads, new_reply]))
    item = json.loads(state.read_text())
    if order == "late-assignee":
        assert item["assignee"] == "" and "owner-gated" in item["labels"], (order, item)
    elif order.startswith("late-"):
        assert "owner-gated" not in item["labels"] and item["assignee"] == "Owner Person", (order, item)
    before_repair = len((root / "calls.jsonl").read_bytes())
    result = subprocess.run([*mail, "owner-answers", "--item", "overseer"], cwd=other, env=other_env,
                            check=True, capture_output=True, text=True, timeout=20)
    seen = [(r["comment"], r["ask"]) for r in mailbox_rows(result) if r["kind"] == "delivered"]
    updates = [json.loads(line) for line in
               (root / "calls.jsonl").read_bytes()[before_repair:].splitlines()]
    marker = f"**Owner, what you do:** Review the newer change `Owner question: {question}`\n\n"
    return (
        gate.stdout == "owner-gate: held=true\n"
        and result.stdout.splitlines()[-1] == "owner-answers: read=read"
        and json.loads(state.read_text()) == {"description": item["description"] if synced else marker + body,
                                             "labels": ["owner-gated", "skills"], "assignee": "Owner Person"}
        and (not synced or all("--description" not in call for call in updates))
        and json.loads(threads_path.read_text()) == [*threads, new_reply]
        and threads[:2] == [before[0], older_reply]
        and seen == [(new_reply["id"], new_ask_id)])


def action_window(root, bash):
    """Supply the stateful tracker and its two real mailboxes to the Rust watch."""
    scripts = root / ".agents/skills/mailbox/scripts"
    shutil.copytree(REPO / "skills/mailbox/scripts", scripts)
    tracker = root / ".agents/skills/linear/scripts/linear.sh"
    tracker.parent.mkdir(parents=True)
    tracker.write_text(TRACKER)
    tracker.chmod(0o755)
    linear = root / "linear"
    shutil.copytree(REPO / "skills/linear/scripts", linear / "scripts")
    curl_dir = linear / "bin"
    curl_dir.mkdir()
    (curl_dir / "curl").write_text(CURL)
    (curl_dir / "curl").chmod(0o755)
    newer = root / "other-project"
    for checkout in (root, newer):
        subprocess.run(["git", "init", "-q", str(checkout)], check=True)
        for key, value in (("gc.auto", "0"), ("maintenance.auto", "false")):
            subprocess.run(["git", "-C", str(checkout), "config", key, value], check=True)

    def environment(checkout):
        env = {"PATH": os.environ["PATH"], "HOME": str(checkout), "TMPDIR": str(checkout),
               "TRACKER_CASE": str(root), "TRACKER_ROW": "posted", "TRACKER_BASH": bash,
               "TRACKER_LINEAR": str(linear / "scripts/linear.sh"), "TRACKER_CURL_DIR": str(curl_dir),
               "ORCH_OWNER_EMAIL": "owner@example.test", "ORCH_OWNER_ASK_LABEL": "owner-gated"}
        env.update({key: str(checkout / key) for key in
                    ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME")})
        return env

    body = "Preserve the original body.\n\n"
    (root / "item.json").write_text(json.dumps({"description": body, "labels": ["skills"], "assignee": ""}))
    (root / "comments.json").write_text("[]")
    (root / "threads.json").write_text("[]")
    message = root / "question"
    message.write_text("Approve the change?\n")
    mail = scripts / "lane-mail"

    def ask(action):
        return [bash, str(mail), "ask", "--item", "overseer", "--to", "owner", "--issue", "KEN-7",
                "--do", action, "--wait", "5", "--options", "approve,hold", "--recommend", "approve",
                "--effect", "none", "--file", str(message)]

    env = environment(root)
    old = subprocess.run(ask("Review the older change"), cwd=root, env=env, check=True,
                         capture_output=True, text=True, timeout=15)
    old_ask = old.stdout.strip().split("=", 1)[1]
    old_question = (root / "question-id").read_text()
    threads = root / "threads.json"
    clarification = tracker_reply("older-reply", old_question, "Prior clarification")
    clarification["user_email"] = "participant@example.test"
    threads.write_text(json.dumps([*json.loads(threads.read_text()), clarification]))
    (root / "before-clear.json").write_text(json.dumps(
        {"flag": "--description", "args": ask("Review the newer change"),
         "cwd": str(newer), "env": environment(newer)}))
    return {"mail": str(mail), "tracker": str(tracker), "newer": str(newer), "message": str(message),
            "env": env, "old_ask": old_ask, "old_question": old_question, "body": body}


if __name__ == "__main__":
    if sys.argv[1] == "action-window":
        print(json.dumps(action_window(Path(sys.argv[2]), sys.argv[3])))
    else:
        print(json.dumps(run(Path(sys.argv[1]), sys.argv[2], sys.argv[3], *sys.argv[4:])))
