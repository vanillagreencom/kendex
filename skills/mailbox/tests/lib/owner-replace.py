"""Observe owner ask replacement against a stateful tracker.

The shell suites own the assertions. This driver returns observations from
real mailbox commands and the stub tracker's state, one group per suite:
`ask` for the ask that replaces, `answers` for owner-answers, `compact` for
retention. The stub keeps one item store and one comment store per case.
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


# Linear as the linear package answers the mailbox, per command: `issues
# bulk-get` reads an identifier in any case, a lower-case UUID and a moved
# issue's former identifier as the one issue, refuses the whole read for any
# other ref, and names in `missing` a ref it holds no issue for, its
# identifiers in upper case (linear_issue_refs_read); `comments bulk-get`
# answers {id: {url}} with no entry for an absent comment; `comments
# bulk-list` takes identifiers alone, refusing the whole read with no
# `missing` for any other ref, a UUID included (linear_issue_refs
# identifiers), keys each identifier's comments and names a missing issue in
# `missing` (comments --help); `comments update` exits 1 with no LINEAR_TEAM
# (its configured-team gate); auth-check reports writes_enabled and the actor.
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
moved = json.loads((state / "moved.json").read_text())
with (state / "calls").open("a") as log:
    log.write(" ".join(args) + "\n")
actor = (state / "actor").read_text() if (state / "actor").exists() else "agent"
team = not (state / "no-team").exists()
users = [{"id": "owner", "name": "Owner Person", "email": "owner@example.test", "display_name": "owner.person"}]
IDENTIFIER = re.compile(r"[A-Za-z0-9]+-[0-9]+")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def option(flag):
    return args[args.index(flag) + 1] if flag in args else None


def positional():
    return [arg for arg in args[2:] if not arg.startswith("--")]


def safe(row):
    return {key: row[key] for key in ("id", "body", "user_id", "user_email", "parent_id", "url", "created_at")}


def key_of(ref):
    """The item a ref names, or None where Linear holds no such issue."""
    if UUID.fullmatch(ref):
        return next((key for key, item in items.items() if item["uuid"] == ref), None)
    ref = ref.upper()
    return ref if ref in items else moved.get(ref)


def save():
    (state / "items.json").write_text(json.dumps(items))
    (state / "comments.json").write_text(json.dumps(comments))


def refuse_missing(missing):
    print(json.dumps({"error": "Entity not found: Issue"}), file=sys.stderr)
    print(json.dumps({"error": "Issues not read: " + ", ".join(missing), "missing": missing}), file=sys.stderr)
    sys.exit(1)


if args[:2] == ["users", "list"]:
    print(json.dumps(users))
elif args[:1] == ["auth-check"]:
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
    item = items[key_of(json.loads(option("--variables"))["id"])]
    print(json.dumps({"issue": {"description": item["description"],
        "assignee": {"name": item["assignee"]} if item["assignee"] else None,
        "labels": {"pageInfo": {"hasNextPage": False}, "nodes": [{"name": l} for l in item["labels"]]}}}))
elif args[:2] == ["issues", "update"]:
    item = items[key_of(args[2])]
    if "--assignee" in args:
        item["assignee"] = next(u["name"] for u in users if u["id"] == option("--assignee"))
    if "--labels" in args:
        item["labels"] = option("--labels").split(",")
    if "--description" in args:
        item["description"] = option("--description")
    save()
    print("{}")
elif args[:2] == ["issues", "list"]:
    print(json.dumps([{"id": key, "uuid": item["uuid"], "assignee": item["assignee"], "description": item["description"]}
                      for key, item in items.items()
                      if item["assignee"] == "Owner Person" and option("--label") in item["labels"]]))
elif args[:2] == ["issues", "bulk-get"]:
    refs = positional()
    if not all(IDENTIFIER.fullmatch(ref) or UUID.fullmatch(ref) for ref in refs):
        print(json.dumps({"error": "Not an issue identifier (TEAM-123) or UUID"}), file=sys.stderr)
        sys.exit(1)
    missing = [ref if UUID.fullmatch(ref) else ref.upper() for ref in refs if key_of(ref) is None]
    if missing:
        refuse_missing(missing)
    keys = list(dict.fromkeys(key_of(ref) for ref in refs))
    print(json.dumps([{"id": key, "uuid": items[key]["uuid"]} for key in keys]))
elif args[:2] == ["comments", "create"]:
    if (state / "fail-create").exists():
        print("tracker: refused=create", file=sys.stderr)
        sys.exit(1)
    number = len(comments) + 1
    key = key_of(args[2])
    comments.append({"id": "c%d" % number, "issue": key, "body": Path(option("--body-file")).read_text(),
                     "user_id": actor, "user_email": actor + "@example.test", "parent_id": option("--parent"),
                     "url": "https://linear.app/workspace/issue/%s#comment-c%d" % (key, number),
                     "created_at": "2026-01-01T00:%02d:%02dZ" % divmod(number, 60)})
    save()
    print(json.dumps({"success": True, "data": {"success": True, "comment": {"id": "c%d" % number}}}))
elif args[:2] == ["comments", "update"]:
    if not team:
        print(json.dumps({"error": "No Linear team configured for this project - refusing to write."}), file=sys.stderr)
        sys.exit(1)
    if (state / "fail-update").exists():
        print(json.dumps({"error": "API request failed"}), file=sys.stderr)
        sys.exit(1)
    row = next(row for row in comments if row["id"] == args[2])
    row["body"] = Path(option("--body-file")).read_text()
    save()
    print(json.dumps({"success": True, "identifier": None, "url": None, "data": {"success": True}}))
elif args[:2] == ["comments", "react"]:
    print(json.dumps({"success": True, "data": {"reaction": {"emoji": option("--emoji")}}}))
elif args[:2] == ["comments", "bulk-get"]:
    print(json.dumps({row["id"]: {"url": row["url"]} for row in comments
                      if row["id"] in positional() and row["issue"] != "deleted"}))
elif args[:2] == ["comments", "list"]:
    key = key_of(args[2])
    print(json.dumps([safe(row) for row in comments if row["issue"] == key]))
elif args[:2] == ["comments", "bulk-list"]:
    if not all(IDENTIFIER.fullmatch(ref) for ref in positional()):
        print(json.dumps({"error": "Not an issue identifier (TEAM-123)"}), file=sys.stderr)
        sys.exit(1)
    wanted = [ref.upper() for ref in positional()]
    missing = [key for key in wanted if key not in items or key in json.loads((state / "vanished.json").read_text())]
    if missing:
        refuse_missing(missing)
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
        self.uuids = {issue: "%08x-0000-4000-8000-%012x" % (number, number)
                      for number, issue in enumerate(issues, 1)}
        self.write("items", {issue: {"description": "Item body.\n", "labels": ["skills"], "assignee": "",
                                     "uuid": self.uuids[issue]} for issue in issues})
        self.write("comments", [])
        self.write("moved", {})
        self.write("vanished", [])

    def write(self, name, value):
        (self.state / (name + ".json")).write_text(json.dumps(value))

    def read(self, name):
        return json.loads((self.state / (name + ".json")).read_text())

    def checkout(self):
        root = self.dir / "asker"
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
        return self.read("comments")

    def body(self, comment):
        return next(row["body"] for row in self.comments() if row["id"] == comment)

    def url(self, comment):
        return next(row["url"] for row in self.comments() if row["id"] == comment)

    def reply(self, issue, parent, body, author="owner"):
        """A comment on ISSUE under PARENT, or at the top level where PARENT is None."""
        comments = self.comments()
        number = len(comments) + 1
        comments.append({"id": "c%d" % number, "issue": issue, "body": body, "user_id": author,
                         "user_email": author + "@example.test", "parent_id": parent, "url": "",
                         "created_at": "2026-01-01T00:%02d:%02dZ" % divmod(number, 60)})
        self.write("comments", comments)
        return "c%d" % number

    def drop_comment(self, comment):
        """Deleted from its item; the row keeps its place so no later comment reuses its id."""
        comments = self.comments()
        next(row for row in comments if row["id"] == comment)["issue"] = "deleted"
        self.write("comments", comments)

    def move(self, former, issue):
        """FORMER now names ISSUE, as Linear answers a moved issue's earlier identifier."""
        self.write("moved", dict(self.read("moved"), **{former: issue}))

    def vanish(self, issue):
        """Listed still, and gone by the time its comments are read."""
        self.write("vanished", self.read("vanished") + [issue])

    def clear(self, issue):
        """ISSUE as the watch leaves an item whose last open ask on it closed:
        the owner label dropped and the assignee cleared (clear_owner_item)."""
        items = self.read("items")
        items[issue]["assignee"] = ""
        items[issue]["labels"] = [label for label in items[issue]["labels"] if label != "owner-gated"]
        self.write("items", items)

    def flag(self, name, on):
        path = self.state / name
        path.touch() if on else path.unlink(missing_ok=True)

    def act_as(self, actor):
        """The credential acts as ACTOR from now on; None makes auth-check
        name no actor."""
        self.flag("fail-auth", actor is None)
        if actor is not None:
            (self.state / "actor").write_text(actor)

    def calls(self):
        path = self.state / "calls"
        return path.read_text().splitlines() if path.exists() else []


class Overseer:
    def __init__(self, root, env, mail):
        self.root, self.env, self.mail = root, env, mail

    def run(self, *args, env=None):
        return subprocess.run([*self.mail, *args], cwd=self.root, env=env or self.env,
                              capture_output=True, text=True, timeout=60)

    def try_ask(self, *extra, text="Approve the change?\n"):
        question = self.root / "question"
        question.write_text(text)
        return self.run("ask", "--item", "overseer", "--to", "owner", "--options", "approve,hold",
                        "--recommend", "approve", "--effect", "none", "--wait", "60",
                        "--file", str(question), *extra)

    def ask(self, *extra, text="Approve the change?\n"):
        """The new ask's id and stderr; a refused ask raises."""
        result = self.try_ask(*extra, text=text)
        if result.returncode:
            raise RuntimeError("ask exit=%d: %s" % (result.returncode, result.stderr))
        return result.stdout.strip().split("=", 1)[1], result.stderr

    def item_ask(self, issue, *extra, text="Approve the change?\n"):
        return self.ask("--issue", issue, "--do", "Approve change", *extra, text=text)

    def resolve(self, ask):
        result = self.run("resolve", "--item", "overseer", "--id", ask)
        if result.returncode:
            raise RuntimeError("resolve exit=%d: %s" % (result.returncode, result.stderr))

    def close_with(self, ask, text):
        """resolve --text: an answer given outside the mailbox closes ASK."""
        answer = self.root / "answer"
        answer.write_text(text)
        return self.run("resolve", "--item", "overseer", "--id", ask, "--text", str(answer))

    def rows(self, box):
        path = self.root / "tmp/lane-mail/overseer" / box
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def pending(self):
        result = self.run("pending", "--item", "overseer", "--to", "owner")
        return {row["id"]: row for row in map(json.loads, result.stdout.splitlines())}

    def asks(self):
        """Every owner ask, open or closed, as the mailbox's reads fold it."""
        result = self.run("events", "--item", "overseer")
        return {row["id"]: row for row in map(json.loads, result.stdout.splitlines())
                if row.get("box") == "to-overseer" and row.get("kind") == "ask"}

    def lines(self):
        return len(self.rows("to-overseer.jsonl")), len(self.rows("to-lane.jsonl"))

    def closes(self):
        return {row["re"]: row for row in self.rows("to-lane.jsonl") if row["kind"] == "resolution"}

    def comment(self, ask):
        return next(row["tracker_comment"] for row in self.rows("to-overseer.jsonl")
                    if row.get("kind") == "tracker-posted" and row.get("re") == ask)

    def legacy(self, ask, ref):
        """ASK and its tracker record name their item by REF and carry no
        identity, as an ask recorded before asks read one keeps it."""
        path = self.root / "tmp/lane-mail/overseer/to-overseer.jsonl"
        rows = self.rows("to-overseer.jsonl")
        changed = [row for row in rows if ask in (row.get("id"), row.get("re")) and "issue" in row]
        assert len(changed) == 2, changed
        for row in changed:
            row["issue"] = ref
            row.pop("identity", None)
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))

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
        result = self.run("owner-answers", "--item", "overseer")
        return Pass(result, self.rows("to-lane.jsonl"))


class Pass:
    """One owner-answers run, and every tracker comment the mailbox holds as
    an answer, by the comment id its delivery id names."""

    def __init__(self, result, rows):
        self.result = result
        self.answers = {}
        self.counts = {}
        for row in rows:
            if row.get("delivery_id", "").startswith("linear:"):
                comment = row["delivery_id"].split(":", 1)[1]
                self.answers[comment] = row
                self.counts[comment] = self.counts.get(comment, 0) + 1
        self.data = [row for row in rows if row.get("kind") == "data"]

    def ok(self):
        return self.result.returncode == 0 and self.result.stdout.splitlines()[-1:] == ["owner-answers: read=read"]

    def plain(self, comment, ask, body):
        """Delivered once to ASK with no opening line."""
        answer = self.answers.get(comment, {})
        return self.ok() and answer.get("re") == ask and answer.get("text") == body and self.counts[comment] == 1

    def headed(self, comment, replaced, open_ask, body):
        """Delivered once to OPEN_ASK, its first line naming the replaced ask
        and the open one, then the comment."""
        answer = self.answers.get(comment, {})
        lines = answer.get("text", "").splitlines()
        return (self.ok() and answer.get("re") == open_ask and len(lines) == 3 and lines[1:] == ["", body]
                and set(re.findall(r"\d+-\d+-\d+", lines[0])) == {replaced, open_ask} and self.counts[comment] == 1)

    def left_out(self, comment):
        """Delivered to no ask, and nothing told about it."""
        return self.ok() and comment not in self.answers and not self.data


def marked(body, original, url):
    """The replaced question opens with a link to the newer one, or with no
    link where URL is None, and ends with its own lines struck."""
    lines, original = body.splitlines(), original.splitlines()
    struck = [("~~" + line + "~~") if line.strip() else line for line in original]
    linked = ("](" not in lines[0]) if url is None else ("(" + url + ")" in lines[0])
    return lines[0] != original[0] and linked and lines[-len(struck):] == struck


# --- ask --------------------------------------------------------------------


def same_item(case, facts):
    """T1: a re-ask on the item strikes the earlier question and closes its ask."""
    overseer = case.checkout()
    first, _ = overseer.item_ask("KEN-7")
    other, _ = overseer.item_ask("KEN-8")
    first_comment = overseer.comment(first)
    before = case.body(first_comment)
    second, stderr = overseer.item_ask("KEN-7", text="Approve half of it?\n")
    second_comment = overseer.comment(second)
    overseer.resolve(other)
    closes, open_asks = overseer.closes(), overseer.pending()
    shape = lambda row: {key: value for key, value in row.items() if key not in ("id", "at", "re")}
    item = case.read("items")["KEN-7"]
    facts["same_item_replaces"] = (
        marked(case.body(first_comment), before, case.url(second_comment)) and set(open_asks) == {second}
        and set(closes) == {first, other} and shape(closes[first]) == shape(closes[other])
        and "lane-mail: resolved id=%s by=explicit answer=%s" % (first, closes[first]["id"]) in stderr.splitlines()
        and "lane-mail: replacement id=%s outcome=in-force" % second in stderr.splitlines()
        and open_asks[second]["replacement"] == "in-force"
        and open_asks[second]["identity"] == {"identifier": "KEN-7", "uuid": case.uuids["KEN-7"]}
        and open_asks[second]["replaces"] == [{"id": first, "tracker_comment": first_comment,
                                               "identity": {"identifier": "KEN-7", "uuid": case.uuids["KEN-7"]}}]
        and item["assignee"] == "Owner Person" and "owner-gated" in item["labels"])


def spellings(case, facts):
    """T2: an earlier ask kept under another spelling of the item is the same item."""
    overseer = case.checkout()
    replaced = []
    for ref in ("ken-7", case.uuids["KEN-7"], "OLD-3"):
        earlier, _ = overseer.item_ask("KEN-7")
        overseer.legacy(earlier, ref)
        if ref == "OLD-3":
            case.move("OLD-3", "KEN-7")
        later, _ = overseer.item_ask("KEN-7", text="Approve it as %s?\n" % ref)
        replaced.append(earlier not in overseer.pending() and earlier in overseer.closes()
                        and [row["id"] for row in overseer.pending()[later]["replaces"]] == [earlier])
        overseer.resolve(later)
    facts["spellings_replaced"] = all(replaced) and len(replaced) == 3


def refused_marks(case, facts):
    """T3: a mark known to be refused refuses the ask before it appends or posts."""
    overseer = case.checkout()
    first, _ = overseer.item_ask("KEN-7")
    results = []
    for setup, cause in ((lambda: case.act_as(None), "actor-unread"), (lambda: case.act_as("agent-2"), "comment-foreign")):
        setup()
        lines, count = overseer.lines(), len(case.comments())
        refused = overseer.try_ask("--issue", "KEN-7", "--do", "Approve change", text="Approve half of it?\n")
        results.append(refused.returncode == 2
                       and refused.stderr.split()[1:4] == ["replace-unmarkable", "cause=" + cause, "id=" + first]
                       and overseer.lines() == lines and len(case.comments()) == count
                       and set(overseer.pending()) == {first})
    facts["refused_before_post"] = all(results)


def incomplete(case, facts):
    """T4: a mark that fails after the post leaves the earlier ask open until a
    pass retries it, whether the replacing ask is still open (KEN-7) or was
    closed before the retry (KEN-8)."""
    overseer = case.checkout()
    issues = ("KEN-7", "KEN-8")
    first = {issue: overseer.item_ask(issue)[0] for issue in issues}
    comment = {issue: overseer.comment(first[issue]) for issue in issues}
    before = {issue: case.body(comment[issue]) for issue in issues}
    unmarked = lambda: all(case.body(comment[issue]) == before[issue] for issue in issues)
    case.flag("fail-update", True)
    second, held = {}, True
    for issue in issues:
        second[issue], stderr = overseer.item_ask(issue, text="Approve half of it?\n")
        held &= ("lane-mail: replace-unclosed id=%s cause=comment-update" % first[issue] in stderr.splitlines()
                 and overseer.pending()[second[issue]]["replacement"] == "incomplete")
    overseer.resolve(second["KEN-8"])
    standing = {first["KEN-7"], second["KEN-7"], first["KEN-8"]}
    held &= set(overseer.pending()) == standing and unmarked()
    # A pass while the edit still fails leaves both as they were.
    overseer.owner_answers()
    held &= set(overseer.pending()) == standing and unmarked()
    case.flag("fail-update", False)
    calls = len(case.calls())
    read = overseer.owner_answers()
    retried = case.calls()[calls:]
    asks = overseer.asks()
    facts["incomplete_retried"] = (
        held and read.ok() and set(overseer.pending()) == {second["KEN-7"]}
        and {first[issue] for issue in issues} <= set(overseer.closes())
        and all(asks[second[issue]]["replacement"] == "in-force" for issue in issues)
        and all(marked(case.body(comment[issue]), before[issue], case.url(overseer.comment(second[issue])))
                for issue in issues)
        and sorted("comments update %s" % comment[issue] for issue in issues)
        == sorted(" ".join(c.split()[:3]) for c in retried if c.startswith("comments update ")))


def absent(case, facts):
    """T5: a question comment Linear holds no longer closes its ask with no edit."""
    overseer = case.checkout()
    first, _ = overseer.item_ask("KEN-7")
    case.drop_comment(overseer.comment(first))
    second, stderr = overseer.item_ask("KEN-7", text="Approve half of it?\n")
    facts["absent_closes"] = (set(overseer.pending()) == {second} and first in overseer.closes()
                              and overseer.pending()[second]["replacement"] == "in-force"
                              and not any(call.startswith("comments update ") for call in case.calls()))


def no_team(case, facts):
    """T6: a re-ask in a home with no LINEAR_TEAM is refused whole, a first ask still posts."""
    overseer = case.checkout()
    first, _ = overseer.item_ask("KEN-7")
    first_comment = overseer.comment(first)
    before, lines, count = case.body(first_comment), overseer.lines(), len(case.comments())
    case.flag("no-team", True)
    refused = overseer.try_ask("--issue", "KEN-7", "--do", "Approve change", text="Approve half of it?\n")
    untouched = overseer.lines() == lines and len(case.comments()) == count
    other, _ = overseer.item_ask("KEN-8")
    facts["no_team_refused"] = (refused.returncode == 2
        and refused.stderr.split()[1:3] == ["replace-unconfigured", "cause=team-unset"]
        and untouched and case.body(first_comment) == before and set(overseer.pending()) == {first, other}
        and overseer.pending()[other]["tracker_posted"] is True)


def explicit(case, facts):
    """T7: --replaces closes a chat-only ask, an automatic ask leaves another
    item alone, and --replaces across items closes its target."""
    overseer = case.checkout()
    chat, _ = overseer.ask()
    first, _ = overseer.item_ask("KEN-7")
    first_comment = overseer.comment(first)
    before = case.body(first_comment)
    on_other, _ = overseer.item_ask("KEN-8", "--replaces", chat)
    kept = (first in overseer.pending() and case.body(first_comment) == before and chat in overseer.closes()
            and overseer.pending()[on_other]["replaces"] == [{"id": chat}])
    across, _ = overseer.item_ask("KEN-9", "--replaces", first, text="Approve it on KEN-9?\n")
    facts["explicit_replaces"] = (
        kept and set(overseer.pending()) == {on_other, across} and first in overseer.closes()
        and marked(case.body(first_comment), before, case.url(overseer.comment(across))))


# --- answers ----------------------------------------------------------------


# T8: a reply under the first question of a replacement chain reaches the one
# open ask, opening with the line naming both. Each row: its fact, the asks in
# order as (item or None for a chat ask, index of the ask it names with
# --replaces or None), and the items the watch clears once their last open ask
# closed. An ask with an item replaces the open ask on that item by itself.
REPLACED = (
    ("replaced_reply", (("KEN-7", None), ("KEN-7", None)), ()),
    ("chat_replaced", (("KEN-7", None), (None, 0)), ("KEN-7",)),
    ("chain_first_replaced", (("KEN-8", None), ("KEN-7", 0), ("KEN-7", None)), ("KEN-8",)),
)


def replaced_route(fact, steps, cleared):
    def scenario(case, facts):
        overseer = case.checkout()
        asks = []
        for number, (issue, replaces) in enumerate(steps):
            extra = ("--replaces", asks[replaces]) if replaces is not None else ()
            text = "Approve step %d?\n" % number
            asks.append((overseer.item_ask(issue, *extra, text=text) if issue else overseer.ask(*extra, text=text))[0])
        for issue in cleared:
            case.clear(issue)
        under = case.reply(steps[0][0], overseer.comment(asks[0]), "A")
        read = overseer.owner_answers()
        facts[fact] = set(overseer.pending()) == {asks[-1]} and read.headed(under, asks[0], asks[-1], "A")
    scenario.__name__ = fact
    return scenario


def threads(case, facts):
    """T9: a reply under another mailbox's question is not delivered; a nested
    chain that ends at a question of this mailbox is."""
    overseer = case.checkout()
    first, _ = overseer.item_ask("KEN-7")
    question = case.reply("KEN-7", None, "Another overseer's question.", author="agent")
    foreign = case.reply("KEN-7", question, "yes")
    top = case.reply("KEN-7", overseer.comment(first), "half")
    nested = case.reply("KEN-7", top, "and the docs")
    read = overseer.owner_answers()
    facts["thread_chain"] = (read.ok() and foreign not in read.answers
                             and read.plain(top, first, "half") and read.plain(nested, first, "and the docs"))


def flat(case, facts):
    """T10: a top-level comment after the current question reaches its ask,
    after a re-ask the newest question's ask with no opening line; one with no
    open question before it is left out."""
    overseer = case.checkout()
    early = case.reply("KEN-7", None, "context")
    first, _ = overseer.item_ask("KEN-7")
    after = case.reply("KEN-7", None, "approve")
    read = overseer.owner_answers()
    second, _ = overseer.item_ask("KEN-7", text="Approve half of it?\n")
    later = case.reply("KEN-7", None, "approve half")
    again = overseer.owner_answers()
    facts["flat_comment"] = (read.plain(after, first, "approve") and read.left_out(early)
                             and again.plain(later, second, "approve half"))


def missing_item(case, facts):
    """T13: an item Linear holds no issue for is named, and the other items are read."""
    overseer = case.checkout()
    gone, _ = overseer.item_ask("KEN-8")
    first, _ = overseer.item_ask("KEN-7")
    case.vanish("KEN-8")
    answer = case.reply("KEN-7", None, "approve")
    read = overseer.owner_answers()
    facts["missing_item"] = (read.plain(answer, first, "approve")
                             and read.result.stderr.splitlines() == ["owner-answers: item-missing issue=KEN-8"])


def uuid_ref(case, facts):
    """T14: an ask made by its item's UUID is read off the owner list by the
    identifier its identity recorded; an older ask known by a UUID alone is
    named and left unread, and the other items are read."""
    overseer = case.checkout()
    by_uuid, _ = overseer.item_ask(case.uuids["KEN-7"])
    legacy, _ = overseer.item_ask("KEN-9")
    overseer.legacy(legacy, case.uuids["KEN-9"])
    listed, _ = overseer.item_ask("KEN-8")
    for issue in ("KEN-7", "KEN-9"):
        case.clear(issue)
    under = case.reply("KEN-7", overseer.comment(by_uuid), "approve")
    other = case.reply("KEN-8", None, "approve too")
    read = overseer.owner_answers()
    facts["uuid_ref"] = (read.plain(under, by_uuid, "approve") and read.plain(other, listed, "approve too")
                         and read.result.stderr.splitlines()
                         == ["owner-answers: item-unreadable issue=%s cause=ref-form" % case.uuids["KEN-9"]])


def reacts(case, before):
    """The eyes marks the tracker took since call BEFORE, by comment id."""
    return [call.split()[2] for call in case.calls()[before:] if call.startswith("comments react ")]


def close_replaced(case, facts):
    """T15: a reply under a question, posted before an ask replaced it, takes
    no mark from the replacement's close: the replacing ask takes the reply,
    and its one mark comes when owner-answers delivers it there."""
    overseer = case.checkout()
    first, _ = overseer.item_ask("KEN-7")
    under = case.reply("KEN-7", overseer.comment(first), "A")
    before = len(case.calls())
    second, _ = overseer.item_ask("KEN-7", text="Approve half of it?\n")
    closing = reacts(case, before)
    read = overseer.owner_answers()
    facts["close_replaced"] = (first in overseer.closes() and closing == []
                               and read.headed(under, first, second, "A") and reacts(case, before) == [under])


def close_chat(case, facts):
    """T16: a chat ask that replaced an item question, closed on an answer
    given elsewhere, marks the owner's reply under that question once."""
    overseer = case.checkout()
    first, _ = overseer.item_ask("KEN-7")
    chat, _ = overseer.ask("--replaces", first)
    case.clear("KEN-7")
    under = case.reply("KEN-7", overseer.comment(first), "A")
    before = len(case.calls())
    closed = overseer.close_with(chat, "A\n")
    read = overseer.owner_answers()
    facts["close_chat"] = (closed.returncode == 0 and not closed.stderr and chat in overseer.closes()
                           and read.ok() and under not in read.answers and reacts(case, before) == [under])


def close_missing(case, facts):
    """T17: a close whose replaced question is on an item Linear holds no
    issue for names that item, and marks the reply on the live item."""
    overseer = case.checkout()
    gone, _ = overseer.item_ask("KEN-8")
    live, _ = overseer.item_ask("KEN-7", "--replaces", gone, text="Approve it on KEN-7?\n")
    under = case.reply("KEN-7", overseer.comment(live), "approve")
    case.vanish("KEN-8")
    before = len(case.calls())
    closed = overseer.close_with(live, "approve\n")
    facts["close_missing"] = (closed.returncode == 0 and live in overseer.closes()
                              and closed.stderr.splitlines() == ["owner-answers: item-missing issue=KEN-8"]
                              and reacts(case, before) == [under])


# --- compact ----------------------------------------------------------------


def retention(case, facts):
    """T11: an open replacement keeps its predecessor's exchange and delivery
    rows; an unrelated closed ask on the item ages out and its answer is not
    delivered again."""
    overseer = case.checkout()
    unrelated, _ = overseer.item_ask("KEN-7")
    old_answer = case.reply("KEN-7", None, "approve the old one")
    overseer.owner_answers()
    overseer.resolve(unrelated)
    first, _ = overseer.item_ask("KEN-7", text="Ship the docs?\n")
    early = case.reply("KEN-7", None, "ship")
    held = overseer.owner_answers().plain(early, first, "ship")
    second, _ = overseer.item_ask("KEN-7", text="Ship the docs and tests?\n")
    overseer.compact()
    kept = {row.get("id") for row in overseer.rows("to-overseer.jsonl")}
    answers = [row for row in overseer.rows("to-lane.jsonl") if row.get("delivery_id") == "linear:" + early]
    read = overseer.owner_answers()
    facts["replacement_retained"] = (held and {first, second} <= kept and unrelated not in kept
                                     and [row["re"] for row in answers] == [first] and first in overseer.closes()
                                     and read.ok() and read.counts.get(early) == 1)
    facts["aged_out_unrepeated"] = (read.ok() and old_answer not in read.answers
                                    and unrelated not in {row.get("re") for row in overseer.rows("to-lane.jsonl")})


GROUPS = {
    "ask": ((same_item, ("KEN-7", "KEN-8")), (spellings, ("KEN-7",)), (refused_marks, ("KEN-7",)),
            (incomplete, ("KEN-7", "KEN-8")), (absent, ("KEN-7",)), (no_team, ("KEN-7", "KEN-8")),
            (explicit, ("KEN-7", "KEN-8", "KEN-9"))),
    "answers": tuple((replaced_route(fact, steps, cleared), sorted({issue for issue, _ in steps if issue}))
                     for fact, steps, cleared in REPLACED)
               + ((threads, ("KEN-7",)), (flat, ("KEN-7",)), (missing_item, ("KEN-7", "KEN-8")),
                  (uuid_ref, ("KEN-7", "KEN-8", "KEN-9")), (close_replaced, ("KEN-7",)), (close_chat, ("KEN-7",)),
                  (close_missing, ("KEN-7", "KEN-8"))),
    "compact": ((retention, ("KEN-7",)),),
}


def run(group, source, scratch, bash):
    """Each scenario keeps its own tracker, checkout and facts, so they run
    side by side; a scenario that raises reports its fact false with why."""
    def judged(scenario, issues):
        facts = {}
        try:
            scenario(Case(scratch, source, bash, issues), facts)
        except Exception as error:  # the suite names the failed row
            facts["error:" + scenario.__name__] = repr(error)
        return facts

    with ThreadPoolExecutor(max_workers=len(GROUPS[group])) as pool:
        results = [future.result() for future in [pool.submit(judged, *row) for row in GROUPS[group]]]
    return {key: value for facts in results for key, value in facts.items()}


if __name__ == "__main__":
    print(json.dumps(run(sys.argv[1], Path(sys.argv[2]), sys.argv[3], sys.argv[4])))
