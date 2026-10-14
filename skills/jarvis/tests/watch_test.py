"""The shipped producer with real mailbox writes and explicit step barriers."""
import contextlib
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import io
import json
import os
import re
import select
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
SCRIPTS = REPO / "skills/jarvis/scripts"
BASH = os.environ["JARVIS_TEST_BASH"]


def load(path=SCRIPTS / "lib/watch.py"):
    spec = importlib.util.spec_from_file_location("jarvis_watch", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Producer(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.project("home")
        self.peer = self.project("peer")
        self.registry = self.root / "registry"
        self.registry.write_text(str(self.home) + "\n" + str(self.peer) + "\n")
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "XDG_STATE_HOME")
                    and not key.startswith(("JARVIS_", "ORCH_", "KENDEX_", "SLACK_"))}
        self.env.update(PATH=str(self.bin)+os.pathsep+os.environ["PATH"], HOME=str(self.root),
                        REGISTRY=str(self.registry), PYTHONDONTWRITEBYTECODE="1")
        self.executable("kendex", '#!/bin/sh\ncat "$REGISTRY"\n')
        self.module = load()
        self.settings = dict(JARVIS_CONTROL_HOST="", JARVIS_LOG_DIR=str(self.root / "log"), JARVIS_WAKE_SETTLE_SECS="15")

    def project(self, name):
        root = self.root / name
        root.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(root)], check=True, capture_output=True,
                       env={k:v for k,v in os.environ.items() if not k.startswith("GIT_")})
        for key, value in (("gc.auto", "0"), ("maintenance.auto", "false")):
            subprocess.run(["git", "-C", str(root), "config", key, value], check=True,
                           env={k:v for k,v in os.environ.items() if not k.startswith("GIT_")})
        for name in ("mailbox", "orch", "slack"):
            target = root / ".agents/skills" / name
            target.mkdir(parents=True)
            target.joinpath("scripts").symlink_to(REPO / "skills" / name / "scripts", target_is_directory=True)
        clean = {k:v for k,v in os.environ.items() if not k.startswith(("GIT_", "ORCH_", "KENDEX_"))}
        state = REPO / "skills/orch/scripts/workflow-state"
        subprocess.run([str(state), "init", "oversee"], cwd=root, env=clean, check=True, capture_output=True)
        subprocess.run([str(state), "set", "oversee", "overseer", json.dumps({"pane":"%1", "server":str(os.getpid())})],
                       cwd=root, env=clean, check=True, capture_output=True)
        return root

    def executable(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)
        return path

    def command(self, args, root=None):
        return subprocess.run(list(map(str, args)), cwd=root or self.home, env=self.env,
                              capture_output=True, text=True, timeout=30)

    def mail(self, root, verb, text, *options):
        payload = self.root / "message"
        payload.write_text(text)
        result = self.command([root / ".agents/skills/mailbox/scripts/lane-mail", verb,
                               "--item", "overseer", "--file", payload, *options], root)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def read_pass(self, cursor=None):
        result = self.command([BASH, SCRIPTS / "vm-watch.sh", "--home", self.home,
                               "--cursor", json.dumps(cursor or {})])
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        return result.stdout, json.loads(lines[-1][8:])["roots"]

    def watch(self):
        return self.module.Watch(self.home, BASH, self.settings)

    def append(self, watch, content):
        watch.append(content + 'cursor: {"side":"local","roots":{}}\n')

    def inbox(self):
        path = self.home / "tmp/lane-mail/overseer/to-lane.jsonl"
        return [json.loads(row) for row in path.read_text().splitlines()] if path.exists() else []

    def test_mail_pass_markers_restore_and_unreachable(self):
        self.mail(self.home, "notice", "owner message", "--to", "owner")
        ask = self.mail(self.peer, "ask", "question", "--to", "owner", "--recommend", "yes", "--options", "yes,no")
        ask_id = ask.stdout.split("id=", 1)[1].split()[0]
        self.mail(self.peer, "send", "peer answer", "--re", ask_id)
        self.mail(self.home, "send", "already delivered at home", "--directive")
        noted = self.project("noted")
        self.mail(noted, "notice", "must stay hidden", "--to", "owner")
        missing = self.root / "missing"
        with self.registry.open("a") as out:
            out.write(str(noted) + " (worktree of ignored)\n" + str(missing) + "\n")
        output, cursor = self.read_pass()
        self.assertIn("EVENT mail repo=home file=to-overseer\n", output)
        self.assertIn("peer answer\n", output)
        self.assertIn("ask to=owner ref= options=yes,no recommend=yes deadline=", output)
        self.assertNotIn("already delivered at home", output)
        self.assertNotIn("must stay hidden", output)
        self.assertIn("EVENT root-unreachable repo=missing", output)
        marker = self.home / "tmp/lane-mail/overseer/to-overseer.seen"
        self.assertEqual(marker.read_text().strip(), str(cursor[str(self.home)]["to-overseer"]["count"]))
        # Consume the canonical marker through the unchanged relay owner.
        probe = ('import sys; from pathlib import Path; '
                 'sys.path.insert(0,sys.argv[1]); from relay import RootRelay; from mailbox import LaneMail; '
                 'reader=RootRelay.__new__(RootRelay); reader._mail=LaneMail(Path(sys.argv[2])); '
                 'events=reader.mail.events(); print(reader.jarvis_session_read(events))')
        received = self.command([sys.executable, "-B", "-c", probe, REPO / "skills/slack/scripts/lib", self.home])
        self.assertEqual(received.returncode, 0, received.stderr)
        self.assertEqual(received.stdout.strip(), str(cursor[str(self.home)]["to-overseer"]["count"]))
        again, cursor = self.read_pass(cursor)
        self.assertNotIn("EVENT ", again)
        # A restored box may have a smaller logical count. The successful
        # header becomes the retained position, so a later append is visible.
        box = self.peer / "tmp/lane-mail/overseer/to-overseer.jsonl"
        box.write_text("")
        _, cursor = self.read_pass(cursor)
        self.assertEqual(cursor[str(self.peer)]["to-overseer"]["count"], 0)
        self.mail(self.peer, "notice", "after restore", "--to", "owner")
        output, cursor = self.read_pass(cursor)
        self.assertIn("after restore", output)
        # The public marker includes rows the event filter does not emit.
        with (self.home / "tmp/lane-mail/overseer/to-overseer.jsonl").open("a") as out:
            out.write("interrupted producer left a terminated invalid row\n")
        _, cursor = self.read_pass(cursor)
        self.assertEqual(marker.read_text().strip(), str(cursor[str(self.home)]["to-overseer"]["count"]))

    def test_compaction_and_failed_read(self):
        for value in ("old a", "old b"):
            self.mail(self.peer, "notice", value, "--to", "owner")
        _, cursor = self.read_pass()
        # The mailbox compactor owns numbering and retention. Date injection
        # ages the notices without editing its private numbering files.
        real_date = shutil.which("date")
        self.executable("date", '#!/bin/sh\ncase "$*" in *+%s*) echo 9999999999;; *) exec '+real_date+' "$@";; esac\n')
        result = self.command([self.peer / ".agents/skills/mailbox/scripts/lane-mail", "compact", "--item", "overseer"], self.peer)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.bin.joinpath("date").unlink()
        self.mail(self.peer, "notice", "new after compact", "--to", "owner")
        output, cursor = self.read_pass(cursor)
        self.assertIn("new after compact", output)
        self.assertNotIn("old a", output)
        self.assertGreater(cursor[str(self.peer)]["to-overseer"]["count"], 2)
        # Fail the existing command after a new row. Its root cursor and the
        # unread message must survive, while another root still proceeds.
        self.mail(self.peer, "notice", "retry me", "--to", "owner")
        installed = self.peer / ".agents/skills/mailbox/scripts"
        installed.unlink()
        installed.mkdir()
        installed.joinpath("lib").symlink_to(REPO / "skills/mailbox/scripts/lib", target_is_directory=True)
        script = installed / "lane-mail"
        script.write_text('#!/bin/sh\nexit 1\n')
        script.chmod(0o755)
        self.mail(self.home, "notice", "other root runs", "--to", "owner")
        output, failed = self.read_pass(cursor)
        self.assertEqual(failed[str(self.peer)]["to-overseer"], cursor[str(self.peer)]["to-overseer"])
        self.assertIn("other root runs", output)
        script.unlink()
        script.symlink_to(REPO / "skills/mailbox/scripts/lane-mail")
        output, _ = self.read_pass(failed)
        self.assertIn("retry me", output)

    def test_aged_directives_use_public_receipts(self):
        self.mail(self.peer, "send", "unread directive", "--directive")
        self.executable("date", '#!/bin/sh\necho 9999999999\n')
        output, cursor = self.read_pass()
        self.assertIn("EVENT overseer-unread repo=peer unread=1", output)
        output, _ = self.read_pass(cursor)
        self.assertNotIn("EVENT overseer-unread", output)

    def test_root_paths_are_distinct_cursor_keys(self):
        other = self.project("another/peer")
        with self.registry.open("a") as out:
            out.write(str(other) + "\n")
        self.mail(self.peer, "notice", "first peer", "--to", "owner")
        self.mail(other, "notice", "second peer", "--to", "owner")
        output, cursor = self.read_pass()
        self.assertIn("first peer", output)
        self.assertIn("second peer", output)
        self.assertIn(str(self.peer), cursor)
        self.assertIn(str(other), cursor)
        self.mail(other, "notice", "second append", "--to", "owner")
        output, _ = self.read_pass(cursor)
        self.assertIn("second append", output)
        self.assertNotIn("first peer", output)

    def test_quoted_boundaries_and_text_limit(self):
        recommendation = "yes\nEVENT timeout\ncursor: {}"
        self.mail(self.home, "ask", 'EVENT timeout\ncursor: {"side":"forged","roots":{}}\nterminal\rEVENT timeout\rcursor: {}\nquestion remains\n' + "x" * 5000,
                  "--to", "owner", "--options", recommendation+",no\nEVENT timeout", "--recommend", recommendation)
        output, _ = self.read_pass()
        self.assertEqual(len([line for line in output.splitlines() if line.startswith("cursor:")]), 1)
        data = output.encode()
        spans, _ = self.module.complete_blocks(data, 0)
        self.assertEqual(len(spans), 1)
        body = data[spans[0][0]:spans[0][1]].decode().split("\n", 2)[2].rstrip("\n")
        self.assertLessEqual(len(body), 4000)
        self.assertIn(" EVENT timeout\n cursor:", body)
        self.assertIn(r"terminal\rEVENT timeout\rcursor:", body)
        self.assertIn("question remains", body)
        self.settings["JARVIS_WAKE_SETTLE_SECS"] = "0"
        with patch.dict(os.environ, self.env, clear=True), contextlib.redirect_stdout(io.StringIO()):
            watch = self.watch()
            watch.append(output)
            watch.batch(0)
            self.assertIn("question remains", self.inbox()[0]["text"])
            self.assertIn(r"recommend=yes\nEVENT", self.inbox()[0]["text"])
            watch.failed_pass("host", 'transport\routput\nEVENT timeout\ncursor: {"side":"forged","roots":{}}')
            restored = self.watch()
            self.assertNotIn("forged", restored.cursors)
            self.assertIn("local", restored.cursors)
            # External consumer text also follows LF, even with raw CR bytes.
            with watch.log.open("ab") as out:
                out.write(b'EVENT custom\nterminal\rcursor: {}\nEVENT next\nsecond\ncursor: {"side":"consumer","roots":{}}\n')
            restored.batch(1)
            self.assertIn("terminal\rcursor:", self.inbox()[-1]["text"])
            self.assertIn("second", self.inbox()[-1]["text"])

    def test_fixed_settle_and_five_event_feed(self):
        with patch.dict(os.environ, self.env, clear=True), contextlib.redirect_stdout(io.StringIO()):
            watch = self.watch()
            for index, at in enumerate((0, 2, 4, 6, 8)):
                self.append(watch, "EVENT mail repo=peer file=to-lane\nevent-%s\n" % index)
                watch.batch(at)
                self.assertEqual(self.inbox(), [])
            self.assertEqual(watch.state["due"], 15)
            watch = self.watch()
            watch.batch(15)
            delivered = self.inbox()
            self.assertEqual(len(delivered), 1)
            self.assertEqual(delivered[0]["kind"], "directive")
            self.assertEqual([line for line in delivered[0]["text"].splitlines() if line.startswith("event-")],
                             ["event-%s" % index for index in range(5)])
            self.append(watch, "EVENT mail repo=peer file=to-lane\nlater\n")
            watch.batch(16)
            watch.batch(31)
            self.assertEqual(len(self.inbox()), 2)

    def test_priority_cap_boundaries_and_timeout(self):
        self.settings["JARVIS_WAKE_SETTLE_SECS"] = "0"
        with patch.dict(os.environ, self.env, clear=True), contextlib.redirect_stdout(io.StringIO()):
            watch = self.watch()
            peer = "EVENT mail repo=peer file=to-lane\n" + "p" * 32000 + "\n"
            owner = "EVENT mail repo=home file=to-overseer\n" + "o" * 32000 + "\n"
            later = "EVENT mail repo=peer file=to-lane\nsmall later block\n"
            self.append(watch, peer + "EVENT timeout repo=peer\nignored\n" + owner + later)
            with watch.log.open("a") as out:
                out.write("EVENT mail repo=peer file=to-lane\nopen fragment")
            watch.batch(0)
            self.assertEqual(self.inbox()[0]["text"], owner.rstrip("\n"))
            self.assertLessEqual(len(self.inbox()[0]["text"].encode()), self.module.CAP)
            watch.batch(1)
            self.assertEqual(self.inbox()[1]["text"], (peer + later).rstrip("\n"))
            self.assertEqual(watch.state["spans"], [])
            with watch.log.open("a") as out:
                out.write('\ncursor: {"side":"local","roots":{}}\n')
            watch.batch(2)
            self.assertIn("open fragment", self.inbox()[2]["text"])

    def test_saved_selection_after_append_restart(self):
        self.settings["JARVIS_WAKE_SETTLE_SECS"] = "0"
        with patch.dict(os.environ, self.env, clear=True), contextlib.redirect_stdout(io.StringIO()):
            watch = self.watch()
            self.append(watch, "EVENT mail repo=peer file=to-lane\noriginal\n")
            original_save = watch.save
            def stop_after_receipt():
                if watch.state["pending"] is None:
                    raise InterruptedError("acknowledgement barrier before commit")
                original_save()
            watch.save = stop_after_receipt
            with self.assertRaises(InterruptedError):
                watch.batch(0)
            original_id = self.inbox()[0]["id"]
            pending = json.loads(watch.path.read_text())["pending"]
            self.assertIn("original", pending["body"])
            with watch.log.open("a") as out:
                out.write('EVENT mail repo=peer file=to-lane\nnew during restart\ncursor: {"side":"consumer","roots":{}}\n')
            resumed = self.watch()
            resumed.batch(1)
            self.assertEqual(len(self.inbox()), 1)
            self.assertEqual(self.inbox()[0]["id"], original_id)
            resumed.batch(2)
            self.assertEqual(len(self.inbox()), 2)
            self.assertIn("new during restart", self.inbox()[1]["text"])
            self.assertNotIn("original", self.inbox()[1]["text"])

    def test_failed_send_retains_selection(self):
        self.settings["JARVIS_WAKE_SETTLE_SECS"] = "0"
        with patch.dict(os.environ, self.env, clear=True), contextlib.redirect_stdout(io.StringIO()):
            watch = self.watch()
            self.append(watch, "EVENT mail repo=peer file=to-lane\nretained\n")
            script = self.home / ".agents/skills/mailbox/scripts"
            script.unlink()
            script.mkdir()
            script.joinpath("lib").symlink_to(REPO / "skills/mailbox/scripts/lib", target_is_directory=True)
            script.joinpath("lane-mail").write_text('#!/bin/sh\nexit 1\n')
            script.joinpath("lane-mail").chmod(0o755)
            watch.batch(0)
            saved = json.loads(watch.path.read_text())["pending"]
            self.assertIn("retained", saved["body"])
            script.joinpath("lane-mail").unlink()
            script.joinpath("lane-mail").symlink_to(REPO / "skills/mailbox/scripts/lane-mail")
            self.watch().batch(1)
            self.assertEqual(len(self.inbox()), 1)

    def test_slow_acquisition_does_not_extend_settle(self):
        ready, release = self.root / "ready", self.root / "release"
        os.mkfifo(ready)
        os.mkfifo(release)
        self.env.update(ACQUIRE_READY=str(ready), ACQUIRE_RELEASE=str(release))
        self.executable("kendex", '#!/bin/sh\nprintf ready > "$ACQUIRE_READY"\nread -r ack < "$ACQUIRE_RELEASE"\ncat "$REGISTRY"\n')
        with patch.dict(os.environ, self.env, clear=True), contextlib.redirect_stdout(io.StringIO()):
            watch = self.watch()
            watch.next_presence["local"] = 1000000
            self.append(watch, "EVENT mail repo=peer file=to-lane\nready before slow read\n")
            read_fd = os.open(ready, os.O_RDONLY | os.O_NONBLOCK)
            try:
                with ThreadPoolExecutor(max_workers=1) as passes:
                    pending = passes.submit(watch.acquire, 0)
                    try:
                        self.assertTrue(select.select([read_fd], [], [], 30)[0], "acquisition did not acknowledge start")
                        self.assertEqual(os.read(read_fd, 5), b"ready")
                        pending = watch._poll(passes, pending, 0)
                        self.assertEqual(self.inbox(), [])
                        pending = watch._poll(passes, pending, 15)
                        self.assertFalse(pending.done())
                        self.assertIn("ready before slow read", self.inbox()[0]["text"])
                    finally:
                        with release.open("w") as out:
                            out.write("ack\n")
                    pending.result(timeout=30)
            finally:
                os.close(read_fd)

    def test_settings_precedence_and_transport(self):
        shared = self.home / "kendex.settings.toml"
        private = self.home / ".env.local"
        values = {"JARVIS_CONTROL_HOST": "host", "JARVIS_LOG_DIR": str(self.root / "logs"), "JARVIS_WAKE_SETTLE_SECS": "7"}
        shared.write_text("[env]\n" + "".join('%s = "%s"\n' % pair for pair in values.items()))
        with patch.dict(os.environ, self.env, clear=True):
            self.assertEqual({key: self.module.config(BASH, self.home)[key] for key in values}, values)
            private.write_text("".join('%s=private\n' % key for key in values))
            self.assertEqual({self.module.config(BASH, self.home)[key] for key in values}, {"private"})
            with patch.dict(os.environ, values):
                self.assertEqual({key: self.module.config(BASH, self.home)[key] for key in values}, values)
        private.unlink()
        shared.unlink()
        example = (REPO / "skills/jarvis/kendex.settings.toml.example").read_text()
        consumed = set(re.findall(r'["\'](JARVIS_[A-Z_]+)["\']', (SCRIPTS / "lib/watch.py").read_text()))
        declared = set(re.findall(r'^(JARVIS_[A-Z_]+)\s*=', example, re.M))
        self.assertEqual(declared, consumed)
        with patch.dict(os.environ, self.env, clear=True):
            defaults = self.module.config(BASH, self.home)
            self.assertEqual(defaults["JARVIS_CONTROL_HOST"], "")
            self.assertEqual(defaults["JARVIS_WAKE_SETTLE_SECS"], "15")
            self.assertEqual(defaults["JARVIS_LOG_DIR"], str(self.root / ".local/state/jarvis"))
            with patch.dict(os.environ, XDG_STATE_HOME=str(self.root / "xdg")):
                self.assertEqual(self.module.config(BASH, self.home)["JARVIS_LOG_DIR"], str(self.root / "xdg/jarvis"))
            self.assertEqual(self.module.home_root(self.root), self.root)
            inside = self.home / "nested"
            inside.mkdir()
            self.assertEqual(self.module.home_root(inside), self.home)
        self.executable("ssh", '#!/bin/sh\nprintf "%s\\n" "$1" >> "$SSH_LOG"\ncd "$REMOTE_ROOT" || exit\nexec '+BASH+' -s\n')
        self.env.update(SSH_LOG=str(self.root / "ssh.log"), REMOTE_ROOT=str(self.peer))
        self.mail(self.peer, "notice", "remote owner", "--to", "owner")
        with patch.dict(os.environ, self.env, clear=True), contextlib.redirect_stdout(io.StringIO()):
            watch = self.watch()
            watch.tick(0, watch.acquire(0))
            self.assertFalse((self.root / "ssh.log").exists())
            self.settings["JARVIS_CONTROL_HOST"] = "host.example"
            watch = self.watch()
            watch.tick(1, watch.acquire(1))
            self.assertEqual((self.root / "ssh.log").read_text().splitlines(), ["host.example"])
            self.assertIn("remote owner", watch.log.read_text())
            self.assertIn("host", watch.cursors)

    def test_hold_paths_and_failed_renewal_reset(self):
        with patch.dict(os.environ, self.env, clear=True):
            settings = self.home / "kendex.settings.toml"
            cases = ((str(self.root / "absolute"), self.root / "absolute"),
                     ("~/user-hold", self.root / "user-hold"), ("relative", self.home / "relative"))
            for value, expected in cases:
                with self.subTest(value=value):
                    settings.write_text('[env]\nSLACK_JARVIS_SESSION_FILE = "'+value+'"\n')
                    self.module.hold(self.home, lambda: True)
                    self.assertTrue(expected.is_file())
            for declarations, expected in (
                ('SLACK_MASTER_FILE = "old"', self.home / "old"),
                ('SLACK_MASTER_FILE = "old"\nSLACK_JARVIS_SESSION_FILE = "new"', self.home / "new"),
                ('SLACK_MASTER_FILE = "unused"\nSLACK_JARVIS_SESSION_FILE = ""', None)):
                settings.write_text('[env]\n'+declarations+'\n')
                self.module.hold(self.home, lambda: True)
                if expected is not None:
                    self.assertTrue(expected.is_file())
            self.assertFalse((self.home / "unused").exists())
            settings.write_text('[env]\nSLACK_JARVIS_SESSION_FILE = "missing/hold"\n')
            watch = self.watch()
            for expected_count in (1, 0):
                before = watch.log.read_text().count("EVENT presence-renew-failed") if watch.log.exists() else 0
                watch.accept_presence("local", self.module.presence_roots(lambda: True))
                self.assertEqual(watch.log.read_text().count("EVENT presence-renew-failed")-before, expected_count)
            self.home.joinpath("missing").mkdir()
            watch.accept_presence("local", self.module.presence_roots(lambda: True))
            self.assertNotIn(str(self.home), watch.state["presence_failures"]["local"])
            self.home.joinpath("missing/hold").unlink()
            self.home.joinpath("missing").rmdir()
            watch.accept_presence("local", self.module.presence_roots(lambda: True))
            self.assertEqual(watch.log.read_text().count("EVENT presence-renew-failed"), 2)

    def test_probe_failure_denies_presence_and_keeps_delivery(self):
        self.settings["JARVIS_WAKE_SETTLE_SECS"] = "0"
        self.home.joinpath("kendex.settings.toml").write_text('[env]\nSLACK_JARVIS_SESSION_FILE = "hold"\n')
        original = self.module.run
        for error in (subprocess.TimeoutExpired("native-probe", 60), OSError("native-probe-unavailable")):
            def external(args, *positional, **keywords):
                if "live" in list(map(str, args)):
                    raise error
                return original(args, *positional, **keywords)
            with self.subTest(error=type(error).__name__), patch.dict(os.environ, self.env, clear=True), \
                    patch.object(self.module, "run", side_effect=external), contextlib.redirect_stdout(io.StringIO()):
                watch = self.watch()
                self.assertFalse(watch.live(0))
                watch.accept_presence("local", watch.presence("local"))
                self.assertFalse(self.home.joinpath("hold").exists())
                self.append(watch, "EVENT mail repo=peer file=to-lane\ndelivery after "+type(error).__name__+"\n")
                watch.tick(0, watch.acquire(0))
                self.assertIn("delivery after "+type(error).__name__, self.inbox()[-1]["text"])

    def test_log_checkpoint_skips_unchanged_and_processed_bytes(self):
        self.settings["JARVIS_WAKE_SETTLE_SECS"] = "0"
        with patch.dict(os.environ, self.env, clear=True), contextlib.redirect_stdout(io.StringIO()):
            watch = self.watch()
            watch.accept(watch.acquire(0))
            size = watch.log.stat().st_size
            watch.accept(watch.acquire(1))
            self.assertEqual(watch.log.stat().st_size, size)
            with watch.log.open("ab") as out:
                out.write(b'cursor: {"side":"consumer","roots":{}}\n' * 512)
            watch.batch(0)
            checkpoint = watch.state["offset"]
            watch = self.watch()
            self.append(watch, "EVENT mail repo=peer file=to-lane\nnew tail\n")
            original = Path.open
            starts = []
            class Observed:
                def __init__(self, stream):
                    self.stream = stream
                def __enter__(self):
                    return self
                def __exit__(self, *args):
                    return self.stream.__exit__(*args)
                def __getattr__(self, name):
                    return getattr(self.stream, name)
                def __iter__(self):
                    while True:
                        line = self.readline()
                        if not line:
                            return
                        yield line
                def read(self, *args):
                    starts.append(self.stream.tell())
                    return self.stream.read(*args)
                def readline(self, *args):
                    starts.append(self.stream.tell())
                    return self.stream.readline(*args)
            def opened(path, *args, **kwargs):
                stream = original(path, *args, **kwargs)
                return Observed(stream) if path == watch.log and args and args[0] == "rb" else stream
            with patch.object(Path, "open", opened), patch.object(Path, "read_bytes", side_effect=AssertionError("whole-log read")):
                watch.batch(1)
                for at in (2, 3, 4):
                    watch.batch(at)
                watch = self.watch()
            self.assertTrue(starts)
            self.assertGreaterEqual(min(starts), checkpoint)
            # Simulate append before the checkpoint write. Recovery reads
            # only the tail and still restores the authoritative cursor.
            with watch.log.open("a") as out:
                out.write('cursor: {"side":"host","roots":{"resumed":{"to-lane":{"count":7}}}}\n')
            restored = self.watch()
            self.assertEqual(restored.cursors["host"]["resumed"]["to-lane"]["count"], 7)

    def test_instrument_control(self):
        # This uncompiled source control stays in the instrument. A zeroed
        # settle must fail the same five-event behavioral assertion.
        with tempfile.TemporaryDirectory() as folder:
            source = (SCRIPTS / "lib/watch.py").read_text()
            old = 'now + int(self.settings["JARVIS_WAKE_SETTLE_SECS"])'
            self.assertEqual(source.count(old), 1)
            mutant = source.replace(old, "now")
            self.assertNotEqual(source, mutant)
            path = Path(folder) / "watch.py"
            path.write_text(mutant)
            self.module = load(path)
            with self.assertRaises(AssertionError):
                self.test_fixed_settle_and_five_event_feed()


if __name__ == "__main__":
    unittest.main()
