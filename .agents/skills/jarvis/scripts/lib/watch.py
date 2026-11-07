"""Jarvis mail acquisition and the single durable event-batch owner."""
import argparse
import base64
from collections import namedtuple
from concurrent.futures import ThreadPoolExecutor
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import subprocess
import sys
import tempfile
import time
import uuid

LIB = Path(__file__).resolve().parent
CAP = 60 * 1024
# This loop's own batch directives carry this delivery-key prefix.
BATCH_KEY = "jarvis-"
# The owner's note fixes both numbers; no consumer has asked to tune them.
OWNER_WAIT_SECS = 600
UNANSWERED_EVERY_SECS = 300
FORWARD_EVERY_SECS = 60
# A machine's role from JARVIS_MAIN_HOST: kind main, satellite or invalid. An
# invalid value is still a satellite, so a typo never makes a second main.
Role = namedtuple("Role", "kind dest home")
Destination = namedtuple("Destination", "key host")


class DestinationRefusal(Exception):
    """A destination selection refusal: key, value and optional cause."""


def destinations(settings):
    """The main's declared machines; a satellite never discovers fleet roots."""
    local = Destination("local", None)
    if role(settings).kind != "main":
        return (local,)
    hosts = []
    control = settings.get("JARVIS_CONTROL_HOST", "")
    if control:
        hosts.append(control)
    for host in settings.get("JARVIS_REMOTE_HOSTS", "").split():
        if not re.fullmatch(r"[^\s:/-][^\s:/]*", host):
            raise DestinationRefusal("setting-invalid", "JARVIS_REMOTE_HOSTS", host)
        if host not in hosts:
            hosts.append(host)
    return (local, *(Destination("ssh:" + host, host) for host in hosts))


def destination_roots(destination):
    if destination.host:
        return listed_roots(checked(["ssh", destination.host, "kendex project list"], operation="project-list"))
    return listed_roots(checked(["kendex", "project", "list"], operation="project-list"))


def note_routes(settings, repo, host=None, local=False):
    """Select without sending; only the legacy route discovers its fallback lazily."""
    declared = destinations(settings)
    if host is not None or local:
        key = "ssh:" + host if host is not None else "local"
        selected = [target for target in declared if target.key == key]
        if not selected:
            raise DestinationRefusal("destination-unknown", host)
    else:
        selected = list(declared)
    legacy = host is None and not local and len(declared) == (2 if settings.get("JARVIS_CONTROL_HOST") else 1)
    if legacy:
        selected.reverse()
    matches = []
    for target in selected:
        try:
            roots = [root for root in destination_roots(target) if root.rstrip("/").rsplit("/", 1)[-1] == repo]
        except Failure as error:
            side = "host" if legacy and target.host else target.key
            raise DestinationRefusal("project-list-failed", side, str(error)) from error
        if len(roots) > 1:
            raise DestinationRefusal("repo-ambiguous", repo, "destination=%s roots=%s" % (target.key, " ".join(roots)))
        if legacy:
            if roots:
                yield target, roots[0], True
        else:
            matches.extend((target, root) for root in roots)
    if not legacy:
        if len(matches) > 1:
            raise DestinationRefusal("repo-ambiguous", repo, " ".join("%s:%s" % (target.key, root) for target, root in matches))
        yield from ((target, root, False) for target, root in matches)


class Failure(RuntimeError):
    """Stable operation identity, separate from the first useful diagnostic."""
    def __init__(self, operation, category, code, detail):
        self.record = {"key": [operation, category, str(code)], "detail": str(detail)}
        super().__init__(str(detail))


def failure(operation, error):
    if isinstance(error, Failure):
        return error
    category = "timeout" if isinstance(error, subprocess.TimeoutExpired) else type(error).__name__
    return Failure(operation, category, getattr(error, "errno", None), str(error))


def child_failure(operation, result):
    detail = result.stderr.strip() or "child exit=" + str(result.returncode)
    # Our transported pass carries its typed result. CLI refusal keys are
    # machine fields on the first line, never English traceback classification.
    first = detail.split("\n", 1)[0]
    if first.startswith("jarvis: failure="):
        record = json.loads(first[len("jarvis: failure="):])
        return Failure(*record["key"], record["detail"])
    # owner-note and forward prefix the refusals their host scripts print.
    keyed = re.match(r"^(?:lane-mail|kendex|jarvis|owner-note|forward): ([a-z][a-z0-9-]*)=", first)
    return Failure(operation, "refusal" if keyed else "exit",
                   keyed[1] if keyed else result.returncode, detail)


def run(args, cwd=None, data=None, operation=None, timeout=60):
    try:
        return subprocess.run(list(map(str, args)), cwd=cwd, input=data,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        raise failure(operation or Path(args[0]).name, error) from error


def checked(args, cwd=None, data=None, operation=None, timeout=60):
    operation = operation or Path(args[0]).name
    result = run(args, cwd, data, operation, timeout)
    if result.returncode:
        raise child_failure(operation, result)
    return result.stdout


def epoch():
    return int(checked(["date", "+%s"]).strip())


def instant(value):
    """A mailbox `at` stamp, YYYY-MM-DDTHH:MM:SSZ, as an aware UTC time."""
    return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)


def home_root(path):
    path = Path(path).resolve()
    result = run(["git", "rev-parse", "--show-toplevel"], path)
    return Path(result.stdout.strip()).resolve() if result.returncode == 0 else path


def owner_row(envelope):
    """An owner message in the home inbox, read from lane-mail's events record.

    The relay keys each owner send; this loop's own batches are not owner mail.
    """
    key = envelope.get("delivery_id")
    return (envelope.get("from") == "owner" and envelope.get("mail_class") in ("owner-note", "resolution")
            and isinstance(key, str) and bool(key) and not key.startswith(BATCH_KEY))


def config(bash, root):
    return json.loads(checked([bash, LIB / "jarvis-env.sh", "config", root]))


def role(settings):
    """JARVIS_MAIN_HOST, empty or DEST:/abs/home, as this machine's Role."""
    value = settings["JARVIS_MAIN_HOST"]
    if not value:
        return Role("main", None, None)
    match = re.fullmatch(r"([^\s:/-][^\s:/]*):(/.*)", value)
    if not match or not match[2].isprintable():
        return Role("invalid", None, None)
    return Role("satellite", match[1], match[2])


def line_value(value, token=False, limit=None):
    # Ordinary source code is data. Only protocol controls become escapes.
    result, used = [], 0
    text = str(value)
    for index, char in enumerate(text):
        units = []
        if not token and (index == 0 or text[index-1] == "\n") and text.startswith(("EVENT ", "cursor:"), index):
            units.append(" ")
        code = ord(char)
        if (char != "\n" or token) and (code < 32 or 127 <= code < 160 or (token and char.isspace())):
            unit = {"\n": r"\n", "\r": r"\r", "\t": r"\t"}.get(char, "\\u%04x" % code)
        elif token and char == " ":
            unit = r"\u0020"
        else:
            unit = char
        units.append(unit)
        size = sum(map(len, units))
        if limit is not None and used + size > limit:
            break
        result.extend(units)
        used += size
    return "".join(result)


def event(header, **fields):
    return "EVENT " + header + "".join(" %s=%s" % (key, line_value(value, True)) for key, value in fields.items()) + "\n"


def report_key(text):
    match = re.fullmatch(r"EVENT report-due reason=(minutes|issues) since=(\S+)( landed=\d+)?\n", text)
    if not match:
        raise Failure("report-due", "protocol", "due-unread", "due-unread")
    return hashlib.sha256(match[2].encode()).hexdigest()


def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as out:
        temporary = Path(out.name)
        try:
            json.dump(value, out)
            out.flush()
            os.fsync(out.fileno())
        except BaseException:
            temporary.unlink()
            raise
    try:
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def permission_after_failure(permitted, error):
    # A failed permission probe must not become ordinary inactivity on retry.
    if isinstance(error, Failure) and error.record["key"][0] == "presence-live":
        raise error
    return permitted()


def hold(root, permitted):
    if not permitted():
        return "skipped"
    # Code comes from the producer's declared siblings. Targets are data.
    packages = LIB.parents[2]
    owner = packages / "slack/scripts/lib"
    code = """import json,os,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
os.environ["SLACK_ORCH_DIR"]=sys.argv[2]
from settings import load_presence
from refusals import Refusal
try:
 print(json.dumps({"path":load_presence(Path(sys.argv[3])).jarvis_session_file}))
except Refusal as error:
 print(json.dumps({"failure":{"key":["presence-settings","refusal",error.key],"detail":str(error)}}))
"""
    try:
        record = json.loads(checked([sys.executable, "-B", "-c", code, owner,
                                     packages / "orch", root], operation="presence-settings"))
        if "failure" in record:
            error = record["failure"]
            raise Failure(*error["key"], error["detail"])
        value = record["path"]
        at = epoch() if value else None
        # No external command may follow this final permission before touch.
        if not permitted():
            return "skipped"
        if value:
            path = Path(value)
            with path.open("a"):
                os.utime(path, (at, at))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        if not permission_after_failure(permitted, error):
            return "skipped"
        raise failure("presence-hold", error) from error
    return "ok"


def listed_roots(text):
    """The folders `kendex project list` prints, skipping rows that carry a note."""
    return [line.strip() for line in text.split("\n") if line.strip() and "(" not in line]


def project_roots():
    try:
        roots = destination_roots(Destination("local", None))
    except Failure as error:
        raise Failure(*error.record["key"], "kendex-missing fix=install-kendex-on-host-PATH " + str(error)) from error
    return [Path(root).expanduser().resolve() for root in roots]


def presence_roots(permitted):
    if not permitted():
        return [(None, "skipped", None)]
    results = []
    for root in project_roots():
        try:
            results.append((str(root), hold(root, permitted), None))
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            results.append((str(root), "failed", failure("presence-hold", error).record))
    return results


def pass_output(side, roots, events):
    body, origins, size = [], [], 0
    for root, block, *binding in events:
        if root is not None:
            header, separator, tail = block.partition("\n")
            block = header + " destination=" + line_value(side, True) + " root=" + line_value(binding[0] if binding else root, True) + separator + tail
        end = size + len(block.encode())
        origins.append([size, end, str(root)] if root is not None else [size, end, None])
        body.append(block)
        size = end
    record = {"side": side, "roots": roots, "event_bytes": size, "origins": origins}
    return "".join(body) + "cursor: " + json.dumps(record, separators=(",", ":")) + "\n"


def lane_mail():
    """The producer's own mailbox code; a target's installed copy is never run."""
    return LIB.parents[2] / "mailbox/scripts/lane-mail"


def mailbox_header(line):
    """The `count=N first=ID` header lane-mail's drain and events print, as (count, first), or None."""
    match = re.fullmatch(r"count=(\d+) first=(\S*)", line)
    return (int(match[1]), match[2]) if match else None


def mailbox_receipts(lines):
    """`drain --receipts` output as (index, cursor, count, rows).

    index is the receipts line's, cursor its value or None where it reads
    `missed`, count to-lane's logical line count, and rows each listed
    directive as (line, id, epoch), epoch None where its `at` did not parse.
    """
    index = next((i for i, row in enumerate(lines) if row.startswith("receipts ")), None)
    match = re.fullmatch(r"receipts cursor=(\d+|missed) count=(\d+) first=\S*", lines[index]) if index is not None else None
    if not match:
        raise Failure("mailbox-read", "protocol", "receipts-unread", "receipts-unread")
    rows = []
    for row in lines[index + 1:]:
        parts = row.split(" ")
        if len(parts) == 3 and parts[0].isdigit() and (parts[2].isdigit() or not parts[2]):
            rows.append((int(parts[0]), parts[1], int(parts[2]) if parts[2] else None))
    return index, None if match[1] == "missed" else int(match[1]), int(match[2]), rows


def send_receipt(result, key):
    """A `lane-mail send --delivery-id KEY` result as (id, repeated), or None with no receipt.

    A new append prints `sent` and exits 0; a key the mailbox already holds
    refuses `delivery-repeated`, naming the envelope that landed.
    """
    if result.returncode == 0:
        match = re.search(r"^lane-mail: sent item=overseer id=([^\s]+)(?:\s|$)", result.stdout, re.M)
    else:
        match = re.search(r"^lane-mail: delivery-repeated=" + re.escape(key) + r" id=([^\s]+)(?:\s|$)",
                          result.stderr, re.M)
    return (match[1], result.returncode != 0) if match else None


def mailbox_events(bash, root, box, after=0, mark_read=False):
    """One `lane-mail events --item overseer --box` read in root, as (count, rows)."""
    operation = "mailbox-events-" + box
    args = [bash, lane_mail(), "events", "--item", "overseer", "--box", box, "--after", str(after)]
    if mark_read:
        args.append("--mark-read")
    lines = checked(args, root, operation=operation).split("\n")
    header = mailbox_header(lines[0])
    if not header:
        raise Failure("mailbox-read", "protocol", "events-header-unread", "events-header-unread")
    return header[0], [json.loads(row) for row in lines[1:] if row]


def owner_unread(bash, root, cursor, count, now, reported, events):
    """Owner rows past the home receipt cursor for OWNER_WAIT_SECS, each reported once."""
    if count <= cursor:
        return []
    _, rows = mailbox_events(bash, root, "to-lane", cursor)
    owned = [row for row in rows if owner_row(row) and now - instant(row["at"]).timestamp() >= OWNER_WAIT_SECS]
    events.extend(event("owner-unread", id=row["id"], at=row["at"])
                  for row in owned if row["id"] not in reported)
    return [row["id"] for row in owned]


def mailbox_root(bash, root):
    """The checkout whose overseer mailbox lane-mail reads at root."""
    if not root.is_dir():
        raise Failure("root-read", "missing", "root", "root-missing")
    if not lane_mail().is_file():
        raise Failure("root-read", "missing", "mailbox", "dependency=mailbox-missing")
    return Path(checked([bash, LIB / "jarvis-env.sh", "common-root", root], operation="common-root").strip())


def mailbox_readers(bash, roots):
    """Each root as (root, mailbox checkout or read failure, the root that reads that mailbox).

    A project registered inside another's git tree resolves to the outer
    mailbox. The mailbox's own checkout reads it, else the first listed
    root; a failed root reads for itself, to report the failure. A listed
    home is always its mailbox's own checkout: home_root takes its git top
    level, and `kendex project list` notes a linked worktree, which
    listed_roots skips.
    """
    resolved = []
    for root in roots:
        try:
            resolved.append((root, mailbox_root(bash, root)))
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            resolved.append((root, failure("root-read", error)))
    reader = {}
    for index, (root, common) in enumerate(resolved):
        if isinstance(common, Path):
            rank = (root != common, index)
            if common not in reader or rank < reader[common][0]:
                reader[common] = (rank, root)
    return [(root, common, reader[common][1] if isinstance(common, Path) else root) for root, common in resolved]


def mailbox_cursor(state, key, mailbox, own_lane):
    """The record of root key as the reader of mailbox, its cursors handed over from the last reader.

    The last reader's record carries `mailbox`. Its box cursors and unread
    marker follow the mailbox, so a new reader delivers no row twice. A
    record no reader carries keeps its own. With own_lane the to-lane
    cursor stays the root's own: a local home's to-lane read emits no
    event, so rereading from its own cursor repeats none, and it delivers
    the owner rows a stand-in's to-lane read, which emits answers alone,
    skipped.
    """
    record = dict(state.get(key, {}))
    last = next((other for other, value in state.items() if other != key and value.get("mailbox") == mailbox), None)
    if last is not None:
        for field in ("to-overseer", "unread") if own_lane else ("to-lane", "to-overseer", "unread"):
            if field in state[last]:
                record[field] = state[last][field]
            else:
                record.pop(field, None)
        state[last] = {field: value for field, value in state[last].items() if field != "mailbox"}
    record["mailbox"] = mailbox
    return record


def mail_pass(bash, home, side, cursor, delivered=None, satellite=False):
    """One pass over every root. A local home read adds each owner row it reads to delivered.

    A satellite is no fleet contact: it reads its own home alone, as a
    registered home, so its session gets its own mail and owner-unread.
    """
    state = json.loads(json.dumps(cursor))
    events = []
    now = epoch()
    roots = [home] if satellite else project_roots()
    # A home the project list omits (unregistered, removed, or a noted
    # worktree row) still receives owner mail. Its to-lane alone is read for
    # those rows: no mail event, no to-overseer mark-read, no receipts.
    alone = side == "local" and home not in roots
    readers = mailbox_readers(bash, roots)
    if alone:
        # Its to-lane read takes owner rows alone, so it never replaces a
        # listed root's full read of a shared mailbox, nor takes its cursors.
        readers += mailbox_readers(bash, [home])
    for root, common, reader in readers:
        if reader != root:
            continue
        boxes = ("to-lane",) if alone and root == home else ("to-lane", "to-overseer")
        key = str(root)
        prior = state.get(key, {})
        if isinstance(common, Path) and len(boxes) > 1:
            prior = mailbox_cursor(state, key, str(common), side == "local" and root == home)
        next_root = json.loads(json.dumps(prior))
        cause = None
        root_events, root_delivered = [], []
        try:
            if not isinstance(common, Path):
                raise common
            for box in boxes:
                before = prior.get(box, {})
                filename = common / "tmp/lane-mail/overseer" / (box + ".jsonl")
                size_read = run(["wc", "-c", str(filename)])
                size = int(size_read.stdout.split()[0]) if size_read.returncode == 0 else None
                if size is not None and size == before.get("size"):
                    continue
                count, envelopes = mailbox_events(bash, root, box, before.get("count", 0),
                                                  mark_read=box == "to-overseer")
                next_root[box] = {"count": count, "size": size}
                for envelope in envelopes:
                    if box == "to-lane":
                        if side == "local" and root == home:
                            if owner_row(envelope):
                                root_delivered.append({"id": envelope["id"], "at": envelope["at"]})
                            continue
                        if envelope.get("kind") != "answer":
                            continue
                        metadata = "%s %s re %s" % tuple(line_value(value, True) for value in
                            (envelope["id"], envelope["kind"], envelope.get("re", "")))
                    else:
                        if envelope.get("to") != "owner":
                            continue
                        metadata = "%s %s to=owner ref=%s options=%s recommend=%s deadline=%s" % tuple(line_value(value, True) for value in (
                            envelope["id"], envelope["kind"], envelope.get("ref") or "",
                            ",".join(envelope.get("options") or []), envelope.get("recommend") or "", envelope.get("deadline") or ""))
                    text = line_value(envelope.get("text", ""), limit=4000)
                    root_events.append((root, event("mail", repo=root.name, file=box) + metadata + "\n" + text + "\n"))
            if len(boxes) > 1:
                receipts = checked([bash, lane_mail(), "drain", "--item", "overseer", "--after", "0", "--receipts"], root, operation="mailbox-receipts").split("\n")
                _, cursor_read, lane_count, listed = mailbox_receipts(receipts)
                if cursor_read is None:
                    raise Failure("mailbox-read", "protocol", "receipts-missed", "receipts-missed")
                unread = [row for row in listed if row[2] is not None and row[0] > cursor_read]
                if side == "local" and root == home:
                    # Only the home inbox's receipts say whether owner mail was read.
                    unread_events = []
                    owned = owner_unread(bash, root, cursor_read, lane_count, now,
                                         prior.get("owner_unread", []), unread_events)
                    # Page admission binds the shared mailbox; batch origins
                    # and acquisition cursors still belong to this home.
                    root_events.extend((common, block) for block in unread_events)
                    if owned:
                        next_root["owner_unread"] = owned
                    else:
                        next_root.pop("owner_unread", None)
                if unread and now - int(unread[0][2]) >= 900:
                    oldest = unread[0][1]
                    if prior.get("unread") != oldest:
                        root_events.append((root, event("overseer-unread", repo=root.name, unread=len(unread),
                                                       oldest=oldest, age=str((now-int(unread[0][2]))//60) + "min")))
                    next_root["unread"] = oldest
                else:
                    next_root.pop("unread", None)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            cause = failure("root-read", error).record
        if cause:
            if not isinstance(prior.get("cause"), dict) or prior["cause"].get("key") != cause["key"]:
                events.append((root, event("root-unreachable", repo=root.name, cause=cause["detail"])))
                next_root = dict(prior, cause=cause)
            else:
                next_root = prior
            # A failed root read commits neither of its box cursors.
        else:
            next_root.pop("cause", None)
            events.extend((root, block, binding) for binding, block in root_events)
            if delivered is not None:
                delivered.extend(root_delivered)
        state[key] = next_root
    # A root whose mailbox another root reads has no read outcome of its
    # own: its record takes the reader's outcome from this pass, so no field
    # goes stale while the other root reads.
    for root, _, reader in readers:
        if reader != root:
            read = state[str(reader)]
            record = {"cause": read["cause"]} if "cause" in read else {}
            if record or str(root) in state:
                state[str(root)] = record
    return pass_output(side, state, events)


def decode_log(data, offset):
    """One LF decoder for committed pass bytes and consumer blocks.

    The append lock makes a producer footer and its events one snapshot.
    Origins come only from that footer; old and consumer bytes stay unknown.
    """
    blocks, records = [], []
    opened = None
    position = offset
    for part in data.split(b"\n")[:-1]:
        boundary = part.startswith((b"EVENT ", b"cursor:"))
        if boundary and opened is not None:
            blocks.append([opened, position])
            opened = None
        if part.startswith(b"EVENT "):
            opened = position
        if part.startswith(b"cursor: "):
            record = json.loads(part[8:])
            records.append((position + len(part) + 1, record))
            start = position - record.get("event_bytes", 0)
            origins = {(start+a, start+b): [record["side"], root]
                       for a, b, root in record.get("origins", []) if root is not None}
            for span in reversed(blocks):
                if span[0] < start:
                    break
                origin = origins.get(tuple(span[:2]))
                if origin is not None:
                    span.append(origin)
        position += len(part) + 1
    return blocks, opened if opened is not None else position, records


def complete_blocks(data, offset):
    blocks, end, _ = decode_log(data, offset)
    return blocks, end


class Watch:
    def __init__(self, home, bash, settings, initial_passes=None):
        self.home, self.bash, self.settings = home, bash, settings
        self.directory = Path(os.path.expanduser(settings["JARVIS_LOG_DIR"]))
        self.directory.mkdir(parents=True, exist_ok=True)
        self.log = self.directory / "events.log"
        self.path = self.directory / "batch.json"
        self.destinations = destinations(settings)
        seeds = self.initial_cursors(initial_passes) if initial_passes is not None else None
        self.state = json.loads(self.path.read_text()) if self.path.exists() else {
            "generation": uuid.uuid4().hex, "offset": 0, "spans": [], "due": None, "pending": None}
        self._saved = json.loads(json.dumps(self.state)) if self.path.exists() else None
        if seeds is not None:
            # Include the whole vector in the first save, even the legacy binding save.
            self.state["cursors"] = seeds
        if not self.state.get("legacy_control_host") and settings.get("JARVIS_CONTROL_HOST"):
            # Old host cursors contain no alias. Keep the original setting
            # through this first upgrade; the frozen binding owns old tails.
            self.state["legacy_control_host"] = settings["JARVIS_CONTROL_HOST"]
            self.save()
        if not self.path.exists():
            self.save()
        self.cursors = self.state.get("cursors", {})
        self.state["cursors"] = self.cursors
        legacy = self.destination_key("host")
        if legacy != "host":
            if "host" in self.cursors:
                self.cursors[legacy] = self.cursors.pop("host")
            if "host_failure" in self.state:
                self.state[legacy + "_failure"] = self.state.pop("host_failure")
            failures = self.state.get("presence_failures", {})
            if "host" in failures:
                failures[legacy] = failures.pop("host")
                if "host" in failures[legacy]:
                    failures[legacy][legacy] = failures[legacy].pop("host")
            self.state["spans"] = [self.canonical_span(span) for span in self.state["spans"]]
        if self.log.exists():
            with self.log.open("rb") as source:
                fcntl.flock(source, fcntl.LOCK_SH)
                self.ingest(source)
        self.save()
        self.next_presence = {}
        self.presence_pending = {}
        self.next_unanswered = 0
        self.unanswered_pending = None
        self.report_pending = None
        self.next_report = 0
        self.relay_pending = None
        self.next_relay = 0
        self.satellite = role(settings).kind != "main"
        self.forward_pending = None
        self.next_forward = 0
        self.mail_pending = {}

    def initial_cursors(self, paths):
        # Explicit adoption cannot enter ordinary migration or log recovery.
        for path in (self.path, self.log):
            if path.exists():
                raise Failure("initial-pass", "refusal", "state-exists", str(path))
        seeds = {}
        for path in paths:
            try:
                data = Path(path).read_bytes()
                _, _, records = decode_log(data, 0)
                if len(records) != 1 or records[0][0] != len(data):
                    raise ValueError("complete single pass required")
                record = records[0][1]
                if record.get("event_bytes") != data.rfind(b"\ncursor: ") + 1 or not isinstance(record.get("roots"), dict):
                    raise ValueError("public pass footer required")
                side, roots = record["side"], record["roots"]
                if not isinstance(side, str):
                    raise ValueError("destination key required")
                if not all(isinstance(root, dict) for root in roots.values()):
                    raise ValueError("root record required")
            except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError) as error:
                raise Failure("initial-pass", "refusal", "pass-unread", "%s: %s" % (path, error)) from error
            if side not in {target.key for target in self.destinations}:
                raise Failure("initial-pass", "refusal", "destination-unknown", "%s: %s" % (path, side))
            if side in seeds:
                raise Failure("initial-pass", "refusal", "destination-repeated", "%s: %s" % (path, side))
            if any("cause" in root for root in roots.values()):
                raise Failure("initial-pass", "refusal", "root-failed", str(path))
            seeds[side] = roots
        return seeds

    def destination_key(self, side):
        host = self.state.get("legacy_control_host")
        return "ssh:" + host if side == "host" and host else side

    def destination(self, side):
        key = self.destination_key(side)
        return next(target for target in self.destinations if target.key == key)

    def canonical_span(self, span):
        if len(span) == 3:
            return [*span[:2], [self.destination_key(span[2][0]), span[2][1]]]
        return span

    def save(self):
        if self.state != self._saved:
            atomic_json(self.path, self.state)
            self._saved = json.loads(json.dumps(self.state))

    def ingest(self, source):
        offset = self.state["offset"]
        checkpoint = self.state.get("cursor_offset", 0)
        start = min(offset, checkpoint) if self.state["pending"] is None else checkpoint
        source.seek(start)
        spans, end, records = decode_log(source.read(), start)
        if self.state["pending"] is None:
            self.state["spans"].extend(self.canonical_span(span) for span in spans if span[0] >= offset)
            self.state["offset"] = end
        for at, record in records:
            if at > checkpoint:
                self.cursors[self.destination_key(record["side"])] = record["roots"]
                self.state["cursor_offset"] = at
        self.state["cursor_offset"] = max(self.state.get("cursor_offset", 0), end)

    def append(self, output):
        data = output.encode()
        _, _, records = decode_log(data, 0)
        if not records or records[-1][0] != len(data):
            raise RuntimeError("pass-incomplete")
        record = records[-1][1]
        if data.startswith(b"cursor: ") and self.cursors.get(record["side"]) == record["roots"]:
            return
        with self.log.open("a+b") as out:
            fcntl.flock(out, fcntl.LOCK_EX)
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
            self.ingest(out)
        self.save()

    def batch(self, now):
        if self.state["pending"] is None:
            if self.log.exists():
                with self.log.open("rb") as source:
                    fcntl.flock(source, fcntl.LOCK_SH)
                    self.ingest(source)
            end = self.state["offset"]
            def block(span, header=False):
                with self.log.open("rb") as source:
                    source.seek(span[0])
                    return source.readline(span[1]-span[0]) if header else source.read(span[1]-span[0])
            eligible = [span for span in self.state["spans"] if not block(span, True).startswith(b"EVENT timeout")]
            self.state["spans"] = eligible
            if not eligible:
                self.state["due"] = None
                self.save()
                return
            if self.state["due"] is None:
                self.state["due"] = now + int(self.settings["JARVIS_WAKE_SETTLE_SECS"])
            if now < self.state["due"]:
                self.save()
                return
            owner = ["local", str(self.home.resolve())]
            ordered = sorted(eligible, key=lambda span: len(span) < 3 or span[2] != owner)
            selected, retained, body = [], [], b""
            full = False
            for span in ordered:
                size = span[1] - span[0]
                if not full and len(body) + size <= CAP:
                    selected.append(span)
                    body += block(span)
                else:
                    full = True
                    retained.append(span)
            if not selected:
                raise RuntimeError("event-too-large limit=61440")
            identity = json.dumps([self.state["generation"], selected]).encode()
            self.state["pending"] = {"key": BATCH_KEY + hashlib.sha256(identity).hexdigest(),
                                     "body": body.decode(), "retained": retained, "end": end}
            # Selection is durable before the mailbox append. A retry uses
            # these bytes even if the event log gained complete new blocks.
            self.save()
        pending = self.state["pending"]
        with tempfile.NamedTemporaryFile(mode="w", dir=self.directory) as payload:
            payload.write(pending["body"])
            payload.flush()
            try:
                result = run([self.bash, lane_mail(), "send", "--item", "overseer",
                              "--directive", "--file", payload.name, "--delivery-id", pending["key"]], self.home)
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                print("watch-loop: send=pending " + str(error), file=sys.stderr)
                return
        receipt = send_receipt(result, pending["key"])
        if not receipt:
            print("watch-loop: send=pending " + result.stderr.strip(), file=sys.stderr)
            return
        self.state.update(spans=[self.canonical_span(span) for span in pending["retained"]], pending=None, due=None)
        self.save()
        print("watch-loop: batch=" + pending["key"] + " id=" + receipt[0] + " inbox=overseer", flush=True)

    def live(self, now=None):
        try:
            result = run([self.bash, LIB / "jarvis-env.sh", "live", self.home])
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            return False
        if result.returncode:
            error = child_failure("presence-live", result)
            if error.record["key"][1:] == ["refusal", "dependency"]:
                raise error
            return False
        try:
            at = datetime.datetime.fromisoformat(result.stdout.strip().replace("Z", "+00:00")).timestamp()
            if now is None:
                now = epoch()
            return 0 <= now - at < 300
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            return False

    def remote_command(self, args):
        # Carry exact dependency bytes, never target-local code or settings.
        files = {"jarvis/scripts/" + name: base64.b64encode((LIB.parent / name).read_bytes()).decode()
                 for name in ("vm-watch.sh", "lib/watch.py", "lib/jarvis-env.sh")}
        packages = LIB.parents[2]
        for name in ("slack/scripts/lib/settings.py", "slack/scripts/lib/refusals.py",
                     "orch/scripts/lib/kendex-env.sh", "mailbox/scripts/lane-mail",
                     "mailbox/scripts/lib/file-lock.sh", "mailbox/scripts/lib/mailbox-append.sh",
                     "mailbox/scripts/lib/common-root.sh", "mailbox/scripts/lib/kendex-env.sh",
                     "mailbox/scripts/lib/lane-mail-store.py"):
            files[name] = base64.b64encode((packages / name).read_bytes()).decode()
        # The mailbox closure exceeds a host's single-argument limit. Keep
        # stdin for presence permission replies and close the map before launch.
        bootstrap = """import base64,json,os,pathlib,subprocess,sys,tempfile
with os.fdopen(3) as source:
 files=json.load(source)
with tempfile.TemporaryDirectory(prefix='jarvis-pass-') as folder:
 root=pathlib.Path(folder)
 for name,value in files.items():
  path=root/name; path.parent.mkdir(parents=True,exist_ok=True); path.write_bytes(base64.b64decode(value))
 result=subprocess.run([sys.argv[1],str(root/'jarvis/scripts/vm-watch.sh'),*sys.argv[2:]])
 sys.exit(result.returncode)
"""
        return ("python3 -c " + shlex.quote(bootstrap) + " \"$BASH\" " + shlex.join(args) +
                " 3<<'jarvis-files'\n" + json.dumps(files) + "\njarvis-files\n")

    def remote(self, destination):
        args = ["--side", destination.key, "--cursor", json.dumps(self.cursors.get(destination.key, {}))]
        return run(["ssh", destination.host, "bash -s"], data=self.remote_command(args))

    def presence(self, side):
        try:
            if not self.live():
                return [(None, "skipped", None)]
            try:
                return self._presence(side)
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                if not permission_after_failure(self.live, error):
                    return [(None, "skipped", None)]
                raise
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            return [(None, "failed", failure("presence-" + side, error).record)]

    def _presence(self, side):
        destination = self.destination(side)
        permitted = self.live
        if destination.host is None:
            return presence_roots(permitted)
        # Each host operation requests current local permission. The host
        # supplies the touch timestamp before its final permission request.
        with tempfile.TemporaryFile(mode="w+") as errors:
            process = subprocess.Popen(["ssh", destination.host, "bash -s"],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
                                       text=True, bufsize=1)
            try:
                process.stdin.write(self.remote_command(["--presence"]))
                process.stdin.flush()
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    while True:
                        if not selector.select(60):
                            raise subprocess.TimeoutExpired(process.args, 60)
                        line = process.stdout.readline()
                        if not line:
                            break
                        message = json.loads(line)
                        if message["kind"] == "permission":
                            process.stdin.write("renew\n" if permitted() else "skip\n")
                            process.stdin.flush()
                        else:
                            results = message["results"]
                            process.stdin.close()
                            status = process.wait(timeout=60)
                            if status == 0:
                                return results
                            break
                errors.seek(0)
                raise child_failure("host-presence", subprocess.CompletedProcess(process.args, process.wait(timeout=60), "", errors.read()))
            finally:
                if not process.stdin.closed:
                    process.stdin.close()
                process.stdout.close()
                if process.poll() is None:
                    process.kill()
                process.wait()

    def acquire(self, now, side="local"):
        """One destination's pass, accepted independently by the loop thread."""
        destination = self.destination(side)
        try:
            delivered = []
            if destination.host is None:
                output = mail_pass(self.bash, self.home, side, self.cursors.get(side, {}), delivered, self.satellite)
            else:
                result = self.remote(destination)
                if result.returncode:
                    raise child_failure("host-pass", result)
                output = result.stdout
            return [(side, output, None, delivered)]
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            return [(side, None, failure("host-pass" if destination.host else "local-pass", error).record, [])]

    def report(self):
        try:
            result = checked([self.bash, LIB.parent / "jarvis-session", "report-due", "--home", self.home],
                             self.home, operation="report-due")
            if not result:
                return None
            result = "EVENT " + result
            report_key(result)
            return result
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            return failure("report-due", error)

    def accept_report(self, result):
        if isinstance(result, Failure):
            self.failed_pass("report", result.record)
        else:
            self.state.pop("report_failure", None)
            # Retain the emitted event's identity in the existing pass cursor,
            # so restart reads only the uncheckpointed tail, never a due row.
            if result and report_key(result) != self.cursors.get("report", {}).get("event"):
                self.append(pass_output("report", {"event": report_key(result)}, [(None, result)]))

    def relay_status(self):
        try:
            output = checked([self.bash, LIB.parents[2] / "slack/scripts/slack", "listen",
                              "--status", "--root", self.home], self.home, operation="relay-status")
            # Slack's public state owns freshness and the reconnect bound.
            match = re.fullmatch(re.escape("slack: slack-relay=" + str(self.home.resolve())) +
                                 r" state=(ok|failing|stale|never)(?: [^\n]*)?\n", output)
            if not match:
                raise Failure("relay-status", "protocol", "status-unread", output)
            return match[1], output.rstrip("\n")
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            return failure("relay-status", error)

    def accept_relay(self, result):
        prior = self.cursors.get("relay", {})
        state = dict(prior)
        blocks = []
        if isinstance(result, Failure):
            if prior.get("unavailable") != result.record["key"]:
                blocks.append((None, event("relay-unavailable", home=self.home, cause=result.record["detail"])))
            state["unavailable"] = result.record["key"]
        else:
            current, detail = result
            previous = prior.get("state")
            if current != "ok" and (previous is None or previous == "ok"):
                blocks.append((None, event("relay-down", home=self.home, state=current, detail=detail)))
            elif current == "ok" and previous is not None and previous != "ok":
                blocks.append((None, event("relay-up", home=self.home, state=current)))
            state = {"state": current}
        # The log footer checkpoints transitions even across an interrupted
        # state write; an unreadable status never replaces the last reading.
        self.append(pass_output("relay", state, blocks))

    def forward(self):
        try:
            return checked([self.bash, LIB.parent / "jarvis-session", "forward-drain", "--home", self.home],
                           self.home, operation="forward-drain")
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            return failure("forward-drain", error)

    def accept_forward(self, result):
        if isinstance(result, Failure):
            self.failed_pass("forward", result.record)
            return
        self.state.pop("forward_failure", None)
        blocks = [block for block in re.split(r"(?m)^(?=EVENT )", result) if block]
        if not all(block.startswith("EVENT ") and block.endswith("\n") for block in blocks):
            self.failed_pass("forward", Failure("forward-drain", "protocol", "output-unread", result[:200]).record)
            return
        headers = [block.split("\n", 1)[0] for block in blocks]
        # The drain prints every open block on each run; the pass cursor keeps
        # the headers already appended, so a restart appends none twice.
        emitted = set(self.cursors.get("forward", {}).get("emitted", []))
        self.append(pass_output("forward", {"emitted": headers},
                                [(None, block) for block, header in zip(blocks, headers) if header not in emitted]))
        self.save()

    def accept(self, outputs):
        for side, output, failure, delivered in outputs:
            if failure is not None:
                self.failed_pass(side, failure)
            else:
                if delivered:
                    # A delivered owner row waits for coverage. It is saved
                    # before the pass cursor moves past it, so a restart
                    # rereads it rather than losing it; ids merge once.
                    waiting = self.state.setdefault("unanswered", {"reported": [], "failed": False}) \
                        .setdefault("pending", [])
                    known = {row["id"] for row in waiting}
                    waiting.extend(row for row in delivered if row["id"] not in known)
                    self.save()
                self.append(output)
                self.state.pop(side + "_failure", None)
                self.save()

    def tick(self, now, outputs):
        self.accept(outputs)
        self.batch(now)

    def unanswered(self, waiting):
        """One owner-unanswered check of the waiting rows.

        Returns (waiting, rows, now, None), or (waiting, None, None, failure record).
        """
        try:
            # The window starts at the oldest waiting row, so a waiting row the
            # helper does not list is covered, never outside its window.
            output = checked([self.bash, LIB.parent / "owner-unanswered", "--root", self.home,
                              "--since", min(row["at"] for row in waiting), "--older", "0"],
                             self.home, operation="owner-unanswered")
            return waiting, [json.loads(line) for line in output.split("\n") if line], epoch(), None
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            return waiting, None, None, failure("owner-unanswered", error).record

    def accept_unanswered(self, waiting, rows, now, cause):
        # A reminder for the session, never a page: owner-unread alone says mail is unread.
        memory = self.state.setdefault("unanswered", {"reported": [], "failed": False})
        blocks = []
        if cause is not None:
            # Unread coverage covers nothing: every waiting row stays.
            if not memory["failed"]:
                blocks.append(event("owner-unanswered-failed", cause=cause["detail"]))
            memory["failed"] = True
        else:
            checked_ids = {row["id"] for row in waiting}
            listed = {row["id"] for row in rows}
            due = [row for row in rows if row["id"] in checked_ids
                   and now - instant(row["at"]).timestamp() >= OWNER_WAIT_SECS]
            blocks.extend(event("owner-unanswered", id=row["id"], at=row["at"], kind=row["kind"]) +
                          line_value(row.get("text", ""), limit=4000) + "\n"
                          for row in due if row["id"] not in memory.get("reported", []))
            # A checked row the helper no longer lists is covered; a row
            # delivered during the check waits for the next one. Only rows
            # old enough to remind are remembered as reported.
            self.state["unanswered"] = {
                "pending": [row for row in memory.get("pending", [])
                            if row["id"] not in checked_ids or row["id"] in listed],
                "reported": [row["id"] for row in due], "failed": False}
        if blocks:
            self.append(pass_output("local", self.cursors.get("local", {}),
                                    [(str(self.home), block) for block in blocks]))
        self.save()

    def _poll(self, passes, pending, now):
        relay = self.relay_pending
        if relay is not None and relay.done():
            self.accept_relay(relay.result())
            self.relay_pending = None
        if self.relay_pending is None and now >= self.next_relay:
            self.next_relay = now + 30
            self.relay_pending = passes.submit(self.relay_status)
        work = self.unanswered_pending
        if work is not None and work.done():
            self.accept_unanswered(*work.result())
            self.unanswered_pending = None
        # Only a delivered owner row that no check has found covered starts a check.
        waiting = self.state.get("unanswered", {}).get("pending", [])
        if self.unanswered_pending is None and waiting and now >= self.next_unanswered:
            self.next_unanswered = now + UNANSWERED_EVERY_SECS
            self.unanswered_pending = passes.submit(self.unanswered, list(waiting))
        if self.satellite:
            # A satellite renews no fleet presence and owes no checkpoint;
            # it drains its forward outbox on the same executor instead.
            work = self.forward_pending
            if work is not None and work.done():
                self.accept_forward(work.result())
                self.forward_pending = None
            if self.forward_pending is None and now >= self.next_forward:
                self.next_forward = now + FORWARD_EVERY_SECS
                self.forward_pending = passes.submit(self.forward)
            sides = ()
        else:
            report = self.report_pending
            if report is not None and report.done():
                self.accept_report(report.result())
                self.report_pending = None
            if self.report_pending is None and now >= self.next_report:
                self.next_report = now + 30
                self.report_pending = passes.submit(self.report)
            sides = tuple(target.key for target in self.destinations)
            for side in sides:
                if side == "local":
                    continue
                work = self.mail_pending.get(side)
                if work is not None and work.done():
                    self.accept(work.result())
                    del self.mail_pending[side]
                if side not in self.mail_pending:
                    self.mail_pending[side] = passes.submit(self.acquire, now, side)
        for side in sides:
            work = self.presence_pending.get(side)
            if work is not None and work.done():
                self.accept_presence(side, work.result())
                del self.presence_pending[side]
            if side not in self.presence_pending and now >= self.next_presence.get(side, 0):
                self.next_presence[side] = now + 120
                self.presence_pending[side] = passes.submit(self.presence, side)
        if pending.done():
            self.tick(now, pending.result())
            pending = passes.submit(self.acquire, now)
        else:
            self.batch(now)
        return pending

    def failed_pass(self, side, cause):
        side = self.destination_key(side)
        prior = self.state.get(side + "_failure", {})
        if prior.get("key") != cause["key"]:
            self.append(pass_output(side, self.cursors.get(side, {}), [(None,
                event("root-unreachable", repo=side if side.startswith("ssh:") else self.home.name,
                      cause=cause["detail"]))]))
            self.state[side + "_failure"] = cause
            self.save()

    def accept_presence(self, side, results):
        side = self.destination_key(side)
        failures = self.state.setdefault("presence_failures", {}).setdefault(side, {})
        if any(status == "ok" for _, status, _ in results) and all(status != "failed" for _, status, _ in results):
            failures.pop(side, None)
        for root, status, cause in results:
            # A whole-side result has no target. Its storage key is scope,
            # never a root identity passed to the event serializer.
            scope = root if root is not None else side
            if status == "ok":
                failures.pop(scope, None)
            elif status == "failed":
                if scope not in failures:
                    self.append(pass_output(side, self.cursors.get(side, {}), [(root,
                        event("presence-renew-failed", repo=Path(root).name if root is not None else side,
                              side=side, cause=cause["detail"]))]))
                    failures[scope] = cause
            elif status != "skipped":
                raise RuntimeError("presence-status-invalid")
        self.save()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("loop", "pass"))
    parser.add_argument("--bash", required=True)
    parser.add_argument("--home", default=".")
    parser.add_argument("--side", default="local")
    parser.add_argument("--cursor", default="{}")
    parser.add_argument("--presence", action="store_true")
    parser.add_argument("--initial-pass", action="append", type=Path,
                        help="initialize fresh loop state from a reconciled public pass, then exit; repeat per destination")
    args = parser.parse_args()
    if args.initial_pass and args.mode != "loop":
        parser.error("--initial-pass requires loop mode")
    initial_passes = [path.absolute() for path in args.initial_pass] if args.initial_pass else None
    home = home_root(args.home)
    if args.mode == "pass":
        if args.presence:
            def permitted():
                print(json.dumps({"kind":"permission"}), flush=True)
                return sys.stdin.readline() == "renew\n"
            print(json.dumps({"kind":"results", "results":presence_roots(permitted)}), flush=True)
        else:
            print(mail_pass(args.bash, home, args.side, json.loads(args.cursor)), end="")
    else:
        settings = config(args.bash, home)
        if not re.fullmatch(r"0|[1-9][0-9]*", settings["JARVIS_WAKE_SETTLE_SECS"]):
            raise RuntimeError("settle-invalid")
        os.chdir(home)
        # A second launch can reach the same log through a repeated session
        # start. Hold the OS lock for this loop's whole lifetime.
        directory = Path(os.path.expanduser(settings["JARVIS_LOG_DIR"]))
        directory.mkdir(parents=True, exist_ok=True)
        with (directory / "watch.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            watch = Watch(home, args.bash, settings, initial_passes)
            if initial_passes is not None:
                return
            # Slow SSH and mailbox reads cannot extend an already-started
            # settle. Only this thread appends results or commits batch state.
            with ThreadPoolExecutor(max_workers=2 * len(watch.destinations) + 3) as passes:
                pending = passes.submit(watch.acquire, epoch())
                while True:
                    pending = watch._poll(passes, pending, epoch())
                    time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, DestinationRefusal, subprocess.SubprocessError) as error:
        print("jarvis: failure=" + json.dumps(failure("pass", error).record), file=sys.stderr)
        sys.exit(1)
