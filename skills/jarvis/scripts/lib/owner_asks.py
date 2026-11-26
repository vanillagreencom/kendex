"""The main home's owner-ask pages and action deltas, never a source replica."""

import base64
from concurrent.futures import ThreadPoolExecutor
import datetime
import hashlib
import json
import os
import re
import shlex
import sys
import tempfile
import time
import uuid
from urllib.parse import urlsplit

import forward
import watch

# VGS replaces one page per view. Its 15-second child bound leaves one
# second here for a structured failure to reach that caller.
CALL_SECONDS = 14
# A satellite keeps this share of its own deadline for the SSH connect, the
# main's start and the answer's return, and gives the main the rest, so the
# main answers with its own cause first. The trip, run on 2026-11-23
# through host_call to a real sshd and jarvis-session
# with a near-zero main budget, took 0.42 s on loopback. Behind a proxy that
# delayed each direction, it took 1.2 s at a 100 ms round trip and 2.8 s at
# 300 ms. Counting the TCP handshake the proxy skips, a trip costs 0.42 s plus
# about 8.8 round trips, so this share holds to about a 180 ms round trip. A
# slower trip reports as main-slow.
TRANSPORT_SECONDS = 2
PAGE_ROWS = 32
PAGE_BYTES = 16 * 1024
# A first page reuses the last complete collection younger than this, so
# consoles polling an unchanged list cost at most one collection a window,
# about four Linear requests, however many poll.
COLLECTION_SECONDS = 60
# A Done click is the owner's claim. The delegate who reads it decides
# completion, so the claim says so where the delegate reads it.
DONE_CLAIM = "Done claim; delegate verification is still required."
DELIVERY_UNCONFIRMED = "Delivery is not confirmed; retry with the same request identity and text."
# The caller's mailbox code over each root's data. Each registered root
# answers one record and each distinct mailbox one read, so the caller can
# prove the read complete. jq carries every path and payload as a JSON
# string: the line framing never meets a path's own bytes, and jq -c leaves
# U+2028/U+2029 raw in strings, so each record ends at LF only.
# Pending carries current questions and their text. The outward read carries
# the original snapshot header and the evidence that joins an ask to its
# tracker comment or records a replacement. Action rechecks compare this
# projection, including the header's logical count and first id.
MAILBOX_READS = r"""set -euo pipefail
mail=$1
shift
. "${mail%/*}/lib/common-root.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "${work:?}"' EXIT
seen=()
for root in "$@"; do
  # Only a work tree holds an overseer mailbox; lane-mail refuses
  # root-unresolved elsewhere. rev-parse answers true there and false in git
  # metadata with no work tree, a bare or .git directory. Outside every
  # repository it dies with 128, git's status for every fatal error, so that
  # outcome is known only by the first line of its untranslated die text.
  # Git's trace variables, GIT_TRACE and every GIT_TRACE_* and GIT_TRACE2*
  # name in git(1) § Debugging, can print to stderr ahead of the die text.
  status=0
  inside="$(for name in $(compgen -e); do case $name in GIT_TRACE*) unset "$name" ;; esac; done
    LC_ALL=C git -C "$root" rev-parse --is-inside-work-tree 2>"$work/probe")" || status=$?
  first=
  IFS= read -r first <"$work/probe" || true
  case "$status:$inside:$first" in
    0:true:*) ;;
    0:false:* | '128::fatal: not a git repository (or any '*)
      jq -cn --arg root "$root" '{registered: $root, mailbox: null}'
      continue ;;
    *)
      cat -- "$work/probe" >&2
      exit 1 ;;
  esac
  # The sentinel keeps a path's own trailing line feeds; the function adds one.
  common="$(mailbox_common_root "$root" && printf .)"
  common="${common%.}"
  common="${common%$'\n'}"
  jq -cn --arg root "$root" --arg mailbox "$common" '{registered: $root, mailbox: $mailbox}'
  for known in ${seen[@]+"${seen[@]}"}; do
    [ "$known" != "$common" ] || continue 2
  done
  seen+=("$common")
  # Only lane-mail runs inside the checkout: a bare name resolved there could
  # meet a PATH entry relative to that folder.
  (
    cd -- "$common"
    "$BASH" "$mail" pending --item overseer --root "$common" --to owner >"$work/pending"
    "$BASH" "$mail" events --item overseer --root "$common" --box to-overseer >"$work/outward"
  )
  jq -cn --arg root "$common" --rawfile pending "$work/pending" --rawfile outward "$work/outward" \
    '{root: $root, pending: $pending,
      outward: ($outward | split("\n")
        | [.[0], (.[1:][] | select(length > 0) | fromjson
            | select(.kind == "ask" and .to == "owner")
            | with_entries(select(.key | IN(
                "id", "tracker_posted", "tracker_comment", "identity", "replacement", "replaces")))
            | tojson), ""]
        | join("\n"))}'
done
"""
# The owner's answer to one mailbox ask, through the caller's lane-mail as the
# destination account. The text arrives on stdin, after a host's command and
# closure. lane-mail names its sender's repository from its working folder,
# so it alone runs inside the checkout, from a subshell; mktemp, cat and the
# trap's rm resolve their names outside it.
MAILBOX_ANSWER = r"""set -euo pipefail
mail=$1
root=$2
shift 2
note="$(mktemp)"
trap 'rm -f -- "${note:?}"' EXIT
cat >"$note"
(cd -- "$root" && exec "$BASH" "$mail" send --item overseer --root "$root" --file "$note" "$@")
"""
TRACKER_QUESTIONS = r"""set -euo pipefail
. "$1"
exec jq -c --arg done "$2" "$OWNER_QUESTION_JQ"'
  .tracker as $tracker | .closed as $closed | .replaced as $replaced | .replies as $replies
  | {workspace: $tracker.workspace, requests: [
      $tracker.requests | group_by(.issueUuid)[] | . as $requests | .[0].issueUuid as $issue
      | ($tracker.discussions[$issue] | INDEX(.id)) as $rows
      | (INDEX($requests[]; .comment.id)) as $questions
      | (reduce ($rows[] | .id as $id
                 | if $replies | has($id) then select([$issue, .parent_id] == $replies[$id]) | .parent_id
                   elif .ruling then .parent_id
                   else select(.user_id == $tracker.owner and .opening != $done)
                     | owner_question_parent($rows; $questions; false) end
                 | select(. != null)) as $id
           ({}; .[$id] = true)) as $answers
      | $requests[] | .comment.id as $id
      | select(.comment | owner_question_settled($answers[$id]; ($closed | has($id)) and
          ($closed[$id] == null or $closed[$id] == $issue); $replaced[$issue][$id]) | not)
    ]}'
"""
# lane-mail's refusals of an answer to an ask closed, or compacted after closing.
CLOSED = re.compile(r"lane-mail: (?:resolved-already|ask-unknown)=")
# A reply comment by the identity the main minted for it. Linear's
# Query.comment "returns an error if no accessible comment matches", which
# linear.sh graphql exits 2 for.
COMMENT_READ = "query OwnerReply($id: String!) { comment(id: $id) { id parent { id } issue { id } } }"
REACHED = "owner-asks: main-reached"
MAIN = '''set -euo pipefail
printf '%%s\\n' %(reached)s >&2
cd -- "$1"
home=$1
budget=$2
shift 2
exec env JARVIS_OWNER_ASK_MAIN=1 JARVIS_OWNER_ASK_BUDGET="$budget" "$BASH" .agents/skills/jarvis/scripts/jarvis-session owner-asks "$@" --home "$home"
''' % {"reached": shlex.quote(REACHED)}


class Unavailable(ValueError):
    """The source or consistency evidence needed for an answer is unread."""
    def __init__(self, cause, diagnostic=None):
        super().__init__(cause)
        self.diagnostic = diagnostic


def source_failure(operation, destination, error):
    record = dict(watch.failure(operation, error).record, destination=destination)
    return Unavailable("The required " + operation + " evidence at " + destination + " could not be read.", record)


def diagnostic(error, operation):
    record = error.diagnostic if isinstance(error, Unavailable) else watch.failure(operation, error).record
    if record is None:
        return
    # Dependency diagnostics can quote private-file values. Redact inherited
    # credentials and the shared shipped value patterns before any emission.
    try:
        lines = (watch.LIB.parents[2] / "orch/references/secret-value.ere").read_text().splitlines()
        patterns = [line for line in lines if line.strip() and not line.lstrip().startswith("#")]
        if len(patterns) != 1:
            raise ValueError("secret-pattern-invalid")
        pattern = re.compile(patterns[0], re.I | re.M)
        secrets = [value for name, value in os.environ.items() if value and
                   any(word in name.upper() for word in ("TOKEN", "SECRET", "PASSWORD", "API_KEY"))]

        def sanitized(value):
            if isinstance(value, dict):
                return {key: sanitized(item) for key, item in value.items()}
            if isinstance(value, list):
                return [sanitized(item) for item in value]
            if isinstance(value, str):
                for secret in secrets:
                    value = value.replace(secret, "[redacted]")
                return pattern.sub("[redacted]", value)[:2048]
            return value

        detail = encoded(sanitized(record))
    except (OSError, ValueError, re.error):
        detail = encoded({"key": [operation, "diagnostic-redaction-unavailable"], "detail": "unavailable"})
    print("jarvis-session: owner-asks-failure=" + detail, file=sys.stderr)


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(encoded(value).encode()).hexdigest()


def instant(value):
    if not isinstance(value, str) or "T" not in value:
        raise ValueError("instant")
    result = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("offset")
    return result.timestamp()


def iso(now):
    return datetime.datetime.fromtimestamp(now, datetime.timezone.utc).isoformat()


def printable(value):
    return isinstance(value, str) and bool(value) and value.isprintable()


def http(value):
    return isinstance(value, str) and urlsplit(value).scheme in ("http", "https") and bool(urlsplit(value).netloc)


def mirrored(ask):
    """An outward row that names the tracker comment mirroring its ask."""
    return ask.get("tracker_posted") is True and bool(ask.get("tracker_comment"))


def tracker_reply_parent(route):
    # An outstanding request recorded by the old sender keeps its destination.
    return route["question"] if "question" in route else route["thread"]


def tracker_question(workspace, issue, comment):
    return ["linear", workspace, issue, comment]


class Sources:
    """The one owner of every owner-ask source read and answer.

    Each command is the caller's own package code with the caller's settings,
    run as the destination's account. A destination supplies data alone: its
    project registry and each root's mailbox files. Linear runs on the main,
    beside the caller's credentials.

    An answer goes where its ask was read, so no credential crosses machines.
    A mailbox ask's answer is data in the destination's own mailbox, written
    with no credential; whatever carries it further, that destination's own
    relay or tracker mirror, runs there with its own settings. A tracker item
    is one the main's own Linear credential read, so the same credential
    replies in the same workspace."""

    def __init__(self, session, settings):
        self.session, self.settings = session, settings
        # Encoded at the first host read; a host read sends it once per destination and collect.
        self.closure = None

    def call(self, target, root, package, script, args=(), shell_args=(), data=None, check=True):
        """The command's result; DATA is its stdin, after a host's command and closure."""
        operation = package + "/" + script
        place = target.key + (":" + str(root) if root is not None else "")
        name = package + "/scripts/" + script
        try:
            if target.host:
                # Only mailbox code runs on a host: lane-mail and its library.
                if self.closure is None:
                    self.closure = watch.package_files(watch.MAILBOX_FILES)
                # The login shell parses only "bash -s": fish turns \\ inside
                # single quotes into \, so a quoted command reaches bash
                # changed. POSIX sh's INPUT FILES leaves a shell reading stdin
                # directly after its command, so the closure after the
                # command's line reaches the bootstrap unread by bash. With
                # DATA, the closure rides fd 3 inside the command and DATA
                # follows it, the command's own stdin.
                if data is None:
                    command, payload = watch.remote_command(self.closure, name, args, stdin=True, shell_args=shell_args)
                    result = watch.run(watch.host_args(target, "bash -s"), data=command + "\n" + payload,
                                       operation=operation, timeout=self.remaining())
                else:
                    command, _ = watch.remote_command(self.closure, name, args, shell_args=shell_args)
                    result = watch.run(watch.host_args(target, "bash -s"), data=command + data,
                                       operation=operation, timeout=self.remaining())
            else:
                result = watch.run([self.session.env["JARVIS_BASH"], *shell_args, watch.LIB.parents[2] / name, *args],
                                   self.session.home, data, operation=operation, timeout=self.remaining())
            if check and result.returncode:
                raise watch.child_failure(operation, result)
            return result
        except (OSError, watch.Failure) as error:
            raise source_failure(operation, place, error) from error

    def remaining(self):
        remaining = self.session.deadline - time.monotonic()
        if remaining <= 0:
            raise Unavailable("The request read reached its deadline.")
        return remaining

    def caller(self, package, script, args=()):
        """A read on the main with the caller home's settings: Linear and tracker settings."""
        local = watch.Destination("local", None, None)
        result = self.call(local, self.session.home, package, script, args)
        try:
            return json.loads(result.stdout)
        except ValueError as error:
            raise source_failure(package + "/" + script, "local:" + self.session.home, error) from error

    def registered(self, target):
        """Every folder the destination's registry names; any registration not in state ok makes the list unavailable."""
        try:
            roots = []
            for entry in watch.destination_projects(target, timeout=self.remaining()):
                if entry.state != "ok":
                    raise watch.Failure("project-list", "registration-unreadable", entry.state, entry.folder)
                roots.append(entry.folder)
        except watch.Failure as error:
            raise source_failure("project-list", target.key, error) from error
        return roots

    def mailboxes(self, target, roots):
        """Owner-ask evidence from each distinct overseer mailbox, in one call per destination."""
        if not roots:
            return []
        result = self.call(target, None, "mailbox", "lane-mail", roots, shell_args=["-c", MAILBOX_READS, "owner-asks"])
        try:
            records = [json.loads(line) for line in result.stdout.split("\n") if line]
            answers = [record for record in records if "registered" in record]
            reads = [record for record in records if "registered" not in record]
            if [answer["registered"] for answer in answers] != roots:
                raise ValueError("mailbox-roots")
            mailboxes = dict.fromkeys(answer["mailbox"] for answer in answers if answer["mailbox"] is not None)
            if [read["root"] for read in reads] != list(mailboxes):
                raise ValueError("mailbox-reads")
        except (ValueError, TypeError, KeyError) as error:
            raise source_failure("mailbox/lane-mail", target.key, error) from error
        return reads

    @staticmethod
    def events(text):
        lines = text.split("\n")
        if watch.mailbox_header(lines[0]) is None:
            raise Unavailable("The original mailbox read is incomplete.")
        return {"header": lines[0], "rows": [json.loads(line) for line in lines[1:] if line]}

    def posted(self, comment_ids):
        if not comment_ids:
            return {}
        return self.caller("linear", "linear.sh", ["comments", "bulk-get", *comment_ids])

    def tracker(self):
        """The owner tracker settings and, where they are set, the owner-requests view."""
        config = self.caller("mailbox", "owner-tracker-settings")
        if config["configured"]:
            return config, self.caller("linear", "linear.sh",
                                       ["comments", "owner-requests", "--email", config["email"], "--label", config["label"]])
        if config["cause"] != "settings-unset":
            raise Unavailable("The owner tracker settings could not be read.")
        return config, None

    def destination(self, target):
        """Every overseer mailbox the destination's registered roots hold, read."""
        roots = self.registered(target)
        if not target.host and self.session.home not in roots:
            roots.append(self.session.home)
        return [{"destination": target.key, "root": record["root"],
                 "asks": [json.loads(line) for line in record["pending"].split("\n") if line],
                 "outward": self.events(record["outward"])} for record in self.mailboxes(target, roots)]

    def open_tracker(self, tracker, mailboxes, requests):
        if tracker is None:
            return None
        closed, replaced = {}, {}
        # Retained evidence suppresses stale mirrors and names compacted predecessors.
        for mailbox in mailboxes:
            pending = {ask["id"] for ask in mailbox["asks"]}
            for ask in mailbox["outward"]["rows"]:
                if mirrored(ask) and ask["id"] not in pending:
                    closed[ask["tracker_comment"]] = (ask.get("identity") or {}).get("uuid")
                if ask.get("replacement") == "in-force":
                    for prior in ask.get("replaces", []):
                        item = (prior.get("identity") or {}).get("uuid")
                        if item and prior.get("tracker_comment"):
                            replaced.setdefault(item, {})[prior["tracker_comment"]] = True
        replies = {}
        for entry in requests:
            route = entry.get("route", {})
            if route.get("source") == "linear":
                item, question = route["issueUuid"], tracker_reply_parent(route)
                # Legacy retries keep their saved parent without settling a different row.
                payload = entry["payload"]
                matches = payload["id"] == digest(tracker_question(tracker["workspace"], item, question))
                replies[entry["key"]] = [item, question] if payload["action"] == "reply" and matches else None
        result = self.call(watch.Destination("local", None, None), self.session.home, "mailbox", "lib/mailbox-append.sh",
                           [DONE_CLAIM], shell_args=["-c", TRACKER_QUESTIONS, "owner-asks"],
                           data=encoded({"tracker": tracker, "closed": closed, "replaced": replaced, "replies": replies}))
        return json.loads(result.stdout)

    def collect(self, requests=()):
        targets = watch.destinations(self.settings)
        # The tracker and each destination are read side by side, so the
        # call's one deadline holds the longest chain of reads, not their sum.
        with ThreadPoolExecutor(max_workers=1 + len(targets)) as pool:
            tracker = pool.submit(self.tracker)
            reads = [pool.submit(self.destination, target) for target in targets]
            mailboxes = [mailbox for read in reads for mailbox in read.result()]
            # Pending already carries confirmed posting IDs. Closed asks'
            # outward evidence is still needed to suppress their mirrors.
            posted = self.posted(list(dict.fromkeys(ask["tracker_comment"] for mailbox in mailboxes
                                                    for ask in mailbox["asks"] if mirrored(ask))))
            config, tracker = tracker.result()
        for mailbox in mailboxes:
            mailbox["links"] = {}
            for ask in mailbox["asks"]:
                if mirrored(ask):
                    comment = posted.get(ask["tracker_comment"])
                    if comment is not None:
                        mailbox["links"][ask["id"]] = comment
        return {"config": config, "tracker": self.open_tracker(tracker, mailboxes, requests), "mailboxes": mailboxes, "posted": posted}

    def stable(self, requests):
        first, second = self.collect(requests), self.collect(requests)
        if digest(first) != digest(second):
            raise Unavailable("The request sources changed during the read; refresh from the first page.")
        return second

    def deliver(self, route, body, key, retry):
        """Add BODY to the conversation ROUTE names once per KEY: True once it
        stands there, False where the mailbox ask closed first. Unavailable
        while the outcome is unknown, which a retry with KEY settles."""
        try:
            if route["source"] == "mailbox":
                return self.answer(route, body, key)
            return self.reply(route, body, key, retry)
        except (Unavailable, ValueError, TypeError, KeyError) as error:
            raise Unavailable(DELIVERY_UNCONFIRMED, error.diagnostic if isinstance(error, Unavailable)
                              else watch.failure("owner-asks-delivery", error).record) from error

    def answer(self, route, body, key):
        # lane-mail judges a repeated delivery id under the mailbox lock and
        # names the answer that landed, before it judges closure.
        delivery = "owner-ask-" + key
        target = next((target for target in watch.destinations(self.settings) if target.key == route["destination"]), None)
        if target is None:
            raise Unavailable("The ask's destination is no longer declared.")
        result = self.call(target, route["root"], "mailbox", "lane-mail", [route["root"], "--re", route["ask"], "--delivery-id", delivery],
                           shell_args=["-c", MAILBOX_ANSWER, "owner-asks"], data=body, check=False)
        if watch.send_receipt(result, delivery):
            return True
        if result.returncode == 2 and CLOSED.match(result.stderr):
            return False
        raise source_failure("mailbox/lane-mail", target.key + ":" + route["root"], watch.child_failure("mailbox/lane-mail", result))

    def reply(self, route, body, key, retry):
        # KEY is the comment's own id, Linear's CommentCreateInput.id ("The
        # identifier in UUID v4 format"), unique per entity, so a resend after
        # an unanswered create cannot post twice; a retry reads it first.
        local = watch.Destination("local", None, None)
        parent = tracker_reply_parent(route)
        if retry:
            read = self.call(local, None, "linear", "linear.sh",
                             ["graphql", "--query", COMMENT_READ, "--variables", encoded({"id": key})], check=False)
            if read.returncode == 0:
                comment = json.loads(read.stdout)["comment"]
                if (comment["id"] != key or comment["issue"]["id"] != route["issueUuid"]
                        or (comment["parent"] or {}).get("id") != parent):
                    raise Unavailable("The reply identity names another comment.")
                return True
            if read.returncode != 2:
                raise source_failure("linear/linear.sh", "local", watch.child_failure("linear/linear.sh", read))
        with tempfile.NamedTemporaryFile(mode="w", dir=self.session.path.parent, suffix=".md") as file:
            file.write(body)
            file.flush()
            # The text is the owner's own, as the mailbox answer's from=owner
            # says on the other route: no agent attribution line opens it.
            result = self.call(local, None, "linear", "linear.sh", ["comments", "create", route["issueUuid"], "--parent", parent,
                                                                    "--id", key, "--no-attribution", "--body-file", file.name])
        created = json.loads(result.stdout)
        if created["success"] is not True or created["data"]["comment"]["id"] != key:
            raise Unavailable("The tracker did not confirm the reply.")
        return True


def source_rows(source):
    """The rows by identity, and the conversation each one's answer goes to."""
    rows, routes = {}, {}
    # Linear's GraphQL schema gives each comment an `id`, "the unique
    # identifier of the entity", and every read runs the caller's one Linear
    # credential: a comment id alone names its mirror.
    mirrors = {ask["tracker_comment"] for mailbox in source["mailboxes"]
               for ask in mailbox["asks"] if mirrored(ask)}

    def add(identity, kind, what, author, at, link, thread, route):
        instant(at)
        if (not printable(author["id"]) or not printable(author["name"])
                or link is not None and not http(link["url"])):
            raise Unavailable("An original request author or conversation link is not confirmed.")
        key = digest(identity)
        if key in rows:
            raise Unavailable("The request source contains an ambiguous duplicate identity.")
        rows[key] = {"id": key, "kind": kind, "what": what, "askedBy": author, "askedAt": at,
                     "link": link, "threadRef": digest(thread)}
        routes[key] = route

    for mailbox in source["mailboxes"]:
        destination, root = mailbox["destination"], mailbox["root"]
        for ask in mailbox["asks"]:
            # An ask with no confirmed tracker mirror has no conversation link.
            link = mailbox["links"].get(ask["id"])
            identity = ["mailbox", destination, root, ask["id"]]
            add(identity, "fleet-approval" if ask.get("draft") else "jarvis-ask",
                ask["text"], {"id": ask["from"], "name": ask["from"]}, ask["at"],
                None if link is None else {"label": "Original ask", "url": link["url"]}, identity,
                {"source": "mailbox", "destination": destination, "root": root, "ask": ask["id"]})
    tracker = source["tracker"]
    if tracker is not None:
        for request in tracker["requests"]:
            comment = request["comment"]
            if comment["id"] in mirrors:
                continue
            add(tracker_question(tracker["workspace"], request["issueUuid"], comment["id"]), "tracker-item", comment["body"],
                {"id": comment["user_id"], "name": comment["user"]}, comment["created_at"],
                {"label": request["issue"], "url": comment["url"]},
                ["linear", tracker["workspace"], request["issueUuid"], request["thread"]],
                {"source": "linear", "issueUuid": request["issueUuid"], "question": comment["id"]})
    return rows, routes


class OwnerAsks:
    def __init__(self, session, sources, clock=time.time):
        self.session, self.sources, self.clock = session, sources, clock

    def read(self):
        try:
            state = json.loads(self.session.path.read_text())
        except FileNotFoundError:
            state = {"v": 1, "home": self.session.home, "homeId": str(uuid.uuid4()), "sequence": 0, "deltas": {}, "requests": {}}
            self.session.write(state)
        if (not isinstance(state, dict) or state.get("v") != 1 or state.get("home") != self.session.home or not printable(state.get("homeId"))
                or type(state.get("sequence")) is not int or not isinstance(state.get("deltas"), dict)
                or not isinstance(state.get("requests"), dict) or not isinstance(state.get("pageSnapshots", {}), dict)
                or not isinstance(state.get("collection", {}), dict)):
            raise Unavailable("The main home's owner-action record could not be read.")
        return state

    def current(self, state, source):
        rows, routes = source_rows(source)
        now = self.clock()
        # A complete read alone owns membership: an ask it no longer returns
        # was closed, compacted after closing, or sits in a root or on a host
        # no longer read.
        closed_keys = [key for key in state["deltas"] if key not in rows]
        if closed_keys:
            for key in closed_keys:
                del state["deltas"][key]
            self.session.write(state)
        for key, row in rows.items():
            shown, until = self.shown(state["deltas"].get(key, {}), now)
            row.update(state=shown, snoozedUntil=until,
                       actions={action: {"allowed": True, "reason": ""} for action in ("reply", "done", "later")})
        revision = digest([state["homeId"], source, state["sequence"], rows])
        for row in rows.values():
            row["revision"] = revision
        return rows, routes, revision, now

    @staticmethod
    def shown(delta, now):
        """A row's state and snooze time from its delta: a live snooze, else a Done claim, else open."""
        until = delta.get("until")
        if until is not None and instant(until) > now:
            return "snoozed", until
        return "checking" if delta.get("checking") else "open", None

    @staticmethod
    def remember(state, source, at):
        state["collection"] = {"at": at, "source": source}

    def collection(self, state):
        """The last complete collection while it is younger than COLLECTION_SECONDS, else a new one.

        Every caller holds the home's lock, so a first page that waits on a
        running collection takes its result here."""
        saved = state.get("collection")
        if saved is not None and 0 <= self.clock() - saved["at"] < COLLECTION_SECONDS:
            return saved
        source = self.sources.collect(state["requests"].values())
        self.remember(state, source, self.clock())
        self.session.write(state)
        return state["collection"]

    def page(self, state, view, cursor):
        snapshots = state.setdefault("pageSnapshots", {})
        offset = 0
        if cursor is None:
            collection = self.collection(state)
            rows, _, revision, _ = self.current(state, collection["source"])
            ordered = sorted(rows.values(), key=lambda row: (instant(row["askedAt"]), row["id"]))
            active = [row for row in ordered if row["state"] != "snoozed"]
            snoozed = [row for row in ordered if row["state"] == "snoozed"]
            # The revision digests every row, so a cursor bound to it reads
            # the same rows from any refresh that finds the same revision.
            snapshot = {"sequence": state["sequence"], "revision": revision, "observedAt": iso(collection["at"]),
                        "activeCount": len(active), "snoozedCount": len(snoozed),
                        "rows": active if view == "active" else snoozed}
        else:
            try:
                decoded = json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())
                snapshot = snapshots[view]
                if (decoded[:3] != [state["homeId"], snapshot["revision"], view] or len(decoded) != 4
                        or snapshot["sequence"] != state["sequence"]
                        or type(decoded[3]) is not int or not 0 < decoded[3] < len(snapshot["rows"])):
                    raise ValueError("cursor")
                offset = decoded[3]
            except (ValueError, TypeError, UnicodeError, IndexError, KeyError):
                raise Unavailable("The page cursor is stale or invalid; refresh from the first page.")

        selected = snapshot["rows"]

        def result(end):
            next_cursor = (base64.urlsafe_b64encode(encoded([state["homeId"], snapshot["revision"], view, end]).encode()).decode()
                           if end < len(selected) else None)
            return {"v": 1, "homeId": state["homeId"], "revision": snapshot["revision"], "observedAt": snapshot["observedAt"],
                    "activeCount": snapshot["activeCount"], "snoozedCount": snapshot["snoozedCount"], "rows": selected[offset:end],
                    "nextCursor": next_cursor, "complete": next_cursor is None}

        end = min(offset + PAGE_ROWS, len(selected))
        page = result(end)
        while len(encoded(page).encode()) + 1 > PAGE_BYTES and end > offset:
            end -= 1
            page = result(end)
        if end == offset and offset < len(selected) or len(encoded(page).encode()) + 1 > PAGE_BYTES:
            raise Unavailable("An individual owner ask exceeds the page byte limit.")
        if cursor is None:
            # A snapshot of the same revision holds the same rows, so one
            # this refresh would not save still serves a walk in progress.
            retained = {name: previous for name, previous in snapshots.items()
                        if previous["revision"] == snapshot["revision"]}
            if not page["complete"]:
                retained[view] = snapshot
            if retained != snapshots:
                state["pageSnapshots"] = retained
                self.session.write(state)
        return page

    def receipt(self, request, kind, state, cause=""):
        return {"v": 1, "requestId": request["requestId"], "kind": kind, "state": state, "cause": cause}

    def act(self, state, action, key, request):
        payload = {"action": action, "id": key, "request": request}
        previous = state["requests"].get(request["requestId"])
        if previous is not None:
            if previous["payload"] != payload:
                return self.receipt(request, "refused", None, "This request identity already names different content.")
            if previous["receipt"] is not None:
                return previous["receipt"]
            # A saved delivery whose outcome is unknown. Its own delivery
            # identity settles it; the revision it was sent at has moved on.
            return self.deliver(state, previous, retry=True)
        source = self.sources.stable(state["requests"].values())
        # The next first page lists this read, so a refusal for a changed
        # list leads to the revision it was judged at.
        self.remember(state, source, self.clock())
        rows, routes, revision, now = self.current(state, source)
        row = rows.get(key)

        def settle(kind, shown, cause=""):
            receipt = self.receipt(request, kind, shown, cause)
            state["requests"][request["requestId"]] = {"payload": payload, "receipt": receipt}
            self.session.write(state)
            return receipt

        if row is None:
            return settle("refused", None, "This ask is no longer open in the canonical source.")
        if request["expectedRevision"] != revision:
            return settle("refused", row["state"], "The ask list changed; refresh it before acting.")
        if action == "later":
            try:
                if instant(request.get("until")) <= now:
                    raise ValueError("past")
            except (ValueError, TypeError, OverflowError):
                return settle("refused", row["state"], "Choose a future absolute time with a timezone offset.")
            state["sequence"] += 1
            state["deltas"][key] = dict(state["deltas"].get(key, {}), until=request["until"])
            return settle("accepted", "snoozed")
        text = request.get("text", "")
        if not isinstance(text, str) or action == "reply" and not text.strip():
            return settle("refused", row["state"], "Write the reply text for the original conversation.")
        body = DONE_CLAIM + ("\n\n" + text if text.strip() else "") if action == "done" else text
        entry = {"payload": payload, "receipt": None, "route": routes[key], "body": body, "key": str(uuid.uuid4())}
        state["requests"][request["requestId"]] = entry
        # The intent is durable before the external effect: a crash between
        # the send and its receipt leaves a retry with the same identity.
        self.session.write(state)
        return self.deliver(state, entry, retry=False)

    def deliver(self, state, entry, retry):
        payload = entry["payload"]
        key, request = payload["id"], payload["request"]
        delivered = self.sources.deliver(entry["route"], entry["body"], entry["key"], retry)
        # Only a new read shows what the delivery settled, or that the ask had closed.
        state.pop("collection", None)
        if not delivered:
            entry["receipt"] = self.receipt(request, "refused", "closed",
                                            "This ask is closed in its mailbox, so this request added nothing to it.")
        elif payload["action"] == "done":
            # The claim replaces any snooze. The row stays checking until a
            # complete read omits it: the delegate closed it.
            state["sequence"] += 1
            state["deltas"][key] = {"checking": True}
            entry["receipt"] = self.receipt(request, "accepted", "checking")
        else:
            entry["receipt"] = self.receipt(request, "accepted", self.shown(state["deltas"].get(key, {}), self.clock())[0])
        self.session.write(state)
        return entry["receipt"]


def main(args, session_type, refusal_type):
    try:
        session = session_type(args.home)
        session.path = session.path.with_name("owner-asks.json")
        # A main called by a satellite stops at the satellite's budget for it.
        budget = float(os.environ.get("JARVIS_OWNER_ASK_BUDGET", CALL_SECONDS))
        session.deadline = time.monotonic() + min(CALL_SECONDS, budget)
        settings = watch.config(session.env["JARVIS_BASH"], session.home)
        role = watch.role(settings)
        data = sys.stdin.read() if args.action != "list" else None
        if role.kind == "invalid":
            raise Unavailable("The main-home setting is invalid.")
        if role.kind == "satellite":
            if os.environ.get("JARVIS_OWNER_ASK_MAIN"):
                raise Unavailable("The selected main is configured as a satellite.")
            argv = ["%.3f" % (session.deadline - time.monotonic() - TRANSPORT_SECONDS), args.action]
            if args.action == "list":
                argv += ["--view", args.view]
                if args.cursor is not None:
                    argv += ["--cursor", args.cursor]
            else:
                argv += ["--id", args.id]
            cause, result = forward.host_call(role, session.deadline, MAIN, argv, data, reached=REACHED)
            if cause != "ok":
                place = role.dest + ":" + role.home
                failure = source_failure("main-home", place, watch.Failure("main-home", "transport", cause, result))
                if cause == forward.MAIN_SLOW:
                    raise Unavailable("The main home at " + place + " did not answer before the satellite's deadline.",
                                      failure.diagnostic)
                raise failure
            # The main prints the same bounded public response. No local
            # copy of its state or interpretation of its receipt is kept.
            sys.stdout.write(result.stdout)
            sys.stderr.write(result.stderr.replace(REACHED + "\n", "", 1))
            return result.returncode
        owner = OwnerAsks(session, Sources(session, settings))
        with session.locked():
            state = owner.read()
            if args.action == "list":
                result = owner.page(state, args.view, args.cursor)
            else:
                request = json.loads(data)
                if not isinstance(request, dict) or not printable(request.get("requestId")) or not printable(request.get("expectedRevision")):
                    raise Unavailable("The action needs a printable request identity and revision.")
                result = owner.act(state, args.action, args.id, request)
        print(encoded(result))
        return 0
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, OverflowError, watch.DestinationRefusal, refusal_type) as error:
        diagnostic(error, "owner-asks-" + args.action)
        cause = str(error) if isinstance(error, Unavailable) else "The owner-ask operation could not read its required evidence."
        print(encoded({"v": 1, "kind": "unavailable", "cause": cause}))
        return 1
