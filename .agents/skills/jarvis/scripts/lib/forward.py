"""A satellite's forwards of confirmed owner requests to the main home, and their outbox.

The outbox is machine-local and is the one record of each forward. `forward`
checks the caller's record, enqueues the request and makes the first attempt.
The watch loop runs `forward-drain`, which retries delivery and reads the
main's answers.
"""
import calendar
from contextlib import contextmanager
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import time

LIB = Path(__file__).resolve().parent
sys.path.insert(0, str(LIB))
import owner_note  # noqa: E402
import watch  # noqa: E402

# One deadline for every host call of a run, below the watch's 60 s bound on
# the drain, so a hung main still leaves time to record why.
DRAIN_SECONDS = 45
CONNECT_SECONDS = 10
CLOSED_KEEP_DAYS = 30
# How long a delivered forward waits for its answer. Past it, an answer the
# main's compaction dropped unread, or one sent without --ref, cannot be told
# from none, so the forward closes as answer-unseen and is read no more. The
# main keeps an answer row max(ORCH_RECORD_RETENTION_DAYS, SLACK_THREAD_DAYS)
# days, read or not, seven by default, a setting the satellite cannot read.
ANSWER_WAIT_DAYS = 7
RECORD_BYTES = 65536
WORDS_LIMIT = 300
# A caller that records how the owner confirmed, not his words: VGS records
# a spoken or an on-screen confirmation of the operation.
METHODS = ("voice", "physical")
# The record's reference sources are a closed set. An id holds no whitespace,
# quote or backslash, so it stands unescaped in the provenance line.
REFERENCE = re.compile(r"(vgs-audit|transcript|lane-mail):[A-Za-z0-9._:@#+/=-]{1,200}", re.ASCII)
# UTC with Z only: jq todate's form and JavaScript toISOString's.
INSTANT = re.compile(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z", re.ASCII)
# A drain read past every line prints the header alone: the start of a read.
HEADER_ONLY = "2147483647"
HOST_READ = """set -euo pipefail
cd -- "$1"
[ -f %(mail)s ] || { printf 'forward: mailbox-missing=%%s\\n' "$1" >&2; exit 2; }
"$BASH" %(mail)s drain --item overseer --after "$2" ${3:+--receipts}
""" % {"mail": owner_note.LANE_MAIL}
# The host refusal keys a forward names as its cause; any other refusal takes
# the operation's own cause.
HOST_CAUSES = ("mailbox-missing", "overseer-absent", "overseer-unreadable")
# Causes no retry clears: the drain reports each once as an event.
TERMINAL = ("mailbox-missing", "send-failed", "setting-invalid", "receipts-missed", "answer-unseen", "stop")
UNREACHABLE = "main-unreachable"
SESSION_ID = re.compile(r"vgs-voice:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", re.ASCII)
BOOT_ID = None


class Refusal(Exception):
    """KEY, then a detail line or "field=PATH": nothing was enqueued or sent."""


def iso(at):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at)) if at is not None else None


def nanoseconds(value):
    """A checked record time as integer nanoseconds since the epoch, or None when it names no instant."""
    match = INSTANT.fullmatch(value)
    if not match:
        return None
    try:
        moment = datetime.datetime(*map(int, match.groups()[:6]))
    except ValueError:
        return None
    return calendar.timegm(moment.timetuple()) * 10 ** 9 + int((match[7] or "").ljust(9, "0"))


def canonical_at(value):
    """A checked record time as YYYY-MM-DDTHH:MM:SS.fffffffffZ, so equal instants spell alike."""
    match = INSTANT.fullmatch(value)
    return "%s-%s-%sT%s:%s:%s." % match.groups()[:6] + (match[7] or "").ljust(9, "0") + "Z"


def checked_record(path):
    """The caller's record at PATH after its shape and order checks; the first failure refuses."""
    try:
        with open(path, "rb") as source:
            data = source.read(RECORD_BYTES + 1)
        if len(data) > RECORD_BYTES:
            raise ValueError("over %d bytes" % RECORD_BYTES)
        record = json.loads(data.decode("utf-8"))
        if not isinstance(record, dict):
            raise ValueError("not one JSON object")
    except (OSError, ValueError) as error:
        raise Refusal("record-unreadable", str(error)) from error

    def invalid(field, valid):
        if not valid:
            raise Refusal("record-invalid", "field=" + field)

    scoped = "session" in record
    invalid("record", set(record) == ({"v", "request", "confirmation", "session"} if scoped
                                      else {"v", "request", "confirmation"})
            and type(record["v"]) is int and record["v"] == 1)
    # VGS records modality, not identity; its legacy records need no caller field.
    confirmation = record["confirmation"]
    form = "method" if isinstance(confirmation, dict) and "method" in confirmation else "words"
    caller = ("caller",) if isinstance(confirmation, dict) and "caller" in confirmation else ()
    fields = {"request": ("ref", "at", "text"),
              "confirmation": ("ref", "at", form, *caller, *(("scope",) if scoped else ()))}
    for part, keys in fields.items():
        invalid(part, isinstance(record[part], dict) and set(record[part]) == set(keys))
        for key in keys:
            invalid(part + "." + key, isinstance(record[part][key], str))
    invalid("confirmation.caller", confirmation.get("caller", "unproved") == "unproved")
    invalid("confirmation.method", form == "words" or confirmation["method"] in METHODS)
    if scoped:
        session = record["session"]
        invalid("session", isinstance(session, dict) and set(session) == {"id", "name", "main", "lease"})
        for field in session:
            invalid("session." + field, isinstance(session[field], str))
        identity = SESSION_ID.fullmatch(session["id"])
        invalid("session.id", identity)
        invalid("session.name", session["name"] == "Jarvis Voice " + identity[1])
        invalid("session.main", bool(session["main"]))
        invalid("session.lease", Path(session["lease"]).is_absolute()
                and Path(session["lease"]).name == identity[1] + ".json")
        invalid("confirmation.scope", confirmation["scope"] == "session" and form == "method")
    for part in fields:
        invalid(part + ".ref", REFERENCE.fullmatch(record[part]["ref"]))
    for part in fields:
        invalid(part + ".at", nanoseconds(record[part]["at"]) is not None)
    invalid("request.text", record["request"]["text"].strip())
    invalid("confirmation.words", form == "method" or confirmation["words"].strip())
    # One record row may hold both turns, so the references may match and the times be equal.
    if not scoped and nanoseconds(confirmation["at"]) < nanoseconds(record["request"]["at"]):
        raise Refusal("confirmation-early", "")
    if form == "words" and not confirms(confirmation["words"]):
        raise Refusal("confirmation-unclear", "")
    return record


def live_session(session, main):
    """VGS's private lease admits this send; revocation cannot recall an admitted send.

    One lease content read and one process stat read per attempt. The boot
    identity is cached once per command; metadata checks cover only the file
    and its immediate parent, so a fresh grant's path cannot revive old work.
    """
    global BOOT_ID
    try:
        if session["main"] != main:
            return False
        path = Path(session["lease"])
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            mode = os.fstat(directory)
            if mode.st_uid != os.geteuid() or stat.S_IMODE(mode.st_mode) != 0o700:
                return False
            descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
            with os.fdopen(descriptor, "rb") as source:
                mode = os.fstat(source.fileno())
                if (not stat.S_ISREG(mode.st_mode) or mode.st_uid != os.geteuid()
                        or stat.S_IMODE(mode.st_mode) != 0o600):
                    return False
                lease = json.loads(source.read(RECORD_BYTES + 1))
        finally:
            os.close(directory)
        if not isinstance(lease, dict) or type(lease.get("v")) is not int or lease["v"] != 1:
            return False
        if lease.get("id") != session["id"] or lease.get("main") != session["main"]:
            return False
        owner = lease.get("owner")
        if (not isinstance(owner, dict) or type(owner.get("pid")) is not int or owner["pid"] <= 0
                or not isinstance(owner.get("start"), str) or not re.fullmatch(r"[0-9]+", owner["start"])):
            return False
        if BOOT_ID is None:
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
            if not SESSION_ID.fullmatch("vgs-voice:" + boot):
                return False
            BOOT_ID = boot
        if owner.get("boot") != BOOT_ID:
            return False
        fields = Path("/proc/%d/stat" % owner["pid"]).read_text().rsplit(")", 1)[1].split()
        return fields[0] not in ("Z", "X") and fields[19] == owner["start"]
    except (OSError, ValueError, AttributeError, IndexError):
        return False


def confirms(words):
    """A line `forward`, or a whole text `yes`, each after trimming, case folding and one trailing . or !"""
    def plain(text):
        text = text.strip().casefold()
        return text[:-1] if text.endswith((".", "!")) else text
    if len(words) > WORDS_LIMIT:
        return False
    return plain(words) == "yes" or any(plain(line) == "forward" for line in words.split("\n"))


class Outbox:
    """forward.json in the home's state DIRECTORY, beside its session record, under its own lock.

    `first` is the main to-overseer's first id, so a replaced mailbox is
    seen; each entry's `after` is the logical count past which its answer
    lies, None before its first send.
    """

    def __init__(self, home, directory):
        self.home = home
        self.path = directory / "forward.json"

    def read(self):
        try:
            value = json.loads(self.path.read_text())
        except FileNotFoundError:
            return {"v": 1, "home": self.home, "first": None, "probe": None, "last_answer": None, "entries": []}
        except (OSError, ValueError) as error:
            raise Refusal("outbox-unreadable", str(error)) from error
        if not (isinstance(value, dict) and value.get("v") == 1 and value.get("home") == self.home
                and isinstance(value.get("entries"), list)
                and all(isinstance(entry, dict) and isinstance(entry.get("key"), str) for entry in value["entries"])):
            raise Refusal("outbox-unreadable", "format")
        return value

    @contextmanager
    def locked(self):
        """The current outbox; what the block leaves in it is saved atomically, unless it raises."""
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (self.path.parent / "forward.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            state = self.read()
            yield state
            watch.atomic_json(self.path, state)


def entry_state(entry):
    if entry.get("closed_at") is not None:
        return "closed"
    if entry.get("forwarded") is None:
        return "queued"
    return "read" if entry.get("read") else "delivered"


def kept(entry, now):
    """True for an open entry, or a closed one inside CLOSED_KEEP_DAYS, which still refuses and reports."""
    return entry_state(entry) != "closed" or now - entry["closed_at"] < CLOSED_KEEP_DAYS * 86400


def find(state, key):
    return next((entry for entry in state["entries"] if entry["key"] == key), None)


def close(entry, now, cause=None):
    """A closed entry keeps only what answered-already, or its unseen answer's event, needs."""
    for field in list(entry):
        if field not in ("key", "request"):
            del entry[field]
    entry["closed_at"] = now
    if cause is not None:
        entry["cause"] = cause


def replaced(state, first):
    """Record the main to-overseer's FIRST id; True when it names another mailbox.

    A replaced mailbox restarts its logical lines, so every open entry reads
    it whole.
    """
    if state["first"] and first != state["first"]:
        for entry in state["entries"]:
            if entry_state(entry) != "closed" and entry.get("after") is not None:
                entry["after"] = 0
        state["first"] = first
        return True
    state["first"] = first
    return False


class Forwarder:
    def __init__(self, bash, home, directory):
        self.bash, self.home = bash, home
        self.settings = watch.config(bash, home)
        self.role = watch.role(self.settings)
        self.outbox = Outbox(home, directory)
        self.deadline = time.monotonic() + DRAIN_SECONDS

    def satellite(self):
        if self.role.kind == "main":
            raise Refusal("role-main", "")

    def host(self, script, args, data=None):
        """One call on the main: ("ok", result), or (cause, first diagnostic line)."""
        remaining = self.deadline - time.monotonic()
        if remaining < 1:
            return UNREACHABLE, "budget-spent"
        command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=%d" % CONNECT_SECONDS, self.role.dest,
                   "bash -c " + shlex.quote(script) + " forward " + " ".join(map(shlex.quote, [self.role.home, *args]))]
        try:
            result = watch.run(command, data=data, operation="forward-host", timeout=remaining)
        except watch.Failure as error:
            if error.record["key"][1] == "timeout":
                return UNREACHABLE, "timeout"
            return "send-failed", error.record["detail"]
        if result.returncode == 255:
            return UNREACHABLE, result.stderr.strip().split("\n", 1)[0]
        return "ok", result

    @staticmethod
    def refusal(result, fallback):
        """A host call's refusal as (cause, first diagnostic line); FALLBACK names an unknown one."""
        error = watch.child_failure("forward-host", result)
        _, category, code = error.record["key"]
        cause = code if category == "refusal" and code in HOST_CAUSES else fallback
        return cause, error.record["detail"].split("\n", 1)[0][:200]

    def probe(self, cause):
        reachable = cause != UNREACHABLE
        with self.outbox.locked() as state:
            state["probe"] = {"at": watch.epoch(), "reachable": reachable, "cause": None if reachable else UNREACHABLE}

    def take_cursor(self, keys):
        """Give the entries KEYS the main's current to-overseer end as their answer cursor.

        It is read before their first send, and an answer follows its
        directive, so a read from there misses none of theirs. Returns None,
        or the (cause, detail) that stopped it.
        """
        outcome, result = self.host(HOST_READ, [HEADER_ONLY])
        self.probe(outcome)
        if outcome != "ok":
            return outcome, result
        if result.returncode:
            return self.refusal(result, "send-failed")
        header = watch.mailbox_header(result.stdout.split("\n", 1)[0])
        if not header:
            return "read-failed", "header-unread"
        with self.outbox.locked() as state:
            replaced(state, header[1])
            for entry in state["entries"]:
                if entry["key"] in keys and entry.get("after") is None:
                    entry["after"] = header[0]
        return None

    def send(self, keys=None):
        """Deliver each queued entry, oldest first, stopping at an unreachable main."""
        queued = [entry for entry in self.outbox.read()["entries"]
                  if entry_state(entry) == "queued" and (keys is None or entry["key"] in keys)
                  and (entry.get("last_attempt") is None
                       or watch.epoch() - entry["last_attempt"]["at"] >= watch.FORWARD_EVERY_SECS)]
        if not queued:
            return
        fresh = {entry["key"] for entry in queued if entry.get("after") is None}
        stopped = self.take_cursor(fresh) if fresh else None
        unreachable = False
        for entry in queued:
            if entry.get("session") and not live_session(entry["session"], self.settings["JARVIS_MAIN_HOST"]):
                with self.outbox.locked() as state:
                    current = find(state, entry["key"])
                    if current is not None and entry_state(current) == "queued":
                        close(current, watch.epoch(), "stop")
                continue
            # Cursor failure and an earlier unreachable send must not bypass
            # revocation of any later entry. Each lease is checked once, here
            # at its own send boundary, after any blocking cursor read.
            if stopped is not None:
                self.record([entry], *stopped)
                continue
            if unreachable:
                continue
            outcome, result = self.host(owner_note.HOST_SEND, ["--delivery-id", entry["key"]], entry["text"])
            self.probe(outcome)
            if outcome != "ok":
                self.record([entry], outcome, result)
                if outcome == UNREACHABLE:
                    unreachable = True
                continue
            receipt = watch.send_receipt(result, entry["key"])
            if receipt:
                self.record([entry], None, None, *receipt)
            else:
                self.record([entry], *self.refusal(result, "send-failed"))

    def record(self, entries, cause, detail, forwarded=None, repeated=False):
        at = watch.epoch()
        with self.outbox.locked() as state:
            for each in entries:
                entry = find(state, each["key"])
                if entry is None or entry_state(entry) != "queued":
                    continue
                entry["attempts"] = entry.get("attempts", 0) + 1
                entry.update(last_attempt={"at": at, "cause": cause}, cause=cause, detail=detail)
                if forwarded is not None:
                    entry.update(forwarded=forwarded, delivered_at=at, detail=None)
                if repeated:
                    # The directive landed at an unknown earlier point, perhaps
                    # before this entry's cursor: read its answer from the start.
                    entry["after"] = 0

    def read_main(self):
        """The main's answers and reader receipts, read while an open entry may have landed.

        A queued entry may have landed once a send was attempted, its
        receipt lost, so its answer is read too and closes it.
        """
        state = self.outbox.read()
        keys = {entry["key"] for entry in state["entries"] if entry_state(entry) != "closed"
                and entry.get("after") is not None and entry.get("attempts", 0) > 0}
        if not keys:
            return
        after = min(entry["after"] for entry in state["entries"] if entry["key"] in keys)
        outcome, result = self.host(HOST_READ, [str(after), "receipts"])
        self.probe(outcome)
        header = receipts = None
        if outcome == "ok" and result.returncode:
            outcome = self.refusal(result, "read-failed")[0]
        elif outcome == "ok":
            lines = result.stdout.split("\n")
            header = watch.mailbox_header(lines[0])
            try:
                receipts = watch.mailbox_receipts(lines)
            except watch.Failure:
                # An unreadable receipts block leaves receipts None: the read is read-failed and no entry moves.
                pass
            if not (header and receipts):
                outcome = "read-failed"
        now = watch.epoch()
        with self.outbox.locked() as state:
            reading = [entry for entry in state["entries"] if entry["key"] in keys and entry_state(entry) != "closed"]
            if outcome != "ok":
                # A queued entry keeps the cause of its own send.
                for entry in reading:
                    if entry_state(entry) != "queued":
                        entry["cause"] = outcome
                return
            if replaced(state, header[1]):
                return
            index, cursor, _, listed = receipts
            # Each key's first final answer, and its place in the mailbox.
            answers = {}
            for place, row in enumerate(json.loads(line) for line in lines[1:index] if line):
                if row.get("kind") == "notice" and not row.get("progress") and isinstance(row.get("re_delivery_id"), str):
                    answers.setdefault(row["re_delivery_id"], (place, row))
            directives = {directive: line for line, directive, _ in listed}
            latest = None
            for entry in reading:
                if entry["key"] in answers:
                    place, answer = answers[entry["key"]]
                    if latest is None or place > latest[0]:
                        latest = (place, {"request": entry["request"], "forwarded": entry.get("forwarded"),
                                          "answer": answer["id"], "at": answer["at"]})
                    retained = {"request": entry["request"], "request_at": canonical_at(entry["request_at"]),
                                "key": entry["key"], "forwarded": entry.get("forwarded"),
                                "answer": answer["id"], "at": answer["at"], "text": answer["text"],
                                "closed_at": iso(now), "expires_at": iso(now + CLOSED_KEEP_DAYS * 86400)}
                    close(entry, now)
                    entry["answer"] = retained
                    continue
                entry["after"] = header[0]
                if entry_state(entry) == "queued":
                    continue
                line = directives.get(entry["forwarded"])
                entry["cause"] = None
                if cursor is None:
                    entry["cause"] = "receipts-missed"
                elif line is not None and line <= cursor:
                    entry["read"] = True
                elif line is not None:
                    entry["cause"] = "main-unread"
                if now - entry["delivered_at"] >= ANSWER_WAIT_DAYS * 86400:
                    close(entry, now, "answer-unseen")
            if latest is not None:
                state["last_answer"] = latest[1]

    def events(self):
        """One forward-failed block per kept entry whose cause no retry clears, a closed answer-unseen one included.

        The watch's pass cursor appends a printed block once, so a closed
        block prints on every drain until its keep ends, and a failed pass
        loses none. The header names the forward's key: a reused reference's
        later request is another forward, and its block another event.
        """
        state = self.outbox.read()
        now = watch.epoch()
        blocks = []
        for entry in state["entries"]:
            if kept(entry, now) and entry.get("answer"):
                blocks.append(watch.event("forward-answer", request=entry["request"], key=entry["key"],
                                          answer=entry["answer"]["answer"]))
            if kept(entry, now) and entry.get("cause") in TERMINAL:
                fields = {"request": entry["request"], "key": entry["key"], "cause": entry["cause"]}
                if entry.get("detail"):
                    fields["detail"] = entry["detail"]
                blocks.append(watch.event("forward-failed", **fields))
        return "".join(blocks)

    def invalid(self):
        """An unparsable setting holds every open entry and reports it."""
        with self.outbox.locked() as state:
            for entry in state["entries"]:
                if entry_state(entry) != "closed":
                    entry.update(cause="setting-invalid", detail=None)

    def drain(self):
        self.satellite()
        if self.role.kind == "invalid":
            self.invalid()
        else:
            self.send()
            self.read_main()
        return self.events()

    def forward(self, path):
        self.satellite()
        if self.role.kind == "invalid":
            raise Refusal("setting-invalid", "JARVIS_MAIN_HOST")
        record = checked_record(path)
        request, confirmation = record["request"], record["confirmation"]
        # A reference reused with a new request time is a new request, with its own key.
        key = "forward-" + hashlib.sha256((self.home + "\n" + request["ref"] + "\n" +
                                           canonical_at(request["at"])).encode()).hexdigest()
        digest = hashlib.sha256(request["text"].encode()).hexdigest()
        # Every value but the last is whitespace-free; the words are one
        # ASCII-escaped JSON string, or null in the method form, last, so
        # they cannot fake a field.
        line = "forwarded-request: " + " ".join("%s=%s" % pair for pair in (
            ("satellite", watch.line_value(os.uname().nodename, True)), ("request-ref", request["ref"]),
            ("request-at", request["at"]), ("confirmation-ref", confirmation["ref"]),
            ("confirmed-at", confirmation["at"]), ("key", key),
            ("confirmation-method", confirmation.get("method", "words")),
            ("confirmation-text", json.dumps(confirmation.get("words"), ensure_ascii=True))))
        now = watch.epoch()
        with self.outbox.locked() as state:
            state["entries"] = [entry for entry in state["entries"] if kept(entry, now)]
            entry = find(state, key)
            if entry is not None and entry_state(entry) == "closed":
                raise Refusal(entry.get("cause") or "answered-already", request["ref"])
            # An open forward of this reference holds it, whatever its key.
            if any(entry_state(each) != "closed" and each["request"] == request["ref"]
                   and (each["request_sha256"], canonical_at(each["request_at"])) != (digest, canonical_at(request["at"]))
                   for each in state["entries"]):
                raise Refusal("request-conflict", request["ref"])
            if entry is None:
                # The text is frozen here: every retry sends the same bytes
                # under one key, citing the first confirmation.
                state["entries"].append({
                    "key": key, "request": request["ref"], "request_at": request["at"], "request_sha256": digest,
                    "confirmation": confirmation["ref"], "confirmed_at": confirmation["at"],
                    "text": "forwarded-confirmation: caller=unproved\nrequest-text: "
                            + json.dumps(request["text"], ensure_ascii=True) + "\n\n" + line,
                    "queued_at": now, "attempts": 0,
                    "last_attempt": None, "cause": None, "detail": None, "forwarded": None,
                    "delivered_at": None, "read": False, "after": None, "closed_at": None})
                if "session" in record:
                    state["entries"][-1]["session"] = record["session"]
        self.send([key])
        entry = find(self.outbox.read(), key)
        if entry_state(entry) == "closed":
            raise Refusal(entry.get("cause") or "answered-already", request["ref"])
        delivered = entry_state(entry) != "queued"
        if delivered:
            watch.forward_ready(self.settings, key, entry["delivered_at"])
        return {"v": 1, "request": request["ref"], "key": key, "state": "delivered" if delivered else "queued",
                "forwarded": entry.get("forwarded"), "cause": None if delivered else entry.get("cause")}

    def status(self):
        if self.role.kind == "main":
            return {"v": 1, "role": "main"}
        state = self.outbox.read()
        probe = state.get("probe") or {}
        requests = [{"request": entry["request"], "key": entry["key"], "state": entry_state(entry),
                     "cause": entry.get("cause"), "forwarded": entry.get("forwarded"),
                     "queued_at": iso(entry.get("queued_at")), "attempts": entry.get("attempts", 0)}
                    for entry in state["entries"] if entry_state(entry) != "closed"]
        answers = sorted((entry["answer"] for entry in state["entries"]
                          if entry.get("answer") and kept(entry, watch.epoch())),
                         key=lambda answer: (answer["closed_at"], answer["key"]))
        return {"v": 1, "role": "satellite", "main": self.role.dest,
                "reachable": probe.get("reachable"), "checked_at": iso(probe.get("at")),
                "cause": "setting-invalid" if self.role.kind == "invalid" else probe.get("cause"),
                "last_answer": state.get("last_answer"), "requests": requests, "answers": answers}


def main(args, home_state):
    """Run forward, forward-drain or status --main for the parsed ARGS; return the exit code.

    home_state(home) is the home's state directory, the session record's.
    """
    try:
        home = str(Path(args.home).resolve(strict=True))
        forwarder = Forwarder(os.environ["JARVIS_BASH"], home, home_state(home))
        if args.verb == "forward":
            answer = forwarder.forward(args.record)
            print(json.dumps(answer, separators=(",", ":")), flush=True)
            return 0 if answer["state"] == "delivered" else 75
        if args.verb == "forward-drain":
            sys.stdout.write(forwarder.drain())
            return 0
        print(json.dumps(forwarder.status(), separators=(",", ":")), flush=True)
        return 0
    except Refusal as refusal:
        key, detail = refusal.args
        if detail.startswith("field="):
            print("jarvis-session: %s=refused cause=%s %s" % (args.verb, key, detail), file=sys.stderr)
        else:
            print("jarvis-session: %s=refused cause=%s" % (args.verb, key), file=sys.stderr)
            if detail:
                print(detail, file=sys.stderr)
        return 2
    except (OSError, ValueError, RuntimeError) as error:
        print("jarvis-session: %s=failed cause=%s" % (args.verb, watch.line_value(error, True)), file=sys.stderr)
        return 2
