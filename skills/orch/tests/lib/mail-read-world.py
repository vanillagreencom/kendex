"""Prepare the read cases whose base outputs are committed as fixtures."""

import json
from pathlib import Path
import sys


def prepare(root, state):
    box = Path(root) / "tmp/lane-mail/KEN-1"
    box.mkdir(parents=True, exist_ok=True)
    lane = [{"id": "answer", "kind": "answer", "re": "answered", "at": "2000-01-01T00:00:00Z"},
            {"id": "directive", "kind": "directive", "text": "First\nSecond", "at": "2000-01-01T00:00:00Z"},
            {"id": "halt", "kind": "directive", "halt": True, "at": "invalid"}]
    over = [{"id": "answered", "kind": "ask", "text": "Answered"},
            {"id": "notice", "kind": "notice", "text": "Notice"},
            {"id": "open", "kind": "ask", "to": "owner", "deadline": "2000-01-01T00:00:00Z"}]
    for name, rows in (("to-lane", lane), ("to-overseer", over)):
        raw = b"".join(json.dumps(row).encode() + b"\n" for row in rows[:1]) + b"invalid\n"
        raw += b"".join(json.dumps(row).encode() + b"\n" for row in rows[1:])
        if state == "broken":
            raw += b'{"id":"unfinished"}'
        (box / (name + ".jsonl")).write_bytes(raw)
        if state == "numbered":
            (box / (name + ".jsonl.numbering")).write_text(json.dumps(
                {"dropped": 5, "first": "original", "lines": [2, 4, 7, 8]}) + "\n")
    if state not in ("missed", "absent"):
        (box / "to-lane.cursor").write_text("1\n")
    if state != "absent":
        (box / "to-lane.cursor.lock").touch()


if __name__ == "__main__":
    prepare(*sys.argv[1:])
