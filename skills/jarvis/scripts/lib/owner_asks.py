"""The main home's owner-ask pages and action deltas, never a source replica."""

import base64
import datetime
import hashlib
import json
import os
import re
from pathlib import Path
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
    """Compose only public mailbox, Linear, Slack and project-discovery owners."""

    def __init__(self, session, settings):
        self.session, self.settings = session, settings

    def call(self, target, root, package, script, args=(), data=None, check=True):
        operation = package + "/" + script
        destination = target.key + ":" + str(root)
        packages = watch.LIB.parents[2]
        shell_args = (["-c", 'source "$1"; mailbox_common_root "$2"', "owner-asks"]
                      if operation == "mailbox/lib/common-root.sh" else [])
        try:
            files = {}
            if target.host:
                # All dependencies come from the caller's declared packages,
                # including sibling reads made by Linear and Slack themselves.
                for name in ("mailbox", "linear", "slack"):
                    directory = packages / name / "scripts"
                    for path in directory.rglob("*"):
                        if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc":
                            files[str(path.relative_to(packages))] = base64.b64encode(path.read_bytes()).decode()
                for name in ("orch/scripts/lib/kendex-env.sh", "orch/references/secret-value.ere"):
                    files[name] = base64.b64encode((packages / name).read_bytes()).decode()
            command, payload = watch.remote_command(files, package + "/scripts/" + script, args,
                                                    data=data, stdin=True, shell_args=shell_args,
                                                    local_root=None if target.host else packages)
            if target.host:
                role = watch.Role("satellite", target.host, str(root))
                cause, result = forward.host_call(role, self.session.deadline,
                                                  'set -euo pipefail\ncd -- "$1"\n' + command, [], payload)
                if cause != "ok":
                    raise watch.Failure(operation, "transport", cause, result)
            else:
                result = watch.run([self.session.env["JARVIS_BASH"], "-c", command], root, payload,
                                   operation=operation, timeout=self.remaining())
            if check and result.returncode:
                raise watch.child_failure(operation, result)
            return result
        except (OSError, watch.Failure) as error:
            raise source_failure(operation, destination, error) from error

    def remaining(self):
        remaining = self.session.deadline - time.monotonic()
        if remaining <= 0:
            raise Unavailable("The request read reached its deadline.")
        return remaining

    def value(self, target, root, package, script, args=(), data=None):
        result = self.call(target, root, package, script, args, data)
        try:
            return json.loads(result.stdout)
        except ValueError as error:
            raise source_failure(package + "/" + script, target.key + ":" + str(root), error) from error

    def events(self, target, root, box):
        result = self.call(target, root, "mailbox", "lane-mail", ["events", "--item", "overseer", "--box", box])
        lines = result.stdout.splitlines()
        if not lines or watch.mailbox_header(lines[0]) is None:
            raise Unavailable("The original mailbox read is incomplete.")
        return {"header": lines[0], "rows": [json.loads(line) for line in lines[1:]]}

    def collect(self):
        local = watch.Destination("local", None)
        config = self.value(local, self.session.home, "mailbox", "owner-tracker-settings")
        tracker = None
        if config["configured"]:
            tracker = self.value(local, self.session.home, "linear", "linear.sh",
                                 ["comments", "owner-requests", "--email", config["email"], "--label", config["label"]])
        elif config["cause"] != "settings-unset":
            raise Unavailable("The owner tracker settings could not be read.")
        mailboxes = []
        for target in watch.destinations(self.settings):
            try:
                roots = watch.destination_roots(target, timeout=self.remaining(), complete=True)
            except watch.Failure as error:
                raise source_failure("project-list", target.key, error) from error
            if not target.host and self.session.home not in roots:
                roots.append(self.session.home)
            canonical = set()
            for root in roots:
                root = self.call(target, root, "mailbox", "lib/common-root.sh", [root]).stdout.strip()
                if root in canonical:
                    continue
                canonical.add(root)
                pending = self.call(target, root, "mailbox", "lane-mail", ["pending", "--item", "overseer", "--to", "owner"])
                asks = [json.loads(line) for line in pending.stdout.splitlines()]
                outward, inward = self.events(target, root, "to-overseer"), self.events(target, root, "to-lane")
                posted, links = {}, {}
                # Retained closed asks still own their exact tracker mirror;
                # a delayed label update must not resurrect that mirror.
                for ask in outward["rows"]:
                    if ask.get("tracker_posted") is not True or not ask.get("tracker_comment"):
                        continue
                    issue = ask["issue"]
                    if issue not in posted:
                        workspace = self.value(target, root, "linear", "linear.sh", ["teams", "keys"])["urlKey"]
                        item = self.value(target, root, "linear", "linear.sh", ["issues", "get", issue, "--format=safe"])
                        comments = self.value(target, root, "linear", "linear.sh", ["comments", "list", issue, "--format=safe"])
                        posted[issue] = {"workspace": workspace, "uuid": item["uuid"], "comments": comments}
                    comment = next((row for row in posted[issue]["comments"] if row["id"] == ask["tracker_comment"]), None)
                    if comment is not None:
                        links[ask["id"]] = {"url": comment["url"], "thread": comment["parent_id"] or comment["id"]}
                need_links = [ask["id"] for ask in asks if ask["id"] not in links]
                if need_links:
                    links.update(self.value(target, root, "slack", "slack", ["ask-links", "--root", root], encoded(need_links)))
                mailboxes.append({"destination": target.key, "root": root, "asks": asks,
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
        target = watch.Destination(route["destination"], route.get("host"))
        if route["source"] == "mailbox":
            result = forward.owner_note.send(self.session.env["JARVIS_BASH"], "host" if target.host else "local",
                                             target.host, route["root"], text,
                                             options=["--re", route["ask"], "--delivery-id", key],
                                             timeout=self.remaining(), check=False)
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
                               check=False)
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
        closed_keys = []
        for key, delta in state["deltas"].items():
            route = delta["route"]
            if key not in rows:
                if route["source"] == "mailbox":
                    closed = any(row.get("mail_class") == "close" and row.get("re") == route["ask"]
                                 for box in source["mailboxes"] if box["destination"] == route["destination"] and box["root"] == route["root"]
                                 for row in box["inward"]["rows"])
                    if not closed:
                        raise Unavailable("The original mailbox no longer proves this acted-on ask; ask the delegate to verify it.")
                # A complete configured tracker view alone owns membership.
                closed_keys.append(key)
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
            local = watch.Destination("local", None)
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
        delta = state["deltas"].setdefault(key, {"route": entry["route"]})
        if action == "done":
            delta["checking"] = True
            # Confirming an older delivery cannot undo a newer visibility
            # choice. Legacy intents precede sequenced actions in this home.
            if delta.get("until_sequence", 0) <= entry.get("sequence", 0):
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
