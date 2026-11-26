#!/usr/bin/env python3
"""Compare the in-process store with lane-mail's unchanged events output."""

import json
import errno
import fcntl
import os
import subprocess
import sys
from pathlib import Path

if sys.argv[1] != "--child":
    result = subprocess.run([sys.executable, __file__, "--child", *sys.argv[1:]], timeout=60)
    sys.exit(result.returncode)
del sys.argv[1]

sys.path.insert(0, sys.argv[1])
from mailbox import MAILBOX_READ_FILES, LaneMail

root = Path(sys.argv[2])
mail = LaneMail(root)
linked = len(sys.argv) > 3
mailbox_root = Path(sys.argv[3]).resolve() if linked else root.resolve()
box = mailbox_root / "tmp/lane-mail/overseer"


def equivalent():
    expected = subprocess.run([str(mail.script), "events", "--item", "overseer"],
                              cwd=root, capture_output=True, text=True, check=True, timeout=30)
    rows, _ = mail._read_events()
    actual = "".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in rows)
    assert actual == expected.stdout, (actual, expected.stdout)
    return rows


assert equivalent() == [], "a missing mailbox must remain empty"

# The bound public writer and compactor produce this version's real format.
def command(*args):
    return subprocess.run([str(mail.script), *args], cwd=root, capture_output=True,
                          text=True, check=True, timeout=30).stdout


text = root / "tmp/producer.txt"
text.write_text("Historical producer notice.\n")
command("notice", "--item", "overseer", "--to", "owner", "--file", str(text))
text.write_text("Historical producer ask?\n")
command("ask", "--item", "overseer", "--to", "owner", "--file", str(text),
        "--options", "yes,no", "--reserved")
text.write_text("Historical producer directive.\n")
command("send", "--item", "overseer", "--directive", "--file", str(text))
produced = equivalent()
assert {row["kind"] for row in produced} == {"notice", "ask", "directive"}
over = box / "to-overseer.jsonl"
source = [json.loads(raw) for raw in over.read_text().splitlines()]
source[0]["at"] = "2000-01-01T00:00:00Z"
over.write_text("".join(json.dumps(row) + "\n" for row in source))
command("compact", "--item", "overseer")
compacted_rows = equivalent()
ask = next(row for row in compacted_rows if row["kind"] == "ask")
assert (ask["line"], ask["count"]) == (2, 2)
assert not any(row["kind"] == "notice" for row in compacted_rows)
text.write_text("Historical appended tail.\n")
command("notice", "--item", "overseer", "--to", "owner", "--file", str(text))
tail = next(row for row in equivalent() if row["text"] == "Historical appended tail.")
assert (tail["line"], tail["count"]) == (3, 3)
command("inbox", "--item", "overseer")
receipt_lines = command("drain", "--item", "overseer", "--after", "0", "--receipts").splitlines()
header = next(line for line in receipt_lines if line.startswith("receipts "))
fields = dict(word.split("=", 1) for word in header.split()[1:])
assert int(fields["cursor"]) == mail.read_receipts()[0] == 1
directive = next(row for row in produced if row["kind"] == "directive")
assert mail.read_receipts()[1] == {directive["id"]}
assert any(line.split()[1:2] == [directive["id"]] for line in receipt_lines)

for name in ("to-overseer.jsonl.numbering", "to-lane.jsonl.numbering"):
    (box / name).unlink(missing_ok=True)
box.mkdir(parents=True, exist_ok=True)
over = box / "to-overseer.jsonl"
lane = box / "to-lane.jsonl"
rows = [
    {"id": "notice-a", "kind": "notice", "at": "2026-10-13T00:00:00Z", "text": "A", "to": "owner"},
    {"id": "ask-a", "kind": "ask", "at": "2026-10-13T00:00:00Z", "text": "Question", "to": "owner", "issue": "FIXTURE-1"},
    {"id": "posted-a", "kind": "tracker-posted", "re": "ask-a", "issue": "FIXTURE-1", "tracker_label": "owner"},
]
over.write_text("".join(json.dumps(row) + "\n" for row in rows) + "bad-json\n[]\n{\"id\":\"partial\"")
# The Jarvis read has passed the damaged lines 4 and 5, so both readers step over them.
(box / "to-overseer.seen").write_text("5\n")
lane.write_text(json.dumps({"id": "directive-a", "kind": "directive", "at": "2026-10-13T00:00:00Z", "text": "Read me"}) + "\n")
events = equivalent()
assert [(row["id"], row["line"], row["count"]) for row in events] == [
    ("notice-a", 1, 5), ("ask-a", 2, 5), ("directive-a", 1, 1)]
assert events[1]["tracker_posted"] is True and events[1]["tracker_label"] == "owner"
assert events[2]["mail_class"] == "owner-note"
assert equivalent() == events, "an unchanged snapshot must preserve envelopes"

# A compacted mailbox retains logical numbering and continues its count.
over.write_text(json.dumps(rows[1]) + "\n" + json.dumps(rows[2]) + "\n")
Path(str(over) + ".numbering").write_text(json.dumps({"dropped": 3, "first": "notice-a", "lines": [2, 3]}) + "\n")
events = equivalent()
assert [(row["id"], row["line"], row["count"]) for row in events] == [("ask-a", 2, 5), ("directive-a", 1, 1)]
with over.open("a") as stream:
    stream.write(json.dumps(dict(rows[0], id="notice-b")) + "\n")
events = equivalent()
assert [(row["id"], row["line"], row["count"]) for row in events] == [
    ("ask-a", 2, 6), ("notice-b", 6, 6), ("directive-a", 1, 1)]

# Cursor replacement does not change mailbox bytes and must invalidate no events.
cursor = box / "to-lane.cursor"
for value, wanted in [("0\n", (0, set())), ("1\n", (1, {"directive-a"})), ("9\n", (1, {"directive-a"}))]:
    cursor.write_text(value)
    assert mail.read_receipts() == wanted
cursor.unlink()
(box / "to-lane.cursor.lock").touch()
assert mail.read_receipts() == (0, set())
assert equivalent() == events

# The safety owner must still refuse a mailbox component after cache warm-up.
watch = box / "to-lane.watch"
watch.symlink_to(cursor)
try:
    try:
        mail.events()
    except Exception as error:
        assert error.key == "lane-mail-failed" and error.value == f"lane-mail: mailbox-unsafe={watch}"
    else:
        raise AssertionError("a symlink mailbox component must be refused")
finally:
    watch.unlink()

# A directory-mutex compactor changes bytes and numbering between the two
# reads. The Path hook identifies the parser's metadata read without a sleep.
old = dict(rows[0], id="notice-old", at="2000-01-01T00:00:00Z")
kept = dict(rows[0], id="notice-kept", at="2099-01-01T00:00:00Z")
over.write_text(json.dumps(old) + "\n" + json.dumps(kept) + "\n")
numbering = Path(str(over) + ".numbering")
numbering.write_text(json.dumps({"dropped": 0, "first": "notice-old", "lines": []}) + "\n")
mail.snapshots.clear()
original_read_text = Path.read_text
compacted = False


def compact_during_read(path, *args, **kwargs):
    global compacted
    if path == numbering and not compacted:
        compacted = True
        mutex = Path(str(over) + ".d")
        mutex.mkdir()
        try:
            over.write_text(json.dumps(kept) + "\n")
            numbering.write_text(json.dumps({"dropped": 1, "first": "notice-old", "lines": [2]}) + "\n")
        finally:
            mutex.rmdir()
    return original_read_text(path, *args, **kwargs)


Path.read_text = compact_during_read
try:
    actual, _ = mail._read_events()
finally:
    Path.read_text = original_read_text
assert compacted, "the producer must reach the numbering read"
assert actual == equivalent(), "a snapshot must not mix pre-compaction bytes and new numbering"

# A writer that holds its directory mutex cannot hold the worker forever.
# Fake time advances only at the production retry's sleep boundary.
class FakeTime:
    now = 0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(0.1, seconds)
        if self.now > 2:
            raise RuntimeError("read exceeded its deadline")


namespace = mail.reader.__globals__
original_time = namespace["time"]
namespace["time"] = FakeTime()
mutex = Path(str(over) + ".d")
mutex.mkdir()
try:
    try:
        mail.reader(box, mail.jq_defs, {}, timeout=1)
    except Exception as error:
        assert getattr(error, "key", None) == "lock-failed"
    else:
        raise AssertionError("a held writer must reach the bounded refusal")
finally:
    mutex.rmdir()
    namespace["time"] = original_time

# A damaged line past its box's consumer count refuses the relay's read, at
# the line `events --box` refuses at; one at or below it, or a killed
# writer's marked fragment, reads. A row with no mailbox bytes keeps the
# previous row's, so the cached snapshot judges the moved count.
notice = json.dumps(dict(rows[0], id="notice-d")) + "\n"
directive = json.dumps({"id": "directive-d", "kind": "directive", "at": "2026-10-13T00:00:00Z", "text": "D"}) + "\n"
for name in ("to-overseer.jsonl.numbering", "to-lane.jsonl.numbering", "to-lane.cursor.lock"):
    (box / name).unlink(missing_ok=True)
DAMAGE = [
    # label, to-overseer bytes, to-lane bytes, to-overseer.seen, to-lane.cursor, refusing box and line
    ("overseer-unread", notice + "bad-json\n", directive, None, "0", ("to-overseer", 2)),
    ("overseer-seen-raised", None, None, "2", "0", None),
    ("overseer-seen", notice + "bad-json\n", directive, "2", "0", None),
    ("lane-unread", notice, directive + "[]\n", "0", "1", ("to-lane", 2)),
    ("lane-cursor", notice, directive + "[]\n", "0", "2", None),
    ("torn-fragment", notice + "{\"id\":\"cut\x1etorn\n", directive, None, "0", None),
]
for label, over_bytes, lane_bytes, seen, lane_cursor, refused in DAMAGE:
    if over_bytes is None:
        warm = mail.snapshots["stamp"]
    else:
        over.write_text(over_bytes)
        lane.write_text(lane_bytes)
    seen_path = box / "to-overseer.seen"
    seen_path.unlink(missing_ok=True)
    if seen is not None:
        seen_path.write_text(seen + "\n")
    cursor.write_text(lane_cursor + "\n")
    wanted = refused and f"lane-mail: envelope-invalid path={box / (refused[0] + '.jsonl')} line={refused[1]}"
    for name in ("to-overseer", "to-lane"):
        cli = subprocess.run([str(mail.script), "events", "--item", "overseer", "--box", name],
                             cwd=root, capture_output=True, text=True, timeout=30)
        if refused and refused[0] == name:
            assert cli.returncode == 2 and cli.stderr.startswith(wanted + "\n"), (label, cli.stderr)
        else:
            assert cli.returncode == 0, (label, name, cli.stderr)
    if refused:
        try:
            mail.events()
        except Exception as error:
            assert (error.key, error.value) == ("lane-mail-failed", wanted), (label, error)
        else:
            raise AssertionError(f"{label}: a damaged unread line must refuse the relay's read")
    else:
        assert [row["id"] for row in equivalent()] == ["notice-d", "directive-d"], label
    if over_bytes is None:
        assert mail.snapshots["stamp"] == warm, "the raised count must be judged on the cached snapshot"
(box / "to-overseer.seen").unlink(missing_ok=True)

# The CLI's flock helper leaves ownership on its shell's descriptors. The
# child inherits this fixture environment unchanged, as the real helper does.
for fd in (8, 9):
    try:
        os.fstat(fd)
    except OSError as error:
        assert error.errno == errno.EBADF
    else:
        raise AssertionError("the fixture must own its inherited descriptor slots")
streams = [over.open("rb"), lane.open("rb")]
for fd, stream in zip((8, 9), streams):
    os.dup2(stream.fileno(), fd)
try:
    command = [sys.executable, str(MAILBOX_READ_FILES[0]),
               "plain-lock", str(box), str(over), str(lane)]
    result = subprocess.run(command, pass_fds=(8, 9), capture_output=True, check=True, timeout=30)
    assert result.stdout == b""
    for path in (over, lane):
        with path.open("rb") as stream:
            try:
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                assert error.errno in (errno.EACCES, errno.EAGAIN)
            else:
                raise AssertionError("a helper's inode lock must survive its exit")

    # A second descriptor for the held inode cannot acquire its lock.
    # Inject one deadline-sized time advance instead of a real wait.
    with over.open("rb") as contender:
        os.dup2(contender.fileno(), 8)
        child = r'''
import runpy, sys
from pathlib import Path
scope = runpy.run_path(sys.argv[1])
class Clock:
    now = 0
    def monotonic(self): return self.now
    def sleep(self, seconds):
        self.now += 30
        if self.now > 30: raise RuntimeError("lock exceeded its deadline")
scope["validate_and_lock_pair"].__globals__["time"] = Clock()
try:
    scope["validate_and_lock_pair"](Path(sys.argv[2]), [Path(path) for path in sys.argv[3:5]])
except scope["StoreRefusal"] as error:
    print(error.key)
else:
    raise AssertionError("the second reader must reach its lock bound")
'''
        result = subprocess.run([sys.executable, "-c", child, *command[1:2], *command[3:]],
                                pass_fds=(8, 9), capture_output=True, check=True, timeout=30)
        assert result.stdout == b"lock-failed\n"
finally:
    for fd in (8, 9):
        os.close(fd)
    for stream in streams:
        stream.close()
# A mailbox package from before its damaged-line rule supplies every read
# definition but MAILBOX_LINE_JQ, and its read_events calls none: Slack still
# reads beside it.
import mailbox as slack_mailbox
import shlex
older = root / "tmp/older-mailbox"
older.mkdir(parents=True, exist_ok=True)
(older / "mailbox-append.sh").write_text(f". {shlex.quote(str(MAILBOX_READ_FILES[1]))}\nunset MAILBOX_LINE_JQ\n")
(older / "lane-mail-store.py").write_text(
    "def read_events(box, jq_defs, previous, receipts=False, timeout=30):\n    return [{'defs': jq_defs}], None\n")
installed = slack_mailbox.MAILBOX_READ_FILES
slack_mailbox.MAILBOX_READ_FILES = (older / "lane-mail-store.py", older / "mailbox-append.sh", installed[2])
try:
    older_rows, _ = LaneMail(root)._read_events()
finally:
    slack_mailbox.MAILBOX_READ_FILES = installed
older_defs = older_rows[0]["defs"]
assert "def overseer_mail_class" in older_defs and "mailbox_line_invalid" not in older_defs, older_defs[:200]

if linked:
    assert mail.box == box
    assert not (root / "tmp/lane-mail/overseer").exists(), "reads must not create a second mailbox"
assert Path(mail.reader.__code__.co_filename) == MAILBOX_READ_FILES[0], \
    "the reader code must come from the installed dependency beside Slack"
print("mailbox-read: output-equivalent=yes numbered-tail=yes cursor=yes")
