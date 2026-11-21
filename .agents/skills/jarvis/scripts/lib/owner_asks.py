"""The main home's owner-ask pages and action deltas, never a source replica."""

import base64
import datetime
import hashlib
import json
import os
import re
from pathlib import Path
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
PAGE_ROWS = 32
PAGE_BYTES = 16 * 1024
# Drivers over the caller's mailbox code. Roots are data: each driver names
# the roots it reads and runs lane-mail in each one.
COMMON_ROOTS = r"""set -euo pipefail
. "$1"
shift
for root in "$@"; do
  common="$(mailbox_common_root "$root")"
  printf '%s\0' "$common"
done
"""
# ask-links reads the root's Slack binding and journal, the files slack's
# store.py names, on the main, so a host returns their bytes beside the mail.
# jq -c leaves U+2028/U+2029 raw in strings: each record ends at LF only.
MAILBOX_READS = r"""set -euo pipefail
mail=$1
shift
work="$(mktemp -d)"
trap 'rm -rf -- "${work:?}"' EXIT
for root in "$@"; do
  cd -- "$root"
  "$BASH" "$mail" pending --item overseer --to owner >"$work/pending"
  "$BASH" "$mail" events --item overseer --box to-overseer >"$work/outward"
  "$BASH" "$mail" events --item overseer --box to-lane >"$work/inward"
  slack=()
  for file in binding:tmp/slack/binding.json journal:tmp/slack/journal.jsonl; do
    if [ -f "${file#*:}" ]; then
      slack+=(--rawfile "${file%%:*}" "${file#*:}")
    else
      slack+=(--argjson "${file%%:*}" null)
    fi
  done
  jq -cn --arg root "$root" --rawfile pending "$work/pending" --rawfile outward "$work/outward" \
    --rawfile inward "$work/inward" "${slack[@]}" \
    '{root: $root, pending: $pending, outward: $outward, inward: $inward, binding: $binding, journal: $journal}'
done
"""
MAILBOX_SEND = r"""set -euo pipefail
mail=$1
cd -- "$2"
shift 2
note="$(mktemp)"
trap 'rm -f -- "${note:?}"' EXIT
cat >"$note"
"$BASH" "$mail" send --item overseer --file "$note" "$@"
"""
MAIN = '''set -euo pipefail
cd -- "$1"
home=$1
shift
exec env JARVIS_OWNER_ASK_MAIN=1 "$BASH" .agents/skills/jarvis/scripts/jarvis-session owner-asks "$@" --home "$home"
'''


class Unavailable(ValueError):
    """The source, consistency or delivery evidence needed for an answer is unread."""
    def __init__(self, cause, diagnostic=None):
        super().__init__(cause)
        self.diagnostic = diagnostic


def source_failure(operation, destination, error, delivery=False):
    record = watch.failure(operation, error).record
    record = dict(record, destination=destination)
    cause = ("Delivery is not confirmed; retain this request identity and reply draft." if delivery else
             "The required " + operation + " evidence at " + destination + " could not be read.")
    return Unavailable(cause, record)


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


class Sources:
    """The one owner of every owner-ask source read and send.

    Each command is the caller's own package code with the caller's settings,
    run as the destination's account. A destination supplies data alone: its
    project registry, each root's mailbox files and the root's Slack journal.
    Linear and Slack run on the main, beside the caller's credentials."""

    def __init__(self, session, settings):
        self.session, self.settings = session, settings
        # Encoded once; a host read sends it once per destination and collect.
        self.closures = {}

    def call(self, target, root, package, script, args=(), data=None, shell_args=(), check=True,
             place=None, delivery=False):
        operation = package + "/" + script
        place = place or target.key + (":" + str(root) if root is not None else "")
        name = package + "/scripts/" + script
        try:
            if target.host:
                # Only mailbox code runs on a host: lane-mail and its library.
                names = watch.MAILBOX_FILES if name == watch.MAILBOX_FILES[0] else (name,)
                if names not in self.closures:
                    self.closures[names] = watch.package_files(names)
                command, payload = watch.remote_command(self.closures[names], name, args, data=data,
                                                        stdin=True, shell_args=shell_args)
                result = watch.run(watch.host_args(target, "bash -c " + shlex.quote(command)), data=payload,
                                   operation=operation, timeout=self.remaining())
            else:
                result = watch.run([self.session.env["JARVIS_BASH"], *shell_args, watch.LIB.parents[2] / name, *args],
                                   root or self.session.home, data, operation=operation, timeout=self.remaining())
            if check and result.returncode:
                raise watch.child_failure(operation, result)
            return result
        except (OSError, watch.Failure) as error:
            raise source_failure(operation, place, error, delivery) from error

    def remaining(self):
        remaining = self.session.deadline - time.monotonic()
        if remaining <= 0:
            raise Unavailable("The request read reached its deadline.")
        return remaining

    def value(self, target, root, package, script, args=(), data=None, place=None):
        result = self.call(target, root, package, script, args, data, place=place)
        try:
            return json.loads(result.stdout)
        except ValueError as error:
            raise source_failure(package + "/" + script, place or target.key + ":" + str(root), error) from error

    def caller(self, package, script, args=(), data=None, place=None):
        """A read on the main with the caller home's settings: Linear, Slack and tracker settings."""
        return self.value(watch.Destination("local", None, None), self.session.home, package, script, args, data, place)

    def registered(self, target):
        """Every folder the destination's registry names; one it cannot read hides its asks."""
        argv = watch.host_args(target, "kendex project list --json") if target.host else ["kendex", "project", "list", "--json"]
        try:
            roots = []
            for entry in json.loads(watch.checked(argv, operation="project-list", timeout=self.remaining())):
                if entry["state"] != "ok":
                    raise watch.Failure("project-list", "registration-unreadable", entry["state"], entry["folder"])
                roots.append(entry["folder"])
        except (ValueError, TypeError, KeyError, watch.Failure) as error:
            raise source_failure("project-list", target.key, error) from error
        return roots

    def mailboxes(self, target, roots):
        """Each distinct mailbox root of ROOTS with its raw reads, in two calls per destination."""
        if not roots:
            return []
        common = self.call(target, None, "mailbox", "lib/common-root.sh", roots,
                           shell_args=["-c", COMMON_ROOTS, "owner-asks"]).stdout.split("\0")
        if len(common) != len(roots) + 1 or common.pop():
            raise Unavailable("The original mailbox read is incomplete.")
        canonical = list(dict.fromkeys(common))
        result = self.call(target, None, "mailbox", "lane-mail", canonical,
                           shell_args=["-c", MAILBOX_READS, "owner-asks"])
        try:
            records = [json.loads(line) for line in result.stdout.split("\n") if line]
            if [record["root"] for record in records] != canonical:
                raise ValueError("mailbox-roots")
        except (ValueError, TypeError, KeyError) as error:
            raise source_failure("mailbox/lane-mail", target.key, error) from error
        return records

    @staticmethod
    def events(text):
        lines = text.split("\n")
        if watch.mailbox_header(lines[0]) is None:
            raise Unavailable("The original mailbox read is incomplete.")
        return {"header": lines[0], "rows": [json.loads(line) for line in lines[1:] if line]}

    def ask_links(self, target, record, ids):
        # The permalink read carries the caller's Slack token, so it runs here
        # with the caller's settings, over a copy of the root's two files.
        with tempfile.TemporaryDirectory(dir=self.session.path.parent) as copy:
            slack = Path(copy) / "tmp/slack"
            slack.mkdir(parents=True)
            for name, field in (("binding.json", "binding"), ("journal.jsonl", "journal")):
                if record[field] is not None:
                    (slack / name).write_text(record[field])
            return self.caller("slack", "slack", ["ask-links", "--root", copy], encoded(ids),
                               place=target.key + ":" + record["root"])

    def collect(self):
        config = self.caller("mailbox", "owner-tracker-settings")
        tracker = None
        if config["configured"]:
            tracker = self.caller("linear", "linear.sh",
                                  ["comments", "owner-requests", "--email", config["email"], "--label", config["label"]])
        elif config["cause"] != "settings-unset":
            raise Unavailable("The owner tracker settings could not be read.")
        workspace, mailboxes = None, []
        for target in watch.destinations(self.settings):
            roots = self.registered(target)
            if not target.host and self.session.home not in roots:
                roots.append(self.session.home)
            for record in self.mailboxes(target, roots):
                asks = [json.loads(line) for line in record["pending"].split("\n") if line]
                outward, inward = self.events(record["outward"]), self.events(record["inward"])
                posted, links = {}, {}
                # Retained closed asks still own their exact tracker mirror;
                # a delayed label update must not resurrect that mirror.
                for ask in outward["rows"]:
                    if ask.get("tracker_posted") is not True or not ask.get("tracker_comment"):
                        continue
                    issue = ask["issue"]
                    if issue not in posted:
                        if workspace is None:
                            workspace = self.caller("linear", "linear.sh", ["teams", "keys"])["urlKey"]
                        item = self.caller("linear", "linear.sh", ["issues", "get", issue, "--format=safe"])
                        comments = self.caller("linear", "linear.sh", ["comments", "list", issue, "--format=safe"])
                        posted[issue] = {"workspace": workspace, "uuid": item["uuid"], "comments": comments}
                    comment = next((row for row in posted[issue]["comments"] if row["id"] == ask["tracker_comment"]), None)
                    if comment is not None:
                        links[ask["id"]] = {"url": comment["url"], "thread": comment["parent_id"] or comment["id"]}
                need_links = [ask["id"] for ask in asks if ask["id"] not in links]
                if need_links:
                    links.update(self.ask_links(target, record, need_links))
                mailboxes.append({"destination": target.key, "root": record["root"], "asks": asks,
                                  "outward": outward, "inward": inward, "posted": posted, "links": links})
        return {"config": config, "tracker": tracker, "mailboxes": mailboxes}

    def stable(self):
        first, second = self.collect(), self.collect()
        if digest(first) != digest(second):
            raise Unavailable("The request sources changed during the read; refresh from the first page.")
        return second

    def send(self, route, text, key):
        try:
            return self._send(route, text, key)
        except (OSError, watch.Failure, watch.DestinationRefusal) as error:
            raise source_failure(route["source"] + "-delivery", route["destination"] + ":" + route["root"],
                                 error, delivery=True) from error

    def _send(self, route, text, key):
        target = next((target for target in watch.destinations(self.settings)
                       if target.key == route["destination"]), None)
        if target is None:
            raise watch.DestinationRefusal("destination-unknown", route["destination"])
        if route["source"] == "mailbox":
            result = self.call(target, route["root"], "mailbox", "lane-mail",
                               [route["root"], "--re", route["ask"], "--delivery-id", key], text,
                               shell_args=["-c", MAILBOX_SEND, "owner-asks"], check=False, delivery=True)
            if result.returncode:
                raise source_failure("mailbox-delivery", target.key + ":" + route["root"],
                                     watch.child_failure("mailbox-delivery", result), delivery=True)
            receipt = watch.send_receipt(result, key)
            return receipt[0] if receipt else None
        with tempfile.NamedTemporaryFile(mode="w", dir=self.session.path.parent) as body:
            body.write(text)
            body.flush()
            result = self.call(target, route["root"], "linear", "linear.sh",
                               ["comments", "create", route["issueUuid"], "--parent", route["thread"], "--body-file", body.name],
                               check=False, delivery=True)
        if result.returncode:
            raise source_failure("linear-delivery", target.key + ":" + route["root"],
                                 watch.child_failure("linear-delivery", result), delivery=True)
        result = json.loads(result.stdout)
        return result.get("data", {}).get("comment", {}).get("id") if result.get("success") is True else None


def source_rows(source):
    rows, routes, mirrors = {}, {}, set()

    def add(identity, kind, what, author, at, link, route):
        instant(at)
        if not printable(author["id"]) or not printable(author["name"]) or not http(link["url"]):
            raise Unavailable("An original request author or conversation link is not confirmed.")
        key = digest(identity)
        if key in rows:
            raise Unavailable("The request source contains an ambiguous duplicate identity.")
        rows[key] = {"id": key, "kind": kind, "what": what, "askedBy": author, "askedAt": at,
                     "link": link, "threadRef": digest(route)}
        routes[key] = route

    for mailbox in source["mailboxes"]:
        destination, root = mailbox["destination"], mailbox["root"]
        for ask in mailbox["outward"]["rows"]:
            if ask.get("tracker_posted") is True and ask.get("tracker_comment"):
                posted = mailbox["posted"][ask["issue"]]
                mirrors.add((posted["workspace"], posted["uuid"], ask["tracker_comment"]))
        for ask in mailbox["asks"]:
            link = mailbox["links"].get(ask["id"])
            if link is None:
                raise Unavailable("The original owner-ask conversation has no confirmed link.")
            route = {"source": "mailbox", "destination": destination, "host": destination[4:] if destination.startswith("ssh:") else None,
                     "root": root, "ask": ask["id"]}
            add(["mailbox", destination, root, ask["id"]], "fleet-approval" if ask.get("draft") else "jarvis-ask",
                ask["text"], {"id": ask["from"], "name": ask["from"]}, ask["at"],
                {"label": "Original ask", "url": link["url"]}, route)
    tracker = source["tracker"]
    if tracker is not None:
        for request in tracker["requests"]:
            comment = request["comment"]
            identity = (tracker["workspace"], request["issueUuid"], comment["id"])
            if identity in mirrors:
                continue
            route = {"source": "linear", "destination": "local", "host": None, "root": source["home"],
                     "workspace": tracker["workspace"], "issueUuid": request["issueUuid"], "comment": comment["id"], "thread": request["thread"]}
            add(["linear", *identity], "tracker-item", comment["body"], {"id": comment["user_id"], "name": comment["user"]},
                comment["created_at"], {"label": request["issue"], "url": comment["url"]}, route)
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
                or not isinstance(state.get("requests"), dict)):
            raise Unavailable("The main home's owner-action record could not be read.")
        return state

    def current(self, state):
        source = self.sources.stable()
        source["home"] = self.session.home
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
            delta = state["deltas"].get(key, {})
            snoozed = delta.get("until") is not None and instant(delta["until"]) > now
            row.update(state="snoozed" if snoozed else "checking" if delta.get("checking") else "open",
                       snoozedUntil=delta.get("until") if snoozed else None)
            row["actions"] = {action: {"allowed": True, "reason": ""} for action in ("reply", "done", "later")}
        revision = digest([state["homeId"], source, state["sequence"], rows])
        for row in rows.values():
            row["revision"] = revision
        return source, rows, routes, revision, now

    def page(self, state, view, cursor):
        _, rows, _, revision, now = self.current(state)
        ordered = sorted(rows.values(), key=lambda row: (instant(row["askedAt"]), row["id"]))
        active = [row for row in ordered if row["state"] != "snoozed"]
        snoozed = [row for row in ordered if row["state"] == "snoozed"]
        selected = active if view == "active" else snoozed
        offset = 0
        if cursor is not None:
            try:
                decoded = json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())
                if (decoded[:3] != [state["homeId"], revision, view] or len(decoded) != 4
                        or type(decoded[3]) is not int or not 0 < decoded[3] < len(selected)):
                    raise ValueError("cursor")
                offset = decoded[3]
            except (ValueError, TypeError, UnicodeError, IndexError):
                raise Unavailable("The page cursor is stale or invalid; refresh from the first page.")

        def result(end):
            next_cursor = (base64.urlsafe_b64encode(encoded([state["homeId"], revision, view, end]).encode()).decode()
                           if end < len(selected) else None)
            return {"v": 1, "homeId": state["homeId"], "revision": revision, "observedAt": iso(now),
                    "activeCount": len(active), "snoozedCount": len(snoozed), "rows": selected[offset:end],
                    "nextCursor": next_cursor, "complete": next_cursor is None}

        end = min(offset + PAGE_ROWS, len(selected))
        page = result(end)
        while len(encoded(page).encode()) + 1 > PAGE_BYTES and end > offset:
            end -= 1
            page = result(end)
        if end == offset and offset < len(selected) or len(encoded(page).encode()) + 1 > PAGE_BYTES:
            raise Unavailable("An individual owner ask exceeds the page byte limit.")
        return page

    def receipt(self, request, kind, state, cause=""):
        return {"v": 1, "requestId": request["requestId"], "kind": kind, "state": state, "cause": cause}

    def action(self, state, action, key, request):
        payload = {"action": action, "id": key, "request": request}
        previous = state["requests"].get(request["requestId"])
        if previous is not None:
            if previous["payload"] != payload:
                return self.receipt(request, "refused", None, "This request identity already names different content.")
            if previous["receipt"] is not None:
                return previous["receipt"]
            # Never resend an uncertain append. Only a matching positive
            # canonical delivery receipt can settle the retained request.
            source = self.sources.stable()
            if not self.recovered(source, previous):
                raise Unavailable("Delivery is not confirmed; retain this request identity and ask the delegate to check.")
            return self.accept(state, previous)
        source, rows, routes, revision, now = self.current(state)
        row = rows.get(key)

        def refuse(cause):
            receipt = self.receipt(request, "refused", row["state"] if row else None, cause)
            state["requests"][request["requestId"]] = {"payload": payload, "receipt": receipt}
            self.session.write(state)
            return receipt

        if row is None:
            return refuse("This ask is no longer open in the canonical source.")
        if request["expectedRevision"] != revision:
            return refuse("The ask list changed; refresh it before acting.")
        if action == "later":
            try:
                if instant(request.get("until")) <= now:
                    raise ValueError("past")
            except (ValueError, TypeError, OverflowError):
                return refuse("Choose a future absolute time with a timezone offset.")
        elif not isinstance(request.get("text", ""), str) or action == "reply" and not request.get("text", "").strip():
            return refuse("Supply the reply text for the original conversation.")
        entry = {"payload": payload, "receipt": None, "route": routes[key]}
        state["requests"][request["requestId"]] = entry
        state["sequence"] += 1
        entry["sequence"] = state["sequence"]
        if action == "later":
            return self.accept(state, entry)
        delivery = "owner-action-" + digest([state["homeId"], request["requestId"]])
        entry["delivery"] = delivery
        entry["body"] = ("Done claim; delegate verification is still required.\n\n" if action == "done" else "") + request.get("text", "")
        if entry["route"]["source"] == "linear":
            # A recovery needs the actual posting actor, not the configured
            # owner's identity: an app token can post on the owner's behalf.
            local = watch.Destination("local", None, None)
            actor = self.sources.value(local, self.session.home, "linear", "linear.sh", ["users", "me", "--format=raw"])
            entry["actor"] = actor["viewer"]["id"]
            entry["body"] += "\n\n<!-- jarvis-owner-action:" + delivery + " -->"
        # Durable intent precedes every external effect, including a crash
        # between a successful send and recording its acknowledgement.
        self.session.write(state)
        landed = self.sources.send(entry["route"], entry["body"], delivery)
        if not landed:
            raise Unavailable("Delivery is not confirmed; retain this request identity and reply draft.")
        entry["landed"] = landed
        return self.accept(state, entry)

    def accept(self, state, entry):
        payload = entry["payload"]
        key, action, request = payload["id"], payload["action"], payload["request"]
        # A reply changes no visibility, so it leaves no delta.
        delta = state["deltas"].get(key, {}) if action == "reply" else state["deltas"].setdefault(key, {})
        if action == "done":
            delta["checking"] = True
            # Confirming an older delivery cannot undo a newer visibility choice.
            if delta.get("until_sequence", 0) <= entry["sequence"]:
                delta.pop("until", None)
                delta.pop("until_sequence", None)
        elif action == "later":
            delta["until"] = request["until"]
            delta["until_sequence"] = entry["sequence"]
        current = "snoozed" if delta.get("until") and instant(delta["until"]) > self.clock() else "checking" if delta.get("checking") else "open"
        entry["receipt"] = self.receipt(request, "accepted", "checking" if action == "done" else current)
        self.session.write(state)
        return entry["receipt"]

    @staticmethod
    def recovered(source, entry):
        route = entry["route"]
        if route["source"] == "mailbox":
            return any(row.get("delivery_id") == entry["delivery"] and row.get("re") == route["ask"]
                       for box in source["mailboxes"] if box["destination"] == route["destination"] and box["root"] == route["root"]
                       for row in box["inward"]["rows"])
        tracker = source["tracker"]
        return tracker is not None and tracker["workspace"] == route["workspace"] and any(
            row["user_id"] == entry["actor"] and row["parent_id"] == route["thread"] and row["body"] == entry["body"]
            for issue in tracker["issues"] if issue["uuid"] == route["issueUuid"] for row in issue["comments"])


def main(args, session_type, refusal_type):
    try:
        session = session_type(args.home)
        session.path = session.path.with_name("owner-asks.json")
        session.deadline = time.monotonic() + CALL_SECONDS
        settings = watch.config(session.env["JARVIS_BASH"], session.home)
        role = watch.role(settings)
        data = sys.stdin.read() if args.action != "list" else None
        if role.kind == "invalid":
            raise Unavailable("The main-home setting is invalid.")
        if role.kind == "satellite":
            if os.environ.get("JARVIS_OWNER_ASK_MAIN"):
                raise Unavailable("The selected main is configured as a satellite.")
            argv = [args.action]
            if args.action == "list":
                argv += ["--view", args.view]
                if args.cursor is not None:
                    argv += ["--cursor", args.cursor]
            else:
                argv += ["--id", args.id]
            cause, result = forward.host_call(role, session.deadline, MAIN, argv, data)
            if cause != "ok":
                raise source_failure("main-home", role.dest + ":" + role.home,
                                     watch.Failure("main-home", "transport", cause, result))
            # The main prints the same bounded public response. No local
            # copy of its state or interpretation of its receipt is kept.
            sys.stdout.write(result.stdout)
            sys.stderr.write(result.stderr)
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
                result = owner.action(state, args.action, args.id, request)
        print(encoded(result))
        return 0
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, OverflowError, watch.DestinationRefusal, refusal_type) as error:
        diagnostic(error, "owner-asks-" + args.action)
        cause = str(error) if isinstance(error, Unavailable) else "The owner-ask operation could not read its required evidence."
        print(encoded({"v": 1, "kind": "unavailable", "cause": cause}))
        return 1
