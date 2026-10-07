"""Drive the production lane-mail and prune commands in isolated repositories."""

import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tarfile
import unittest

ROOT, SCRATCH = map(Path, sys.argv[1:3])
sys.argv[1:] = []
SCRIPTS = ROOT / "skills/orch/scripts"
OLD = "2000-01-01T00:00:00Z"
FRESH = "2026-10-01T00:00:00Z"


class Compaction(unittest.TestCase):
    def setUp(self):
        self.home = SCRATCH / self.id().split(".")[-1]
        self.home.mkdir()
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.home), "LC_ALL": "C",
                    "ORCH_RECORD_RETENTION_DAYS": "5", "SLACK_THREAD_DAYS": "5",
                    "FLEET_DIR": str(self.home / "fleet")}
        self.bin = self.home / "bin"
        self.bin.mkdir()
        date = shutil.which("date", path=self.env["PATH"])
        (self.bin / "date").write_text(
            f'#!/bin/sh\nif [ "$*" = "-u +%s" ]; then echo "${{TEST_NOW:-1790870400}}"; else exec "{date}" "$@"; fi\n')
        (self.bin / "date").chmod(0o755)
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        self.serial = 0

    def world(self):
        self.serial += 1
        repo = self.home / f"repo-{self.serial}"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], env=self.env, check=True)
        for key in ("gc.auto", "maintenance.auto"):
            subprocess.run(["git", "-C", str(repo), "config", key, "0" if key == "gc.auto" else "false"],
                           env=self.env, check=True)
        box = repo / "tmp/lane-mail/overseer"
        box.mkdir(parents=True)
        (repo / "tmp/workflow-state-oversee.json").write_text(
            json.dumps({"overseer": {"server": "7000", "pane": "%0"}}) + "\n")
        return repo, box

    def run_cli(self, repo, *args, scripts=SCRIPTS, check=True):
        target = [] if args[0] == "peer" else ["--item", "overseer", "--root", str(repo)]
        result = subprocess.run([str(scripts / "lane-mail"), *args, *target],
                                cwd=repo, env=self.env, text=True, capture_output=True)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def rows(self, box, name, rows):
        (box / (name + ".jsonl")).write_text("".join(json.dumps(row) + "\n" for row in rows))

    def fixture(self):
        repo, box = self.world()
        self.rows(box, "to-overseer", [
            {"id": "closed", "kind": "ask", "at": OLD},
            {"id": "open", "kind": "ask", "at": OLD},
            {"id": "expired", "kind": "notice", "at": OLD},
            {"id": "fresh", "kind": "notice", "at": FRESH}])
        self.rows(box, "to-lane", [
            {"id": "closed-answer", "kind": "answer", "re": "closed", "at": OLD},
            {"id": "read-old", "kind": "directive", "at": OLD},
            {"id": "read-fresh", "kind": "directive", "at": FRESH},
            {"id": "unread-old", "kind": "directive", "at": OLD}])
        (box / "to-lane.cursor").write_text("3\n")
        (box / "to-lane.cursor.lock").touch()
        return repo, box

    def stable_values(self, scripts):
        repo, box = self.fixture()
        before = self.run_cli(repo, "events", scripts=scripts).stdout
        peek = self.run_cli(repo, "inbox", "--peek", scripts=scripts).stdout
        compacted = self.run_cli(repo, "compact", scripts=scripts)
        self.assertEqual(compacted.stdout, "compacted item=overseer to-lane=2 to-overseer=2\n")
        pointers = [line.partition("=")[2] for line in compacted.stderr.splitlines()
                    if line.startswith("lane-mail: archived=")]
        self.assertEqual(len(pointers), 1)
        self.assertTrue(Path(pointers[0]).is_file())
        after = self.run_cli(repo, "events", scripts=scripts).stdout
        before_rows = [json.loads(row) for row in before.splitlines()]
        kept = {"open", "fresh", "read-fresh", "unread-old"}
        self.assertEqual([json.loads(row) for row in after.splitlines()],
                         [row for row in before_rows if row["id"] in kept])
        self.assertEqual(self.run_cli(repo, "inbox", "--peek", scripts=scripts).stdout, peek)
        drained = self.run_cli(repo, "drain", "--after", "3", "--receipts", scripts=scripts).stdout
        self.assertEqual(drained.splitlines()[0], "count=4 first=closed")
        self.assertIn("receipts cursor=3 count=4 first=closed-answer", drained)
        self.assertIn("3 read-fresh ", drained)
        self.assertIn("4 unread-old ", drained)
        self.assertEqual([json.loads(row)["id"] for row in drained.splitlines() if row.startswith("{")], ["fresh"])
        self.assertEqual((box / "to-lane.cursor").read_text(), "3\n")
        self.assertEqual(json.loads((box / "to-lane.jsonl.numbering").read_text())["dropped"], 2)
        pending = [json.loads(row)["id"] for row in self.run_cli(repo, "pending", scripts=scripts).stdout.splitlines()]
        self.assertEqual(pending, ["open", "unread-old"])
        self.assertEqual(self.run_cli(repo, "compact", scripts=scripts).stdout,
                         "compacted item=overseer to-lane=0 to-overseer=0\n")
        text = repo / "message.txt"
        text.write_text("another directive\n")
        self.run_cli(repo, "send", "--directive", "--file", str(text), scripts=scripts)
        events = [json.loads(row) for row in self.run_cli(repo, "events", scripts=scripts).stdout.splitlines()]
        self.assertEqual((events[-1]["line"], events[-1]["count"]), (5, 5))
        archives = list((self.home / "fleet/archive" / repo.name / "oversee").glob("*.tgz"))
        self.assertEqual(len(archives), 1)
        self.assertEqual(Path(pointers[0]), archives[0])
        with tarfile.open(archives[0]) as archive:
            archived = b"".join(archive.extractfile(member).read() for member in archive.getmembers() if member.isfile())
        self.assertIn(b'"expired"', archived)
        self.assertNotIn(b'"open"', archived)

    def mutant(self, name, relative, old, new):
        scripts = self.home / name / "scripts"
        shutil.copytree(SCRIPTS, scripts)
        path = scripts / relative
        content = path.read_text()
        self.assertEqual(content.count(old), 1, f"mutation target: {old}")
        changed = content.replace(old, new)
        self.assertNotEqual(content, changed)
        path.write_text(changed)
        return scripts

    def test_stable_cursor(self):
        self.stable_values(SCRIPTS)
        mutant = self.mutant("missing-parser", "lane-mail", '"$MAILBOX_TIME_JQ$MAILBOX_CLASS_JQ"',
                             '"$MAILBOX_CLASS_JQ"')
        with self.assertRaises(AssertionError):
            self.stable_values(mutant)
        mutant = self.mutant("physical", "lib/lane-mail-store.py", "numbers = record[\"lines\"] + list(range(",
                             "numbers = [] + list(range(")
        with self.assertRaises(AssertionError):
            self.stable_values(mutant)
        mutant = self.mutant("archive-pointer", "lane-mail", '    lm_message archived "$ARCHIVE" >&2',
                             '    : archived "$ARCHIVE"')
        with self.assertRaises(AssertionError):
            self.stable_values(mutant)

    def test_empty_numbered_mailbox(self):
        repo, box = self.world()
        self.rows(box, "to-lane", [{"id": "original", "kind": "directive", "at": OLD}])
        (box / "to-lane.cursor").write_text("1\n")
        self.assertEqual(self.run_cli(repo, "compact").stdout,
                         "compacted item=overseer to-lane=1 to-overseer=0\n")
        self.assertEqual(self.run_cli(repo, "inbox", "--peek").stdout, "count=1 first=original\n")
        self.assertEqual(self.run_cli(repo, "pending").stdout, "")
        text = repo / "message.txt"
        text.write_text("new\n")
        self.run_cli(repo, "send", "--directive", "--file", str(text))
        event = json.loads(self.run_cli(repo, "events").stdout)
        self.assertEqual((event["line"], event["count"]), (2, 2))
        self.assertEqual(self.run_cli(repo, "inbox", "--peek").stdout.splitlines()[0], "count=2 first=original")

    def test_open_ask(self):
        cases = [
            ("unanswered", ["old-open"], "or unread or open_ask", "or unread or False"),
            ("answered", ["old-open"], 'row["class"] == "close"',
             'row["class"] in ("close", "resolution")'),
            ("resolved", [], 'row["class"] == "close"', 'row["class"] == "resolution"'),
            ("legacy", [], None, None),
        ]
        for mode, expected, old, new in cases:
            variants = [SCRIPTS]
            if old is not None:
                variants.append(self.mutant(mode, "lib/lane-mail-store.py", old, new))
            for scripts in variants:
                with self.subTest(mode=mode, control=scripts != SCRIPTS):
                    repo, box = self.world()
                    self.rows(box, "to-overseer", [
                        {"id": "old-open", "kind": "ask", "to": "owner", "at": OLD}])
                    self.env["TEST_NOW"] = "946684800"
                    if mode == "answered":
                        text = repo / "message.txt"
                        text.write_text("continue\n")
                        self.run_cli(repo, "send", "--re", "old-open", "--file", str(text), scripts=scripts)
                    elif mode == "resolved":
                        self.run_cli(repo, "resolve", "--id", "old-open", scripts=scripts)
                    elif mode == "legacy":
                        # The pre-1.3 resolve producer wrote no closes field.
                        self.rows(box, "to-lane", [{"id": "legacy-close", "kind": "answer",
                                                  "by": "text", "re": "old-open", "at": OLD}])
                    self.run_cli(repo, "inbox", scripts=scripts)
                    self.env["TEST_NOW"] = "1790870400"
                    self.run_cli(repo, "compact", scripts=scripts)
                    retained = [json.loads(row)["id"] for row in
                                (box / "to-overseer.jsonl").read_text().splitlines()]
                    if scripts == SCRIPTS:
                        self.assertEqual(retained, expected)
                        pending = [json.loads(row)["id"] for row in
                                   self.run_cli(repo, "pending", "--to", "owner").stdout.splitlines()]
                        self.assertEqual(pending, expected)
                        events = [json.loads(row) for row in self.run_cli(repo, "events").stdout.splitlines()]
                        self.assertEqual([row["id"] for row in events if row["kind"] == "ask"], expected)
                        self.assertEqual(len(events), 2 if mode == "answered" else len(expected))
                    else:
                        with self.assertRaises(AssertionError):
                            self.assertEqual(retained, expected)

    def peer_exchange(self, scripts):
        requester, requester_box = self.world()
        receiver, receiver_box = self.world()
        text = requester / "message.txt"
        self.env["TEST_NOW"] = "946684800"
        asks = []
        for words in ("closed", "open"):
            text.write_text(words + "\n")
            sent = self.run_cli(requester, "peer", "ask", "--repo", str(receiver), "--file", str(text))
            self.assertTrue(sent.stdout.startswith("id="), sent.stdout)
            asks.append(sent.stdout.strip()[3:])
        self.assertEqual([json.loads(row)["id"] for row in
                          self.run_cli(receiver, "inbox").stdout.splitlines()], asks)
        text.write_text("done\n")
        self.run_cli(receiver, "peer", "send", "--repo", str(requester), "--re", asks[0],
                     "--file", str(text), scripts=scripts)
        self.assertEqual(self.run_cli(requester, "wait", "--id", asks[0], "--timeout", "1",
                                     scripts=scripts).stdout, "done\n")
        self.assertEqual(self.run_cli(requester, "inbox", scripts=scripts).stdout, "")
        self.env["TEST_NOW"] = "1790870400"
        self.assertEqual(self.run_cli(receiver, "compact", scripts=scripts).stdout,
                         "compacted item=overseer to-lane=1 to-overseer=1\n")
        self.assertEqual(json.loads((receiver_box / "to-lane.jsonl").read_text())["id"], asks[1])
        self.assertEqual((receiver_box / "to-overseer.jsonl").read_text(), "")
        self.assertEqual(self.run_cli(requester, "compact").stdout,
                         "compacted item=overseer to-lane=1 to-overseer=1\n")
        self.assertEqual(json.loads((requester_box / "to-overseer.jsonl").read_text())["id"], asks[1])

    def test_peer_exchange(self):
        self.peer_exchange(SCRIPTS)
        mutant = self.mutant("unrecorded-reply", "lane-mail",
                             'if [ "$PEER_VERB" = ask ] || [ -n "$MSGID" ]; then',
                             'if [ "$PEER_VERB" = ask ]; then')
        with self.assertRaisesRegex(AssertionError, "compacted item=overseer to-lane=0 to-overseer=0"):
            self.peer_exchange(mutant)
        frozen = self.mutant("wait-cursor-frozen", "lane-mail",
                             '        [ "$SEEN" -ge "$ANSWER_AT" ] || lm_cursor_write "$ANSWER_AT"',
                             '        :')
        with self.assertRaisesRegex(AssertionError, "done"):
            self.peer_exchange(frozen)

    def race(self, scripts):
        repo, box = self.world()
        path = box / "to-lane.jsonl"
        self.rows(box, "to-lane", [{"id": "expired", "kind": "directive", "at": OLD}])
        (box / "to-lane.cursor").write_text("1\n")
        ready, release, opened = [self.home / f"{name}-{self.serial}" for name in ("ready", "release", "opened")]
        for fifo in (ready, release, opened):
            os.mkfifo(fifo)
        fds = [os.open(fifo, os.O_RDWR) for fifo in (ready, release, opened)]
        env = dict(self.env, READY=str(ready), RELEASE=str(release), OPENED=str(opened))
        compact = subprocess.Popen([str(scripts / "lane-mail"), "compact", "--item", "overseer", "--root", str(repo)],
                                   cwd=repo, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        writer = None
        try:
            # FIFO readiness proves both processes reached the lock, rather
            # than assuming a scheduler speed through a sleep.
            self.assertTrue(select.select([fds[0]], [], [], 30)[0], "compactor reached rewrite")
            os.read(fds[0], 1)
            writer = subprocess.Popen(["bash", "-c", '''set -euo pipefail
. "$1/lib/file-lock.sh"
. "$1/lib/mailbox-append.sh"
original=$(declare -f orch_take_lock)
eval "${original/orch_take_lock/original_take_lock}"
orch_take_lock() { printf x > "$OPENED"; original_take_lock "$@"; }
printf '%s\\n' '{"id":"writer","kind":"directive"}' | mailbox_append_locked "$2" 30
''', "writer", str(SCRIPTS), str(path)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertTrue(select.select([fds[2]], [], [], 30)[0], "writer opened the locked inode")
            os.read(fds[2], 1)
            os.write(fds[1], b"x")
            out, err = compact.communicate(timeout=30)
            self.assertEqual(compact.returncode, 0, err)
            out, err = writer.communicate(timeout=30)
            self.assertEqual(writer.returncode, 0, err)
            self.assertEqual(json.loads(path.read_text())["id"], "writer")
        finally:
            for process in (compact, writer):
                if process and process.poll() is None:
                    process.kill()
                    process.communicate()
            for fd in fds:
                os.close(fd)

    def test_waiting_writer(self):
        paused = self.mutant("paused", "lib/lane-mail-store.py", "    os.lseek(fd, 0, os.SEEK_SET)\n    with os.fdopen(os.dup(fd), \"r+b\")",
                             '''    with open(os.environ["READY"], "w") as ready:
        ready.write("x")
    with open(os.environ["RELEASE"], "r") as release:
        release.read(1)
    os.lseek(fd, 0, os.SEEK_SET)
    with os.fdopen(os.dup(fd), "r+b")''')
        self.race(paused)
        path = paused / "lib/lane-mail-store.py"
        old = '    Path(str(path) + ".numbering").write_bytes'
        text = path.read_text()
        self.assertEqual(text.count(old), 1)
        path.write_text(text.replace(old, '''    replacement = Path(str(path) + ".replacement")
    replacement.write_bytes(kept)
    os.replace(replacement, path)
''' + old))
        with self.assertRaises((AssertionError, json.JSONDecodeError)):
            self.race(paused)

    def prune_sessions(self, scripts, ordinary_name, keeps, removed, absolute=False):
        repo, box = self.world()
        files = [box / f"session-999999-{pane}.jsonl" for pane in (1, 2, 3, 4)]
        neighbor = box / "session-999999-10.jsonl"
        neighbor.write_text('{}\n')
        ordinary = repo / "tmp" / ordinary_name
        if ordinary_name == "keep.run":
            ordinary.mkdir()
            (ordinary / "watch.log").write_text("watch\n")
            os.utime(ordinary / "watch.log", (946684800, 946684800))
        else:
            ordinary.write_text("watch\n")
        os.utime(ordinary, (946684800, 946684800))
        unknown = box / "session-888888-1.jsonl"
        unknown.write_text('{}\n')
        (self.bin / "ps").write_text("#!/bin/sh\nprintf 'tmux\\n'\n")
        (self.bin / "tmux").write_text("#!/bin/sh\nprintf '999999 1 %%4\\n'\n")
        for command in ("ps", "tmux"):
            (self.bin / command).chmod(0o755)
        for path in files:
            path.write_text('{}\n')
        state = repo / "tmp/workflow-state-oversee.json"
        state.write_text(json.dumps({"issue_id": "oversee", "overseer": {
            "session_rows": str(files[1]), "pending": {"session_rows": str(files[2])}}}))
        self.rows(box, "to-overseer", [{"id": "expired", "kind": "notice", "at": OLD}])
        args = [word for path in keeps for word in ("--keep", str(repo / path) if absolute else path)]
        result = subprocess.run([str(scripts / "workflow-state"), "--state-dir", str(repo / "tmp"), "prune", *args],
                                cwd=repo, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        judged = [ordinary, files[0], neighbor]
        self.assertEqual([path.name for path in judged if not path.exists()], removed)
        self.assertTrue(files[1].exists())
        self.assertTrue(files[2].exists())
        self.assertTrue(files[3].exists())
        self.assertTrue(unknown.exists())
        sessions = sum(name.startswith("session-") for name in removed)
        self.assertIn(f"pruned fleet_log=0 lanes=0 progress_reports=0 paths={len(removed)} "
                      f"to-lane=0 to-overseer=1 sessions={sessions}\n", result.stdout)
        self.assertEqual([line[12:] for line in result.stdout.splitlines() if line.startswith("pruned path=")],
                         [str(path) for path in judged if path.name in removed])
        kept = [Path(line[5:]) for line in result.stdout.splitlines() if line.startswith("kept=")]
        self.assertEqual(len(kept), 2 if removed else 1)
        self.assertTrue(all(path.is_file() for path in kept))
        archived_paths = set()
        for path in kept:
            with tarfile.open(path) as archive:
                archived_paths.update(member.name.rstrip("/") for member in archive.getmembers())
        for path in judged:
            self.assertEqual(str(path).lstrip("/") in archived_paths, path.name in removed)

    def test_prune_sessions(self):
        cases = [
            ("kept.log", (), ["kept.log", "session-999999-1.jsonl", "session-999999-10.jsonl"], False),
            ("kept.log", ("tmp/kept.log", "tmp/lane-mail/overseer/session-999999-1.jsonl"),
             ["session-999999-10.jsonl"], True),
            ("keep.run", ("tmp/keep.run/watch.log", "tmp/lane-mail/overseer/session-999999-1.jsonl"),
             ["session-999999-10.jsonl"], False),
            ("keep.run", ("tmp/keep.run/watch.log", "tmp/lane-mail/overseer/session-999999-1.jsonl",
                          "tmp/lane-mail/overseer/session-999999-10.jsonl"), [], False),
        ]
        for case in cases:
            with self.subTest(keeps=case[1]):
                self.prune_sessions(SCRIPTS, *case)
        mutant = self.mutant("unnamed", "lib/session-rows.sh",
                             '    case "$nl$named$nl" in *"$nl$file$nl"*) continue ;; esac',
                             '    : "$nl$named$nl"')
        with self.assertRaises(AssertionError):
            self.prune_sessions(mutant, *cases[0])
        mutant = self.mutant("prune-pointer", "workflow-state",
                             '    [[ -z "$mailbox_archive" ]] || printf \'kept=%s\\n\' "$mailbox_archive"',
                             '    : "$mailbox_archive"')
        with self.assertRaises(AssertionError):
            self.prune_sessions(mutant, *cases[0])
        mutant = self.mutant("ignored-keep", "workflow-state",
                             '[[ "$unit" != "$keep" && "$keep" != "$unit"/* ]] || return 0',
                             '[[ "$unit" != "$keep" && "$keep" != "$unit"/* ]] || :')
        with self.assertRaises(AssertionError):
            self.prune_sessions(mutant, *cases[2])
        mutant = self.mutant("ignored-containment", "workflow-state",
                             '[[ "$unit" != "$keep" && "$keep" != "$unit"/* ]] || return 0',
                             '[[ "$unit" != "$keep" ]] || return 0')
        with self.assertRaisesRegex(AssertionError, r"\['keep\.run', 'session-999999-10\.jsonl'\]"):
            self.prune_sessions(mutant, *cases[2])
        mutant = self.mutant("session-keep-bypass", "workflow-state",
                             'for unit in ${SESSION_ROWS_DEAD[@]+"${SESSION_ROWS_DEAD[@]}"}; do\n'
                             '        unit_explicitly_kept "$unit" ${keeps[@]+"${keeps[@]}"} && continue',
                             'for unit in ${SESSION_ROWS_DEAD[@]+"${SESSION_ROWS_DEAD[@]}"}; do\n'
                             '        unit_explicitly_kept "$unit" ${keeps[@]+"${keeps[@]}"} && :')
        with self.assertRaises(AssertionError):
            self.prune_sessions(mutant, *cases[1])

    def test_retention_floor(self):
        self.env["SLACK_THREAD_DAYS"] = "7"
        repo, box = self.world()
        self.rows(box, "to-overseer", [{"id": "relay-window", "kind": "notice", "at": "2026-09-25T16:00:00Z"}])
        self.assertEqual(self.run_cli(repo, "compact").stdout,
                         "compacted item=overseer to-lane=0 to-overseer=0\n")
        mutant = self.mutant("floor", "lane-mail",
                             '    [ "$COMPACT_DAYS" -ge "$THREAD_DAYS" ] || COMPACT_DAYS="$THREAD_DAYS"',
                             '    : "$COMPACT_DAYS" "$THREAD_DAYS"')
        self.assertEqual(self.run_cli(repo, "compact", scripts=mutant).stdout,
                         "compacted item=overseer to-lane=0 to-overseer=1\n")
        self.env["ORCH_RECORD_RETENTION_DAYS"] = "0"
        result = self.run_cli(repo, "compact", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("lane-mail: retention-invalid=0:7", result.stderr)
        mutant = self.mutant("invalid", "lane-mail",
                             '    [ "$COMPACT_DAYS" -gt 0 ] && [ "$THREAD_DAYS" -gt 0 ] || refuse retention-invalid "$COMPACT_DAYS:$THREAD_DAYS"',
                             '    : "$COMPACT_DAYS:$THREAD_DAYS"')
        self.assertEqual(self.run_cli(repo, "compact", scripts=mutant).returncode, 0)

    def test_archive_failure(self):
        repo, box = self.fixture()
        before = (box / "to-lane.jsonl").read_bytes()
        (self.bin / "tar").write_text('#!/bin/sh\nprintf partial > "$2"\nexit 1\n')
        (self.bin / "tar").chmod(0o755)
        result = self.run_cli(repo, "compact", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("lane-mail: archive-failed=", result.stderr)
        self.assertEqual((box / "to-lane.jsonl").read_bytes(), before)
        self.assertFalse((box / "to-lane.jsonl.numbering").exists())
        archive_dir = self.home / "fleet/archive" / repo.name / "oversee"
        self.assertEqual(list(archive_dir.iterdir()), [])
        mutant = self.mutant("no-cleanup", "lib/state-archive.sh",
                             'rm -rf -- "${stage:?}" || exit 1',
                             ': -- "${stage:?}"')
        self.assertEqual(self.run_cli(repo, "compact", scripts=mutant, check=False).returncode, 2)
        self.assertTrue(any(archive_dir.iterdir()))
        mutant = self.mutant("no-archive", "lane-mail",
                             'refuse archive-failed "$ARCHIVE_DIR" "$ARCHIVE_ERR"',
                             ': archive-failed "$ARCHIVE_DIR" "$ARCHIVE_ERR"')
        self.assertEqual(self.run_cli(repo, "compact", scripts=mutant, check=False).returncode, 0)
        self.assertNotEqual((box / "to-lane.jsonl").read_bytes(), before)


unittest.main(verbosity=2)
