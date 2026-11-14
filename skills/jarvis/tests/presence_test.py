"""Real native hook writes, injected clock, and the existing inspector API."""
import contextlib
from concurrent.futures import ThreadPoolExecutor
import datetime
import io
import json
import os
from pathlib import Path
import shutil
import select
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from watch_test import load, BASH, REPO


class Presence(unittest.TestCase):
    def test_hook_activity_and_presence_failures(self):
        module = load()
        root = Path(os.environ["PRESENCE_ROOT"])
        transcript = os.environ["PRESENCE_TRANSCRIPT"]
        scratch = root.parent / "presence"
        scratch.mkdir()
        bins = scratch / "bin"
        bins.mkdir()
        clock = scratch / "clock"
        epoch = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
        clock.write_text(str(epoch))
        def at_stamp(after=0):
            # The native turn end stamps context.json's `at` with the system
            # clock and presence reads that stamp, so each moment here counts
            # from the stamp the last hook wrote: the clock stand-in, Jarvis's
            # own time and the holds', is moved AFTER seconds past it.
            row = json.loads((root / "tmp/lane-mail/overseer/context.json").read_text())
            now = int(datetime.datetime.fromisoformat(row["at"].replace("Z", "+00:00")).timestamp()) + after
            clock.write_text(str(now))
            return now
        real_date = shutil.which("date")
        def executable(name, body):
            path = bins / name
            path.write_text('#!/bin/sh\n' + body)
            path.chmod(0o755)
            return path
        executable("date", 'case "$*" in *+%s*) cat "$CLOCK";; *+%Y-%m-%dT%H:%M:%SZ*) '+
                   sys_python()+' -c \'import datetime,os; print(datetime.datetime.fromtimestamp(int(open(os.environ["CLOCK"]).read()),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))\';; *) exec '+real_date+' "$@";; esac\n')
        executable("kendex", 'printf "%s\\n" "$PRESENCE_ROOT"\n')
        # The session's harness: a planted process the fleet record names as
        # its harness identity, which agent-runtime's status read takes the
        # session's liveness from. A word written here sets what that read
        # meets: `gone` kills the harness, `exited` lets it exit; `unjudged`,
        # `unknown` and an empty word keep it running where `ps` cannot read
        # its start (an exit with words, a refusal, an empty answer), so the
        # read refuses `controller-unreadable`; any other word keeps a harness
        # running, a new one recorded where the last one ended.
        unreadable = scratch / "ps-unreadable"
        real_ps = shutil.which("ps")
        executable("ps", 'case "$*" in *lstart=*) case "$(cat "$PS_UNREADABLE")" in\n'
                   'unjudged) echo "ps: unjudged" >&2; exit 2;; unknown) echo "ps: unknown" >&2; exit 1;; empty) exit 0;;\n'
                   'esac;; esac\nexec '+real_ps+' "$@"\n')
        test = self
        class Harness:
            process = None
            def write_text(self, word):
                unreadable.write_text({"unjudged": "unjudged", "unknown": "unknown", "": "empty"}.get(word, "readable"))
                if word in ("gone", "exited"):
                    if self.process is not None and self.process.poll() is None:
                        self.process.kill() if word == "gone" else self.process.stdin.close()
                        self.process.wait()
                elif self.process is None or self.process.poll() is not None:
                    self.process = process = subprocess.Popen(["cat"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
                    test.addCleanup(lambda: (process.kill(), process.wait(), process.stdin.close()))
                    started = subprocess.run([real_ps, "-o", "lstart=", "-p", str(process.pid)], check=True, text=True,
                                             capture_output=True, env=dict(os.environ, LC_ALL="C", TZ="UTC")).stdout
                    subprocess.run([str(root / ".agents/skills/orch/scripts/workflow-state"), "update", "oversee",
                                    ".overseer.harness_pid = %s | .overseer.harness_start = %s"
                                    % (json.dumps(str(process.pid)), json.dumps("lstart:" + started.strip()))],
                                   cwd=root, env=os.environ, check=True, capture_output=True)
        state = Harness()
        state.write_text("idle")
        remote = scratch / "remote"
        remote.mkdir()
        subprocess.run(["git", "init", "-q", str(remote)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(remote), "config", "gc.auto", "0"], check=True)
        subprocess.run(["git", "-C", str(remote), "config", "maintenance.auto", "false"], check=True)
        remote_hold = remote / "hold"
        local_slack = root / ".agents/skills/slack"
        local_slack.mkdir(parents=True, exist_ok=True)
        if not local_slack.joinpath("scripts").exists():
            local_slack.joinpath("scripts").symlink_to(REPO / "skills/slack/scripts", target_is_directory=True)
        remote.joinpath("kendex.settings.toml").write_text('[env]\nSLACK_JARVIS_SESSION_FILE = "hold"\n')
        failure = scratch / "fail-host"
        executable("ssh", 'if [ -n "${TRANSPORT_READY:-}" ]; then\nprintf ready > "$TRANSPORT_READY"\nread -r ack < "$TRANSPORT_RELEASE"\nfi\n[ ! -f "$FAIL_HOST" ] || exit 1\ncd "$REMOTE_ROOT" || exit\nPRESENCE_ROOT=$REMOTE_ROOT; export PRESENCE_ROOT\nexec '+BASH+' -s\n')
        root.joinpath("kendex.settings.toml").write_text('[env]\nSLACK_JARVIS_SESSION_FILE = "hold"\n')
        env = dict(os.environ, PATH=str(bins)+os.pathsep+os.environ["PATH"], CLOCK=str(clock),
                   PS_UNREADABLE=str(unreadable),
                   FAIL_HOST=str(failure), REMOTE_ROOT=str(remote))
        settings = dict(JARVIS_LOG_DIR=str(scratch / "log"), JARVIS_CONTROL_HOST="host", JARVIS_MAIN_HOST="",
                        JARVIS_WAKE_SETTLE_SECS="0")
        with patch.dict(os.environ, env, clear=True), contextlib.redirect_stdout(io.StringIO()):
            watch = module.Watch(root, BASH, settings)
            def renew():
                for side in ("local", "host"):
                    watch.accept_presence(side, watch.presence(side))
            def hook(name, extra=None):
                payload = dict(session_id="s1", transcript_path=transcript, cwd=str(root),
                               source="startup", model="claude-opus-5-5", tool_name="Bash",
                               tool_input={"command":"git status"}, stop_hook_active=False)
                payload.update(extra or {})
                result = subprocess.run([BASH, str(root / ".claude/hooks" / name)],
                                        input=json.dumps(payload), text=True, cwd=root, env=os.environ,
                                        capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
            hook("session-start-row.sh")
            context = root / "tmp/lane-mail/overseer/context.json"
            hook("lane-mail-deliver.sh")
            installed = root / ".agents/skills/orch"
            saved = scratch / "target-orch"
            installed.rename(saved)
            try:
                for target_code in ("absent", "refusing"):
                    if target_code == "refusing":
                        for file in ("lib/lane-context.sh", "lib/overseer-launch.sh", "workflow-state", "overseer-host"):
                            path = installed / "scripts" / file
                            path.parent.mkdir(parents=True, exist_ok=True)
                            path.write_text("exit 93\n")
                            path.chmod(0o755)
                    epoch = at_stamp()
                    self.assertTrue(watch.live(epoch))
                    renew()
                    for hold in (root / "hold", remote_hold):
                        self.assertEqual(hold.stat().st_mtime, epoch)
            finally:
                if installed.exists():
                    shutil.rmtree(installed)
                saved.rename(installed)
            # Tools and turn ends alternate. The existing hook is the only
            # writer of context activity; the producer alone touches holds.
            for index, (elapsed, observed) in enumerate(((0, "idle"), (120, "idle"),
                                                        (240, "rate-limit-switch"),
                                                        (360, "idle"), (480, "idle"))):
                state.write_text(observed)
                hook("lane-mail-deliver.sh" if index % 2 == 0 else "lane-mail-check.sh")
                # Each row's moment, epoch + elapsed, is the stamp its hook wrote.
                epoch = at_stamp() - elapsed
                row = json.loads(context.read_text())
                self.assertEqual(row["session_id"], "s1")
                self.assertEqual(row["pane_key"], os.environ["TMUX_SERVER_ID"] + " " + os.environ["TMUX_PANE"])
                self.assertTrue(watch.live(epoch+elapsed), row)
                for hold in (root / "hold", remote_hold):
                    if hold.exists():
                        os.utime(hold, (1, 1))
                renew()
                for hold in (root / "hold", remote_hold):
                    self.assertLess(epoch + elapsed - hold.stat().st_mtime, 120)
                    self.assertEqual(hold.stat().st_mtime, epoch + elapsed)
                module.checked([root / ".agents/skills/mailbox/scripts/lane-mail", "inbox", "--item", "overseer"], root)
            def no_renew(at):
                for hold in (root / "hold", remote_hold):
                    os.utime(hold, (1, 1))
                clock.write_text(str(at))
                renew()
                for hold in (root / "hold", remote_hold):
                    self.assertEqual(hold.stat().st_mtime, 1)
                module.checked([root / ".agents/skills/mailbox/scripts/lane-mail", "inbox", "--item", "overseer"], root)
            # Stale context never borrows an unproved native idle route.
            self.assertFalse(watch.live(epoch+780))
            no_renew(epoch+780)
            for change in ({"pane_key":"different pane"}, {"session_id":"predecessor"}):
                altered = dict(row, **change)
                context.write_text(json.dumps(altered))
                self.assertFalse(watch.live(epoch+480))
                no_renew(epoch+480)
            context.write_text(json.dumps(row))
            for observed in ("gone", "exited", "unjudged", "unknown", ""):
                state.write_text("idle")
                state.write_text(observed)
                self.assertFalse(watch.live(epoch+480), observed)
                no_renew(epoch+480)
            state.write_text("idle")
            workflow = root / ".agents/skills/orch/scripts/workflow-state"
            subprocess.run([str(workflow), "update", "oversee", '.overseer.session_id = null'],
                           cwd=root, env=os.environ, check=True, capture_output=True)
            self.assertFalse(watch.live(epoch+480))
            no_renew(epoch+480)
            subprocess.run([str(workflow), "update", "oversee", '.overseer.session_id = "s1"'],
                           cwd=root, env=os.environ, check=True, capture_output=True)
            def warnings():
                # Delivered warnings leave the input log; the mailbox owns their receipts.
                _, rows = module.mailbox_events(BASH, root, "to-lane")
                bodies = [row["text"] for row in rows] + [watch.log.read_text()]
                return [line.split(" cause=", 1)[0] for body in bodies for line in body.splitlines()
                        if line.startswith("EVENT presence-renew-failed ")]
            warning = "EVENT presence-renew-failed repo=ssh:host side=ssh:host"
            failure.touch()
            for elapsed in (600, 601, 720, 721):
                hook("lane-mail-deliver.sh")
                epoch = at_stamp() - elapsed
                if elapsed % 120 == 0:
                    renew()
                watch.tick(epoch+elapsed, watch.acquire(epoch+elapsed))
                module.checked([root / ".agents/skills/mailbox/scripts/lane-mail", "inbox", "--item", "overseer"], root)
            self.assertEqual(warnings(), [warning])
            failure.unlink()
            # A successful ordinary mail poll cannot confirm a hold renewal.
            watch.tick(epoch+722, watch.acquire(epoch+722))
            self.assertTrue(watch.state["presence_failures"]["ssh:host"])
            watch = module.Watch(root, BASH, settings)
            failure.touch()
            clock.write_text(str(epoch+723))
            renew()
            self.assertEqual(warnings(), [warning])
            failure.unlink()
            hook("lane-mail-deliver.sh")
            epoch = at_stamp() - 840
            renew()
            module.checked([root / ".agents/skills/mailbox/scripts/lane-mail", "inbox", "--item", "overseer"], root)
            failure.touch()
            hook("lane-mail-deliver.sh")
            # The clock stands 299 s past this stamp, inside presence's 300 s,
            # so the transport rows' own hook calls below, stamped later, are
            # read live at it too.
            epoch = at_stamp(299) - 960
            renew()
            self.assertEqual(warnings(), [warning, warning])
            failure.unlink()
            # A session can end during transport, before any host permission
            # request. Both a failed and a successful transport must skip.
            ready, release = scratch / "transport-ready", scratch / "transport-release"
            os.mkfifo(ready)
            os.mkfifo(release)
            for transport_fails in (False, True):
                state.write_text("idle")
                hook("lane-mail-deliver.sh")
                before = remote_hold.stat().st_mtime
                if transport_fails:
                    failure.touch()
                read_fd = os.open(ready, os.O_RDONLY | os.O_NONBLOCK)
                release_fd = os.open(release, os.O_RDWR | os.O_NONBLOCK)
                try:
                    with patch.dict(os.environ, TRANSPORT_READY=str(ready), TRANSPORT_RELEASE=str(release)), \
                            ThreadPoolExecutor(max_workers=1) as work:
                        pending = work.submit(watch.presence, "host")
                        try:
                            self.assertTrue(select.select([read_fd], [], [], 30)[0])
                            self.assertEqual(os.read(read_fd, 5), b"ready")
                            state.write_text("gone")
                        finally:
                            os.write(release_fd, b"ack\n")
                        results = pending.result(timeout=30)
                    self.assertTrue(all(status == "skipped" for _, status, _ in results), results)
                    watch.accept_presence("host", results)
                    self.assertEqual(remote_hold.stat().st_mtime, before)
                    self.assertEqual(warnings(), [warning, warning])
                finally:
                    os.close(read_fd)
                    os.close(release_fd)
                    if failure.exists():
                        failure.unlink()
            state.write_text("idle")
            # Block the real mailbox events command after its start
            # acknowledgement. Presence must keep running in the same owner.
            ready, release = scratch / "ready", scratch / "release"
            os.mkfifo(ready)
            os.mkfifo(release)
            blocked = False
            original_run = module.run
            def mailbox_run(args, *positional, **keywords):
                nonlocal blocked
                if not blocked and list(map(str, args[:3])) == [BASH, str(REPO / "skills/mailbox/scripts/lane-mail"), "events"]:
                    blocked = True
                    with ready.open("w") as out:
                        out.write("ready")
                    with release.open() as incoming:
                        self.assertEqual(incoming.readline(), "ack\n")
                return original_run(args, *positional, **keywords)
            watch.cursors = {}
            watch.state["cursors"] = watch.cursors
            watch.next_presence = {}
            read_fd = os.open(ready, os.O_RDONLY | os.O_NONBLOCK)
            with patch.object(module, "run", side_effect=mailbox_run), ThreadPoolExecutor(max_workers=3) as passes:
                pending = passes.submit(watch.acquire, epoch+1080)
                try:
                    self.assertTrue(select.select([read_fd], [], [], 30)[0])
                    self.assertEqual(os.read(read_fd, 5), b"ready")
                    # Each renewal 120 s after the last, each inside the
                    # 300 s its own hook's stamp holds presence for.
                    for elapsed in (1200, 1320, 1440):
                        hook("lane-mail-deliver.sh")
                        epoch = at_stamp(elapsed - 1200) - elapsed
                        pending = watch._poll(passes, pending, epoch+elapsed)
                        for work in list(watch.presence_pending.values()):
                            work.result(timeout=30)
                        pending = watch._poll(passes, pending, epoch+elapsed)
                        self.assertFalse(pending.done())
                        for hold in (root / "hold", remote_hold):
                            self.assertEqual(hold.stat().st_mtime, epoch+elapsed)
                        module.checked([root / ".agents/skills/mailbox/scripts/lane-mail", "inbox", "--item", "overseer"], root)
                    state.write_text("gone")
                    clock.write_text(str(epoch+1560))
                    pending = watch._poll(passes, pending, epoch+1560)
                    for work in list(watch.presence_pending.values()):
                        work.result(timeout=30)
                    pending = watch._poll(passes, pending, epoch+1560)
                    for hold in (root / "hold", remote_hold):
                        self.assertEqual(hold.stat().st_mtime, epoch+1440)
                finally:
                    with release.open("w") as out:
                        out.write("ack\n")
                    os.close(read_fd)
                watch.tick(epoch+1560, pending.result(timeout=30))
                for hold in (root / "hold", remote_hold):
                    self.assertEqual(hold.stat().st_mtime, epoch+1440)

    def test_instrument_control(self):
        module = load()
        source_path = REPO / "skills/jarvis/scripts/lib/watch.py"
        source = source_path.read_text()
        old = "return 0 <= now - at < 300"
        self.assertEqual(source.count(old), 1)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "watch.py"
            path.write_text(source.replace(old, "return False"))
            # Keep the private adapter at its real location. The mutation is
            # loaded only by this instrument and grants no production option.
            mutant = load(path)
            mutant.LIB = module.LIB
            with patch(__name__ + ".load", return_value=mutant), self.assertRaisesRegex(AssertionError, "False is not true"):
                # A separate scratch instance owns the complete world.
                original = os.environ["PRESENCE_ROOT"]
                clone = Path(folder) / "project"
                shutil.copytree(original, clone, symlinks=True)
                with patch.dict(os.environ, PRESENCE_ROOT=str(clone)):
                    self.test_hook_activity_and_presence_failures()


def sys_python():
    import shlex
    import sys
    return shlex.quote(sys.executable)


if __name__ == "__main__":
    unittest.main()
