"""Observe owner ask replacement and a relayed ask against a stateful tracker.

The shell suite owns assertions. This driver returns observations from real
mailbox reads and the stub tracker's state. The stub keeps one item store and
one comment store per case, shared by every checkout of the case, and acts as
the Linear user TRACKER_USER names: like Linear, it refuses an edit of a
comment another user wrote.
"""

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

state = Path(os.environ["TRACKER_STATE"])
args = sys.argv[1:]
me = os.environ["TRACKER_USER"]
items = json.loads((state / "items.json").read_text())
comments = json.loads((state / "comments.json").read_text())
with (state / "calls.jsonl").open("a") as out:
    out.write(json.dumps({"user": me, "args": args}) + "\n")
users = [{"id": "owner", "name": "Owner Person", "email": "owner@example.test", "display_name": "owner.person"},
         {"id": "agent", "name": "Agent", "email": "agent@example.test", "display_name": "agent"},
         {"id": "jarvis", "name": "Jarvis", "email": "jarvis@example.test", "display_name": "jarvis"}]
email = {user["id"]: user["email"] for user in users}


def option(flag):
    return args[args.index(flag) + 1] if flag in args else None


def safe(row):
    return {key: row[key] for key in ("id", "body", "user_id", "user_email", "parent_id", "url", "created_at")}


def save():
    (state / "items.json").write_text(json.dumps(items))
    (state / "comments.json").write_text(json.dumps(comments))


if args[:2] == ["users", "list"]:
    print(json.dumps(users))
elif args[:2] == ["users", "me"]:
    print(json.dumps({"id": me}))
elif args[:2] == ["teams", "keys"]:
    print(json.dumps({"urlKey": "workspace", "keys": ["KEN"]}))
elif args[:2] == ["graphql", "--query"] and args[2].startswith("query OwnerTrackerComment("):
    doc = {"type": "doc", "content": [{"type": "suggestion_userMentions", "attrs": {"id": "owner"}}]}
    print(json.dumps({"comment": {"bodyData": json.dumps(doc)}}))
elif args[:2] == ["graphql", "--query"] and args[2].startswith("query OwnerTracker("):
    item = items[json.loads(option("--variables"))["id"]]
    print(json.dumps({"issue": {"description": item["description"],
        "assignee": {"name": item["assignee"]} if item["assignee"] else None,
        "labels": {"pageInfo": {"hasNextPage": False}, "nodes": [{"name": l} for l in item["labels"]]}}}))
elif args[:2] == ["issues", "update"]:
    item = items[args[2]]
    if "--assignee" in args:
        item["assignee"] = next(u["name"] for u in users if u["id"] == option("--assignee"))
    if "--labels" in args:
        item["labels"] = option("--labels").split(",")
    if "--description" in args:
        item["description"] = option("--description")
    save()
    print("{}")
elif args[:2] == ["issues", "list"]:
    print(json.dumps([{"id": key, "assignee": item["assignee"], "description": item["description"]}
                      for key, item in items.items()
                      if item["assignee"] == "Owner Person" and option("--label") in item["labels"]]))
elif args[:2] == ["comments", "create"]:
    number = len(comments) + 1
    comments.append({"id": "c%d" % number, "issue": args[2], "body": Path(option("--body-file")).read_text(),
                     "user_id": me, "user_email": email[me], "parent_id": option("--parent"),
                     "url": "https://linear.app/workspace/issue/%s#comment-c%d" % (args[2], number),
                     "created_at": "2026-01-01T00:00:%02dZ" % number})
    save()
    print(json.dumps({"success": True, "data": {"success": True, "comment": {"id": "c%d" % number}}}))
elif args[:2] == ["comments", "update"]:
    row = next(row for row in comments if row["id"] == args[2])
    if row["user_id"] != me:
        print("tracker: refused=another-author", file=sys.stderr)
        sys.exit(1)
    row["body"] = Path(option("--body-file")).read_text()
    save()
    print(json.dumps({"success": True, "data": {"success": True}}))
elif args[:2] == ["comments", "list"]:
    print(json.dumps([safe(row) for row in comments if row["issue"] == args[2]]))
elif args[:2] == ["comments", "bulk-list"]:
    wanted = [arg for arg in args[2:] if not arg.startswith("--")]
    print(json.dumps({key: [safe(row) for row in comments if row["issue"] == key] for key in wanted}))
else:
    sys.exit(1)
'''


class Case:
    """One tracker store and the checkouts whose overseers ask through it."""

    def __init__(self, scratch, source, bash, issues):
        self.dir = Path(tempfile.mkdtemp(dir=scratch))
        self.source, self.bash = source, bash
        self.state = self.dir / "tracker"
        self.state.mkdir()
        (self.state / "items.json").write_text(json.dumps(
            {issue: {"description": "Item body.\n", "labels": ["skills"], "assignee": ""} for issue in issues}))
        (self.state / "comments.json").write_text("[]")
        (self.state / "calls.jsonl").write_text("")

    def checkout(self, name, user):
        root = self.dir / name
        scripts = root / ".agents/skills/mailbox/scripts"
        shutil.copytree(self.source / "scripts", scripts)
        tracker = root / ".agents/skills/linear/scripts/linear.sh"
        tracker.parent.mkdir(parents=True)
        tracker.write_text(TRACKER)
        tracker.chmod(0o755)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        for key, value in (("gc.auto", "0"), ("maintenance.auto", "false")):
            subprocess.run(["git", "-C", str(root), "config", key, value], check=True)
        env = {"PATH": os.environ["PATH"], "HOME": str(root), "TMPDIR": str(root),
               "XDG_CONFIG_HOME": str(root / ".config"), "XDG_DATA_HOME": str(root / ".local/share"),
               "XDG_STATE_HOME": str(root / ".local/state"), "XDG_CACHE_HOME": str(root / ".cache"),
               "ORCH_OWNER_EMAIL": "owner@example.test", "ORCH_OWNER_ASK_LABEL": "owner-gated",
               "TRACKER_STATE": str(self.state), "TRACKER_USER": user}
        return Overseer(root, env, [self.bash, str(scripts / "lane-mail")])

    def comments(self):
        return json.loads((self.state / "comments.json").read_text())

    def items(self):
        return json.loads((self.state / "items.json").read_text())

    def calls(self):
        return [json.loads(line) for line in (self.state / "calls.jsonl").read_text().splitlines()]

    def owner_reply(self, issue, parent, body):
        comments = self.comments()
        number = len(comments) + 1
        comments.append({"id": "c%d" % number, "issue": issue, "body": body, "user_id": "owner",
                         "user_email": "owner@example.test", "parent_id": parent, "url": "",
                         "created_at": "2026-01-01T00:00:%02dZ" % number})
        (self.state / "comments.json").write_text(json.dumps(comments))
        return "c%d" % number


class Overseer:
    def __init__(self, root, env, mail):
        self.root, self.env, self.mail = root, env, mail

    def run(self, *args):
        return subprocess.run([*self.mail, *args], cwd=self.root, env=self.env,
                              capture_output=True, text=True, timeout=30)

    def ask(self, *extra, text="Approve the change?\n"):
        question = self.root / "question"
        question.write_text(text)
        result = self.run("ask", "--item", "overseer", "--to", "owner", "--options", "approve,hold",
                          "--recommend", "approve", "--effect", "none", "--wait", "60",
                          "--file", str(question), *extra)
        if result.returncode:
            raise RuntimeError("ask exit=%d: %s" % (result.returncode, result.stderr))
        return result.stdout.strip().split("=", 1)[1], result.stderr

    def item_ask(self, issue, *extra):
        return self.ask("--issue", issue, "--do", "Approve change", *extra)

    def rows(self, box):
        path = self.root / "tmp/lane-mail/overseer" / box
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def pending(self):
        result = self.run("pending", "--item", "overseer", "--to", "owner")
        return {row["id"]: row for row in map(json.loads, result.stdout.splitlines())}


def tracker_comment(overseer, ask):
    return next(row["tracker_comment"] for row in overseer.rows("to-overseer.jsonl")
                if row.get("kind") == "tracker-posted" and row.get("re") == ask)


def replace(scratch, source, bash, facts):
    case = Case(scratch, source, bash, ("KEN-7", "KEN-8"))
    overseer = case.checkout("asker", "agent")
    first, _ = overseer.item_ask("KEN-7")
    other, _ = overseer.item_ask("KEN-8")
    chat, _ = overseer.ask()
    resolved = overseer.run("resolve", "--item", "overseer", "--id", other)
    first_comment, other_comment = tracker_comment(overseer, first), tracker_comment(overseer, other)
    before = {row["id"]: row["body"] for row in case.comments()}
    # A refused --replaces appends nothing to either mailbox file.
    lines = (len(overseer.rows("to-overseer.jsonl")), len(overseer.rows("to-lane.jsonl")))
    for target, key in (("1-1-1", "ask-unknown"), (other, "resolved-already")):
        refused = overseer.run("ask", "--item", "overseer", "--to", "owner", "--options", "approve,hold",
                               "--recommend", "approve", "--effect", "none", "--file", str(overseer.root / "question"),
                               "--replaces", target)
        facts["replaces_refused"] &= (refused.returncode == 2
            and refused.stderr.startswith("lane-mail: " + key + "=")
            and lines == (len(overseer.rows("to-overseer.jsonl")), len(overseer.rows("to-lane.jsonl"))))
    second, stderr = overseer.item_ask("KEN-7", "--replaces", chat)
    second_comment = tracker_comment(overseer, second)
    comments = {row["id"]: row for row in case.comments()}
    lines = comments[first_comment]["body"].splitlines()
    original = before[first_comment].splitlines()
    facts["marked"] &= (lines[0] == "**Replaced** by [the newer question](%s). Answer that one only."
                        % comments[second_comment]["url"]
        and lines[1] == "" and lines[2:] == [("~~" + line + "~~") if line.strip() else line for line in original])
    # An open ask on another item is neither marked nor closed.
    facts["other_item"] &= comments[other_comment]["body"] == before[other_comment]
    open_asks = overseer.pending()
    closes = [row for row in overseer.rows("to-lane.jsonl") if row["kind"] == "resolution"]
    by_ask = {row["re"]: row for row in closes}
    shape = lambda row: {key: value for key, value in row.items() if key not in ("id", "at", "re")}
    facts["closed"] &= (set(open_asks) == {second} and set(by_ask) == {other, first, chat}
        and resolved.returncode == 0 and shape(by_ask[first]) == shape(by_ask[other]) == shape(by_ask[chat])
        and "lane-mail: resolved id=" + first + " " in stderr and "lane-mail: resolved id=" + chat + " " in stderr)
    facts["replaces_field"] &= sorted(open_asks[second].get("replaces", []), key=lambda r: r["id"]) == sorted(
        [{"id": chat}, {"id": first, "issue": "KEN-7", "tracker_comment": first_comment}], key=lambda r: r["id"])
    # The new question is the item's: its label and assignee stand.
    item = case.items()["KEN-7"]
    facts["closed"] &= item["assignee"] == "Owner Person" and "owner-gated" in item["labels"]
    # The owner answers under the replaced question, and on the item.
    under = case.owner_reply("KEN-7", first_comment, "A")
    plain = case.owner_reply("KEN-7", None, "B")
    env = dict(overseer.env, OVERSEE_WATCH_TRACKER=str(overseer.root / ".agents/skills/linear/scripts/linear.sh"))
    imported = subprocess.run([*overseer.mail, "owner-answers", "--item", "overseer"], cwd=overseer.root, env=env,
                              capture_output=True, text=True, timeout=30)
    answers = {row["delivery_id"]: row for row in overseer.rows("to-lane.jsonl") if row["kind"] == "answer"}
    delivered = [json.loads(line) for line in imported.stdout.splitlines() if line.startswith("{")]
    reply = answers.get("linear:" + under, {})
    facts["replaced_reply"] &= (imported.returncode == 0 and set(answers) == {"linear:" + under, "linear:" + plain}
        and reply.get("re") == second and first in reply.get("text", "").splitlines()[0]
        and second in reply.get("text", "").splitlines()[0] and reply["text"].splitlines()[-1] == "A"
        and answers["linear:" + plain]["re"] == second and answers["linear:" + plain]["text"] == "B"
        and {(row["ask"], row["comment"]) for row in delivered if row["kind"] == "delivered"}
        == {(second, under), (second, plain)})


def relay(scratch, source, bash, facts, overseer_first):
    """An overseer and a Jarvis session, each in its own checkout, ask on one item."""
    case = Case(scratch, source, bash, ("KEN-9",))
    order = [("fleet", "agent"), ("jarvis", "jarvis")]
    if not overseer_first:
        order.reverse()
    second_user = order[1][1]
    first = case.checkout(*order[0])
    second = case.checkout(*order[1])
    first_ask, _ = first.item_ask("KEN-9")
    standing = tracker_comment(first, first_ask)
    comments, item = case.comments(), case.items()["KEN-9"]
    calls = len(case.calls())
    second_ask, _ = second.item_ask("KEN-9")
    writes = [call["args"][:2] for call in case.calls()[calls:]
              if call["args"][:2] in (["issues", "update"], ["comments", "create"], ["comments", "update"])]
    facts["relay"] &= (writes == [] and case.comments() == comments and case.items()["KEN-9"] == item
        and second.pending()[second_ask]["tracker_posted"] is True
        and tracker_comment(second, second_ask) == standing)
    if not overseer_first:
        return
    # A second ask from the Jarvis checkout replaces its own first one, whose
    # question the overseer wrote: that comment stays as the overseer left it.
    replacing, stderr = second.item_ask("KEN-9")
    rows = {row["id"]: row for row in case.comments()}
    updates = [call for call in case.calls() if call["args"][:2] == ["comments", "update"]]
    facts["own_author"] &= (rows[standing]["body"] == next(r["body"] for r in comments if r["id"] == standing)
        and updates == [] and set(second.pending()) == {replacing}
        and "lane-mail: replace-unmarked id=%s issue=KEN-9 cause=other-author" % second_ask in stderr.splitlines()
        and rows[tracker_comment(second, replacing)]["user_id"] == second_user)


def run(source, scratch, bash):
    facts = {"marked": True, "other_item": True, "closed": True, "replaces_field": True,
             "replaces_refused": True, "replaced_reply": True, "relay": True, "own_author": True}
    replace(scratch, source, bash, facts)
    relay(scratch, source, bash, facts, overseer_first=True)
    relay(scratch, source, bash, facts, overseer_first=False)
    return facts


if __name__ == "__main__":
    print(json.dumps(run(Path(sys.argv[1]), sys.argv[2], sys.argv[3])))
