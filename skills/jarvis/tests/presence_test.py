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
        epoch = 1800000000
        clock.write_text(str(epoch))
        real_date = shutil.which("date")
        def executable(name, body):
            path = bins / name
            path.write_text('#!/bin/sh\n' + body)
            path.chmod(0o755)
            return path
        executable("date", 'case "$*" in *+%s*) cat "$CLOCK";; *+%Y-%m-%dT%H:%M:%SZ*) '+
                   sys_python()+' -c \'import datetime,os; print(datetime.datetime.fromtimestamp(int(open(os.environ["CLOCK"]).read()),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))\';; *) exec '+real_date+' "$@";; esac\n')
        executable("kendex", 'printf "%s\\n" "$PRESENCE_ROOT"\n')
        state = scratch / "inspect"
        state.write_text("idle")
        inspector = executable("inspector", 'printf "session=%s window=@7 server=%s server_start=%s state=%s\\n" "$TMUX_PANE" "$TMUX_SERVER_ID" "$TMUX_SERVER_START" "$(cat "$INSPECT_STATE")"\n')
        remote = scratch / "remote"
        remote.mkdir()
        subprocess.run(["git", "init", "-q", str(remote)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(remote), "config", "gc.auto", "0"], check=True)
        subprocess.run(["git", "-C", str(remote), "config", "maintenance.auto", "false"], check=True)
        for name in ("mailbox", "orch"):
            path = remote / ".agents/skills" / name
            path.mkdir(parents=True)
            path.joinpath("scripts").symlink_to(REPO / "skills" / name / "scripts", target_is_directory=True)
        remote_hold = remote / "hold"
        local_slack = root / ".agents/skills/slack"
        local_slack.mkdir(parents=True, exist_ok=True)
        if not local_slack.joinpath("scripts").exists():
            local_slack.joinpath("scripts").symlink_to(REPO / "skills/slack/scripts", target_is_directory=True)
        remote_slack = remote / ".agents/skills/slack"
        remote_slack.mkdir(parents=True)
        remote_slack.joinpath("scripts").symlink_to(REPO / "skills/slack/scripts", target_is_directory=True)
        remote.joinpath("kendex.settings.toml").write_text('[env]\nSLACK_JARVIS_SESSION_FILE = "hold"\n')
        failure = scratch / "fail-host"
        executable("ssh", '[ ! -f "$FAIL_HOST" ] || exit 1\ncd "$REMOTE_ROOT" || exit\nPRESENCE_ROOT=$REMOTE_ROOT; export PRESENCE_ROOT\nexec '+BASH+' -s\n')
        root.joinpath("kendex.settings.toml").write_text('[env]\nSLACK_JARVIS_SESSION_FILE = "hold"\n')
        env = dict(os.environ, PATH=str(bins)+os.pathsep+os.environ["PATH"], CLOCK=str(clock),
                   INSPECT_STATE=str(state), ORCH_OVERSEER_HOST=str(inspector),
                   FAIL_HOST=str(failure), REMOTE_ROOT=str(remote))
        settings = dict(JARVIS_LOG_DIR=str(scratch / "log"), JARVIS_CONTROL_HOST="host", JARVIS_WAKE_SETTLE_SECS="0")
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
            # Tools and turn ends alternate. The existing hook is the only
            # writer of context activity; the producer alone touches holds.
            for index, elapsed in enumerate((0, 120, 240, 360, 480)):
                clock.write_text(str(epoch+elapsed))
                hook("lane-mail-deliver.sh" if index % 2 == 0 else "lane-mail-check.sh")
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
            state.write_text("gone")
            self.assertFalse(watch.live(epoch+480))
            no_renew(epoch+480)
            state.write_text("idle")
            workflow = root / ".agents/skills/orch/scripts/workflow-state"
            subprocess.run([str(workflow), "update", "oversee", '.overseer.session_id = null'],
                           cwd=root, env=os.environ, check=True, capture_output=True)
            self.assertFalse(watch.live(epoch+480))
            no_renew(epoch+480)
            subprocess.run([str(workflow), "update", "oversee", '.overseer.session_id = "s1"'],
                           cwd=root, env=os.environ, check=True, capture_output=True)
            failure.touch()
            for elapsed in (600, 601, 720, 721):
                clock.write_text(str(epoch+elapsed))
                hook("lane-mail-deliver.sh")
                if elapsed % 120 == 0:
                    renew()
                watch.tick(epoch+elapsed, watch.acquire(epoch+elapsed))
                module.checked([root / ".agents/skills/mailbox/scripts/lane-mail", "inbox", "--item", "overseer"], root)
            self.assertEqual(watch.log.read_text().count("EVENT presence-renew-failed"), 1)
            failure.unlink()
            # A successful ordinary mail poll cannot confirm a hold renewal.
            watch.tick(epoch+722, watch.acquire(epoch+722))
            self.assertTrue(watch.state["presence_failures"]["host"])
            watch = module.Watch(root, BASH, settings)
            failure.touch()
            clock.write_text(str(epoch+723))
            renew()
            self.assertEqual(watch.log.read_text().count("EVENT presence-renew-failed"), 1)
            failure.unlink()
            clock.write_text(str(epoch+840))
            hook("lane-mail-deliver.sh")
            renew()
            module.checked([root / ".agents/skills/mailbox/scripts/lane-mail", "inbox", "--item", "overseer"], root)
            failure.touch()
            clock.write_text(str(epoch+960))
            hook("lane-mail-deliver.sh")
            renew()
            self.assertEqual(watch.log.read_text().count("EVENT presence-renew-failed"), 2)
            failure.unlink()
            # Block the real mailbox events command after its start
            # acknowledgement. Presence must keep running in the same owner.
            installed = root / ".agents/skills/mailbox/scripts"
            installed.unlink()
            installed.mkdir()
            installed.joinpath("lib").symlink_to(REPO / "skills/mailbox/scripts/lib", target_is_directory=True)
            ready, release = scratch / "ready", scratch / "release"
            os.mkfifo(ready)
            os.mkfifo(release)
            once = scratch / "blocked-once"
            import shlex
            script = installed / "lane-mail"
            script.write_text('#!/bin/sh\nif [ "$1" = events ] && [ ! -e '+shlex.quote(str(once))+' ]; then\n'+
                              'touch '+shlex.quote(str(once))+'\nprintf ready > '+shlex.quote(str(ready))+'\n'+
                              'read -r ack < '+shlex.quote(str(release))+'\nfi\nexec '+
                              shlex.quote(str(REPO / "skills/mailbox/scripts/lane-mail"))+' "$@"\n')
            script.chmod(0o755)
            watch.cursors = {}
            watch.state["cursors"] = watch.cursors
            watch.next_presence = {}
            read_fd = os.open(ready, os.O_RDONLY | os.O_NONBLOCK)
            with ThreadPoolExecutor(max_workers=3) as passes:
                pending = passes.submit(watch.acquire, epoch+1080)
                try:
                    self.assertTrue(select.select([read_fd], [], [], 30)[0])
                    self.assertEqual(os.read(read_fd, 5), b"ready")
                    for elapsed in (1080, 1200, 1320, 1440):
                        clock.write_text(str(epoch+elapsed))
                        hook("lane-mail-deliver.sh")
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
