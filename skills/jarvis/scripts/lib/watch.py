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
from string import Template
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
# A controller is live while its heartbeat is this recent. A restarted
# controller that exits inside this window of its restart has not outlived
# it, so that exit fails the restart rather than opening another.
LIVE_SECS = 300
# A machine's role from JARVIS_MAIN_HOST: kind main, satellite or invalid. An
# invalid value is still a satellite, so a typo never makes a second main.
Role = namedtuple("Role", "kind dest home")
# user is the account every command on that host runs as: owner-note's
# listing and send, and the loop's mail and presence passes. None is the SSH
# user.
Destination = namedtuple("Destination", "key host user")


class DestinationRefusal(Exception):
    """A destination selection refusal: key, value and optional cause."""


def destinations(settings):
    """The main's declared machines; a satellite never discovers fleet roots."""
    local = Destination("local", None, None)
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
    user = settings.get("JARVIS_CONTROL_USER", "") or None
    return (local, *(Destination("ssh:" + host, host, user if host == control else None) for host in hosts))


def host_args(destination, command):
    """The ssh argv that runs the shell text COMMAND on the destination's host, as its user where it names one.
    COMMAND's stdin is the ssh child's stdin on either route."""
    if destination.user:
        # sudo -n refuses rather than prompts. sudo -i would hand the command
        # to the login shell with each `$` unescaped, so "$1" inside it
        # expands there (sudo 1.9.15p5); bash -l is that login, from that
        # user's home, with every argument kept verbatim.
        command = "sudo -n -H -u %s -- bash -l -c %s" % (shlex.quote(destination.user), shlex.quote("cd && " + command))
    return ["ssh", destination.host, command]


# One `kendex project list --json` entry; linked is whether the folder is a
# linked worktree, which a person reaches through its main checkout, and
# cause is the Git error of a `git-unclassified` entry, else None.
Listed = namedtuple("Listed", "folder state linked cause")


def destination_projects(destination, timeout=60):
    """Every entry the destination's registry lists, in its order.

    The rows `kendex project list` prints for a person cannot name a folder
    exactly: their escaping spells a newline as a backslash and an n, and a
    folder may end in a note's text. kendex 1.24.0, the package's kendex
    floor, lists a folder Git cannot classify as its own `git-unclassified`
    entry; an older kendex refuses the whole document for it."""
    if destination.host:
        text = checked(host_args(destination, "kendex project list --json"), operation="project-list", timeout=timeout)
    else:
        text = checked(["kendex", "project", "list", "--json"], operation="project-list", timeout=timeout)
    try:
        entries = []
        for entry in json.loads(text):
            folder, state, worktree = entry["folder"], entry["state"], entry["worktree"]
            cause = entry["cause"] if state == "git-unclassified" else None
            if not isinstance(folder, str) or not isinstance(state, str) or not isinstance(worktree, (dict, type(None))) \
                    or (state == "git-unclassified" and not isinstance(cause, str)):
                raise TypeError("entry-field")
            entries.append(Listed(folder, state, worktree is not None, cause))
    except (ValueError, TypeError, KeyError) as error:
        raise Failure("project-list", "malformed", type(error).__name__, error) from error
    return entries


def destination_roots(destination, every=False):
    """The registered folders a pass or a note may take, each with the Failure that stops it, else None.

    A readable folder that is not a linked worktree is a root. A folder Git
    cannot classify is a root whose Failure, kendex's cause, stops what needs
    Git there, its mail read and a note to it; the presence pass renews no
    hold for it, so Slack delivers its notices. Other unreadable entries are
    skipped, unless EVERY, which a restart's resume asks for: a checkout not
    mounted yet is then a root whose Failure names kendex's state, so its
    fleet is reported, never passed over."""
    roots = []
    for entry in destination_projects(destination):
        if entry.state == "git-unclassified":
            roots.append((entry.folder, Failure("project-list", "registration", entry.state,
                                                entry.state + " " + entry.cause)))
        elif entry.state == "ok":
            if not entry.linked:
                roots.append((entry.folder, None))
        elif every:
            roots.append((entry.folder, Failure("project-list", "registration", entry.state, entry.state)))
    return roots


# lane-mail with every file it sources or runs for the overseer mailbox,
# which a host pass and the owner-ask reads carry to a host.
MAILBOX_FILES = ("mailbox/scripts/lane-mail", "mailbox/scripts/lib/file-lock.sh",
                 "mailbox/scripts/lib/mailbox-append.sh", "mailbox/scripts/lib/common-root.sh",
                 "mailbox/scripts/lib/kendex-env.sh", "mailbox/scripts/lib/lane-mail-store.py")


def package_files(names):
    """The caller's own package bytes, keyed by path under its packages root."""
    packages = LIB.parents[2]
    return {name: base64.b64encode((packages / name).read_bytes()).decode() for name in names}


def remote_command(files, entry, args, stdin=False, shell_args=()):
    """Shell text running ENTRY of FILES, the caller's package bytes, from a fresh folder on a host.

    The host supplies its shell, python3 and the data the command reads, never
    code. The closure exceeds a host's single-argument limit, so it travels on
    stdin, returned as the payload, or on fd 3 where stdin carries the
    command's own dialogue."""
    bootstrap = """import base64,json,os,pathlib,subprocess,sys,tempfile
if sys.argv[1] == 'stdin':
 payload=json.load(sys.stdin)
else:
 with os.fdopen(3) as source: payload=json.load(source)
with tempfile.TemporaryDirectory(prefix='jarvis-pass-') as folder:
 root=pathlib.Path(folder)
 for name,value in payload['files'].items():
  path=root/name; path.parent.mkdir(parents=True,exist_ok=True); path.write_bytes(base64.b64decode(value))
 argv=[sys.argv[2],*json.loads(sys.argv[3]),str(root/sys.argv[4]),*sys.argv[5:]]
 result=subprocess.run(argv)
 sys.exit(result.returncode)
"""
    # -I: a -c program imports from its working directory otherwise. exec:
    # the host's bash -s reads its script from the stream that carries the
    # command's own stdin after it, so a shell left running past a bootstrap
    # that failed would run that stdin as script. Bash's exec builtin replaces
    # the shell, and a non-interactive shell exits where exec cannot run.
    command = ("exec python3 -I -c " + shlex.quote(bootstrap) + " " + ("stdin" if stdin else "fd3") +
               " \"$BASH\" " + shlex.join([json.dumps(list(shell_args)), entry, *map(str, args)]))
    payload = json.dumps({"files": files})
    if stdin:
        return command, payload
    return command + " 3<<'jarvis-files'\n" + payload + "\njarvis-files\n", None


def note_routes(settings, repo, host=None, local=False):
    """Select without sending; only the legacy route discovers its fallback lazily."""
    declared = destinations(settings)
    # Consumer names extend the basename match, never the discovered roots.
    value = settings.get("JARVIS_REPO_ALIASES", "")
    try:
        aliases = json.loads(value) if value else {}
    except ValueError as error:
        raise DestinationRefusal("setting-invalid", "JARVIS_REPO_ALIASES", str(error)) from error
    if not isinstance(aliases, dict) or any(
            not isinstance(name, str) or not name or "/" in name
            for pair in aliases.items() for name in pair):
        raise DestinationRefusal("setting-invalid", "JARVIS_REPO_ALIASES")
    names = {repo, aliases.get(repo, repo)}
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
            roots = [(root, unread) for root, unread in destination_roots(target)
                     if root.rstrip("/").rsplit("/", 1)[-1] in names]
        except Failure as error:
            side = "host" if legacy and target.host else target.key
            raise DestinationRefusal("project-list-failed", side, str(error)) from error
        if len(roots) > 1:
            raise DestinationRefusal("repo-ambiguous", repo, "destination=%s roots=%s" % (target.key, " ".join(root for root, _ in roots)))
        if legacy:
            if roots:
                yield selectable(target, *roots[0], True)
        else:
            matches.extend((target, *root) for root in roots)
    if not legacy:
        if len(matches) > 1:
            raise DestinationRefusal("repo-ambiguous", repo, " ".join("%s:%s" % (target.key, root) for target, root, _ in matches))
        yield from (selectable(target, root, unread, False) for target, root, unread in matches)


def selectable(target, root, unread, fallback):
    """A matched root's route; a root its listing could not classify refuses, so no other side takes its note."""
    if unread is not None:
        raise DestinationRefusal("registration-unclassified", root, str(unread))
    return target, root, fallback


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


def run(args, cwd=None, data=None, operation=None, timeout=60, *, env=None):
    try:
        return subprocess.run(list(map(str, args)), cwd=cwd, input=data,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout, env=env)
    except (OSError, subprocess.SubprocessError) as error:
        raise failure(operation or Path(args[0]).name, error) from error


def checked(args, cwd=None, data=None, operation=None, timeout=60, *, env=None):
    operation = operation or Path(args[0]).name
    result = run(args, cwd, data, operation, timeout, env=env)
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


def voice_request(row):
    """An owner-unanswered row the relay forwarded from a voice call: an owner note opening `voice-request: caller=`."""
    return row["kind"] != "answer" and row.get("text", "").split("\n", 1)[0].startswith("voice-request: caller=")


def config(bash, root, *, env=None):
    return json.loads(checked([bash, LIB / "jarvis-env.sh", "config", root], env=env))


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
        # Reclamation may overwrite the log only after this state is durable.
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
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
        # -I: a -c program imports from its working directory otherwise.
        record = json.loads(checked([sys.executable, "-I", "-B", "-c", code, owner,
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


def project_roots(every=False):
    try:
        roots = destination_roots(Destination("local", None, None), every)
    except Failure as error:
        # Only an absent executable takes the install remedy: a listing kendex
        # refuses, such as one naming a folder with no UTF-8 form, names its own cause.
        if error.record["key"][1] != "FileNotFoundError":
            raise
        raise Failure(*error.record["key"], "kendex-missing fix=install-kendex-on-host-PATH " + str(error)) from error
    return [(Path(root).expanduser().resolve(), unread) for root, unread in roots]


def presence_roots(permitted):
    if not permitted():
        return [(None, "skipped", None)]
    results = []
    for root, unread in project_roots():
        # Jarvis cannot read a folder Git cannot classify, so no hold keeps
        # Slack from delivering that folder's notices.
        if unread is not None:
            results.append((str(root), "unclassified", unread.record))
            continue
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


# The first stderr word jarvis-env.sh gives a status read the runtime refused.
RUNTIME_REFUSED = "jarvis: dependency=agent-runtime-refused"


def replaced(account):
    return "A replacement Jarvis runs on " + (account or "its default account") + "."


def lane_mail():
    """The producer's own mailbox code; a target's installed copy is never run."""
    return LIB.parents[2] / "mailbox/scripts/lane-mail"


def orch_runtime():
    return LIB.parents[2] / "orch/scripts/orch-runtime"


def wall_time(at):
    return datetime.datetime.fromtimestamp(at, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def legacy_wall_notice(memory):
    cause = {"auth": "is signed out on %s", "usage": "has no room left on %s"}[memory["kind"]]
    account = memory["account"] or "its default account"
    at = wall_time(memory["at"])
    return ("Jarvis session " + memory["session"] + " " + cause % account
            + " (read at " + at + "): every turn it tries fails. " + memory["outcome"])


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


def notice_receipt(result):
    """The id of the owner notice lane-mail sent, or of the one it already
    holds: it refuses an owner notice whose text it delivered within the
    day, so that refusal is the receipt of the notice that landed."""
    return re.search(
        r"^lane-mail: (?:duplicate|owner-notice-repeated=overseer) id=(\S+)", result.stderr, re.M
    ) if result.returncode else re.search(r"^lane-mail: sent item=overseer id=(\S+)", result.stdout, re.M)


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
    owned = [row for row in rows if owner_row(row) and not row.get("answered")
             and now - instant(row["at"]).timestamp() >= OWNER_WAIT_SECS]
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
    """Each (root, listing failure or None) as (root, mailbox checkout or read failure, the root that reads that mailbox).

    A project registered inside another's git tree resolves to the outer
    mailbox. The mailbox's own checkout reads it, else the first listed
    root; a failed root reads for itself, to report the failure. A listed
    home is always its mailbox's own checkout: home_root takes its git top
    level, and `kendex project list --json` marks a linked worktree,
    which destination_roots skips.
    """
    resolved = []
    for root, unread in roots:
        if unread is not None:
            resolved.append((root, unread))
            continue
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
    listed = [(home, None)] if satellite else project_roots()
    roots = [root for root, _ in listed]
    # A home the project list omits (unregistered, removed, unreadable or a
    # linked worktree) still receives owner mail. Its to-lane alone is read for
    # those rows: no mail event, no to-overseer mark-read, no receipts.
    alone = side == "local" and home not in roots
    readers = mailbox_readers(bash, listed)
    if alone:
        # Its to-lane read takes owner rows alone, so it never replaces a
        # listed root's full read of a shared mailbox, nor takes its cursors.
        readers += mailbox_readers(bash, [(home, None)])
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


def forward_ready(settings, key, at):
    """Notify the existing log reader of an external forward's successful delivery.

    A scheduler cursor carries identity and time only. It creates no event
    block, mailbox send or independent watcher.
    """
    directory = Path(os.path.expanduser(settings["JARVIS_LOG_DIR"]))
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "events.log").open("ab") as out:
        fcntl.flock(out, fcntl.LOCK_EX)
        out.write(pass_output("forward-ready", {"key": key, "at": at}, []).encode())
        out.flush()
        os.fsync(out.fileno())


class Watch:
    def __init__(self, home, bash, settings, initial_passes=None):
        self.home, self.bash, self.settings = home, bash, settings
        self.forward_ready_due = None
        self.directory = Path(os.path.expanduser(settings["JARVIS_LOG_DIR"]))
        self.directory.mkdir(parents=True, exist_ok=True)
        self.log = self.directory / "events.log"
        self.path = self.directory / "batch.json"
        self.destinations = destinations(settings)
        seeds = self.initial_cursors(initial_passes) if initial_passes is not None else None
        self.state = json.loads(self.path.read_text()) if self.path.exists() else {
            "generation": uuid.uuid4().hex, "offset": 0, "spans": [], "due": None, "pending": None}
        self._saved = json.loads(json.dumps(self.state)) if self.path.exists() else None
        # Recovery must precede migration saves and decoding a possibly overwritten log.
        if "reclaim" in self.state:
            with self.log.open("r+b") as source:
                fcntl.flock(source, fcntl.LOCK_EX)
                self.recover_reclaim(source)
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
        self.collection = None
        self.mail_pending = {}
        # ("read" or "succession", future): one wall pass at a time, so a
        # succession in flight is never read for again.
        self.wall_pending = None
        self.next_wall = 0
        # ("read" or "restart", future): the exited controller's status read
        # or its restart, one at a time, so a restart in flight is never judged.
        self.exited_pending = None

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
                if record["side"] == "forward-ready":
                    due = record["roots"]["at"] + 5
                    self.forward_ready_due = due if self.forward_ready_due is None else min(self.forward_ready_due, due)
                self.state["cursor_offset"] = at
        self.state["cursor_offset"] = max(self.state.get("cursor_offset", 0), end)

    def commit_reclaim(self, cut):
        self.state["log_base"] = self.state.get("log_base", 0) + cut
        for field in ("offset", "cursor_offset"):
            self.state[field] -= cut
        self.state["spans"] = [[span[0] - cut, span[1] - cut, *span[2:]]
                               for span in self.state["spans"]]
        del self.state["reclaim"]
        self.save()

    def recover_reclaim(self, source):
        transaction = self.state["reclaim"]
        end = transaction["end"]
        source.seek(end)
        marked = source.read(1) == b"\x00"
        phase = transaction["phase"]
        # A restarted process can see unsynced log changes in page cache.
        # Synchronize before retiring their recovery record in either branch.
        if phase == "ready" and not marked:
            # Truncate removed the marker. Never overwrite subsequent consumer appends.
            os.fsync(source.fileno())
            self.commit_reclaim(transaction["cut"])
            return
        if phase == "ready":
            source.seek(transaction["cut"])
            source.write(base64.b64decode(transaction["suffix"]))
            source.flush()
        elif phase != "prepared":
            raise RuntimeError("reclaim-phase-invalid: " + str(phase))
        os.fsync(source.fileno())
        # The undo image restores old coordinates. The owner-only marker is
        # below both checkpoints and outside every live event span.
        self.state["offset"] = self.state["cursor_offset"] = end + int(marked)
        del self.state["reclaim"]
        self.save()

    def reclaim(self):
        if self.state["pending"] is not None or not self.log.exists():
            return
        # Keep the inode: a consumer may have opened it before waiting for this lock.
        with self.log.open("r+b") as source:
            fcntl.flock(source, fcntl.LOCK_EX)
            self.ingest(source)
            self.save()
            end = source.seek(0, os.SEEK_END)
            # Open blocks and non-LF fragments pin all bytes until their real boundary.
            if self.state["offset"] != end or self.state.get("cursor_offset", 0) != end:
                return
            cut = min((span[0] for span in self.state["spans"]), default=end)
            # Each pass copies the retained suffix. Waiting until the retired
            # prefix is at least that large keeps a backlog drain linear.
            if not cut or end - cut > cut:
                return
            source.seek(cut)
            suffix = source.read()
            # Consumer appends need not sync; persist the snapshot before preparing undo.
            os.fsync(source.fileno())
            self.state["reclaim"] = {"phase": "prepared", "cut": cut, "end": end,
                                     "suffix": base64.b64encode(suffix).decode()}
            self.save()
            # Supported producers escape NUL. Its position distinguishes an
            # interrupted overwrite from a completed cut followed by appends.
            source.seek(end)
            source.write(b"\x00")
            source.flush()
            os.fsync(source.fileno())
            self.state["reclaim"]["phase"] = "ready"
            self.save()
            source.seek(0)
            source.write(suffix)
            source.flush()
            os.fsync(source.fileno())
            source.truncate(len(suffix))
            os.fsync(source.fileno())
            self.commit_reclaim(cut)

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
                self.reclaim()
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
            base = self.state.get("log_base", 0)
            logical = [[span[0] + base, span[1] + base, *span[2:]] for span in selected]
            identity = json.dumps([self.state["generation"], logical]).encode()
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
        self.reclaim()
        print("watch-loop: batch=" + pending["key"] + " id=" + receipt[0] + " inbox=overseer", flush=True)

    def live(self, now=None):
        """Whether the recorded controller wrote a heartbeat in the last LIVE_SECS."""
        try:
            result = run([self.bash, LIB / "jarvis-env.sh", "live", self.home])
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            return False
        if result.returncode:
            error = child_failure("presence-live", result)
            # A status read the runtime refuses denies renewal without a
            # report: the wall check is the one that reports it.
            if (error.record["key"][1:] == ["refusal", "dependency"]
                    and not error.record["detail"].startswith(RUNTIME_REFUSED + " ")):
                raise error
            return False
        try:
            at = datetime.datetime.fromisoformat(result.stdout.strip().replace("Z", "+00:00")).timestamp()
            if now is None:
                now = epoch()
            return 0 <= now - at < LIVE_SECS
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            return False

    def wall(self):
        """The recorded controller's wall: session, pane, account, kind and row.
        Kind is None for a session its rows do not read walled; None with no bound
        controller; a Failure where the controller or its rows were not read:
        a missing package, or the runtime's refusal of the status or the
        verdict read."""
        try:
            result = run([self.bash, LIB / "jarvis-env.sh", "wall", self.home], operation="controller-wall")
            if result.returncode:
                error = child_failure("controller-wall", result)
                return error if error.record["key"][1:] == ["refusal", "dependency"] else None
            bound = json.loads(result.stdout)
            verdict = run([self.bash, orch_runtime(), "watch", "wall", "--file", bound["rows"]],
                          operation="controller-wall")
            if verdict.returncode:
                raise child_failure("controller-wall", verdict)
            rows = json.loads(verdict.stdout)["result"]
            if rows["reading"] == "unreadable":
                raise Failure("controller-wall", "rows", "unreadable", rows["cause"])
            walled = rows["reading"] == "live" and rows["verdict"] == "walled"
            return bound["session"], bound["pane"], bound["account"], rows["kind"] if walled else None, rows
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
            return failure("controller-wall", error)

    def accept_wall(self, reading, now):
        """One wall reading judged at NOW: the wall kind a succession starts for, or None.

        The notice the last succession owes goes first, and a new wall waits
        for it. A wall is one episode of one controller, its session in its
        pane: a resumed session is another controller, and the episode ends
        once the controller in control reads unwalled, so a refused succession
        whose predecessor recovers in place is told of again when next walled."""
        if isinstance(reading, Failure):
            self.failed_pass("wall", reading.record)
            return None
        self.state.pop("wall_failure", None)
        memory = self.state.get("wall")
        session, pane, account, kind, rows = reading or (None, None, None, None, {})
        if (memory is not None and "row_at" not in memory and memory["kind"] == kind == "usage"
                and session == memory["session"] and pane == memory["pane"]
                and (rows.get("at") is None or rows["at"] <= memory["at"])):
            if memory["outcome"] is not None:
                memory["legacy_notice"] = {"text": legacy_wall_notice(memory), "reported": memory["noticed"]}
            memory.update(row_at=rows.get("at"), window=rows.get("window"), reset=rows.get("reset"),
                          outcome=None, noticed=False)
            self.save()
        if memory is not None and "row_at" in memory:
            same = (kind == "usage" and (session, pane, rows.get("at")) ==
                    (memory["session"], memory["pane"], memory["row_at"]))
            if not same and reading is not None and memory["outcome"] is None:
                memory["outcome"] = (replaced(account) if session != memory["session"] else
                                     "The watch no longer reads that stop.")
                self.save()
            self.notify(memory)
            if same:
                return kind if memory["outcome"] is None else None
            if reading is None or not memory["noticed"]:
                return None
            del self.state["wall"]
            memory = None
        if memory is not None and not memory["noticed"]:
            if memory["outcome"] is None and reading is not None:
                # The loop that started the succession ended before its answer,
                # as one under the predecessor's harness does once the
                # predecessor ends: another session in control is its proof. A
                # successor is always a new session; the walled one resumed in
                # another pane replaced nothing.
                memory["outcome"] = (replaced(reading[2]) if reading[0] != memory["session"] else
                                     "The replacement's outcome was not read; jarvis-session status shows it.")
            if memory["outcome"] is not None:
                self.notify(memory)
        if memory is not None and memory["noticed"] and reading is not None and kind is None:
            del self.state["wall"]
            memory = None
        if kind is None or memory is not None and ((session, pane) == (memory["session"], memory["pane"]) and kind != "usage"
                                                   or not memory["noticed"]):
            self.save()
            return None
        memory = {"session": session, "pane": pane, "account": account, "kind": kind, "at": now,
                  "outcome": None, "noticed": False}
        if kind == "usage":
            memory.update(row_at=rows.get("at"), window=rows.get("window"), reset=rows.get("reset"))
        self.state["wall"] = memory
        self.save()
        if kind == "usage":
            self.notify(memory)
        return kind

    def session(self, operation, verb, *args):
        """jarvis-session's answer to VERB, its last stdout line, or a Failure."""
        try:
            # The session command bounds each wait it makes, the hand-over's too.
            result = run([self.bash, LIB.parent / "jarvis-session", verb, "--home", self.home, *args],
                         self.home, operation=operation, timeout=None)
            lines = result.stdout.splitlines()
            if not lines:
                raise child_failure(operation, result)
            answer = json.loads(lines[-1])
            if not isinstance(answer, dict):
                raise ValueError("answer-unread")
            return answer
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            return failure(operation, error)

    def succeed(self, usage):
        """jarvis-session succeed away from the walled account: its answer, or a Failure.

        Either wall kind is the account's own, so the successor leaves it."""
        return self.session("succeed", "succeed", "--account-walled", *usage)

    def exited(self):
        """The home's controller as jarvis-session status answers it, or a Failure."""
        return self.session("controller-status", "status", "--mark-unread")

    def restart(self, memory):
        """The exited controller started again by MEMORY's route: Start's
        resume of its recorded harness and account, or succeed away from it."""
        if memory["route"] == "succeed":
            return self.session("restart", "succeed", "--exited")
        account = ["--account", memory["account"]] if memory["account"] else []
        return self.session("restart", "start", "--harness", memory["harness"], *account,
                            "--mode", "resume", "--origin", "manual", "--keep-brief")

    def accept_exited(self, answer, now):
        """One status reading at NOW: the episode whose restart starts now, or None.

        A controller whose process is gone, with no stop asked, reads
        stopped and ended. Its exit is one episode: one resume, one succeed
        where that resume is refused, and one owner notice of the outcome.
        A restart that runs holds the episode for LIVE_SECS after it ran: an
        exit read inside that window ends it as failed with one more notice
        and no restart, so a controller that exits on every resume is not
        restarted in a loop. A failed one ends once a controller runs again."""
        if isinstance(answer, Failure):
            self.failed_pass("exited", answer.record)
            return None
        if answer.get("unread"):
            # Status could not make this read: its state and reason name why,
            # and say nothing of the controller.
            self.failed_pass("exited", Failure("controller-status", "refusal", answer.get("reason"),
                                               answer.get("detail") or answer.get("reason")).record)
            return None
        self.state.pop("exited_failure", None)
        memory = self.state.get("exited")
        if memory is not None and memory.get("ran") and memory["noticed"] and now - memory["ran_at"] >= LIVE_SECS:
            # The restart outlived its window: a later exit is another one.
            del self.state["exited"]
            self.save()
            memory = None
        if not answer.get("harness"):
            # Every recorded controller names its harness: this read names none.
            return None
        if memory is None:
            if (answer.get("state"), answer.get("reason")) != ("stopped", "ended"):
                return None
            memory = {"at": now, "harness": answer["harness"], "account": answer.get("account"),
                      "route": "resume", "refused": [], "outcome": None, "noticed": False}
            self.state["exited"] = memory
            self.save()
            return memory
        if memory["noticed"]:
            if memory.get("ran"):
                if (answer.get("state"), answer.get("reason")) == ("stopped", "ended"):
                    memory.update(ran=False, noticed=False, outcome=(
                        "It started again on " + (answer.get("account") or "its default account")
                        + ", then exited again (read at " + wall_time(now) + "), so it is not started again."))
                    self.save()
                    self.tell_exited(memory)
            elif answer.get("state") == "running":
                del self.state["exited"]
                self.save()
            return None
        if memory["outcome"] is not None:
            self.tell_exited(memory)
            return None
        return self.accept_restart(answer, now)

    def accept_restart(self, answer, now):
        """The restart's answer, or a later reading of it: the episode whose
        succeed starts now where its resume was refused, or None."""
        memory = self.state["exited"]
        if isinstance(answer, Failure):
            state, reason, detail = "failed", answer.record["key"][2], answer.record["detail"]
        else:
            state, reason, detail = answer.get("state"), answer.get("reason"), answer.get("detail") or ""
        if state in ("starting", "handing-over", "stopping"):
            return None
        if state == "running":
            memory["ran"], memory["ran_at"] = True, now
            memory["outcome"] = ("It started again on " + (answer.get("account") or "its default account")
                                 + " (" + str(reason) + ").")
        else:
            memory["refused"].append(memory["route"] + " " + str(reason))
            if memory["route"] == "resume":
                memory["route"] = "succeed"
                self.save()
                return memory
            memory["outcome"] = ("It did not start again: " + "; ".join(memory["refused"])
                                 + (" (" + detail[:200] + ")" if detail else "") + ".")
        self.save()
        self.tell_exited(memory)
        return None

    def tell_exited(self, memory):
        """The owner's one notice of an exited controller: its harness, its
        account, the time it was read and the restart's outcome."""
        text = ("Jarvis on " + (memory["account"] or "its default account") + " (" + memory["harness"]
                + ") exited (read at " + wall_time(memory["at"]) + "). " + memory["outcome"])
        try:
            result = self.owner_notice(text, "exited-notice")
            if not notice_receipt(result):
                raise child_failure("exited-notice", result)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            self.failed_pass("exited-notice", failure("exited-notice", error).record)
            return
        memory["noticed"] = True
        self.state.pop("exited-notice_failure", None)
        self.save()

    def owner_notice(self, text, operation, ref=None):
        """lane-mail's answer to the owner notice TEXT, in REF's thread."""
        with tempfile.NamedTemporaryFile(mode="w", dir=self.directory) as payload:
            payload.write(text + "\n")
            payload.flush()
            return run([self.bash, lane_mail(), "notice", "--item", "overseer", "--to", "owner", "--file", payload.name,
                        *(["--ref", ref] if ref else [])], self.home, operation=operation)

    def accept_succession(self, answer, requested):
        memory = self.state["wall"]
        if "row_at" in memory:
            recovery = answer.get("wall_recovery") if not isinstance(answer, Failure) else None
            state = answer.get("state") if not isinstance(answer, Failure) else None
            if requested and not isinstance(answer, Failure) and recovery not in ("unconfirmed", "pending"):
                memory.pop("resume_requested", None)
            if state not in ("running", "handing-over"):
                self.failed_pass("wall-recovery", answer.record if isinstance(answer, Failure) else
                                 Failure("wall-recovery", "succeed", answer.get("reason"), answer.get("detail") or "").record)
                self.save()
                return
            self.state.pop("wall-recovery_failure", None)
            if recovery == "unconfirmed" and "wall_resume" in answer:
                memory["resume"] = answer["wall_resume"]
            elif recovery == "confirmed":
                memory["outcome"] = "The session resumed after the reset."
            if recovery is not None or state == "handing-over":
                self.save()
                if recovery == "confirmed":
                    self.notify(memory)
                return
        if isinstance(answer, Failure):
            memory["outcome"] = "No replacement started: " + answer.record["detail"][:200] + "."
        elif answer.get("state") == "running":
            memory["outcome"] = replaced(answer.get("account"))
        elif answer.get("state") == "handing-over":
            memory["outcome"] = "A replacement Jarvis is starting."
        else:
            memory["outcome"] = ("No replacement started (" + str(answer.get("reason")) + ")"
                                 + (": " + str(answer["detail"]) if answer.get("detail") else "."))
        self.save()
        self.notify(memory)

    def notify(self, memory):
        """The owner's one notice of a wall: its session, its time, its cause, its
        account and the succession's outcome.

        The session and the time make each episode's text its own, so the
        mailbox's refusal of that same text is the receipt of the notice that
        landed, as after a stop before this save."""
        legacy = memory.get("legacy_notice")
        if legacy is not None:
            try:
                _, rows = mailbox_events(self.bash, self.home, "to-overseer")
            except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
                self.failed_pass("wall-notice", failure("wall-notice", error).record)
                return
            receipt = next((row["id"] for row in rows
                            if row.get("kind") == "notice" and row.get("to") == "owner"
                            and row.get("from") == "overseer" and not row.get("ref")
                            and row.get("text") == legacy["text"]), None)
            del memory["legacy_notice"]
            if receipt:
                memory["notice_id"] = receipt
            elif legacy["reported"]:
                memory["notice_missing"] = True
            self.save()
        if memory["noticed"]:
            return
        at = wall_time(memory["at"])
        account = memory["account"] or "its default account"
        session = "Jarvis session " + memory["session"]
        ref = None if memory.get("notice_missing") else memory.get("notice_id")
        usage = "row_at" in memory
        outcome_notice = usage and (ref is not None or memory.get("notice_missing"))
        if outcome_notice:
            if memory["outcome"] is None:
                return
            text = session + " (stop read at " + at + "): " + memory["outcome"]
        elif usage:
            window = memory["window"] or "usage"
            reset = "resets at " + wall_time(memory["reset"]) if memory["reset"] is not None else "reset time unknown"
            text = session + f" hit its {window} limit on {account} (read at {at}, {reset})."
        else:
            text = legacy_wall_notice(memory)
        try:
            result = self.owner_notice(text, "wall-notice", ref)
            if outcome_notice and ref and result.returncode and child_failure("wall-notice", result).record["key"][1:] == [
                    "refusal", "ref-unknown"]:
                memory["notice_missing"] = True
                self.save()
                result = self.owner_notice(text, "wall-notice")
            receipt = notice_receipt(result)
            if not receipt:
                raise child_failure("wall-notice", result)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            self.failed_pass("wall-notice", failure("wall-notice", error).record)
            return
        if usage and not outcome_notice:
            memory["notice_id"] = receipt[1]
        else:
            memory["noticed"] = True
        self.state.pop("wall-notice_failure", None)
        self.save()

    def remote_command(self, args):
        # Carry exact dependency bytes, never target-local code or settings.
        files = package_files(("jarvis/scripts/vm-watch.sh", "jarvis/scripts/lib/watch.py",
                               "jarvis/scripts/lib/jarvis-env.sh", "slack/scripts/lib/settings.py",
                               "slack/scripts/lib/refusals.py", "orch/scripts/lib/kendex-env.sh", *MAILBOX_FILES))
        command, _ = remote_command(files, "jarvis/scripts/vm-watch.sh", args)
        return command

    def remote(self, destination):
        args = ["--side", destination.key, "--cursor", json.dumps(self.cursors.get(destination.key, {}))]
        return run(host_args(destination, "bash -s"), data=self.remote_command(args))

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
            process = subprocess.Popen(host_args(destination, "bash -s"),
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
            if result and (report_key(result) != (held := self.cursors.get("report", {})).get("event") or 0 < int(self.settings.get("ORCH_REPORT_EVERY_MINUTES") or 0) * 60 <= epoch() - held.get("posted", 0)):
                self.append(pass_output("report", {"event": report_key(result), "posted": epoch()}, [(None, result)]))

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
            command = [self.bash, LIB.parent / "jarvis-session"]
            output = checked([*command, "forward-drain", "--collection", "--home", self.home],
                             self.home, operation="forward-drain")
            # Status shares the forwarding owners state location and lifecycle.
            # This local read starts no remote call or independent polling task.
            status = json.loads(checked([*command, "status", "--main", "--home", self.home],
                                        self.home, operation="forward-status"))
            requests = status.get("requests")
            if not isinstance(requests, list) or not all(isinstance(row, dict) for row in requests):
                raise Failure("forward-status", "protocol", "status-unread", "requests")
            interval = 5 if any(row.get("state") in ("delivered", "read") for row in requests) else FORWARD_EVERY_SECS
            return output, interval, (status.get("reachable"), status.get("cause"), status.get("checked_at"))
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

    def collected(self, result):
        """One stderr line per change of the forward collection's outcome, so the unit's journal shows each."""
        if isinstance(result, Failure):
            outcome = ("failed", *result.record["key"])
            line = "forward=failed cause=" + line_value(result.record["detail"], True, 200)
        else:
            reachable, cause, at = result
            outcome = (reachable, cause)
            line = "forward=" + ("unchecked" if reachable is None else "reachable" if reachable else "unreachable")
            line += "".join(" %s=%s" % pair for pair in (("cause", cause), ("checked_at", at)) if pair[1])
        if outcome != self.collection:
            self.collection = outcome
            print("watch-loop: " + line, file=sys.stderr, flush=True)

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
            # With a period, an open voice request is reminded each period
            # from its arrival; every other row once, at OWNER_WAIT_SECS.
            period = int(self.settings["JARVIS_VOICE_REMIND_SECS"])
            voiced = {row["id"] for row in rows if period and voice_request(row)}
            reminded = memory.get("reminded", {})
            due = [row for row in rows if row["id"] in checked_ids
                   and now - instant(row["at"]).timestamp() >= (period if row["id"] in voiced else OWNER_WAIT_SECS)]
            owed = [row for row in due if (now - reminded.get(row["id"], 0) >= period if row["id"] in voiced
                                           else row["id"] not in memory.get("reported", []))]
            blocks.extend(event("owner-unanswered", id=row["id"], at=row["at"], kind=row["kind"]) +
                          line_value(row.get("text", ""), limit=4000) + "\n"
                          for row in owed)
            # A checked row the helper no longer lists is covered; a row
            # delivered during the check waits for the next one. Only rows
            # old enough to remind are remembered as reported.
            self.state["unanswered"] = {
                "pending": [row for row in memory.get("pending", [])
                            if row["id"] not in checked_ids or row["id"] in listed],
                "reported": [row["id"] for row in due],
                "reminded": {row["id"]: now if row in owed else reminded[row["id"]]
                             for row in due if row["id"] in voiced},
                "failed": False}
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
            self.next_unanswered = now + min(UNANSWERED_EVERY_SECS,
                                             int(self.settings["JARVIS_VOICE_REMIND_SECS"]) or UNANSWERED_EVERY_SECS)
            self.unanswered_pending = passes.submit(self.unanswered, list(waiting))
        wall = self.wall_pending
        if wall is not None and wall[1].done():
            self.wall_pending = None
            if wall[0] == "succession":
                self.accept_succession(wall[1].result(), wall[2])
            else:
                reading = wall[1].result()
                kind = self.accept_wall(reading, now)
                # A wall read that binds no live controller, or an exit's
                # episode still open, reads the recorded one's status.
                if self.exited_pending is None and (reading is None or "exited" in self.state):
                    self.exited_pending = ("read", passes.submit(self.exited))
                if kind is not None:
                    usage = []
                    requested = False
                    if kind == "usage":
                        memory = self.state["wall"]
                        usage = ["--usage-wall", memory["session"], memory["pane"]]
                        if memory["reset"] is not None and now >= memory["reset"]:
                            if "resume" in memory:
                                usage.extend(("--reset-passed", "--resume-cursor", str(memory["resume"]["turns_before"])))
                            elif not memory.get("resume_requested"):
                                # A child lost after launch might already have pasted.
                                memory["resume_requested"] = True
                                self.save()
                                requested = True
                                usage.append("--reset-passed")
                    self.wall_pending = ("succession", passes.submit(self.succeed, usage), requested)
        exited = self.exited_pending
        if exited is not None and exited[1].done():
            self.exited_pending = None
            memory = (self.accept_exited(exited[1].result(), now) if exited[0] == "read"
                      else self.accept_restart(exited[1].result(), now))
            if memory is not None:
                self.exited_pending = ("restart", passes.submit(self.restart, dict(memory)))
        if self.wall_pending is None and now >= self.next_wall:
            self.next_wall = now + 30
            self.wall_pending = ("read", passes.submit(self.wall))
        if self.satellite:
            # A satellite renews no fleet presence and owes no checkpoint;
            # it drains its forward outbox on the same executor instead.
            work = self.forward_pending
            if work is not None and work.done():
                result = work.result()
                interval = FORWARD_EVERY_SECS
                if isinstance(result, Failure):
                    self.accept_forward(result)
                    self.collected(result)
                else:
                    output, interval, reach = result
                    self.accept_forward(output)
                    self.collected(reach)
                self.next_forward = now + interval
                self.forward_pending = None
            if self.forward_pending is None:
                if self.forward_ready_due is not None:
                    self.next_forward = min(self.next_forward, self.forward_ready_due)
            if self.forward_pending is None and now >= self.next_forward:
                # This pass covers already-ingested deliveries. Later cursors
                # retain their earliest deadline while the worker runs.
                self.forward_ready_due = None
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
        # A machine that answered lists only roots, none at all included.
        if all(root is not None for root, _, _ in results):
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
            elif status not in ("skipped", "unclassified"):
                raise RuntimeError("presence-status-invalid")
        self.save()


def unit_word(value):
    # systemd.service(5) and systemd.exec(5) apply percent specifiers after
    # unquoting. The unit uses ':' to disable ExecStart dollar expansion.
    return json.dumps(value.replace("%", "%%"), ensure_ascii=False)


def install(bash, home, settings, print_only):
    from home import replace

    if not str(home).isprintable():
        raise Failure("watch-install", "refusal", "home-invalid", repr(str(home)))
    # Preserve only the paths used to find saved settings, the outbox and
    # the watch lock. Unset omitted paths so the manager cannot supply other
    # values. Read the saved role at every start, including after main-host --clear.
    path_keys = ("KENDEX_ENV_FILE", "XDG_STATE_HOME", "JARVIS_LOG_DIR")
    paths = {"HOME": str(Path.home())}
    paths.update({key: os.environ[key] for key in path_keys if key in os.environ})
    unset = ["JARVIS_MAIN_HOST", *(key for key in path_keys if key not in paths)]
    if "JARVIS_MAIN_HOST" in os.environ:
        saved = config(bash, home, env={key: value for key, value in os.environ.items() if key not in unset})
        if saved["JARVIS_MAIN_HOST"] != settings["JARVIS_MAIN_HOST"]:
            raise Failure("watch-install", "refusal", "main-host-not-persisted",
                          "Save the satellite binding with jarvis-session main-host --set before installing.")
    unit = LIB.parents[1] / "systemd/jarvis-watch.service"
    rendered = Template(unit.read_text()).substitute(
        directory=str(home).replace("%", "%%"), launcher=unit_word(str(LIB.parent / "watch-loop")),
        home=unit_word(str(home)), environment=" ".join(unit_word(f"{key}={value}") for key, value in paths.items()),
        unset=" ".join(unset))
    if print_only:
        sys.stdout.write(rendered)
        return

    # loginctl(1): enable starts the unit with the user manager, while
    # lingering starts the user manager at boot and keeps it after logout.
    checked(["loginctl", "enable-linger", str(os.getuid())], operation="enable-linger")
    config_dir = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    target = config_dir / "systemd/user" / unit.name
    target.parent.mkdir(parents=True, exist_ok=True)
    replace(target, rendered)
    for args in (("daemon-reload",), ("enable", unit.name)):
        checked(["systemctl", "--user", *args], operation="systemctl-" + args[0])
    # Like slack install, confirm the unit is active. Type=notify makes
    # restart wait for initialization, so there is no fixed startup sleep.
    try:
        checked(["systemctl", "--user", "restart", unit.name], operation="systemctl-restart")
        checked(["systemctl", "--user", "is-active", "--quiet", unit.name], operation="systemctl-is-active")
    except Failure as error:
        raise Failure(*error.record["key"], f"{error}. Read journalctl --user -u {unit.name}") from error
    print("watch-loop: installed=" + str(target))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("loop", "pass", "install"))
    parser.add_argument("--bash", required=True)
    parser.add_argument("--home", default=".")
    parser.add_argument("--side", default="local")
    parser.add_argument("--cursor", default="{}")
    parser.add_argument("--presence", action="store_true")
    parser.add_argument("--satellite", action="store_true", help="require satellite settings at service start")
    parser.add_argument("--print", action="store_true", help="render the unit without installing it")
    parser.add_argument("--initial-pass", action="append", type=Path,
                        help="initialize fresh loop state from a reconciled public pass, then exit; repeat per destination")
    args = parser.parse_args()
    if args.initial_pass and args.mode != "loop":
        parser.error("--initial-pass requires loop mode")
    if args.print and args.mode != "install":
        parser.error("--print requires install mode")
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
        if (args.mode == "install" or args.satellite) and role(settings).kind != "satellite":
            raise Failure("watch-loop", "refusal", "satellite-required", str(home))
        if args.mode == "install":
            return install(args.bash, home, settings, args.print)
        if not re.fullmatch(r"0|[1-9][0-9]*", settings["JARVIS_WAKE_SETTLE_SECS"]):
            raise RuntimeError("settle-invalid")
        if not re.fullmatch(r"0|[1-9][0-9]*", settings["JARVIS_VOICE_REMIND_SECS"]):
            raise RuntimeError("voice-remind-invalid")
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
            if args.satellite and "NOTIFY_SOCKET" in os.environ:
                checked(["systemd-notify", "--ready"], operation="watch-ready")
            # Slow SSH and mailbox reads cannot extend an already-started
            # settle. Only this thread appends results or commits batch state.
            with ThreadPoolExecutor(max_workers=2 * len(watch.destinations) + 4) as passes:
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
