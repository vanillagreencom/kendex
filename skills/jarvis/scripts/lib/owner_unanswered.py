"""List the owner's messages in the Jarvis home inbox that nothing answers.

The mailbox's public events read supplies both boxes and its mail classes;
the handoff and its archive supply progress records. This module only judges
which reference answers which owner row.
"""
import argparse
import json
from pathlib import Path
import re
import sys

LIB = Path(__file__).resolve().parent
sys.path.insert(0, str(LIB))
from progress import records  # noqa: E402
import watch  # noqa: E402


class Refusal(Exception):
    """KEY, the value it names, and the cause's first line."""


def box(bash, home, name):
    try:
        return watch.mailbox_events(bash, home, name)[1]
    except watch.Failure as error:
        raise Refusal("mailbox-unreadable", name, str(error).split("\n", 1)[0]) from error


def progress_records(home):
    """Records in the handoff and every file under state/archive/."""
    paths = [home / "state/handoff.md"]
    archive = home / "state/archive"
    if archive.is_dir():
        paths.extend(sorted(path for path in archive.rglob("*") if path.is_file()))
    found = []
    for path in paths:
        try:
            found.extend(records(path.read_text(encoding="utf-8")))
        except FileNotFoundError:
            continue
        except (OSError, UnicodeError) as error:
            raise Refusal("handoff-unreadable", path, str(error)) from error
    return found


def names(text, identity):
    """Whether text names the full id as a whole token.

    An id's first part is only its send's epoch second, which other owner
    rows can share, so it names no single message.
    """
    return re.search(r"(?<![0-9A-Za-z])" + re.escape(identity) + r"(?![0-9A-Za-z])", text) is not None


def unanswered(lane, over, logged):
    replies = [row for row in over if row.get("ref")]
    closed = {row.get("re") for row in lane if row.get("mail_class") == "close"}
    open_rows = []
    for row in lane:
        if not watch.owner_row(row):
            continue
        identity = row["id"]
        if any(reply["ref"] == identity for reply in replies):
            continue
        request = row["mail_class"] == "owner-note"
        ask = None if request else row.get("re")
        if ask is not None:
            # A later reply to the ask covers every earlier answer to it; a
            # resolution closes them all. lane-mail lets a reply ref name an
            # owner ask or note, never an owner answer.
            if ask in closed or any(reply["ref"] == ask and reply.get("at", "") >= row.get("at", "")
                                    for reply in replies):
                continue
        handled = False
        for record in logged:
            decision = record.get("Decision", "")
            if names(record.get("Operation", "") + "\n" + decision, identity) and \
                    (not request or "no reply" in decision.lower()):
                handled = True
                break
        if not handled:
            open_rows.append(row)
    return open_rows


def main():
    parser = argparse.ArgumentParser(prog="owner-unanswered", description=(
        "Print one JSON line {id, at, kind, text} per owner message in the Jarvis home's overseer inbox "
        "that no reply reference, closed ask or progress record covers."), epilog=(
        "A refusal prints `owner-unanswered: KEY=VALUE` and its cause's first line on stderr. Exit 2 keys: "
        "since-invalid, older-invalid. Exit 1 keys: mailbox-unreadable (VALUE is the box), "
        "handoff-unreadable (VALUE is the file), clock-unreadable."))
    parser.add_argument("--bash", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--root", default=".", help="the Jarvis home, or a folder inside it")
    parser.add_argument("--since", help="only messages stamped at or after this UTC time, YYYY-MM-DDTHH:MM:SSZ")
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
        logged = progress_records(home)
        try:
            now = watch.epoch()
        except (ValueError, watch.Failure) as error:
            raise Refusal("clock-unreadable", "date", str(error)) from error
    except Refusal as refusal:
        print("owner-unanswered: %s=%s\n%s" % refusal.args, file=sys.stderr)
        return 1
    for row in unanswered(lane, over, logged):
        at = watch.instant(row["at"])
        if (since is not None and at < since) or now - at.timestamp() < int(args.older) * 60:
            continue
        print(json.dumps({"id": row["id"], "at": row["at"], "kind": row["kind"], "text": row.get("text", "")}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
