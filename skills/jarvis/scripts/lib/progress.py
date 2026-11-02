"""The handoff form: progress-log writes and checks it, owner-unanswered reads it.

A record is one list item whose nested items are the fields of
references/long-session.md § Progress records. A value's later lines are
indented four spaces. The README states the id form. The archive INDEX line
of references/long-session.md § Handoff dates an archived file by its records.
A State entry is one line with its indented lines; the ids it names decide
whether `progress-log --check-state` lists it.
"""
from pathlib import Path
import re

from sections import headings, section

DEFAULT_HANDOFF = Path("state/handoff.md")
HEAD = "Id and time"
FIELDS = ("Operation", "Observed result and source", "Decision", "State change")
_HEAD = re.compile(r"^- " + HEAD + r": (P-\d{8}T\d{6}Z(?:-\d+)?) (\S+)$")
_FIELD = re.compile(r"^  - (" + "|".join(map(re.escape, FIELDS)) + r"): ?(.*)$")
_LEGACY = re.compile(r"^- \d{2}:\d{2}Z (.*)$")
INDEX = "INDEX.md"
UNREAD = "unread"
_INDEX_LINE = re.compile(r"- (\S+)(.*)")
_MINUTE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z")
# skills/slack/schemas/journal.md: every relay delivery is keyed `channel:ts`,
# ts a Slack message stamp, the root a top-level message's replies name.
SLACK_KEY = re.compile(r"([A-Za-z0-9]+):(\d+\.\d+)")
# skills/mailbox lane-mail mints `<epoch>-<pid>-<random>`; ten epoch digits
# keep a YYYY-MM-DD date from binding a line.
_MAILBOX_ID = r"\d{10,}-\d+-\d+"
# Narrower than Linear's own identifier shape, which a mailbox id's first two
# parts would match; the alternation order reads a mailbox id whole first.
_TRACKER_ID = r"[A-Z][A-Z0-9]*-\d+"
_ID = re.compile(r"(?<![\w-])(?:(?P<mailbox>%s)|(?P<slack>%s)|(?P<tracker>%s))(?![\w-])"
                 % (_MAILBOX_ID, SLACK_KEY.pattern, _TRACKER_ID))
# The Linear package's closed states: formatters.sh issue_is_open.
CLOSED_TYPES = ("completed", "canceled")


def handoff_path(home, selected):
    """The handoff a --handoff value selects: an absolute path is itself, a relative one starts at the home root."""
    return home / selected


def archive_dir(handoff):
    """The archive beside a handoff, which holds its earlier generations."""
    return handoff.parent / "archive"


def record_id(stamp, taken):
    """P- and the UTC stamp, with -N added when the handoff already holds it."""
    base = "P-" + stamp.replace("-", "").replace(":", "")
    candidate, number = base, 1
    while candidate in taken:
        number += 1
        candidate = "%s-%d" % (base, number)
    return candidate


def format_record(identity, stamp, values):
    lines = ["- %s: %s %s" % (HEAD, identity, stamp)]
    for field in FIELDS:
        # A blank line would end the list item, so a value keeps no empty line.
        parts = [part for part in values[field].splitlines() if part.strip()] or [""]
        lines.append(("  - %s: %s" % (field, parts[0])).rstrip())
        lines.extend("    " + part for part in parts[1:])
    return "".join(line + "\n" for line in lines)


def records(text):
    """Every record in text as a dict of id, at and its fields."""
    found, current, field = [], None, None
    for line in text.splitlines():
        head = _HEAD.match(line)
        if head:
            current = {"id": head[1], "at": head[2]}
            found.append(current)
            field = None
            continue
        if current is None:
            continue
        match = _FIELD.match(line)
        if match:
            field = match[1]
            current[field] = match[2]
        elif field is not None and line.startswith("    ") and line.strip():
            current[field] += "\n" + line[4:]
        else:
            current, field = None, None
    return found


def legacy_entries(text):
    """The text of each pre-cutover `- HH:MMZ ...` item and its indented lines.

    Retained archives still hold this form; nothing writes it, and a reader
    applies it to archive files only.
    """
    found, current = [], None
    for line in text.splitlines():
        head = _LEGACY.match(line)
        if head:
            current = [head[1]]
            found.append(current)
        elif current is not None and line[:1].isspace() and line.strip():
            current.append(line.strip())
        else:
            current = None
    return ["\n".join(lines) for lines in found]


def index_line(name, text):
    """The INDEX.md bullet for the archived file name: the minutes of its first and last record.

    An undated legacy entry leaves both endpoints unread, and so does a
    file with no record, so a reader reads the file.
    """
    stamps = [record["at"] for record in records(text)]
    if not stamps or legacy_entries(text):
        start = end = UNREAD
    else:
        # The fixed-width form sorts as time does.
        start, end = min(stamps)[:16] + "Z", max(stamps)[:16] + "Z"
    return "- %s dates=%s..%s\n" % (name, start, end)


def index_ends(text):
    """Each file an INDEX.md text lists to its END minute string, or None where END is unread.

    Only FILE and dates are read. A repeated line can only widen what is read,
    so the latest END wins and an unread END stays unread.
    """
    ends = {}
    for line in text.splitlines():
        item = _INDEX_LINE.fullmatch(line)
        if not item:
            continue
        fields = dict(field.split("=", 1) for field in item[2].split() if "=" in field)
        _, dots, end = fields.get("dates", "").partition("..")
        end = end if dots and _MINUTE.fullmatch(end) else None
        known = ends.get(item[1], end)
        ends[item[1]] = None if end is None or known is None else max(end, known)
    return ends


def ids(text):
    return {record["id"] for record in records(text)}


def state_entries(lines):
    """Each entry of the State section in keepends lines as (line number, text).

    An entry is a non-blank, non-heading line and the indented lines after it,
    so a parent and its child items are one entry. A State heading that is
    missing or repeated raises section's LookupError.
    """
    start, end = section(lines, "State")
    heads = {index for index, _, _ in headings(lines)}
    found, current = [], None
    for index in range(start + 1, end):
        line = lines[index]
        if index in heads:
            current = None
        elif not line.strip():
            continue
        elif current is not None and line[:1].isspace():
            current[1].append(line)
        else:
            current = (index + 1, [line])
            found.append(current)
    return [(number, "".join(text)) for number, text in found]


def state_ids(text):
    """The tracker ids and the mailbox and Slack ids text names, in order and each once."""
    tracker, other = {}, {}
    for match in _ID.finditer(text):
        (tracker if match["tracker"] else other)[match[0]] = None
    return list(tracker), list(other)


def check_state(entries, reads, not_issue):
    """Each State entry to list as (kind, line number, ids), in entry order.

    reads maps a tracker id to its read (state name, state type); a tracker id
    with no read and not in not_issue is unread. An entry with an open tracker
    id stays unlisted, and an entry is closed only when every tracker id it
    names read closed. A not-issue ref binds nothing.
    """
    found = []
    for number, text in entries:
        tracker, other = state_ids(text)
        refused = [ref for ref in tracker if ref in not_issue]
        tracker = [ref for ref in tracker if ref not in not_issue]
        if refused:
            found.append(("not-issue", number, refused))
        if not tracker:
            if not other:
                found.append(("unbound", number, []))
            continue
        if any(ref in reads and reads[ref][1] not in CLOSED_TYPES for ref in tracker):
            continue
        unread = [ref for ref in tracker if ref not in reads]
        if unread:
            found.append(("unread", number, unread))
        else:
            found.append(("closed", number, ["%s:%s" % (ref, reads[ref][0]) for ref in tracker]))
    return found
