"""The main home's owner-ask pages and action deltas, never a source replica."""

import base64
import datetime
import hashlib
import json
import os
import re
import shlex
import sys
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
# KEN-5390 adds Reply and Done; until then every row reports them refused.
UNBUILT = "Reply and Done are not available yet; KEN-5390 adds them."
# The caller's mailbox code over each root's data. Each registered root
# answers one record and each distinct mailbox one read, so the caller can
# prove the read complete. jq carries every path and payload as a JSON
# string: the line framing never meets a path's own bytes, and jq -c leaves
# U+2028/U+2029 raw in strings, so each record ends at LF only.
MAILBOX_READS = r"""set -euo pipefail
mail=$1
shift
. "${mail%/*}/lib/common-root.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "${work:?}"' EXIT
seen=()
for root in "$@"; do
  # A folder outside any git repository holds no overseer mailbox; lane-mail
  # refuses root-unresolved there. Git's discovery failure is the die text in
  # its setup.c, read untranslated; any other failure refuses the read.
  if ! probe="$(LC_ALL=C git -C "$root" rev-parse --is-inside-work-tree 2>&1 >/dev/null)"; then
    case "$probe" in
      'fatal: not a git repository (or any '* | *$'\n''fatal: not a git repository (or any '*)
        jq -cn --arg root "$root" '{registered: $root, mailbox: null}'
        continue ;;
    esac
    printf '%s\n' "$probe" >&2
    exit 1
  fi
  # The sentinel keeps a path's own trailing line feeds; the function adds one.
  common="$(mailbox_common_root "$root" && printf .)"
  common="${common%.}"
  common="${common%$'\n'}"
  jq -cn --arg root "$root" --arg mailbox "$common" '{registered: $root, mailbox: $mailbox}'
  for known in ${seen[@]+"${seen[@]}"}; do
    [ "$known" != "$common" ] || continue 2
  done
  seen+=("$common")
  cd -- "$common"
  "$BASH" "$mail" pending --item overseer --root "$common" --to owner >"$work/pending"
  "$BASH" "$mail" events --item overseer --root "$common" --box to-overseer >"$work/outward"
  jq -cn --arg root "$common" --rawfile pending "$work/pending" --rawfile outward "$work/outward" \
    '{root: $root, pending: $pending, outward: $outward}'
done
"""
MAIN = '''set -euo pipefail
cd -- "$1"
home=$1
shift
exec env JARVIS_OWNER_ASK_MAIN=1 "$BASH" .agents/skills/jarvis/scripts/jarvis-session owner-asks "$@" --home "$home"
'''


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


class Sources:
    """The one owner of every owner-ask source read.

    Each command is the caller's own package code with the caller's settings,
    run as the destination's account. A destination supplies data alone: its
    project registry and each root's mailbox files. Linear runs on the main,
    beside the caller's credentials."""

    def __init__(self, session, settings):
        self.session, self.settings = session, settings
        # Encoded once; a host read sends it once per destination and collect.
        self.closure = None

    def call(self, target, root, package, script, args=(), shell_args=()):
        operation = package + "/" + script
        place = target.key + (":" + str(root) if root is not None else "")
        name = package + "/scripts/" + script
        try:
            if target.host:
                # Only mailbox code runs on a host: lane-mail and its library.
                if self.closure is None:
                    self.closure = watch.package_files(watch.MAILBOX_FILES)
                command, payload = watch.remote_command(self.closure, name, args, stdin=True, shell_args=shell_args)
                result = watch.run(watch.host_args(target, "bash -c " + shlex.quote(command)), data=payload,
                                   operation=operation, timeout=self.remaining())
            else:
                result = watch.run([self.session.env["JARVIS_BASH"], *shell_args, watch.LIB.parents[2] / name, *args],
                                   root or self.session.home, operation=operation, timeout=self.remaining())
            if result.returncode:
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
        """Each distinct overseer mailbox of ROOTS with its raw reads, in one call per destination."""
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
                outward = self.events(record["outward"])
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
                        links[ask["id"]] = {"url": comment["url"]}
                mailboxes.append({"destination": target.key, "root": record["root"], "asks": asks,
                                  "outward": outward, "posted": posted, "links": links})
        return {"config": config, "tracker": tracker, "mailboxes": mailboxes}

    def stable(self):
        first, second = self.collect(), self.collect()
        if digest(first) != digest(second):
            raise Unavailable("The request sources changed during the read; refresh from the first page.")
        return second


def source_rows(source):
    rows, mirrors = {}, set()

    def add(identity, kind, what, author, at, link, thread):
        instant(at)
        if not printable(author["id"]) or not printable(author["name"]) or not http(link["url"]):
            raise Unavailable("An original request author or conversation link is not confirmed.")
        key = digest(identity)
        if key in rows:
            raise Unavailable("The request source contains an ambiguous duplicate identity.")
        rows[key] = {"id": key, "kind": kind, "what": what, "askedBy": author, "askedAt": at,
                     "link": link, "threadRef": digest(thread)}

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
            identity = ["mailbox", destination, root, ask["id"]]
            add(identity, "fleet-approval" if ask.get("draft") else "jarvis-ask",
                ask["text"], {"id": ask["from"], "name": ask["from"]}, ask["at"],
                {"label": "Original ask", "url": link["url"]}, identity)
    tracker = source["tracker"]
    if tracker is not None:
        for request in tracker["requests"]:
            comment = request["comment"]
            identity = (tracker["workspace"], request["issueUuid"], comment["id"])
            if identity in mirrors:
                continue
            add(["linear", *identity], "tracker-item", comment["body"], {"id": comment["user_id"], "name": comment["user"]},
                comment["created_at"], {"label": request["issue"], "url": comment["url"]},
                ["linear", tracker["workspace"], request["issueUuid"], request["thread"]])
    return rows


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
        rows = source_rows(source)
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
            until = state["deltas"].get(key, {}).get("until")
            snoozed = until is not None and instant(until) > now
            row.update(state="snoozed" if snoozed else "open", snoozedUntil=until if snoozed else None,
                       actions={"reply": {"allowed": False, "reason": UNBUILT},
                                "done": {"allowed": False, "reason": UNBUILT},
                                "later": {"allowed": True, "reason": ""}})
        revision = digest([state["homeId"], source, state["sequence"], rows])
        for row in rows.values():
            row["revision"] = revision
        return rows, revision, now

    def page(self, state, view, cursor):
        rows, revision, now = self.current(state)
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

    def later(self, state, key, request):
        payload = {"action": "later", "id": key, "request": request}
        previous = state["requests"].get(request["requestId"])
        if previous is not None:
            if previous["payload"] != payload:
                return self.receipt(request, "refused", None, "This request identity already names different content.")
            return previous["receipt"]
        rows, revision, now = self.current(state)
        row = rows.get(key)

        def settle(kind, cause=""):
            receipt = self.receipt(request, kind, "snoozed" if kind == "accepted" else row["state"] if row else None, cause)
            state["requests"][request["requestId"]] = {"payload": payload, "receipt": receipt}
            self.session.write(state)
            return receipt

        if row is None:
            return settle("refused", "This ask is no longer open in the canonical source.")
        if request["expectedRevision"] != revision:
            return settle("refused", "The ask list changed; refresh it before acting.")
        try:
            if instant(request.get("until")) <= now:
                raise ValueError("past")
        except (ValueError, TypeError, OverflowError):
            return settle("refused", "Choose a future absolute time with a timezone offset.")
        state["sequence"] += 1
        state["deltas"][key] = {"until": request["until"]}
        return settle("accepted")


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
                result = owner.later(state, args.id, request)
        print(encoded(result))
        return 0
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, OverflowError, watch.DestinationRefusal, refusal_type) as error:
        diagnostic(error, "owner-asks-" + args.action)
        cause = str(error) if isinstance(error, Unavailable) else "The owner-ask operation could not read its required evidence."
        print(encoded({"v": 1, "kind": "unavailable", "cause": cause}))
        return 1
