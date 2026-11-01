"""List the owner's messages in the Jarvis home inbox that nothing answers.

The mailbox's public events read supplies both boxes and its mail classes;
the selected handoff and the archive beside it supply progress records. This
module only judges which reference answers which owner row.
"""
import argparse
import datetime
import json
from pathlib import Path
import re
import sys

LIB = Path(__file__).resolve().parent
sys.path.insert(0, str(LIB))
from progress import DEFAULT_HANDOFF, INDEX, archive_dir, handoff_path, index_ends, legacy_entries, records  # noqa: E402
import watch  # noqa: E402

# Without --since the list starts one day back, the consumer's reporting
# baseline. A caller that waits on rows passes its own --since.
DEFAULT_WINDOW_SECS = 24 * 60 * 60
# An owner's file posted as its own Slack message lands at most this many
# seconds from the text it belongs to.
PAIR_SECS = 30
# skills/slack/schemas/journal.md: every relay delivery is keyed `channel:ts`,
# ts a Slack message stamp, the root a top-level message's replies name.
SLACK_KEY = re.compile(r"([A-Za-z0-9]+):(\d+\.\d+)")
# The relay's fetch_files line for each file of an owner's message: the path
# skills/slack store.save_file wrote, or why it was not fetched.
FILE_LINE = re.compile(r".*/tmp/slack/files/[A-Za-z0-9._-]+|file \S* not fetched: .*")


class Refusal(Exception):
    """KEY, the value it names, and the cause's first line."""


def box(bash, home, name):
    try:
        return watch.mailbox_events(bash, home, name)[1]
    except watch.Failure as error:
        raise Refusal("mailbox-unreadable", name, str(error).split("\n", 1)[0]) from error


def read(path):
    """A handoff, archive or INDEX file's text, or None when it is gone."""
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError) as error:
        raise Refusal("handoff-unreadable", path, str(error)) from error


def minute(text):
    """An INDEX END minute as a UTC time, or None when it is unread."""
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%MZ").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return None


def archive_files(archive, since):
    """The archive files that can hold a record about a row at or after since.

    A record about a message is written after it, so a file whose INDEX end
    minute precedes since's minute holds none and is skipped. A file the
    INDEX lists inside the window that is gone is reported archive-pruned:
    the rows it covered can be listed.
    """
    if not archive.is_dir():
        return []
    index = archive / INDEX
    text = read(index)
    ends = {name: minute(end) for name, end in index_ends(text or "").items()}
    floor = since.replace(second=0, microsecond=0)
    files = sorted(path for path in archive.rglob("*") if path.is_file() and path != index)
    present = {path.relative_to(archive).as_posix() for path in files}
    for name, end in sorted(ends.items()):
        if name not in present and (end is None or end >= floor):
            print("owner-unanswered: archive-pruned=%s" % (archive / name), file=sys.stderr)

    def skipped(path):
        end = ends.get(path.relative_to(archive).as_posix())
        return end is not None and end < floor

    return [path for path in files if not skipped(path)]


def progress_records(handoff, explicit, since):
    """Records in the selected handoff, and records and legacy entries in the archive beside it.

    A missing default handoff holds no records; a missing selected one refuses.
    """
    text = read(handoff)
    if text is None and explicit:
        raise Refusal("handoff-missing", handoff, "no such file")
    found = records(text or "")
    for path in archive_files(archive_dir(handoff), since):
        text = read(path)
        if text is None:
            continue
        found.extend(records(text))
        found.extend({"Operation": entry, "Decision": entry} for entry in legacy_entries(text))
    return found


def names(text, identity):
    """Whether text names the full id as a whole token.

    An id's first part is only its send's epoch second, which other owner
    rows can share, so it names no single message.
    """
    return re.search(r"(?<![0-9A-Za-z])" + re.escape(identity) + r"(?![0-9A-Za-z])", text) is not None


def place(row):
    """Where and when the owner sent a relay-delivered row: (channel, thread root stamp, threaded, sent), or None.

    sent is the Slack stamp in seconds. The row's own `at` is when the relay
    delivered it, and a catch-up delivers a backlog hours old in seconds.
    """
    key = SLACK_KEY.fullmatch(row.get("delivery_id") or "")
    if key is None:
        return None
    thread = row.get("thread_ts")
    return key[1], thread or key[2], bool(thread), float(key[2])


def in_thread(row):
    """Whether the relay posts a to-overseer row with ref in its target's thread.

    skills/slack relay.py `routes` and `post_notice` post an owner notice
    there. `post_ask` posts a new top-level question that only links the
    target, so an ask answers its ref alone, not the rest of that thread.
    """
    return row.get("kind") == "notice" and row.get("to") == "owner"


def thread_key(row, owners):
    """The conversation a row belongs to, so a later reply in it covers its earlier owner rows.

    An owner answer keys on its ask. A relay-delivered directive keys on its
    Slack thread: the thread it was posted in, or its own stamp at top level,
    the root replies to it are posted under. A reply (an owner notice with
    ref) keys as its ref target does, where the relay posts it; a ref naming
    no owner row names an owner ask.
    """
    if "ref" in row:
        target = owners.get(row["ref"])
        return ("ask", row["ref"]) if target is None else thread_key(target, owners)
    if row["mail_class"] == "resolution":
        return ("ask", row["re"]) if row.get("re") else None
    where = place(row)
    return None if where is None else ("thread", where[0], where[1])


def files_only(row):
    """Whether an owner directive's text is only the relay's file lines, a file sent as its own message."""
    return row["mail_class"] == "owner-note" and all(
        FILE_LINE.fullmatch(line) for line in row.get("text", "").split("\n"))


def pairs(rows):
    """Each files-only directive's text directive: the nearest one in the same place, sent PAIR_SECS apart at most.

    The same place is one Slack thread, or both top level in one channel.
    """
    def spot(where):
        channel, root, threaded, _ = where
        return channel, root if threaded else None

    def seconds(row):
        return place(row)[3]

    texts = [(spot(place(row)), row) for row in rows
             if row["mail_class"] == "owner-note" and not files_only(row) and place(row) is not None]
    paired = {}
    for row in rows:
        if place(row) is None or not files_only(row):
            continue
        near = [(abs(seconds(text) - seconds(row)), text) for where, text in texts if where == spot(place(row))]
        near = [item for item in near if item[0] <= PAIR_SECS]
        if near:
            # The first of two equally near texts, in inbox order.
            paired[row["id"]] = min(near, key=lambda item: item[0])[1]
    return paired


def unanswered(lane, over, logged, since, now, older):
    """The open owner rows stamped at or after since and at least older seconds old at now.

    Coverage reads every row; the window applies before a pair collapses, so
    a file is hidden only behind a text that is listed.
    """
    owners = {row["id"]: row for row in lane if watch.owner_row(row)}
    replies = [(row["ref"], thread_key(row, owners) if in_thread(row) else None, row.get("at", ""))
               for row in over if row.get("ref")]
    closed = {row.get("re") for row in lane if row.get("mail_class") == "close"}
    paired = pairs(list(owners.values()))
    # A pair is one message: its ids cover together and it keys as its text.
    # A relay catch-up can deliver one member hours after the other, so a
    # cover that names only the other member counts once this row was
    # delivered, the order the thread reply check compares.
    members = {}
    for identity, text in paired.items():
        members.setdefault(text["id"], {text["id"]}).add(identity)
    for identity, text in paired.items():
        members[identity] = members[text["id"]]

    def covered(row):
        identities = members.get(row["id"], {row["id"]})
        key = thread_key(paired.get(row["id"], row), owners)

        def after(at):
            # Stamps are whole seconds and the boxes and the handoff share no
            # order, so a cover in the row's own second is not after it. A
            # legacy entry carries no date, so it is never after.
            return at > row.get("at", "")

        def reaches(identity, at):
            return identity == row["id"] or (identity in identities and after(at))

        if row["mail_class"] == "resolution" and row.get("re") in closed:
            return True
        if any(reaches(ref, at) or (key is not None and key == reply_key and after(at))
               for ref, reply_key, at in replies):
            return True
        request = row["mail_class"] == "owner-note"
        return any(any(names(record.get("Operation", "") + "\n" + record.get("Decision", ""), identity)
                       and reaches(identity, record.get("at", "")) for identity in identities)
                   and (not request or "no reply" in record.get("Decision", "").lower())
                   for record in logged)

    def eligible(row):
        at = watch.instant(row["at"])
        return at >= since and now - at.timestamp() >= older

    open_rows = [row for row in owners.values() if not covered(row) and eligible(row)]
    listed = {row["id"] for row in open_rows}
    # A pair lists once, as its text, while the text waits.
    return [row for row in open_rows if row["id"] not in paired or paired[row["id"]]["id"] not in listed]


def main():
    parser = argparse.ArgumentParser(prog="owner-unanswered", description=(
        "Print one JSON line {id, at, kind, text} per owner message in the Jarvis home's overseer inbox "
        "that no reply reference, later reply in its thread, closed ask or progress record covers. "
        "A file the owner sent as its own message within %d seconds of its text, in the same thread or "
        "both top level, counts as that message." % PAIR_SECS), epilog=(
        "Records come from the selected handoff and the archive beside it, whose INDEX.md skips files that "
        "ended before the window. A file INDEX.md lists inside the window that is gone prints "
        "`owner-unanswered: archive-pruned=PATH` on stderr and the run goes on: the messages that file "
        "covered can be listed. A refusal prints `owner-unanswered: KEY=VALUE` and its cause's first line on "
        "stderr. Exit 2 keys: since-invalid, older-invalid. Exit 1 keys: mailbox-unreadable (VALUE is the "
        "box), handoff-missing (VALUE is the selected handoff), handoff-unreadable (VALUE is the file), "
        "clock-unreadable."))
    parser.add_argument("--bash", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--root", default=".", help="the Jarvis home, or a folder inside it")
    parser.add_argument("--handoff", type=Path, help=(
        "the handoff progress-log writes: an absolute path, or one relative to the home root; "
        "default %s, which may be missing" % DEFAULT_HANDOFF))
    parser.add_argument("--since", help=(
        "only messages stamped at or after this UTC time, YYYY-MM-DDTHH:MM:SSZ; default %d hours ago"
        % (DEFAULT_WINDOW_SECS // 3600)))
    parser.add_argument("--older", default="0", help="only messages at least this many minutes old")
    args = parser.parse_args()
    try:
        since = watch.instant(args.since) if args.since else None
    except ValueError:
        print("owner-unanswered: since-invalid=" + args.since, file=sys.stderr)
        return 2
    if not re.fullmatch(r"\d+", args.older):
        print("owner-unanswered: older-invalid=" + args.older, file=sys.stderr)
        return 2
    home = watch.home_root(args.root)
    try:
        lane = box(args.bash, home, "to-lane")
        over = box(args.bash, home, "to-overseer")
        try:
            now = watch.epoch()
        except (ValueError, watch.Failure) as error:
            raise Refusal("clock-unreadable", "date", str(error)) from error
        if since is None:
            since = datetime.datetime.fromtimestamp(now - DEFAULT_WINDOW_SECS, datetime.timezone.utc)
        logged = progress_records(handoff_path(home, args.handoff or DEFAULT_HANDOFF), args.handoff is not None,
                                  since)
    except Refusal as refusal:
        print("owner-unanswered: %s=%s\n%s" % refusal.args, file=sys.stderr)
        return 1
    for row in unanswered(lane, over, logged, since, now, int(args.older) * 60):
        print(json.dumps({"id": row["id"], "at": row["at"], "kind": row["kind"], "text": row.get("text", "")}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
