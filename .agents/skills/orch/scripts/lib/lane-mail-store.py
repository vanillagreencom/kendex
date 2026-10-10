"""Numbered mailbox snapshots and retention plans for lane-mail's locked files.

The shell owns the inode locks. Mailbox reads and rewrites use inherited file
descriptors. Cursor replacement runs under the caller's cursor lock.
A numbering record maps retained physical rows to their
original logical lines; subsequent appends continue after the logical count.
"""

import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile


# The shared class and timestamp definitions come from mailbox-append.sh.
READ_JQ = r'''
def objects($box):
  [$box.raw[] | (fromjson? // empty) | objects] as $all
  | [$all[] | select(.kind == "tracker-posted")] as $posted
  | [range(0; $box.raw | length) as $i
      | ($box.raw[$i] | (fromjson? // empty) | objects)
      | select(.kind != "tracker-posted")
      | if .kind == "ask" and .to == "owner" and .issue != null then
          . as $ask | .tracker_posted = any($posted[]; .re == $ask.id and .issue == $ask.issue)
        else . end
      | {line: $box.numbers[$i], envelope: .}];
. as $in | objects(.lane) as $lane | objects(.over) as $over
| [$lane[].envelope | select(.kind == "answer") | .re // empty] as $answered
| [$lane[].envelope | select(overseer_mail_class == "close") | .re] as $closed
| (if $in.after == "" then 0 else ($in.after | tonumber) end) as $after
| (if $in.seen > $in.lane.count and $in.lane.count > 0 then $in.lane.count else $in.seen end) as $seen
| (if $in.verb == "inbox" then
    ([$lane[] | select(.line > $in.seen and .envelope.halt == true) | .line - 1] | first) as $halt
    | ([($in.ack // $in.lane.count), $in.lane.count] | min) as $bound
    | (if $halt != null and $in.ack != null then [$bound, $halt] | min else $bound end) as $ack
    | {output: (if $in.ack != null then [] else
          (if $in.peek then ["count=\($in.lane.count) first=\($in.lane.first)"] else [] end)
          + [$lane[] | select(.line > $in.seen) | .envelope | tojson] end),
       cursor: (if $in.ack != null then
          if $in.seen > $in.lane.count or $ack > $in.seen then $ack else null end
        elif $in.peek then if $in.seen > $in.lane.count then $in.lane.count else null end
        elif $in.seen != $in.lane.count then $in.lane.count else null end),
       lowered: (if ($in.peek or $in.ack != null) and $in.seen > $in.lane.count then $ack else null end),
       clamped: (if $in.ack != null and $in.ack > $in.lane.count then $ack else null end)}
  else
    {output: ((if $in.verb == "drain" then ["count=\($in.over.count) first=\($in.over.first)"] else [] end)
      + [$over[] | select($in.after == "" or .line > $after) | .envelope | . as $envelope
        | select($in.verb == "drain" or .kind == "ask")
        | select(.kind != "ask" or
          ((if .to == "owner" then $closed else $answered end) | index($envelope.id) | not))
        | select($in.to == "" or .to == $in.to)
        | select($in.due == false or (.reserved != true and
          ((.deadline // "" | at_epoch) as $d | $d != null and $d <= now))) | tojson]
      + (if $in.receipts then
          ["receipts cursor=\($in.receipt) count=\($in.lane.count) first=\($in.lane.first)"]
          + [$lane[] | .envelope as $e | select($e.kind == "directive")
              | select(($e.id | type) == "string" and ($e.id | test("^[A-Za-z0-9._-]+$")))
              | "\(.line) \($e.id) \(($e.at | at_epoch) // "")"]
        elif $in.directives then [$lane[] | select(.line > $seen and .envelope.kind == "directive") | .envelope | tojson]
        else [] end)), cursor: null, lowered: null, clamped: null}
  end)
| . + {legacy: (if $in.item == "overseer" then
    if $in.verb == "inbox" then
      [$lane[] | select(.line > $in.seen) | .envelope | select(mailbox_legacy_close) | .id]
    else
      ([$lane[].envelope | select(mailbox_legacy_close) | .id] as $legacy | $legacy + $legacy)
      + [$over[].envelope | select(mailbox_legacy_close) | .id]
    end else [] end)}
'''


def read_snapshot(fd, path):
    try:
        rows, numbers, record, _ = read_box(fd, path)
    except (OSError, ValueError, KeyError, TypeError) as error:
        error.mailbox_path = path
        raise
    return {"raw": [row.decode(errors="replace").rstrip("\n") for row in rows],
            "numbers": numbers, "count": len(rows) + record["dropped"], "first": record["first"]}


def cursor_put(path, count):
    """Replace the cursor while the caller retains its separate lock inode."""
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        scratch = Path(stream.name)
        try:
            stream.write(f"{count}\n")
            stream.close()
            os.replace(scratch, path)
        finally:
            scratch.unlink(missing_ok=True)


def read_mail(box, item, verb, after, receipts, to, due, peek, ack, jq_defs):
    """Read both inherited locked mailboxes and classify them with one jq."""
    cursor = box / "to-lane.cursor"
    directives = verb == "pending" and not to and due == "0"
    reads_cursor = verb == "inbox" or directives or receipts == "1"
    absent = not cursor.exists()
    value = (cursor.read_bytes().split(b"\n", 1)[0].decode(errors="replace")
             if reads_cursor and not absent else "")
    if value and (not value.isascii() or not value.isdecimal()):
        print(f"error\x1fcursor-invalid\x1f{cursor}\x1f")
        return
    seen = int(value or "0")
    if verb == "inbox" and not value:
        try:
            cursor_put(cursor, 0)
        except OSError:
            if peek != "1":
                print(f"error\x1fwrite-failed\x1f{cursor}\x1f")
                return
            try:
                cursor.touch(exist_ok=True)
            except OSError:
                pass
    lane = read_snapshot(9, box / "to-lane.jsonl")
    over = (read_snapshot(8, box / "to-overseer.jsonl") if verb != "inbox" else
            {"raw": [], "numbers": [], "count": 0, "first": ""})
    receipt = str(lane["count"]) if seen > lane["count"] else value or "0"
    if seen > 0 and lane["count"] == 0 or absent and (box / "to-lane.cursor.lock").exists():
        receipt = "missed"
    if verb == "pending" and directives and receipt == "missed":
        print(f"error\x1fmail-read-failed\x1f{item}\x1fcursor=missed")
        return
    data = {"lane": lane, "over": over, "item": item, "verb": verb, "after": after,
            "receipts": receipts == "1", "to": to, "due": due == "1", "peek": peek == "1",
            "ack": int(ack) if ack else None, "seen": seen, "receipt": receipt, "directives": directives}
    result = subprocess.run(["jq", "-c", jq_defs + READ_JQ], input=json.dumps(data).encode(),
                            capture_output=True, check=True,
                            env={key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL") if key in os.environ})
    result = json.loads(result.stdout)
    lowered = result["lowered"]
    if verb == "inbox":
        try:
            if result["cursor"] is not None:
                cursor_put(cursor, result["cursor"])
        except OSError:
            if peek != "1":
                print(f"error\x1fwrite-failed\x1f{cursor}\x1f")
                return
            lowered = None
    print("ok\x1f" + "\x1f".join(str(n) if n is not None else "" for n in
          (lowered, seen, result["clamped"], ack)))
    for id_ in result["legacy"]:
        print(f"legacy\x1f{id_}")
    print("output")
    for line in result["output"]:
        print(line)


def envelope(raw):
    """Return a complete row's object, or None for a writer's broken row."""
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None
    return value if isinstance(value, dict) else None


def read_box(fd, path):
    """Read bytes and numbering while the caller holds this file's lock."""
    os.lseek(fd, 0, os.SEEK_SET)
    with os.fdopen(os.dup(fd), "rb") as stream:
        raw = stream.read()
    end = raw.rfind(b"\n") + 1
    rows = [line + b"\n" for line in raw[:end].split(b"\n")[:-1]]
    record_path = Path(str(path) + ".numbering")
    record = {"dropped": 0, "first": "", "lines": []}
    if record_path.exists():
        record = json.loads(record_path.read_text())
        lines = record["lines"]
        if (type(record["dropped"]) is not int or record["dropped"] < 0
                or not isinstance(record["first"], str)
                or not isinstance(lines, list)
                or any(type(n) is not int or n <= 0 for n in lines)
                or lines != sorted(set(lines))
                or (lines and lines[-1] > len(lines) + record["dropped"])
                or len(lines) > len(rows)):
            raise ValueError(f"invalid numbering: {record_path}")
    elif rows:
        first = envelope(rows[0])
        first_id = first.get("id", "") if first else ""
        if isinstance(first_id, str) and first_id and all(
                c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-" for c in first_id):
            record["first"] = first_id
    numbers = record["lines"] + list(range(
        len(record["lines"]) + record["dropped"] + 1, len(rows) + record["dropped"] + 1))
    return rows, numbers, record, raw[end:]


def snapshot(fd, path, dest):
    """Publish one paired snapshot for lane-mail readers."""
    rows, numbers, record, fragment = read_box(fd, path)
    Path(dest).write_bytes(b"".join(rows) + fragment)
    # lane-mail's terminated-prefix reader decides whether this provisional
    # number becomes readable. Compaction never stores it as a retained row.
    if fragment:
        numbers.append(len(rows) + record["dropped"] + 1)
    Path(dest + ".index").write_text("".join(f"{n}\n" for n in numbers))
    Path(dest + ".header").write_text(
        f"count={len(rows) + record['dropped'] + bool(fragment)} first={record['first']}\n")


def row_metadata(rows, jq_defs):
    """Use lane-mail's stamp parser and mailbox classifier in one jq call."""
    program = jq_defs + ''' split("\\n")[:-1] | map((fromjson? // null)
        | if type == "object" then
            {epoch: (.at // "" | at_epoch), class: overseer_mail_class}
          else {epoch: null, class: null} end)'''
    result = subprocess.run(["jq", "-Rs", program], input=b"".join(rows),
                            capture_output=True, check=True)
    return json.loads(result.stdout)


def plan(box, dest, cutoff, seen, jq_defs):
    """Keep unread rows and each ask's complete, still-needed exchange."""
    boxes = [read_box(8, box / "to-overseer.jsonl"), read_box(9, box / "to-lane.jsonl")]
    objects = [[envelope(row) for row in data[0]] for data in boxes]
    metadata = [row_metadata(data[0], jq_defs) for data in boxes]
    answers = {obj.get("re") for group in objects for obj in group
               if obj and obj.get("kind") == "answer" and isinstance(obj.get("re"), str)}
    owner_closed = {obj.get("re") for obj, row in zip(objects[1], metadata[1])
                    if obj and row["class"] == "close" and isinstance(obj.get("re"), str)}
    protected = set()
    links = []
    keep = []
    for b, group in enumerate(objects):
        selected = []
        for i, obj in enumerate(group):
            at = metadata[b][i]["epoch"]
            unread = b == 1 and boxes[b][1][i] > seen
            open_ask = obj and obj.get("kind") == "ask" and (
                not isinstance(obj.get("id"), str) or obj["id"] not in (
                    owner_closed if obj.get("to") == "owner" else answers))
            retain = at is None or at >= cutoff or unread or open_ask
            selected.append(retain)
            if obj:
                ids = {obj[key] for key in ("id", "re", "ref") if isinstance(obj.get(key), str)}
                links.append((b, i, ids))
                if retain:
                    protected.update(ids)
        keep.append(selected)
    # A kept ask must not lose its answer and become pending again. References
    # also keep the owner note an open exchange needs for its eventual reply.
    changed = True
    while changed:
        changed = False
        for b, i, ids in links:
            if ids & protected and not keep[b][i]:
                keep[b][i] = True
                protected.update(ids)
                changed = True
    counts = {}
    for b, name in enumerate(("to-overseer", "to-lane")):
        rows, numbers, record, fragment = boxes[b]
        removed = [row for i, row in enumerate(rows) if not keep[b][i]]
        retained = [row for i, row in enumerate(rows) if keep[b][i]]
        logical = [n for i, n in enumerate(numbers) if keep[b][i]]
        dropped = record["dropped"] + len(removed)
        # The last logical line can have been removed too. The count, rather
        # than the last retained line, sets where a waiting writer continues.
        record = {"dropped": dropped, "first": record["first"], "lines": logical}
        (dest / (name + ".kept")).write_bytes(b"".join(retained) + fragment)
        (dest / (name + ".jsonl")).write_bytes(b"".join(removed))
        (dest / (name + ".numbering")).write_text(json.dumps(record) + "\n")
        counts[name] = len(removed)
    (dest / "counts.json").write_text(json.dumps(counts) + "\n")


def rewrite(fd, path, dest, name):
    """Rewrite through the locked inode, so an already waiting writer survives."""
    kept = (dest / (name + ".kept")).read_bytes()
    os.lseek(fd, 0, os.SEEK_SET)
    with os.fdopen(os.dup(fd), "r+b") as stream:
        stream.write(kept)
        stream.truncate()
        stream.flush()
        os.fsync(stream.fileno())
    Path(str(path) + ".numbering").write_bytes((dest / (name + ".numbering")).read_bytes())


def main():
    """Run the operation selected by lane-mail, reporting filesystem failures."""
    op = sys.argv[1]
    if op == "snapshot":
        snapshot(int(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
    elif op == "read":
        try:
            read_mail(Path(sys.argv[2]), *sys.argv[3:])
        except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
            path = getattr(error, "mailbox_path", getattr(error, "filename", None)) or sys.argv[2]
            print(f"error\x1ffile-unreadable\x1f{path}\x1f")
            if isinstance(error, subprocess.CalledProcessError):
                print(error.stderr.decode(errors="replace"), end="")
            else:
                print(error)
    elif op == "plan":
        plan(Path(sys.argv[2]), Path(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), sys.argv[6])
    elif op == "rewrite":
        box, dest = Path(sys.argv[2]), Path(sys.argv[3])
        counts = json.loads((dest / "counts.json").read_text())
        for fd, name in ((8, "to-overseer"), (9, "to-lane")):
            if counts[name]:
                rewrite(fd, box / (name + ".jsonl"), dest, name)
    else:
        raise ValueError(f"unknown operation: {op}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(f"lane-mail-store: operation={sys.argv[1]} jq-exit={error.returncode}\n"
              + error.stderr.decode(errors="replace"), file=sys.stderr)
        sys.exit(2)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"lane-mail-store: operation={sys.argv[1]}\n{error}", file=sys.stderr)
        sys.exit(2)
