"""The handoff's progress record form: progress-log writes it, owner-unanswered reads it.

A record is one list item whose nested items are the fields of
references/long-session.md § Progress records. A value's later lines are
indented four spaces. The README states the id form.
"""
import re

HEAD = "Id and time"
FIELDS = ("Operation", "Observed result and source", "Decision", "State change")
_HEAD = re.compile(r"^- " + HEAD + r": (P-\d{8}T\d{6}Z(?:-\d+)?) (\S+)$")
_FIELD = re.compile(r"^  - (" + "|".join(map(re.escape, FIELDS)) + r"): ?(.*)$")


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


def ids(text):
    return {record["id"] for record in records(text)}
