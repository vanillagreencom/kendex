"""Observe owner ask replacement against a stateful tracker.

The shell suite owns assertions. This driver returns observations from real
mailbox reads and the stub tracker's state. The stub keeps one item store and
one comment store per case.
"""

import json
import os
from pathlib import Path
import re
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
items = json.loads((state / "items.json").read_text())
comments = json.loads((state / "comments.json").read_text())
users = [{"id": "owner", "name": "Owner Person", "email": "owner@example.test", "display_name": "owner.person"}]


def option(flag):
    return args[args.index(flag) + 1] if flag in args else None


def safe(row):
    return {key: row[key] for key in ("id", "body", "user_id", "user_email", "parent_id", "url", "created_at")}


def save():
    (state / "items.json").write_text(json.dumps(items))
    (state / "comments.json").write_text(json.dumps(comments))


if args[:2] == ["users", "list"]:
    print(json.dumps(users))
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
    if (state / "fail-create").exists():
        print("tracker: refused=create", file=sys.stderr)
        sys.exit(1)
    number = len(comments) + 1
    comments.append({"id": "c%d" % number, "issue": args[2], "body": Path(option("--body-file")).read_text(),
                     "user_id": "agent", "user_email": "agent@example.test", "parent_id": option("--parent"),
                     "url": "https://linear.app/workspace/issue/%s#comment-c%d" % (args[2], number),
                     "created_at": "2026-01-01T00:00:%02dZ" % number})
    save()
    print(json.dumps({"success": True, "data": {"success": True, "comment": {"id": "c%d" % number}}}))
elif args[:2] == ["comments", "update"]:
    row = next(row for row in comments if row["id"] == args[2])
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
    """One tracker store and the checkout whose overseer asks through it."""

    def __init__(self, scratch, source, bash, issues):
        self.dir = Path(tempfile.mkdtemp(dir=scratch))
        self.source, self.bash = source, bash
        self.state = self.dir / "tracker"
        self.state.mkdir()
        (self.state / "items.json").write_text(json.dumps(
            {issue: {"description": "Item body.\n", "labels": ["skills"], "assignee": ""} for issue in issues}))
        (self.state / "comments.json").write_text("[]")

    def checkout(self, name):
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
               "TRACKER_STATE": str(self.state)}
        return Overseer(root, env, [self.bash, str(scripts / "lane-mail")])

    def comments(self):
        return json.loads((self.state / "comments.json").read_text())

    def items(self):
        return json.loads((self.state / "items.json").read_text())

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

    def owner_answers(self):
        """The answers owner-answers delivered, by the tracker comment each came from."""
        env = dict(self.env, OVERSEE_WATCH_TRACKER=str(self.root / ".agents/skills/linear/scripts/linear.sh"))
        result = subprocess.run([*self.mail, "owner-answers", "--item", "overseer"], cwd=self.root, env=env,
                                capture_output=True, text=True, timeout=30)
        answers = {row["delivery_id"].split(":", 1)[1]: row for row in self.rows("to-lane.jsonl")
                   if row["kind"] == "answer"}
        return result, answers


def marked(body, original, url):
    """The replaced question no longer opens with the owner mention, opens
    with a link to the newer question, and ends with its own lines struck."""
    lines, original = body.splitlines(), original.splitlines()
    struck = [("~~" + line + "~~") if line.strip() else line for line in original]
    return (lines[0] != original[0] and "(" + url + ")" in lines[0]
            and lines[-len(struck):] == struck)


def tracker_comment(overseer, ask):
    return next(row["tracker_comment"] for row in overseer.rows("to-overseer.jsonl")
                if row.get("kind") == "tracker-posted" and row.get("re") == ask)


def replace(scratch, source, bash, facts):
    case = Case(scratch, source, bash, ("KEN-7", "KEN-8"))
    overseer = case.checkout("asker")
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
    facts["marked"] &= marked(comments[first_comment]["body"], before[first_comment], comments[second_comment]["url"])
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


def follow_up(scratch, source, bash, facts):
    """An item ask whose question fails to post, beside an earlier posted one,
    while a posted ask on another item stays open, so owner-answers reads the
    item's comments throughout."""
    case = Case(scratch, source, bash, ("KEN-11", "KEN-12"))
    overseer = case.checkout("asker")
    overseer.item_ask("KEN-12")
    # The earlier question stays open and unedited, and a reply under it
    # answers that ask.
    first, _ = overseer.item_ask("KEN-11")
    first_comment = tracker_comment(overseer, first)
    before = {row["id"]: row["body"] for row in case.comments()}
    (case.state / "fail-create").touch()
    unposted, stderr = overseer.ask("--issue", "KEN-11", "--do", "Approve change", text="Approve it today?\n")
    (case.state / "fail-create").unlink()
    under = case.owner_reply("KEN-11", first_comment, "A")
    imported, answers = overseer.owner_answers()
    facts["unposted_keeps"] &= (set(overseer.pending()) >= {first, unposted}
        and {row["id"]: row["body"] for row in case.comments()}[first_comment] == before[first_comment]
        and "lane-mail: replace-unclosed id=%s cause=tracker-unwritten" % first in stderr.splitlines()
        and imported.returncode == 0 and answers.get(under, {}).get("re") == first)
    # Once the earlier ask closes on its own, a reply under its question
    # answers no ask: the unposted one replaced nothing.
    overseer.run("resolve", "--item", "overseer", "--id", first)
    objection = case.owner_reply("KEN-11", first_comment, "No")
    imported, answers = overseer.owner_answers()
    facts["unposted_keeps"] &= imported.returncode == 0 and objection not in answers
    # The next item ask replaces the unposted ask and carries nothing of the
    # question that ask never replaced: a reply under it is a plain answer.
    third, _ = overseer.ask("--issue", "KEN-11", "--do", "Approve change", text="Approve half of it?\n")
    later = case.owner_reply("KEN-11", first_comment, "C")
    imported, answers = overseer.owner_answers()
    facts["unposted_keeps"] &= (unposted not in overseer.pending() and imported.returncode == 0
        and answers.get(later, {}).get("re") == third and answers[later]["text"] == "C")


def chat_chain(scratch, source, bash, facts):
    """Asks without an item, each replacing the one before, after an item ask."""
    case = Case(scratch, source, bash, ("KEN-8",))
    overseer = case.checkout("asker")
    first, _ = overseer.item_ask("KEN-8")
    question = tracker_comment(overseer, first)
    second, _ = overseer.ask("--replaces", first)
    under = case.owner_reply("KEN-8", question, "A")
    imported, answers = overseer.owner_answers()
    reply = answers.get(under, {})
    head = reply.get("text", "").splitlines()[:1]
    facts["chat_replaces"] &= (imported.returncode == 0 and set(overseer.pending()) == {second}
        and reply.get("re") == second and bool(head) and first in head[0] and second in head[0]
        and reply["text"].splitlines()[-1] == "A")
    # A third ask replacing the second carries the first question forward.
    third, _ = overseer.ask("--replaces", second)
    later = case.owner_reply("KEN-8", question, "B")
    imported, answers = overseer.owner_answers()
    facts["chain"] &= ({"id": first, "issue": "KEN-8", "tracker_comment": question}
        in overseer.pending()[third].get("replaces", [])
        and imported.returncode == 0 and answers.get(later, {}).get("re") == third)


def earlier_answer(scratch, source, bash, facts):
    """Owner comments on the item, not under any question, posted while an ask
    stood and before the ask that replaced it, reach the ask left open, each
    naming the question it followed; one after the open question is its own."""
    case = Case(scratch, source, bash, ("KEN-7", "KEN-8"))
    overseer = case.checkout("asker")

    def follows(answers, comment, replaced, open_ask, text):
        answer = answers.get(comment, {})
        lines = answer.get("text", "").splitlines()
        return (answer.get("re") == open_ask and bool(lines)
                and set(re.findall(r"\d+-\d+-\d+", lines[0])) == {replaced, open_ask} and lines[-1] == text)

    first, _ = overseer.item_ask("KEN-7")
    approve = case.owner_reply("KEN-7", None, "approve")
    second, _ = overseer.ask("--issue", "KEN-7", "--do", "Approve change", text="Approve, hold or split?\n")
    hold = case.owner_reply("KEN-7", None, "hold")
    third, _ = overseer.ask("--issue", "KEN-7", "--do", "Approve change", text="Approve half of it?\n")
    after = case.owner_reply("KEN-7", None, "approve half")
    imported, answers = overseer.owner_answers()
    facts["earlier_answer"] &= (imported.returncode == 0 and set(overseer.pending()) == {third}
        and follows(answers, approve, first, third, "approve") and follows(answers, hold, second, third, "hold")
        and answers.get(after, {}).get("re") == third and answers[after].get("text") == "approve half")
    # An ask without an item replacing an item ask takes the comment too.
    asked, _ = overseer.item_ask("KEN-8")
    early = case.owner_reply("KEN-8", None, "approve")
    chat, _ = overseer.ask("--replaces", asked, text="Approve the whole change?\n")
    imported, answers = overseer.owner_answers()
    facts["earlier_answer"] &= imported.returncode == 0 and follows(answers, early, asked, chat, "approve")


def run(source, scratch, bash):
    facts = {"marked": True, "other_item": True, "closed": True, "replaces_field": True,
             "replaces_refused": True, "replaced_reply": True, "unposted_keeps": True,
             "chat_replaces": True, "chain": True, "earlier_answer": True}
    replace(scratch, source, bash, facts)
    follow_up(scratch, source, bash, facts)
    chat_chain(scratch, source, bash, facts)
    earlier_answer(scratch, source, bash, facts)
    return facts


if __name__ == "__main__":
    print(json.dumps(run(Path(sys.argv[1]), sys.argv[2], sys.argv[3])))
