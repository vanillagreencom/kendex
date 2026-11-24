"""Observe owner ask replacement against a stateful tracker.

The shell suite owns assertions. This driver returns observations from real
mailbox reads and the stub tracker's state. The stub keeps one item store and
one comment store per case.
"""

from concurrent.futures import ThreadPoolExecutor
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
import re
import sys

state = Path(os.environ["TRACKER_STATE"])
args = sys.argv[1:]
items = json.loads((state / "items.json").read_text())
comments = json.loads((state / "comments.json").read_text())
# The account the credential acts as: it writes every comment created here.
actor = (state / "actor").read_text() if (state / "actor").exists() else "agent"
# Linear's comment writes with no LINEAR_TEAM: its configured-team gate
# refuses `comments update` before any call, and auth-check says
# writes_enabled false (a recorded run of linear.sh comments update).
team = not (state / "no-team").exists()
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
elif args[:1] == ["auth-check"]:
    # auth-check prints its report when the API fails too, with no actor.
    if (state / "fail-auth").exists():
        print(json.dumps({"ok": False, "error": "API request failed", "actor": None, "writes_enabled": team}))
        sys.exit(1)
    print(json.dumps({"ok": True, "actor": {"kind": "application", "id": actor, "name": "Agent"}, "writes_enabled": team}))
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
                     "user_id": actor, "user_email": actor + "@example.test", "parent_id": option("--parent"),
                     "url": "https://linear.app/workspace/issue/%s#comment-c%d" % (args[2], number),
                     "created_at": "2026-01-01T00:%02d:%02dZ" % divmod(number, 60)})
    save()
    print(json.dumps({"success": True, "data": {"success": True, "comment": {"id": "c%d" % number}}}))
elif args[:2] == ["comments", "update"]:
    if not team:
        print(json.dumps({"error": "No Linear team configured for this project - refusing to write."}), file=sys.stderr)
        sys.exit(1)
    row = next(row for row in comments if row["id"] == args[2])
    row["body"] = Path(option("--body-file")).read_text()
    save()
    print(json.dumps({"success": True, "data": {"success": True}}))
elif args[:2] == ["comments", "list"]:
    print(json.dumps([safe(row) for row in comments if row["issue"] == args[2]]))
elif args[:2] == ["comments", "bulk-list"]:
    wanted = [arg for arg in args[2:] if not arg.startswith("--")]
    # linear_issue_refs: a ref that is not an identifier, a UUID among them,
    # refuses the whole read before any lookup; an identifier is read and
    # keyed in upper case.
    if not all(re.fullmatch(r"[A-Za-z0-9]+-[0-9]+", key) for key in wanted):
        print(json.dumps({"error": "Not an issue identifier (TEAM-123)"}), file=sys.stderr)
        sys.exit(1)
    wanted = [key.upper() for key in wanted]
    # comments --help: a ref Linear answers it has no issue for refuses the
    # whole read, naming it in `missing` after the lookup's own error line.
    missing = [key for key in wanted if key not in items]
    if missing:
        print(json.dumps({"error": "Entity not found: Issue"}), file=sys.stderr)
        print(json.dumps({"error": "Issues not read: " + ", ".join(missing), "missing": missing}), file=sys.stderr)
        sys.exit(1)
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
        # A report of an unmatched owner comment is a data notice, which needs
        # a registered overseer: agent-runtime's controller status says one is.
        runtime = root / ".agents/skills/agent-runtime/scripts/agent-runtime"
        runtime.parent.mkdir(parents=True)
        runtime.write_text("#!/bin/sh\nprintf '%s\\n' '{\"ok\":true,\"result\":{\"recorded\":{},\"live\":true}}'\n")
        runtime.chmod(0o755)
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
                         "created_at": "2026-01-01T00:%02d:%02dZ" % divmod(number, 60)})
        (self.state / "comments.json").write_text(json.dumps(comments))
        return "c%d" % number

    def drop_comment(self, comment):
        """Deleted from its item; the row keeps its place so no later comment reuses its id."""
        comments = self.comments()
        next(row for row in comments if row["id"] == comment)["issue"] = "deleted"
        (self.state / "comments.json").write_text(json.dumps(comments))

    def delete_item(self, issue):
        """Gone from Linear, deleted or out of the token's reach."""
        items = self.items()
        del items[issue]
        (self.state / "items.json").write_text(json.dumps(items))

    def body(self, comment):
        return next(row["body"] for row in self.comments() if row["id"] == comment)

    def url(self, comment):
        return next(row["url"] for row in self.comments() if row["id"] == comment)

    def failing(self, on):
        """While on, the stub refuses every comment create: an item ask's question does not post."""
        flag = self.state / "fail-create"
        flag.touch() if on else flag.unlink()

    def act_as(self, actor):
        """The credential acts as ACTOR from now on; None leaves the account
        as it is and makes auth-check fail, so no actor reads."""
        flag = self.state / "fail-auth"
        flag.touch() if actor is None else flag.unlink(missing_ok=True)
        if actor is not None:
            (self.state / "actor").write_text(actor)

    def without_team(self):
        """The home's Linear package has no LINEAR_TEAM from now on."""
        (self.state / "no-team").touch()




class Overseer:
    def __init__(self, root, env, mail):
        self.root, self.env, self.mail = root, env, mail

    def run(self, *args, env=None):
        return subprocess.run([*self.mail, *args], cwd=self.root, env=env or self.env,
                              capture_output=True, text=True, timeout=30)

    def ask(self, *extra, text="Approve the change?\n", env=None):
        """The new ask's id and stderr; a refused ask raises."""
        result = self.try_ask(*extra, text=text, env=env)
        if result.returncode:
            raise RuntimeError("ask exit=%d: %s" % (result.returncode, result.stderr))
        return result.stdout.strip().split("=", 1)[1], result.stderr

    def try_ask(self, *extra, text="Approve the change?\n", env=None):
        question = self.root / "question"
        question.write_text(text)
        return self.run("ask", "--item", "overseer", "--to", "owner", "--options", "approve,hold",
                        "--recommend", "approve", "--effect", "none", "--wait", "60",
                        "--file", str(question), *extra, env=env)

    def item_ask(self, issue, *extra, text="Approve the change?\n"):
        return self.ask("--issue", issue, "--do", "Approve change", *extra, text=text)

    def resolve(self, ask):
        result = self.run("resolve", "--item", "overseer", "--id", ask)
        if result.returncode:
            raise RuntimeError("resolve exit=%d: %s" % (result.returncode, result.stderr))

    def rows(self, box):
        path = self.root / "tmp/lane-mail/overseer" / box
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def pending(self):
        result = self.run("pending", "--item", "overseer", "--to", "owner")
        return {row["id"]: row for row in map(json.loads, result.stdout.splitlines())}

    def retain_issue(self, ask, ref):
        """ASK and its tracker record name their item by REF, as an ask the
        earlier ask path accepted with any --issue form keeps it."""
        path = self.root / "tmp/lane-mail/overseer/to-overseer.jsonl"
        rows = self.rows("to-overseer.jsonl")
        changed = [row for row in rows if ask in (row.get("id"), row.get("re"))]
        assert len(changed) == 2, changed
        for row in changed:
            row["issue"] = ref
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))

    def lines(self):
        return len(self.rows("to-overseer.jsonl")), len(self.rows("to-lane.jsonl"))

    def compact(self):
        """The watch's retention a month on, once the overseer has read its
        mail: orch's settings answer their defaults and no archive root is
        placed, so the dropped rows leave with no copy."""
        orch = self.root / ".agents/skills/orch/scripts"
        orch.mkdir(parents=True, exist_ok=True)
        for name, script in (("orch-env", 'printf "%s\\n" "$2"'),
                             ("orch-runtime", "printf '%s\\n' '{\"ok\":true,\"result\":{\"archive\":null}}'")):
            (orch / name).write_text("#!/bin/sh\n" + script + "\n")
            (orch / name).chmod(0o755)
        later = self.root / "later"
        later.mkdir(exist_ok=True)
        date = shutil.which("date", path=self.env["PATH"])
        (later / "date").write_text('#!/bin/sh\nif [ "$*" = "-u +%%s" ]; then echo $(( $("%s" -u +%%s) + 2592000 ))\n'
                                    'else exec "%s" "$@"; fi\n' % (date, date))
        (later / "date").chmod(0o755)
        for args, env in ((("inbox", "--item", "overseer"), None),
                          (("compact", "--item", "overseer"), dict(self.env, PATH=str(later) + os.pathsep + self.env["PATH"]))):
            result = self.run(*args, env=env)
            if result.returncode:
                raise RuntimeError("%s exit=%d: %s" % (args[0], result.returncode, result.stderr))

    def owner_answers(self):
        env = dict(self.env, OVERSEE_WATCH_TRACKER=str(self.root / ".agents/skills/linear/scripts/linear.sh"))
        result = subprocess.run([*self.mail, "owner-answers", "--item", "overseer"], cwd=self.root, env=env,
                                capture_output=True, text=True, timeout=60)
        return Pass(result, self.rows("to-lane.jsonl"))


class Pass:
    """One owner-answers run, and every tracker comment the mailbox now holds
    as an answer to an ask or as an unmatched owner comment report, by the
    comment id its delivery id names."""

    def __init__(self, result, rows):
        self.result = result
        keyed = [(row["delivery_id"].split(":", 1)[1], row) for row in rows
                 if row.get("delivery_id", "").startswith("linear:")]
        self.answers = {comment: row for comment, row in keyed if row["kind"] == "answer"}
        self.reports = {comment: row for comment, row in keyed
                        if row["kind"] == "data" and row.get("source") == "owner-answers"}
        self.counts = {}
        for comment, _ in keyed:
            self.counts[comment] = self.counts.get(comment, 0) + 1
        self.delivered = {(row["ask"], row["comment"]) for row in map(json.loads, result.stdout.splitlines()[:-1])
                          if row.get("kind") == "delivered"} if result.returncode == 0 else set()

    def ok(self):
        return self.result.returncode == 0 and self.result.stdout.splitlines()[-1:] == ["owner-answers: read=read"]

    def plain(self, comment, ask, body):
        """Delivered once to ASK with no header line."""
        answer = self.answers.get(comment, {})
        return (self.ok() and answer.get("re") == ask and answer.get("text") == body
                and self.counts.get(comment, 0) == 1 and comment not in self.reports)

    def headed(self, comment, form, replaced, open_ask, body):
        """Delivered once to OPEN_ASK, its first line the replaced-question
        header of FORM, Reply (under the question) or Comment (on the item),
        naming both asks."""
        answer = self.answers.get(comment, {})
        lines = answer.get("text", "").splitlines()
        return (self.ok() and answer.get("re") == open_ask and bool(lines) and lines[0].split()[0] == form
                and set(re.findall(r"\d+-\d+-\d+", lines[0])) == {replaced, open_ask} and lines[-1] == body
                and self.counts.get(comment, 0) == 1 and comment not in self.reports)

    def records(self, comments):
        """The id of the answer or report each comment holds."""
        return {comment: (self.answers.get(comment) or self.reports.get(comment) or {}).get("id")
                for comment in comments}

    def unjudged(self, comment):
        """Neither delivered to an ask nor reported."""
        return self.ok() and comment not in self.answers and comment not in self.reports

    def reported(self, comment, issue):
        """Reported to the overseer once, naming the item and the comment, and
        delivered to no ask."""
        report = self.reports.get(comment, {})
        lines = report.get("text", "").splitlines()
        return (self.ok() and comment not in self.answers and bool(lines)
                and {issue, comment} <= set(re.findall(r"[\w-]+", lines[0])) and self.counts.get(comment, 0) == 1)


def marked(body, original, url):
    """The replaced question no longer opens with the owner mention, opens
    with a link to the newer question, or with no link where URL is None,
    and ends with its own lines struck."""
    lines, original = body.splitlines(), original.splitlines()
    struck = [("~~" + line + "~~") if line.strip() else line for line in original]
    linked = ("](" not in lines[0]) if url is None else ("(" + url + ")" in lines[0])
    return lines[0] != original[0] and linked and lines[-len(struck):] == struck


def tracker_comment(overseer, ask):
    return next(row["tracker_comment"] for row in overseer.rows("to-overseer.jsonl")
                if row.get("kind") == "tracker-posted" and row.get("re") == ask)


def replace(case, facts):
    overseer = case.checkout("asker")
    first, _ = overseer.item_ask("KEN-7")
    other, _ = overseer.item_ask("KEN-8")
    chat, _ = overseer.ask()
    overseer.resolve(other)
    first_comment, other_comment = tracker_comment(overseer, first), tracker_comment(overseer, other)
    before = {row["id"]: row["body"] for row in case.comments()}
    # A refused --replaces, or an item ask refused for unset settings, appends
    # nothing and leaves the ask it names open.
    lines = overseer.lines()
    unset = {key: value for key, value in overseer.env.items() if key != "ORCH_OWNER_ASK_LABEL"}
    for extra, key, env in ((("--replaces", "1-1-1"), "ask-unknown", None),
                            (("--replaces", other), "resolved-already", None),
                            (("--issue", "KEN-7", "--do", "Approve change", "--replaces", first),
                             "item-ask-unconfigured", unset)):
        refused = overseer.try_ask(*extra, env=env)
        facts["refused_appends_nothing"] &= (refused.returncode == 2
            and refused.stderr.split()[1].split("=")[0] == key and lines == overseer.lines()
            and first in overseer.pending())
    between = case.owner_reply("KEN-7", None, "approve")
    # Replied under the first question before the re-ask, read after it.
    early = case.owner_reply("KEN-7", first_comment, "A first")
    second, stderr = overseer.item_ask("KEN-7", "--replaces", chat)
    second_comment = tracker_comment(overseer, second)
    open_asks = overseer.pending()
    closes = {row["re"]: row for row in overseer.rows("to-lane.jsonl") if row["kind"] == "resolution"}
    shape = lambda row: {key: value for key, value in row.items() if key not in ("id", "at", "re")}
    item = case.items()["KEN-7"]
    facts["same_item_replaces"] &= (marked(case.body(first_comment), before[first_comment], case.url(second_comment))
        and set(open_asks) == {second} and set(closes) == {other, first, chat}
        and shape(closes[first]) == shape(closes[other]) == shape(closes[chat])
        and "lane-mail: resolved id=" + first + " " in stderr and "lane-mail: resolved id=" + chat + " " in stderr
        and sorted(open_asks[second].get("replaces", []), key=lambda r: r["id"]) == sorted(
            [{"id": chat}, {"id": first, "issue": "KEN-7", "tracker_comment": first_comment}], key=lambda r: r["id"])
        and item["assignee"] == "Owner Person" and "owner-gated" in item["labels"])
    facts["other_item_kept"] &= case.body(other_comment) == before[other_comment]
    facts["uncommented_replaced"] &= {"id": chat} in open_asks[second].get("replaces", []) and chat in closes
    under = case.owner_reply("KEN-7", first_comment, "A")
    later = case.owner_reply("KEN-7", None, "B")
    own = case.owner_reply("KEN-7", second_comment, "C")
    read = overseer.owner_answers()
    facts["replaced_window"] &= read.headed(between, "Comment", first, second, "approve")
    facts["replaced_reply"] &= (read.headed(under, "Reply", first, second, "A")
        and read.headed(early, "Reply", first, second, "A first")
        and {(second, early), (second, under), (second, later), (second, own)} <= read.delivered)
    facts["open_question_plain"] &= read.plain(later, second, "B") and read.plain(own, second, "C")


def unposted(case, facts):
    """An item ask whose question fails to post, beside an earlier posted one,
    while a posted ask on another item stays open."""
    overseer = case.checkout("asker")
    overseer.item_ask("KEN-12")
    first, _ = overseer.item_ask("KEN-11")
    first_comment = tracker_comment(overseer, first)
    before = case.body(first_comment)
    case.failing(True)
    retry, stderr = overseer.item_ask("KEN-11", text="Approve it today?\n")
    # The same on another item through --replaces, and with both asks unposted.
    other, other_err = overseer.item_ask("KEN-12", "--replaces", first, text="Approve it there?\n")
    lone, _ = overseer.item_ask("KEN-13", text="Approve the third?\n")
    again, again_err = overseer.item_ask("KEN-13", text="Approve the third today?\n")
    case.failing(False)
    open_asks = overseer.pending()
    unclosed = "lane-mail: replace-unclosed id=%s cause=tracker-unwritten"
    facts["unposted_replaces_nothing"] &= (set(open_asks) >= {first, retry, other, lone, again}
        and case.body(first_comment) == before
        and unclosed % first in stderr.splitlines() and unclosed % first in other_err.splitlines()
        and unclosed % lone in again_err.splitlines()
        and all(open_asks[ask].get("tracker_comment") is None for ask in (retry, other, lone, again)))
    under = case.owner_reply("KEN-11", first_comment, "A")
    read = overseer.owner_answers()
    facts["unposted_replaces_nothing"] &= read.plain(under, first, "A")
    # Once the earlier ask closes on its own, a reply under its question
    # reaches no ask: the unposted ones replaced nothing.
    overseer.resolve(first)
    objection = case.owner_reply("KEN-11", first_comment, "No")
    read = overseer.owner_answers()
    facts["closed_question_reported"] &= read.reported(objection, "KEN-11")
    # The next posted item ask replaces the unposted one only: a reply under
    # the closed question is still no one's.
    third, _ = overseer.item_ask("KEN-11", text="Approve half of it?\n")
    later = case.owner_reply("KEN-11", first_comment, "C")
    read = overseer.owner_answers()
    facts["uncommented_replaced"] &= (retry not in overseer.pending()
        and {"id": retry, "issue": "KEN-11"} in overseer.pending()[third].get("replaces", []))
    facts["closed_reply_after_later_question"] &= read.reported(later, "KEN-11")


def after_unposted(case, facts):
    """After an unposted re-ask, the next posted re-ask on the item replaces both."""
    overseer = case.checkout("asker")
    first, _ = overseer.item_ask("KEN-7")
    first_comment = tracker_comment(overseer, first)
    before = case.body(first_comment)
    case.failing(True)
    retry, _ = overseer.item_ask("KEN-7", text="Approve it today?\n")
    case.failing(False)
    third, _ = overseer.item_ask("KEN-7", text="Approve half of it?\n")
    under = case.owner_reply("KEN-7", first_comment, "A")
    read = overseer.owner_answers()
    facts["posted_after_unposted"] &= (marked(case.body(first_comment), before,
                                              case.url(tracker_comment(overseer, third)))
        and set(overseer.pending()) == {third} and read.headed(under, "Reply", first, third, "A"))


def other_item(case, facts):
    """Asks on two items: one on J left alone by an ask on I, then an ask on J
    replacing the question on I through --replaces."""
    overseer = case.checkout("asker")
    first, _ = overseer.item_ask("KEN-7")
    first_comment = tracker_comment(overseer, first)
    before = case.body(first_comment)
    early = case.owner_reply("KEN-8", None, "before any question")
    plain, _ = overseer.item_ask("KEN-8", text="Ship the docs?\n")
    facts["other_item_kept"] &= case.body(first_comment) == before and first in overseer.pending()
    on_i = case.owner_reply("KEN-7", None, "approve")
    there, _ = overseer.item_ask("KEN-8", "--replaces", first, text="Approve it on KEN-8?\n")
    there_comment = tracker_comment(overseer, there)
    open_asks = overseer.pending()
    facts["other_item_replaces"] &= (marked(case.body(first_comment), before, case.url(there_comment))
        and set(open_asks) == {there}
        and {"id": first, "issue": "KEN-7", "tracker_comment": first_comment} in open_asks[there]["replaces"])
    after = case.owner_reply("KEN-7", None, "approve after")
    under = case.owner_reply("KEN-7", first_comment, "A")
    own = case.owner_reply("KEN-8", there_comment, "B")
    own_item = case.owner_reply("KEN-8", None, "C")
    read = overseer.owner_answers()
    facts["off_item_window"] &= (read.headed(on_i, "Comment", first, there, "approve")
        and read.headed(after, "Comment", first, there, "approve after"))
    facts["off_item_reply"] &= read.headed(under, "Reply", first, there, "A")
    facts["own_item_plain"] &= (read.plain(own, there, "B") and read.plain(own_item, there, "C")
        and read.unjudged(early))
    # Once the replacing ask closes, nothing on either item reaches an ask.
    overseer.resolve(there)
    late = [case.owner_reply("KEN-7", None, "late"), case.owner_reply("KEN-7", first_comment, "late A"),
            case.owner_reply("KEN-8", there_comment, "late B"), case.owner_reply("KEN-8", None, "late C")]
    read = overseer.owner_answers()
    facts["closed_replacer_reported"] &= all(read.reported(comment, issue)
                                             for comment, issue in zip(late, ("KEN-7", "KEN-7", "KEN-8", "KEN-8")))


def closed_question(case, facts):
    """A question closed on its own, then a new question on the same item."""
    overseer = case.checkout("asker")
    before_any = case.owner_reply("KEN-7", None, "context")
    first, _ = overseer.item_ask("KEN-7")
    first_comment = tracker_comment(overseer, first)
    top, under = case.owner_reply("KEN-7", None, "approve"), case.owner_reply("KEN-7", first_comment, "A")
    overseer.resolve(first)
    read = overseer.owner_answers()
    facts["before_first_question"] &= read.unjudged(before_any)
    facts["closed_question_reported"] &= read.reported(top, "KEN-7") and read.reported(under, "KEN-7")
    between = case.owner_reply("KEN-7", None, "after the close")
    before = case.body(first_comment)
    second, _ = overseer.item_ask("KEN-7", text="Approve half of it?\n")
    second_comment = tracker_comment(overseer, second)
    facts["reask_after_close"] &= (case.body(first_comment) == before and second_comment != first_comment
        and "replaces" not in overseer.pending()[second])
    after, own = case.owner_reply("KEN-7", None, "half"), case.owner_reply("KEN-7", second_comment, "B")
    old = case.owner_reply("KEN-7", first_comment, "A again")
    read = overseer.owner_answers()
    facts["closed_window_reported"] &= (read.reported(between, "KEN-7") and read.plain(after, second, "half")
        and read.plain(own, second, "B"))
    facts["closed_reply_after_later_question"] &= read.reported(old, "KEN-7")
    # Nothing reported earlier is reported again.
    facts["closed_question_reported"] &= all(read.counts.get(comment, 0) == 1 for comment in (top, under))
    facts["before_first_question"] &= read.unjudged(before_any)


def unmarked(case, facts):
    """The replaced question's comment is gone when the new ask replaces it."""
    overseer = case.checkout("asker")
    first, _ = overseer.item_ask("KEN-7")
    first_comment = tracker_comment(overseer, first)
    case.drop_comment(first_comment)
    second, stderr = overseer.item_ask("KEN-7", text="Approve half of it?\n")
    open_asks = overseer.pending()
    facts["unmarked_still_closes"] &= (
        "lane-mail: replace-unmarked id=%s issue=KEN-7 cause=comment-missing" % first in stderr.splitlines()
        and set(open_asks) == {second} and first in [row["id"] for row in open_asks[second]["replaces"]])


def refused_close(case, facts, read_between):
    """A replace step whose close is refused, leaving both asks open and
    posted on one item; READ_BETWEEN runs a pass before the earlier closes."""
    overseer = case.checkout("asker")
    first, _ = overseer.item_ask("KEN-7")
    first_comment = tracker_comment(overseer, first)
    before = case.body(first_comment)
    early = case.owner_reply("KEN-7", None, "approve")
    lane = overseer.root / "tmp/lane-mail/overseer/to-lane.jsonl"
    lane.touch()
    lane.chmod(0o444)
    second, stderr = overseer.item_ask("KEN-7", text="Approve half of it?\n")
    lane.chmod(0o644)
    second_comment = tracker_comment(overseer, second)
    under = case.owner_reply("KEN-7", first_comment, "A")
    if read_between:
        facts["refused_close_kept"] &= (
            "lane-mail: replace-unclosed id=%s cause=write-failed" % first in stderr.splitlines()
            and marked(case.body(first_comment), before, case.url(second_comment))
            and set(overseer.pending()) == {first, second}
            and first in [row["id"] for row in overseer.pending()[second]["replaces"]])
        after, own = case.owner_reply("KEN-7", None, "half"), case.owner_reply("KEN-7", second_comment, "B")
        read = overseer.owner_answers()
        facts["both_open"] &= (read.plain(after, second, "half") and read.plain(early, first, "approve")
            and read.plain(under, first, "A") and read.plain(own, second, "B"))
    else:
        overseer.resolve(first)
        read = overseer.owner_answers()
        facts["refused_close_later"] &= (read.headed(under, "Reply", first, second, "A")
            and read.headed(early, "Comment", first, second, "approve"))


def item_chain(case, facts):
    """Re-asks on one item: a pass before the replacement, an unposted third
    ask, the replacer's close and a later question replacing nothing posted."""
    overseer = case.checkout("asker")
    first, _ = overseer.item_ask("KEN-7")
    first_comment = tracker_comment(overseer, first)
    early = case.owner_reply("KEN-7", None, "approve")
    read = overseer.owner_answers()
    facts["read_before_replace"] &= read.plain(early, first, "approve")
    second, _ = overseer.item_ask("KEN-7", text="Approve half of it?\n")
    second_comment = tracker_comment(overseer, second)
    read = overseer.owner_answers()
    facts["read_before_replace"] &= read.plain(early, first, "approve") and not any(
        ask == second for ask, _ in read.delivered)
    case.failing(True)
    third, _ = overseer.item_ask("KEN-7", text="Approve a third of it?\n")
    case.failing(False)
    after = case.owner_reply("KEN-7", None, "half")
    under, own = case.owner_reply("KEN-7", first_comment, "A"), case.owner_reply("KEN-7", second_comment, "B")
    read = overseer.owner_answers()
    facts["unposted_third"] &= (set(overseer.pending()) == {second, third} and read.plain(after, second, "half")
        and read.headed(under, "Reply", first, second, "A") and read.plain(own, second, "B"))
    facts["open_question_plain"] &= read.plain(own, second, "B")
    overseer.resolve(second)
    late = [case.owner_reply("KEN-7", None, "late"), case.owner_reply("KEN-7", first_comment, "late A"),
            case.owner_reply("KEN-7", second_comment, "late B")]
    read = overseer.owner_answers()
    facts["closed_replacer_reported"] &= all(read.reported(comment, "KEN-7") for comment in late)
    fourth, _ = overseer.item_ask("KEN-7", text="Approve a quarter of it?\n")
    replies = [case.owner_reply("KEN-7", first_comment, "A later"), case.owner_reply("KEN-7", second_comment, "B later")]
    newest = case.owner_reply("KEN-7", None, "quarter")
    read = overseer.owner_answers()
    facts["closed_chain_reported"] &= (all(read.reported(comment, "KEN-7") for comment in replies)
        and read.plain(newest, fourth, "quarter")
        and [row["id"] for row in overseer.pending()[fourth].get("replaces", [])] == [third])


def chains(case, facts):
    """A chain of item re-asks on one item, a chat ask carrying a chain on,
    and a chain of chat asks."""
    overseer = case.checkout("asker")
    first, _ = overseer.item_ask("KEN-7")
    first_comment = tracker_comment(overseer, first)
    approve = case.owner_reply("KEN-7", None, "approve")
    second, _ = overseer.item_ask("KEN-7", text="Approve, hold or split?\n")
    hold = case.owner_reply("KEN-7", None, "hold")
    third, _ = overseer.item_ask("KEN-7", text="Approve half of it?\n")
    after = case.owner_reply("KEN-7", None, "approve half")
    under = case.owner_reply("KEN-7", first_comment, "A")
    # A chat ask replacing an item re-ask on KEN-8 takes both windows.
    asked, _ = overseer.item_ask("KEN-8")
    asked_comment = tracker_comment(overseer, asked)
    early = case.owner_reply("KEN-8", None, "first")
    reasked, _ = overseer.item_ask("KEN-8", text="Approve, hold or split?\n")
    middle = case.owner_reply("KEN-8", None, "second")
    chat, _ = overseer.ask("--replaces", reasked, text="Approve the whole change?\n")
    reply = case.owner_reply("KEN-8", asked_comment, "A")
    # Chat asks replacing one another carry the first question to the last.
    lone, _ = overseer.item_ask("KEN-9")
    lone_comment = tracker_comment(overseer, lone)
    hop, _ = overseer.ask("--replaces", lone, text="Approve the first hop?\n")
    last, _ = overseer.ask("--replaces", hop, text="Approve the last hop?\n")
    carried = case.owner_reply("KEN-9", lone_comment, "C")
    read = overseer.owner_answers()
    facts["item_chain"] &= (read.headed(approve, "Comment", first, third, "approve")
        and read.headed(hold, "Comment", second, third, "hold") and read.plain(after, third, "approve half")
        and read.headed(under, "Reply", first, third, "A"))
    facts["mixed_chain"] &= (read.headed(early, "Comment", asked, chat, "first")
        and read.headed(middle, "Comment", reasked, chat, "second") and read.headed(reply, "Reply", asked, chat, "A"))
    facts["uncommented_replaced"] &= ({"id": lone, "issue": "KEN-9", "tracker_comment": lone_comment}
        in overseer.pending()[last].get("replaces", []) and read.headed(carried, "Reply", lone, last, "C"))


def off_item(case, facts):
    """A chat ask replaces the question on I; later questions on I open and close."""
    overseer = case.checkout("asker")
    first, _ = overseer.item_ask("KEN-7")
    first_comment = tracker_comment(overseer, first)
    before = case.body(first_comment)
    early = case.owner_reply("KEN-7", None, "approve")
    thread = case.owner_reply("KEN-7", early, "and the docs")
    chat, _ = overseer.ask("--replaces", first, text="Approve the whole change?\n")
    facts["chat_replaces"] &= (marked(case.body(first_comment), before, None)
        and set(overseer.pending()) == {chat}
        and overseer.pending()[chat]["replaces"] == [{"id": first, "issue": "KEN-7", "tracker_comment": first_comment}])
    after = case.owner_reply("KEN-7", None, "approve after")
    under = case.owner_reply("KEN-7", first_comment, "A")
    read = overseer.owner_answers()
    facts["off_item_window"] &= (read.headed(early, "Comment", first, chat, "approve")
        and read.headed(after, "Comment", first, chat, "approve after"))
    facts["off_item_reply"] &= read.headed(under, "Reply", first, chat, "A")
    facts["reply_under_comment"] &= read.headed(thread, "Comment", first, chat, "and the docs")
    # A later question on I replaces nothing and bounds the replaced window.
    unread = case.owner_reply("KEN-7", None, "approve unread")
    third, _ = overseer.item_ask("KEN-7", text="Ship the docs too?\n")
    third_comment = tracker_comment(overseer, third)
    ship, own = case.owner_reply("KEN-7", None, "ship"), case.owner_reply("KEN-7", third_comment, "B")
    again = case.owner_reply("KEN-7", first_comment, "A again")
    read = overseer.owner_answers()
    facts["third_bounds_window"] &= ("replaces" not in overseer.pending()[third]
        and read.headed(unread, "Comment", first, chat, "approve unread") and read.plain(ship, third, "ship")
        and read.plain(own, third, "B") and read.headed(again, "Reply", first, chat, "A again"))
    # Once that question closes, comments after it reach no ask.
    pending = case.owner_reply("KEN-7", None, "thanks")
    overseer.resolve(third)
    closed = case.owner_reply("KEN-7", None, "also rename the file")
    late = case.owner_reply("KEN-7", third_comment, "B later")
    read = overseer.owner_answers()
    facts["closed_later_question"] &= (read.reported(pending, "KEN-7") and read.reported(closed, "KEN-7")
        and read.reported(late, "KEN-7"))
    gap = case.owner_reply("KEN-7", None, "between")
    fourth, _ = overseer.item_ask("KEN-7", text="Ship the tests too?\n")
    newest = case.owner_reply("KEN-7", None, "ship tests")
    read = overseer.owner_answers()
    facts["closed_between"] &= read.reported(gap, "KEN-7") and read.plain(newest, fourth, "ship tests")


def compacted(case, facts):
    """Row 27's world after retention while the chat ask replacing the first
    question stays open, then once every ask on the item has closed."""
    overseer = case.checkout("asker")
    first, _ = overseer.item_ask("KEN-7")
    chat, _ = overseer.ask("--replaces", first, text="Approve the whole change?\n")
    third, _ = overseer.item_ask("KEN-7", text="Ship the docs too?\n")
    third_comment = tracker_comment(overseer, third)
    top, under = case.owner_reply("KEN-7", None, "ship"), case.owner_reply("KEN-7", third_comment, "B")
    overseer.owner_answers()
    overseer.resolve(third)
    closed = case.owner_reply("KEN-7", None, "thanks")
    held = overseer.owner_answers().records((top, under, closed))
    overseer.compact()
    late = case.owner_reply("KEN-7", None, "also rename the file")
    read = overseer.owner_answers()
    # The same records, not ones a later pass wrote again.
    facts["compacted_kept"] &= (chat in overseer.pending() and None not in held.values()
        and read.records(held) == held and read.plain(top, third, "ship") and read.plain(under, third, "B")
        and read.reported(closed, "KEN-7") and read.reported(late, "KEN-7"))
    # With nothing open on the item, its records leave together, and a later
    # question judges only what follows it.
    overseer.resolve(chat)
    overseer.compact()
    fourth, _ = overseer.item_ask("KEN-7", text="Ship the tests too?\n")
    newest = case.owner_reply("KEN-7", None, "ship tests")
    read = overseer.owner_answers()
    facts["compacted_reask"] &= (not {first, third} & {row.get("id") for row in overseer.rows("to-overseer.jsonl")}
        and read.plain(newest, fourth, "ship tests")
        and all(read.unjudged(comment) for comment in (top, under, closed, late)))


def missing_item(case, facts):
    """An item that held a question of this mailbox is gone from Linear."""
    overseer = case.checkout("asker")
    gone, _ = overseer.item_ask("KEN-8")
    overseer.resolve(gone)
    first, _ = overseer.item_ask("KEN-7")
    case.delete_item("KEN-8")
    answer = case.owner_reply("KEN-7", None, "approve")
    read = overseer.owner_answers()
    notices = read.result.stderr.splitlines()
    facts["missing_item"] &= (read.plain(answer, first, "approve")
        and notices.count("owner-answers: item-missing issue=KEN-8") == 1)
    case.delete_item("KEN-7")
    read = overseer.owner_answers()
    facts["missing_item"] &= read.ok() and {"owner-answers: item-missing issue=KEN-7",
                                            "owner-answers: item-missing issue=KEN-8"} <= set(read.result.stderr.splitlines())


def report_retry(case, facts):
    """A report the mailbox refuses, here for no registered overseer, holds
    neither the pass's read nor the comment: the next pass sends it."""
    overseer = case.checkout("asker")
    runtime = overseer.root / ".agents/skills/agent-runtime/scripts/agent-runtime"
    script = runtime.read_text()
    runtime.unlink()
    first, _ = overseer.item_ask("KEN-7")
    overseer.resolve(first)
    late = case.owner_reply("KEN-7", None, "late")
    read = overseer.owner_answers()
    unsent = [line.split() for line in read.result.stderr.splitlines()
              if line.startswith("owner-answers: report-unsent ")]
    facts["report_unsent_retried"] &= (read.ok() and late not in read.reports
        and [fields[2:4] for fields in unsent] == [["issue=KEN-7", "comment=" + late]]
        and unsent[0][4] != "cause=")
    runtime.write_text(script)
    runtime.chmod(0o755)
    facts["report_unsent_retried"] &= overseer.owner_answers().reported(late, "KEN-7")


def retained_refs(case, facts):
    """Asks an earlier ask path kept naming their items by a UUID and by an
    identifier in lower case, beside an ask naming its item by identifier."""
    overseer = case.checkout("asker")
    uuid = "4029001b-0b88-4e0d-b5a8-3af25993f856"
    by_uuid, _ = overseer.item_ask("KEN-8")
    lower, _ = overseer.item_ask("KEN-9")
    first, _ = overseer.item_ask("KEN-7")
    overseer.retain_issue(by_uuid, uuid)
    overseer.retain_issue(lower, "ken-9")
    answer = case.owner_reply("KEN-7", None, "approve")
    reply = case.owner_reply("KEN-9", tracker_comment(overseer, lower), "B")
    read = overseer.owner_answers()
    facts["retained_ref_skipped"] &= (read.plain(answer, first, "approve") and read.plain(reply, lower, "B")
        and read.result.stderr.splitlines().count(
            "owner-answers: item-skipped issue=%s cause=issue-invalid" % uuid) == 1)


def account_change(case, facts):
    """A re-ask while no acting identity reads, then one after the credential
    changed account."""
    overseer = case.checkout("asker")
    first, _ = overseer.item_ask("KEN-7")
    first_comment = tracker_comment(overseer, first)
    before = case.body(first_comment)
    case.act_as(None)
    second, unread = overseer.item_ask("KEN-7", text="Approve half of it?\n")
    second_comment = tracker_comment(overseer, second)
    second_before = case.body(second_comment)
    case.act_as("agent-2")
    third, foreign = overseer.item_ask("KEN-7", text="Approve a third of it?\n")
    facts["foreign_comment_kept"] &= (
        "lane-mail: replace-unmarked id=%s issue=KEN-7 cause=actor-unread" % first in unread.splitlines()
        and "lane-mail: replace-unmarked id=%s issue=KEN-7 cause=comment-foreign" % second in foreign.splitlines()
        and case.body(first_comment) == before and case.body(second_comment) == second_before
        and set(overseer.pending()) == {third})


def no_team(case, facts):
    """A re-ask in a home whose Linear package has no LINEAR_TEAM."""
    overseer = case.checkout("asker")
    first, _ = overseer.item_ask("KEN-7")
    first_comment = tracker_comment(overseer, first)
    before, lines, count = case.body(first_comment), overseer.lines(), len(case.comments())
    case.without_team()
    refused = overseer.try_ask("--issue", "KEN-7", "--do", "Approve change", text="Approve half of it?\n")
    facts["no_team_refused"] &= (refused.returncode == 2
        and refused.stderr.split()[1:3] == ["replace-unconfigured", "cause=team-unset"]
        and overseer.lines() == lines and len(case.comments()) == count
        and case.body(first_comment) == before and set(overseer.pending()) == {first})
    # An ask that replaces no question comment still posts.
    other, _ = overseer.item_ask("KEN-8")
    facts["no_team_refused"] &= set(overseer.pending()) == {first, other}


ROWS = ("same_item_replaces", "chat_replaces", "other_item_replaces", "other_item_kept", "uncommented_replaced",
        "unposted_replaces_nothing", "posted_after_unposted", "refused_appends_nothing", "reask_after_close",
        "unmarked_still_closes", "refused_close_kept", "read_before_replace", "replaced_window", "replaced_reply",
        "open_question_plain", "closed_replacer_reported", "item_chain", "unposted_third", "mixed_chain",
        "closed_question_reported", "closed_window_reported", "closed_reply_after_later_question",
        "closed_chain_reported", "off_item_window", "off_item_reply", "own_item_plain", "third_bounds_window",
        "closed_later_question", "closed_between", "both_open", "refused_close_later", "before_first_question",
        "reply_under_comment", "report_unsent_retried", "compacted_kept", "compacted_reask", "missing_item",
        "retained_ref_skipped", "foreign_comment_kept", "no_team_refused")


def run(source, scratch, bash):
    """Each scenario keeps its own tracker, checkout and facts, so they run
    side by side; a row holds only where every scenario that judges it holds."""
    scenarios = ((replace, ("KEN-7", "KEN-8")), (unposted, ("KEN-11", "KEN-12", "KEN-13")),
                 (after_unposted, ("KEN-7",)), (other_item, ("KEN-7", "KEN-8")),
                 (closed_question, ("KEN-7",)), (unmarked, ("KEN-7",)),
                 (lambda case, facts: refused_close(case, facts, True), ("KEN-7",)),
                 (lambda case, facts: refused_close(case, facts, False), ("KEN-7",)),
                 (item_chain, ("KEN-7",)), (chains, ("KEN-7", "KEN-8", "KEN-9")),
                 (off_item, ("KEN-7",)), (report_retry, ("KEN-7",)), (compacted, ("KEN-7",)),
                 (missing_item, ("KEN-7", "KEN-8")), (retained_refs, ("KEN-7", "KEN-8", "KEN-9")),
                 (account_change, ("KEN-7",)), (no_team, ("KEN-7", "KEN-8")))

    def judged(scenario, issues):
        facts = dict.fromkeys(ROWS, True)
        scenario(Case(scratch, source, bash, issues), facts)
        return facts

    with ThreadPoolExecutor(max_workers=len(scenarios)) as pool:
        results = [future.result() for future in [pool.submit(judged, *row) for row in scenarios]]
    return {row: all(facts[row] for facts in results) for row in ROWS}


if __name__ == "__main__":
    print(json.dumps(run(Path(sys.argv[1]), sys.argv[2], sys.argv[3])))
