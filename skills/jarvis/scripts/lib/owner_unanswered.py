"""List the owner's messages in the Jarvis home inbox that nothing answers.

The mailbox's public events read supplies both boxes and its mail classes;
the handoff and its archive supply progress records. This module only judges
which reference answers which owner row.
"""
import argparse
import datetime
import json
from pathlib import Path
import re
import sys

LIB = Path(__file__).resolve().parent
sys.path.insert(0, str(LIB))
from progress import records  # noqa: E402
import watch  # noqa: E402


class Unreadable(RuntimeError):
    pass


def instant(value):
    return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)


def box(bash, home, name):
    operation = "mailbox-events-" + name
    result = watch.run([bash, watch.LIB.parents[2] / "mailbox/scripts/lane-mail", "events", "--item", "overseer",
                        "--box", name], home, operation=operation)
    if result.returncode:
        raise Unreadable(name, (result.stderr.strip() or "exit=%d" % result.returncode).split("\n", 1)[0])
    return watch.events_rows(result.stdout, operation)


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
            raise Unreadable("handoff", "%s %s" % (path, error)) from error
    return found


def names(text, identity):
    """Whether text names the id, or its first part, as a whole token."""
    first = identity.split("-", 1)[0]
    return any(re.search(r"(?<![0-9A-Za-z])" + re.escape(token) + r"(?![0-9A-Za-z])", text)
               for token in (identity, first))


def unanswered(lane, over, logged):
    replies = [row for row in over if row.get("ref")]
    closed = {row.get("re") for row in lane if row.get("mail_class") == "close"}
    answers = {}
    for row in lane:
        if row.get("mail_class") == "resolution" and row.get("re"):
            answers.setdefault(row["re"], set()).add(row["id"])
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
            # A later reply to the ask, or to any owner answer to it, covers
            # every earlier answer in that thread; a resolution closes them all.
            thread = {ask} | answers.get(ask, set())
            if ask in closed or any(reply["ref"] in thread and reply.get("at", "") >= row.get("at", "")
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
        "that no reply reference, closed ask or progress record covers."))
    parser.add_argument("--bash", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--root", default=".", help="the Jarvis home, or a folder inside it")
    parser.add_argument("--since", help="only messages stamped at or after this UTC time, YYYY-MM-DDTHH:MM:SSZ")
    parser.add_argument("--older", default="0", help="only messages at least this many minutes old")
    args = parser.parse_args()
    try:
        since = instant(args.since) if args.since else None
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
    except Unreadable as error:
        key = "handoff-unreadable" if error.args[0] == "handoff" else "mailbox-unreadable"
        print("owner-unanswered: %s=%s\n%s" % (key, error.args[0], error.args[1]), file=sys.stderr)
        return 1
    except (ValueError, RuntimeError) as error:
        print("owner-unanswered: mailbox-unreadable=events\n" + str(error), file=sys.stderr)
        return 1
    try:
        now = watch.epoch()
    except (ValueError, RuntimeError) as error:
        print("owner-unanswered: clock-unreadable=date\n" + str(error), file=sys.stderr)
        return 1
    for row in unanswered(lane, over, logged):
        at = instant(row["at"])
        if (since is not None and at < since) or now - at.timestamp() < int(args.older) * 60:
            continue
        print(json.dumps({"id": row["id"], "at": row["at"], "kind": row["kind"], "text": row.get("text", "")}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
