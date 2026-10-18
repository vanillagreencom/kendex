"""Prepare and unpack the watch's read-many snapshot. The shell owns its life."""

import base64
import json
from pathlib import Path
import sys


def requests(entries):
    """Include clone fallback mail only where an earlier pass recorded it."""
    result = []
    for item, root, clone in zip(entries[::3], entries[1::3], entries[2::3]):
        paths = [root + "/.git", root + "/.git/HEAD"]
        for directory in dict.fromkeys((root, clone)):
            if not directory:
                continue
            box = directory + "/tmp/lane-mail/" + item + "/"
            paths.extend(box + name for name in (
                "to-overseer.jsonl", "to-overseer.jsonl.numbering",
                "to-lane.jsonl", "to-lane.jsonl.numbering", "to-lane.cursor", "to-lane.cursor.lock"))
        result.extend({"item": item, "path": path} for path in paths)
    return result


def unpack(directory):
    """Refuse incomplete, duplicate or malformed replies before publishing an index.

    A provider's successful reply proves presence or absence for every file.
    Missing reply rows cannot stand in for files that the lane has not written.
    """
    expected = json.loads((directory / "request").read_text())
    reply = json.loads((directory / "reply").read_text())
    if not isinstance(reply, list) or len(reply) != len(expected):
        raise ValueError("incomplete read-many reply")
    index = []
    for number, (request, row) in enumerate(zip(expected, reply)):
        if (not isinstance(row, dict) or row.get("item") != request["item"]
                or row.get("path") != request["path"] or type(row.get("status")) is not int
                or not 0 <= row["status"] <= 255 or row["status"] == 69
                or not isinstance(row.get("error", ""), str)
                or not isinstance(row.get("data"), str)):
            raise ValueError("invalid read-many reply")
        data = base64.b64decode(row["data"], validate=True)
        if row["status"] and data:
            raise ValueError("failed read-many file carries bytes")
        (directory / str(number)).write_bytes(data)
        (directory / (str(number) + ".error")).write_text(row.get("error", ""))
        index.append(f'{row["item"]}\t{row["path"]}\t{row["status"]}\t{number}\n')
    (directory / "index").write_text("".join(index))


if __name__ == "__main__":
    try:
        if sys.argv[1] == "request":
            print(json.dumps(requests(sys.argv[2:])))
        elif sys.argv[1] == "unpack":
            unpack(Path(sys.argv[2]))
        else:
            raise ValueError("unknown operation")
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"lane-host-read: operation={sys.argv[1]} cause={type(error).__name__}", file=sys.stderr)
        sys.exit(1)
