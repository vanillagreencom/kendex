"""Numbered mailbox snapshots and retention plans for lane-mail's locked files.

The shell owns the inode locks. Mailbox reads and rewrites use inherited file
descriptors. Cursor replacement runs under the caller's cursor lock.
A numbering record maps retained physical rows to their
original logical lines; subsequent appends continue after the logical count.
"""

import json
import errno
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import time


# The shared class and timestamp definitions come from mailbox-append.sh.
OBJECTS_JQ = r'''
def mailbox_directive_receipt:
  .kind == "directive" and ((.id | type) == "string") and (.id | test("^[A-Za-z0-9._-]+$"));
def objects($box):
  [$box.raw[] | (fromjson? // empty) | objects] as $all
  | [$all[] | select(.kind == "tracker-posted" or .kind == "tracker-failed")] as $posted
  | [range(0; $box.raw | length) as $i
      | ($box.raw[$i] | (fromjson? // empty) | objects)
      | owner_tracker_public
      | owner_tracker_record($posted)
      | {line: $box.numbers[$i], envelope: .}];
'''
READ_JQ = OBJECTS_JQ + r'''
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
          ((if .to == "owner" then $closed else $closed + $answered end) | index($envelope.id) | not))
        | select($in.to == "" or .to == $in.to)
        | select($in.due == false or (.reserved != true and
          ((.deadline // "" | at_epoch) as $d | $d != null and $d <= now))) | tojson]
      + (if $in.receipts then
          ["receipts cursor=\($in.receipt) count=\($in.lane.count) first=\($in.lane.first)"]
          + [$lane[] | .envelope as $e | select($e | mailbox_directive_receipt)
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


class StoreRefusal(ValueError):
    def __init__(self, key, path, detail=""):
        self.key, self.path = key, path
        self.detail = detail
        super().__init__(f"lane-mail: {key}={path}")


def validate_mailbox(box):
    """The path rule shared by lane-mail and in-process mailbox readers."""
    for path in (box.parent, box, box / "to-overseer.jsonl", box / "to-lane.jsonl",
                 box / "to-overseer.jsonl.numbering", box / "to-lane.jsonl.numbering",
                 box / "to-lane.cursor", box / "to-lane.cursor.lock", box / "to-lane.watch"):
        directory = path in (box.parent, box)
        if path.is_symlink() or path.exists() and not (path.is_dir() if directory else path.is_file()):
            raise StoreRefusal("mailbox-unsafe", path)


def cached_path(path, files):
    if files is None:
        return path
    status, source = files[path]
    if status == 2:
        return None
    if status:
        detail = Path(str(source) + ".error").read_text()
        raise StoreRefusal("mail-read-failed", path.parent.name,
                           detail + f"lane-host-read: file-failed item={path.parent.name} path={path} status={status}\n")
    if not source.is_file():
        raise FileNotFoundError(source)
    return source


def read_cursor(box, enabled=True, files=None):
    cursor = box / "to-lane.cursor"
    source = cached_path(cursor, files) if enabled else cursor
    absent = source is None or not source.exists()
    value = (source.read_bytes().split(b"\n", 1)[0].decode(errors="replace")
             if enabled and not absent else "")
    if value and (not value.isascii() or not value.isdecimal()):
        raise StoreRefusal("cursor-invalid", cursor)
    return value, int(value or "0"), absent


def validate_and_lock_pair(box, paths):
    """Keep locks on the shell's inherited descriptors after this helper exits."""
    import fcntl
    validate_mailbox(box)
    for fd, path in zip((8, 9), paths):
        if not path.is_file():
            continue
        deadline = time.monotonic() + 30
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as error:
                if error.errno not in (errno.EACCES, errno.EAGAIN) or time.monotonic() >= deadline:
                    raise StoreRefusal("lock-failed", path) from error
                time.sleep(min(0.1, max(0, deadline - time.monotonic())))


def receipt_cursor(box, value, seen, absent, count, files=None):
    lock = cached_path(box / "to-lane.cursor.lock", files) if absent else None
    if seen > 0 and count == 0 or absent and lock is not None and lock.exists():
        return "missed"
    return str(count) if seen > count else value or "0"


def read_events(box, jq_defs, previous, receipts=False, timeout=30):
    """Cache numbered snapshots; read cursor changes without launching lane-mail.

    flock writers hold the file inode. Directory-mutex writers on macOS
    publish their mutex before changing bytes or numbering. A read is usable
    only with unchanged stamps and no such writer during the snapshot.
    """
    import fcntl
    validate_mailbox(box)
    paths = [box / name for name in ("to-overseer.jsonl", "to-lane.jsonl")]
    deadline = time.monotonic() + timeout

    def stamp():
        result = []
        for path in paths:
            for member in (path, Path(str(path) + ".numbering")):
                try:
                    info = member.stat()
                    result.append((info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns))
                except FileNotFoundError:
                    result.append(None)
        return tuple(result)

    def writer():
        return any(Path(str(path) + ".d").exists() for path in paths)

    while True:
        before = stamp()
        # A missing tracker outcome can expire without a writer changing a file.
        release_at = previous.get("release_at")
        if (previous and previous["stamp"] == before and not writer()
                and (release_at is None or time.time() < release_at)):
            break
        if time.monotonic() >= deadline:
            raise StoreRefusal("lock-failed", box)
        if writer():
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))
            continue
        snapshots = []
        retry = False
        for path in paths:
            try:
                with path.open("rb") as stream:
                    try:
                        fcntl.flock(stream.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
                    except OSError as error:
                        if error.errno not in (errno.EACCES, errno.EAGAIN):
                            raise
                        retry = True
                        break
                    snapshots.append(read_snapshot(stream.fileno(), path))
            except FileNotFoundError:
                snapshots.append({"raw": [], "numbers": [], "count": 0, "first": ""})
            except (OSError, ValueError, KeyError, TypeError):
                if writer() or before != stamp():
                    retry = True
                    break
                raise
        if retry or writer() or before != stamp():
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))
            continue
        program = jq_defs + OBJECTS_JQ + r'''
          . as $in | [range(0; 2) as $b | $in[$b] as $box
            | objects($box)[] | .line as $line | .envelope
            | . + {box: (if $b == 0 then "to-overseer" else "to-lane" end), line: $line, count: $box.count}
            | if $b == 1 then . + {mail_class: overseer_mail_class} else . end] as $rows
          | {rows: [$rows[] | owner_tracker_snapshot($now)],
             release_at: ([$rows[] | select(.tracker_pending == true) | owner_tracker_release_at
                           | select(. > $now)] | min),
             directives: [$rows[] | select(.box == "to-lane" and mailbox_directive_receipt) | {line, id}]}
        '''
        result = subprocess.run(["jq", "-c", "--argjson", "now", str(time.time()), program], input=json.dumps(snapshots),
                                capture_output=True, text=True, check=True,
                                timeout=max(0, deadline - time.monotonic()),
                                env={key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL") if key in os.environ})
        projected = json.loads(result.stdout)
        previous.clear()
        previous.update(stamp=before, rows=projected["rows"], release_at=projected["release_at"],
                        directives=projected["directives"], count=snapshots[1]["count"])
        break
    receipt = None
    if receipts:
        value, seen, absent = read_cursor(box)
        cursor = receipt_cursor(box, value, seen, absent, previous["count"])
        count = 0 if cursor == "missed" else int(cursor)
        read = {row["id"] for row in previous["directives"] if row["line"] <= count}
        receipt = count, read
    return [dict(row) for row in previous["rows"]], receipt


def read_snapshot(fd, path, files=None):
    try:
        if files is not None:
            source = cached_path(path, files)
            if source is None:
                return {"raw": [], "numbers": [], "count": 0, "first": ""}
            with source.open("rb") as stream:
                rows, numbers, record, _ = read_box(stream.fileno(), path, files)
        else:
            rows, numbers, record, _ = read_box(fd, path)
    except (OSError, ValueError, KeyError, TypeError) as error:
        error.mailbox_path = path
        raise
    return {"raw": [row.decode(errors="replace").rstrip("\n") for row in rows],
            "numbers": numbers, "count": len(rows) + record["dropped"], "first": record["first"]}


def cursor_put(path, count):
    """Atomically replace a line count without replacing any reader lock inode."""
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        scratch = Path(stream.name)
        try:
            stream.write(f"{count}\n")
            stream.close()
            os.replace(scratch, path)
        finally:
            scratch.unlink(missing_ok=True)


def read_mail(box, item, verb, after, receipts, to, due, peek, ack, jq_defs, deliver, snapshot=None):
    """Read both inherited locked mailboxes and classify them with one jq."""
    cursor = box / "to-lane.cursor"
    files = None
    if snapshot is not None:
        directory = Path(snapshot)
        files = {}
        for row in (directory / "index").read_text().splitlines():
            lane, path, status, number = row.split("\t")
            if lane == item:
                files[Path(path)] = int(status), directory / number
    directives = verb == "pending" and not to and due == "0"
    reads_cursor = verb == "inbox" or directives or receipts == "1"
    value, seen, absent = read_cursor(box, reads_cursor, files)
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
                # A peek moves no cursor, so a failed touch changes no result.
                pass
    lane = read_snapshot(9, box / "to-lane.jsonl", files)
    over = (read_snapshot(8, box / "to-overseer.jsonl", files) if verb != "inbox" else
            {"raw": [], "numbers": [], "count": 0, "first": ""})
    receipt = receipt_cursor(box, value, seen, absent, lane["count"], files) if reads_cursor else "0"
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
    if deliver == "1":
        # The caller's stdout bypasses its control-result capture. A failed or
        # interrupted flush leaves these lines unread under the same locks.
        try:
            with os.fdopen(os.dup(6), "w", encoding="utf-8") as output:
                for line in result["output"]:
                    output.write(line + "\n")
                output.flush()
        except OSError as error:
            print("error\x1fwrite-failed\x1f/dev/stdout\x1f")
            print(error)
            return
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
    if deliver != "1":
        for line in result["output"]:
            print(line)


def envelope(raw):
    """Return a complete row's object, or None for a writer's broken row."""
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None
    return value if isinstance(value, dict) else None


def read_box(fd, path, files=None):
    """Read bytes and numbering while the caller holds this file's lock."""
    os.lseek(fd, 0, os.SEEK_SET)
    with os.fdopen(os.dup(fd), "rb") as stream:
        raw = stream.read()
    end = raw.rfind(b"\n") + 1
    rows = [line + b"\n" for line in raw[:end].split(b"\n")[:-1]]
    record_path = cached_path(Path(str(path) + ".numbering"), files)
    record = {"dropped": 0, "first": "", "lines": []}
    if record_path is not None and record_path.exists():
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
                    owner_closed if obj.get("to") == "owner" else owner_closed | answers))
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
    if op == "plain":
        try:
            validate_mailbox(Path(sys.argv[2]))
        except StoreRefusal as error:
            print(error.path)
    elif op == "plain-lock":
        try:
            validate_and_lock_pair(Path(sys.argv[2]), [Path(path) for path in sys.argv[3:5]])
        except StoreRefusal as error:
            print(f"{error.key}\x1f{error.path}")
    elif op == "snapshot":
        snapshot(int(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
    elif op == "cursor-put":
        cursor_put(Path(sys.argv[2]), int(sys.argv[3]))
    elif op in ("read", "read-cached"):
        args = sys.argv[2:]
        snapshot_dir = args.pop(0) if op == "read-cached" else None
        try:
            read_mail(Path(args[0]), *args[1:], snapshot=snapshot_dir)
        except StoreRefusal as error:
            print(f"error\x1f{error.key}\x1f{error.path}\x1f")
            print(error.detail, end="")
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
