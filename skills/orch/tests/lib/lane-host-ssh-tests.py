"""Run the provider's remote commands in local repositories through an SSH stub.

One must-fail control per verb that has one: create, cat, put, append, stop,
close, and list, which reads the inventory every verb reads first.
"""
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import tarfile
import time
import unittest

PACKAGE = Path(__file__).resolve().parents[2]


class SshHostTests(unittest.TestCase):
    def setUp(self):
        scratch = Path.cwd() / "tmp"
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("LANE_HOST_", "SSH_TEST_", "WORKTREE_", "BOT_", "KENDEX_"))}
        self.env.update(REAL_GIT=shutil.which("git"), REAL_CHMOD=shutil.which("chmod"),
                        REAL_PYTHON=sys.executable, SSH_TEST_SOURCE=str(self.source),
                        SSH_TEST_LOG=str(self.root / "calls"), FLEET_DIR=str(self.root / "fleet"),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.executable(self.bin / "ssh", '''#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$SSH_TEST_LOG"
[[ "${SSH_TEST_FAIL:-0}" == 0 ]] || exit "$SSH_TEST_FAIL"
tty_off=false
for arg in "$@"; do
  if [[ "$arg" == -T ]]; then tty_off=true; fi
done
if [[ -n "${SSH_TEST_CUT:-}" ]]; then
  head -c "$SSH_TEST_CUT" | bash -c "${!#}"
  exit
fi
if [[ "${SSH_TEST_REQUEST_TTY:-}" == force && "$tty_off" == false ]]; then
  bash -c "${!#}" | "$REAL_PYTHON" -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().replace(b"\\n", b"\\r\\n"))'
  exit
fi
exec bash -c "${!#}"
''')
        self.executable(self.bin / "git", '''#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == clone ]]; then
  [[ "$3" != https://github.com/* ]] || exit 17
  exec "$REAL_GIT" clone -- "$SSH_TEST_SOURCE" "${!#}"
fi
exec "$REAL_GIT" "$@"
''')
        self.executable(self.bin / "chmod", '''#!/usr/bin/env bash
if [[ "${SSH_TEST_BSD_CHMOD:-0}" == 1 && "${2:-}" == -- ]]; then exit 97; fi
exec "$REAL_CHMOD" "$@"
''')
        self.executable(self.bin / "kendex", '''#!/usr/bin/env bash
printf 'kendex %s\\n' "$*" >> "$SSH_TEST_LOG"
if [[ "$1" == generated-paths ]]; then
  [[ "${SSH_TEST_GENERATED_PATHS_STATUS:-0}" == 0 ]] || exit "$SSH_TEST_GENERATED_PATHS_STATUS"
  printf '%s\\n' "${SSH_TEST_GENERATED_PATHS:-[]}"
  exit 0
fi
''')
        self.executable(self.bin / "gh", '''#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == repo && "$2" == clone ]]; then
  printf 'gh %s\\n' "$*" >> "$SSH_TEST_LOG"
  [[ "$#" == 4 && "$3" == owner/repo && "${SSH_TEST_GIT_PROTOCOL:-ssh}" == ssh ]] || exit 9
  [[ "${SSH_TEST_CLONE_FAIL:-0}" == 0 ]] || exit "$SSH_TEST_CLONE_FAIL"
  exec "$REAL_GIT" clone -- "$SSH_TEST_SOURCE" "$4"
fi
if [[ "$1" == repo && "$2" == view ]]; then
  [[ "$4" == --json && "$5" == nameWithOwner && "$6" == --jq && "$7" == .nameWithOwner ]] || exit 9
  if [[ "$3" == "$SSH_TEST_SOURCE" ]]; then printf '%s\\n' "${SSH_TEST_REPO_NAME:-owner/repo}"; else printf 'other/repo\\n'; fi
fi
''')
        wt = self.source / ".agents/skills/worktree/scripts/worktree"
        self.executable(wt, '''#!/usr/bin/env bash
set -euo pipefail
printf 'worktree %s\\n' "$*" >> "$SSH_TEST_LOG"
path="$PWD-worktree"
case "$1" in
create)
  if [[ -d "$path" ]]; then [[ " $* " == *" --reuse "* ]] || exit 75
  else
    [[ " $* " != *" --reuse "* ]] || exit 1
    git worktree add --detach "$path" >&2
  fi
  printf '%s\\n' "$path" ;;
exists) if [[ -d "$path" ]]; then printf 'true\\n'; else printf 'false\\n'; fi ;;
# An item's path is the hosted tree while it stands, and once it is gone the
# issue-keyed configured path, under a base dir no create made, as the real
# command answers; --hosted is the one lane path every create uses.
path)
  if [[ "$2" == --hosted || -d "$path" ]]; then printf '%s\\n' "$path"
  else printf '%s\\n' "$PWD-trees/$2"; fi ;;
remove)
  if [[ -n "${SSH_TEST_CLOSE_STDOUT:-}" ]]; then
    printf 'before-delete:%s\\n' "$(cat -- "$SSH_TEST_CLOSE_STDOUT")" >> "$SSH_TEST_LOG"
  fi
  git worktree remove --force "$path" ;;
esac
''')
        scripts = self.source / ".agents/skills/orch/scripts"
        scripts.mkdir(parents=True)
        for name in ("resolve-base-branch", "sync-base", "lane-marker"):
            shutil.copy2(PACKAGE / "scripts" / name, scripts / name)
        # append takes its lock through the clone's own installed lock library.
        shutil.copytree(PACKAGE / "scripts/lib", scripts / "lib")
        self.executable(self.source / ".agents/skills/github/scripts/git-https-auth", '''#!/usr/bin/env bash
exec git "$@"
''')
        (self.source / ".kendex-generated.json").write_text('[\n  ".agents/skills/orch/scripts/lane-marker"\n]\n')
        (self.source / ".gitignore").write_text(".env.local\n.cache/\ntmp/\n")
        (self.source / "kendex.toml").write_text("")
        for args in (("init", "-q"), ("add", "."), ("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "seed")):
            subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), *args], check=True, capture_output=True)
        (self.source / ".env.local").write_bytes(b"SECRET=private-fixture\n")
        cache = self.source / ".cache/linear"
        cache.mkdir(parents=True)
        (cache / "issues.json").write_text('{"cached":true}')
        (cache / "sync.lock").write_text("local lock")
        machine_half = self.source / ".cache/kendex/lock-local.json"
        machine_half.parent.mkdir(parents=True)
        machine_half.write_text("this host's half of the install record")
        self.account = self.root / "local account"
        self.account.mkdir()
        (self.account / "setup-token").write_text("claude-secret-fixture")
        (self.account / "auth.json").write_bytes(b'{"seed":"private"}\n')
        self.row = dict(repo="owner/repo", item="TEST-1", target="lane.example",
                        clone=str(self.root / "remote clone's"), account=str(self.root / "remote account's"))
        self.inventory = self.root / "inventory.json"
        self.inventory.write_text(json.dumps([self.row]))
        self.env.update(LANE_HOST_SSH_INVENTORY=str(self.inventory), LANE_HOST_SSH_SOURCE=str(self.source))
        self.script = self.root / "lane-host-ssh"
        shutil.copy2(PACKAGE / "scripts/lane-host-ssh", self.script)

    def executable(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def call(self, *args, data=b"", **env):
        return subprocess.run([str(self.script), *args], cwd=self.root, env={**self.env, **env}, input=data, capture_output=True)

    def create(self, *args, harness="claude", **env):
        return self.call("create", "--item", "TEST-1", "--repo", "owner/repo", "--harness", harness,
                         "--account", str(self.account), *args, **env)

    def seed_source(self, relative, text):
        """Track one more render in the fixture origin, before any clone of it."""
        path = self.source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        for args in (("add", "--", relative),
                     ("-c", "user.name=Test", "-c", "user.email=test@example.org",
                      "commit", "-qm", "seed render")):
            subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), *args],
                           check=True, capture_output=True)

    def test_prepare_reuse_and_account_protocol(self):
        first = self.create()
        self.assertEqual(first.returncode, 0, first.stderr)
        clone = Path(self.row["clone"])
        self.assertEqual((clone / ".env.local").read_bytes(), (self.source / ".env.local").read_bytes())
        self.assertEqual((clone / ".cache/linear/issues.json").read_text(), '{"cached":true}')
        self.assertFalse((clone / ".cache/linear/sync.lock").exists())
        self.assertFalse((clone / ".cache/kendex/lock-local.json").exists())
        calls = (self.root / "calls").read_text()
        self.assertNotIn("claude-secret-fixture", calls)
        self.assertNotIn("private-fixture", calls)
        self.assertNotIn(b"CLAUDE_CONFIG_DIR", first.stdout)
        fields = dict(word.split("=", 1) for word in first.stdout.decode().strip().split("\t"))
        self.assertEqual(fields["ssh-target"], "lane.example")
        self.assertEqual(fields["path"], self.row["clone"] + "-worktree")
        self.assertEqual(self.create().returncode, 75)
        (clone / ".git/lane-host-item").write_text("OTHER-1\n")
        self.assertEqual(self.create("--reuse").returncode, 75)
        (clone / ".git/lane-host-item").write_text("TEST-1\n")
        for flag in ("--reuse", "--relaunch"):
            with self.subTest(flag=flag):
                again = self.create(flag)
                self.assertEqual((again.returncode, again.stdout), (0, first.stdout), again.stderr)
        (clone / ".cache/linear/issues.json").write_text("remote-cache")
        result = self.create("--reuse", harness="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"CODEX_HOME", result.stdout)
        self.assertEqual((Path(self.row["account"]) / "auth.json").read_bytes(), (self.account / "auth.json").read_bytes())
        self.assertEqual((clone / ".cache/linear/issues.json").read_text(), "remote-cache")
        result = self.create("--reuse", harness="pi")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"PI_CODING_AGENT_DIR", result.stdout)
        # The tree carries the render its base branch commits and the host
        # carries the Pi packages, so no create, fresh or reused, runs either.
        verbs = {line.split()[1] for line in (self.root / "calls").read_text().splitlines()
                 if line.startswith("kendex ")}
        self.assertEqual(verbs & {"refresh", "update-pi"}, set())

    def test_create_places_per_harness_pre_approval(self):
        """The overseer's trust file lands where each harness reads it; Claude's merges."""
        seed = b'{"userID": "kept", "projects": {"/c": {"allowedTools": ["Bash"], "hasTrustDialogAccepted": false}}}'
        merged = {"userID": "kept", "hasCompletedOnboarding": True, "projects": {"/c": {"allowedTools": ["Bash"], "hasTrustDialogAccepted": True}}}
        rows = (("claude", ".claude.json", self.root / ".claude.json", b'{"hasCompletedOnboarding": true, "projects": {"/c": {"hasTrustDialogAccepted": true}}}', json.loads, merged),
                ("codex", "config.toml", Path(self.row["account"]) / "config.toml", b'[projects."/c"]\ntrust_level = "trusted"\n', bytes, None),
                ("pi", "trust.json", Path(self.row["account"]) / "trust.json", b'{"/c": true}\n', bytes, None))
        (self.account / "lane-host").mkdir()
        (self.account / "lane-host/.claude.json").write_bytes(rows[0][3])
        fresh = self.create("--reuse")
        self.assertEqual(fresh.returncode, 0, fresh.stderr)
        self.assertEqual(json.loads((self.root / ".claude.json").read_bytes()), json.loads(rows[0][3]))
        (self.root / ".claude.json").write_bytes(seed)
        for harness, name, landed, data, parse, expected in rows:
            with self.subTest(harness=harness):
                (self.account / "lane-host" / name).write_bytes(data)
                result = self.create("--reuse", harness=harness)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(parse(landed.read_bytes()), expected or data)

    def worktree_root(self):
        return Path(subprocess.run([self.env["REAL_GIT"], "-C", self.row["clone"] + "-worktree",
                                    "rev-parse", "--show-toplevel"],
                                   check=True, capture_output=True).stdout.decode().strip())

    def test_create_marks_the_lane_for_its_mail_hook(self):
        self.assertEqual(self.create().returncode, 0)
        root = subprocess.run([self.env["REAL_GIT"], "-C", self.row["clone"] + "-worktree", "rev-parse", "--show-toplevel"],
                              check=True, capture_output=True).stdout
        self.assertEqual((Path(self.row["clone"]) / ".git/lane-mail/test-1").read_bytes(), root)
        # The lane's own mailbox directory, in the item's own spelling: the
        # turn-end hook resolves the item by it, so a lane nobody has messaged
        # is still judged on its handoff marks.
        self.assertTrue((self.worktree_root() / "tmp/lane-mail/TEST-1").is_dir())

    def test_create_marks_a_worktree_whose_tmp_is_a_symlink(self):
        # skills/worktree's WORKTREE_SYMLINKS makes this shape, and lane-mail
        # has always read a mailbox through it. The remote step is the owner's,
        # so the launch follows the owner's containment and not one of its own.
        self.assertEqual(self.create().returncode, 0)
        worktree = self.worktree_root()
        shutil.rmtree(worktree / "tmp")
        scratch = self.root / "linked-scratch"
        scratch.mkdir()
        (worktree / "tmp").symlink_to(scratch)
        (Path(self.row["clone"]) / ".git/lane-mail/test-1").unlink()
        self.assertEqual(self.create("--reuse").returncode, 0)
        self.assertTrue((Path(self.row["clone"]) / ".git/lane-mail/test-1").is_file())
        self.assertTrue((scratch / "lane-mail/TEST-1").is_dir())

    def test_create_names_a_clone_without_the_marker_writer(self):
        # The sync-base step guards its own exec; this one does too, because by
        # here create has made the worktree and written .git/lane-host-item, so
        # bash's 127 would leave a half-created lane with nothing naming what
        # the clone is missing.
        self.assertEqual(self.create().returncode, 0)
        marker = Path(self.row["clone"]) / ".agents/skills/orch/scripts/lane-marker"
        # The mode is what the step tests, and the sync-base step above it
        # refuses a tracked change, so the clone is told to ignore the bit.
        subprocess.run([self.env["REAL_GIT"], "-C", self.row["clone"], "config", "core.fileMode", "false"], check=True)
        marker.chmod(0o644)
        (Path(self.row["clone"]) / ".git/lane-mail/test-1").unlink()
        refused = self.create("--reuse")
        self.assertEqual(refused.returncode, 1, refused.stderr)
        self.assertIn(f"lane-host-ssh: marker-script-missing path={marker}\n".encode(), refused.stderr)
        self.assertFalse((Path(self.row["clone"]) / ".git/lane-mail/test-1").exists())

    def test_control_lane_mail_marker(self):
        original = self.script.read_text()
        fragment = 'exec "$marker" "$2" "$3"'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, 'true'))
        self.assertEqual(self.create().returncode, 0)
        self.assertFalse((Path(self.row["clone"]) / ".git/lane-mail/test-1").exists())
        self.assertFalse((self.worktree_root() / "tmp/lane-mail/TEST-1").exists())

    def test_put_never_writes_through_a_planted_staging_link(self):
        # The wrapper plants a link at the staging name a PID would give, then
        # execs the real bash, which keeps that PID for the remote script.
        target = self.root / "lane/tmp/lane-mail/TEST-1/to-lane.jsonl"
        target.parent.mkdir(parents=True)
        outside = self.root / "outside"
        outside.write_text("outside\n")
        wrap = self.root / "wrap"
        self.executable(wrap / "bash", '#!/bin/sh\n[ -z "$SSH_TEST_PLANT" ] || ln -s "$SSH_TEST_PLANT_TARGET" "$SSH_TEST_PLANT.kendex-put.$$" 2>/dev/null\nexec "$REAL_BASH" "$@"\n')
        put = self.call("put", "--item", "TEST-1", str(target), data=b"mail\n", PATH=str(wrap) + os.pathsep + self.env["PATH"],
                        REAL_BASH=shutil.which("bash"), SSH_TEST_PLANT=str(target), SSH_TEST_PLANT_TARGET=str(outside))
        self.assertEqual((put.returncode, outside.read_text(), target.read_bytes()), (0, "outside\n", b"mail\n"), put.stderr)

    def test_create_refuses_a_linked_marker(self):
        self.assertEqual(self.create().returncode, 0)
        marker = Path(self.row["clone"]) / ".git/lane-mail/test-1"
        target = self.root / "marker-target"
        marker.unlink()
        marker.symlink_to(target)
        refused = self.create("--reuse")
        # lane-marker owns the containment and the status: 2 is its refusal,
        # and remote() carries that status out rather than flattening it.
        self.assertEqual(refused.returncode, 2, refused.stderr)
        self.assertIn(f"lane-marker: unsafe={marker}\n".encode(), refused.stderr)
        self.assertNotIn(b"path=", refused.stdout)
        self.assertFalse(target.exists())

    def test_mailbox_paths_refuse_a_linked_component(self):
        box = self.root / "lane/tmp/lane-mail/TEST-1"
        away = self.root / "away"
        away.mkdir()
        (away / "to-lane.jsonl").write_text("elsewhere\n")
        box.parent.mkdir(parents=True)
        box.symlink_to(away)
        target = str(box / "to-lane.jsonl")
        for verb, data in (("cat", b""), ("put", b"new\n")):
            with self.subTest(verb=verb):
                refused = self.call(verb, "--item", "TEST-1", target, data=data)
                self.assertEqual(refused.returncode, 3, refused.stderr)
                self.assertIn(f"lane-host-ssh: mailbox-component path={box}\n".encode(), refused.stderr)
        self.assertEqual((away / "to-lane.jsonl").read_text(), "elsewhere\n")

    def test_mailbox_guard_judges_the_last_mailbox_segment(self):
        box = self.root / "srv/tmp/lane-mail/project/tmp/lane-mail/TEST-1"
        away = self.root / "away-last"
        away.mkdir()
        (away / "to-lane.jsonl").write_text("elsewhere\n")
        box.parent.mkdir(parents=True)
        box.symlink_to(away)
        refused = self.call("cat", "--item", "TEST-1", str(box / "to-lane.jsonl"))
        self.assertEqual(refused.returncode, 3, refused.stderr)
        self.assertIn(f"lane-host-ssh: mailbox-component path={box}\n".encode(), refused.stderr)

    def test_fresh_clone_uses_host_github_protocol(self):
        self.assertEqual(self.create(SSH_TEST_GIT_PROTOCOL="ssh").returncode, 0)
        self.assertIn("gh repo clone owner/repo " + self.row["clone"], (self.root / "calls").read_text())

    def test_put_uses_portable_private_permissions(self):
        self.assertEqual(self.create(SSH_TEST_BSD_CHMOD="1").returncode, 0)
        for path in ("-private", str(self.root / "absolute private")):
            with self.subTest(path=path):
                result = self.call("put", "--item", "TEST-1", "--", path,
                                   data=b"secret\n", SSH_TEST_BSD_CHMOD="1")
                self.assertEqual(result.returncode, 0, result.stderr)
                saved = self.root / path
                self.assertEqual(saved.read_bytes(), b"secret\n")
                self.assertEqual(saved.stat().st_mode & 0o777, 0o600)

    def test_put_keeps_the_target_when_a_transfer_is_cut(self):
        """A put whose stream dies mid-feed leaves the previous bytes standing."""
        self.assertEqual(self.create().returncode, 0)
        target = self.root / "mailbox"
        self.assertEqual(self.call("put", "--item", "TEST-1", "--", str(target),
                                   data=b"first answer\n").returncode, 0)
        longer = b"a much longer second answer\n"
        cut = self.call("put", "--item", "TEST-1", "--", str(target), data=longer, SSH_TEST_CUT="5")
        self.assertEqual(cut.returncode, 1, cut.stderr)
        self.assertIn(f"lane-host-ssh: put-short expected={len(longer)} arrived=5".encode(), cut.stderr)
        self.assertEqual(target.read_bytes(), b"first answer\n")
        self.assertEqual(list(target.parent.glob("mailbox.kendex-put.*")), [])
        # put's control: a provider that renames whatever arrived. The staged
        # write and the rename stay, so only the count check is removed.
        original = self.script.read_text()
        fragment = 'if [ "$((arrived + 0))" -ne "$2" ]; then'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, 'if false; then'))
        self.call("put", "--item", "TEST-1", "--", str(target),
                  data=b"a much longer second answer\n", SSH_TEST_CUT="5")
        self.assertEqual(target.read_bytes(), b"a muc")
        self.script.write_text(original)

    def test_append_adds_whole_lines_and_nothing_else(self):
        """Each append adds its line; a fragment is closed and a cut adds nothing."""
        self.assertEqual(self.create().returncode, 0)
        target = self.root / "lane/tmp/lane-mail/TEST-1/to-lane.jsonl"
        target.parent.mkdir(parents=True)
        for line in (b'{"id":"one"}\n', b'{"id":"two"}\n'):
            with self.subTest(line=line):
                result = self.call("append", "--item", "TEST-1", "--", str(target), data=line)
                self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_bytes(), b'{"id":"one"}\n{"id":"two"}\n')
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        # An item directory the lane has not opened yet is created on the way,
        # and the transfer's own umask is what makes the mailbox private.
        fresh = self.root / "lane/tmp/lane-mail/TEST-9/to-lane.jsonl"
        result = self.call("append", "--item", "TEST-1", "--", str(fresh), data=b'{"id":"fresh"}\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fresh.read_bytes(), b'{"id":"fresh"}\n')
        self.assertEqual(fresh.stat().st_mode & 0o777, 0o600)
        # A fragment an interrupted writer left is closed first, so the line
        # after it lands whole instead of glued to it and both lost.
        target.write_bytes(b'{"id":"half"')
        result = self.call("append", "--item", "TEST-1", "--", str(target), data=b'{"id":"whole"}\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_bytes(), b'{"id":"half"\n{"id":"whole"}\n')
        # A stream cut short adds nothing and leaves no staging file behind.
        longer = b'{"id":"a much longer line"}\n'
        cut = self.call("append", "--item", "TEST-1", "--", str(target), data=longer, SSH_TEST_CUT="5")
        self.assertEqual(cut.returncode, 1, cut.stderr)
        self.assertIn(f"lane-host-ssh: append-short expected={len(longer)} arrived=5".encode(), cut.stderr)
        self.assertEqual(target.read_bytes(), b'{"id":"half"\n{"id":"whole"}\n')
        self.assertEqual(list(target.parent.glob("to-lane.jsonl.kendex-append.*")), [])
        # append's control: without the count check a cut stream lands.
        original = self.script.read_text()
        rule = 'if [ "$((arrived + 0))" -ne "$2" ]; then'
        self.assertEqual(original.count(rule), 1)
        self.script.write_text(original.replace(rule, "if false; then"))
        target.write_bytes(b'{"id":"whole"}\n')
        self.call("append", "--item", "TEST-1", "--", str(target), data=b'{"id":"a much longer line"}\n',
                  SSH_TEST_CUT="5")
        self.assertEqual(target.read_bytes(), b'{"id":"whole"}\n{"id"')
        self.script.write_text(original)

    # A race only ever samples one interleaving. Holding the mailbox's own lock
    # through the same orch_take_lock the library calls settles it instead.
    # The release wait is bounded too, so a case that aborts before releasing
    # the lock leaves no process spinning behind the suite.
    HOLD_LOCK = 'set -euo pipefail\n. "%s/file-lock.sh"\nexec 9>>"%s"\norch_take_lock 9 "%s" 30\n' \
        ': > "%s"\nwaited=0\nwhile [ ! -e "%s" ]; do\n' \
        '  waited=$((waited + 1)); [ "$waited" -lt 1200 ] || exit 1\n  sleep 0.05\ndone'

    def test_append_waits_on_the_lock_the_mailbox_owns(self):
        """A second writer of one mailbox waits for it."""
        self.assertEqual(self.create().returncode, 0)
        library = Path(self.row["clone"]) / ".agents/skills/orch/scripts/lib"
        target = self.root / "lane/tmp/lane-mail/TEST-1/to-lane.jsonl"
        target.parent.mkdir(parents=True)
        taken, release = self.root / "lock-taken", self.root / "lock-release"
        hold = self.HOLD_LOCK % (library, target, target, taken, release)
        holder = subprocess.Popen(["bash", "-c", hold], env=self.env)
        # Bounded, and ended as soon as the holder is: a holder that died
        # before taking the lock would otherwise spin to the CI job's own
        # timeout with nothing saying what was in flight.
        deadline = time.monotonic() + 5
        while not taken.exists():
            self.assertIsNone(holder.poll(), "the lock holder exited without taking the lock")
            self.assertLess(time.monotonic(), deadline, f"the lock holder never wrote {taken}")
            time.sleep(0.05)
        append = subprocess.Popen(
            [str(self.script), "append", "--item", "TEST-1", "--", str(target)],
            cwd=self.root, env=self.env, stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        append.stdin.write(b'{"id":"held"}\n')
        append.stdin.close()
        time.sleep(2)
        during = len(target.read_bytes().splitlines())
        release.write_bytes(b"")
        append.wait()
        holder.wait()
        self.assertEqual((during, len(target.read_bytes().splitlines())), (0, 1))

    def test_append_names_its_failure_in_a_word(self):
        """The library's number is decoded where it is printed, not passed on."""
        self.assertEqual(self.create().returncode, 0)
        target = self.root / "lane/tmp/lane-mail/TEST-1/to-lane.jsonl"
        target.parent.mkdir(parents=True)
        library = Path(self.row["clone"]) / ".agents/skills/orch/scripts/lib/mailbox-append.sh"
        original = library.read_text()
        opened = 'exec 9>>"$1" || return 2'
        self.assertEqual(original.count(opened), 1)
        # The write row arranges a real failure: the staging succeeds and the
        # target's own open is what fails, which is that branch with no wait. A
        # directory refusing every open would stop at the staging and never
        # reach the decode. The lock row takes its code from a library copy
        # rather than from a real thirty-second wait on a held mailbox.
        # Fields: the target's mode, the library the clone holds, the word an
        # operator must read, and the number they must not.
        rows = (
            (0o400, original, b"reason=write-failed", b"reason=2"),
            (0o600, original.replace(opened, "return 3"), b"reason=lock-timeout", b"reason=3"),
        )
        for mode, source, word, number in rows:
            with self.subTest(word=word):
                target.write_bytes(b'{"id":"kept"}\n')
                target.chmod(mode)
                library.write_text(source)
                refused = self.call("append", "--item", "TEST-1", "--", str(target),
                                    data=b'{"id":"nowhere"}\n')
                target.chmod(0o600)
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn(b"lane-host-ssh: append-failed", refused.stderr)
                self.assertIn(word, refused.stderr)
                self.assertNotIn(number, refused.stderr)
                self.assertEqual(target.read_bytes(), b'{"id":"kept"}\n')
        library.write_text(original)

    @unittest.skipUnless(os.path.exists("/dev/full") and os.path.isdir("/proc/self/fd"),
                         "needs /dev/full and /proc to aim one write at a full device")
    def test_a_full_disk_leaves_no_staged_file_and_names_the_cause(self):
        """A write refused for lack of space says so and leaves nothing staged."""
        self.assertEqual(self.create().returncode, 0)
        target = self.root / "lane/tmp/lane-mail/TEST-1/to-lane.jsonl"
        target.parent.mkdir(parents=True)
        # The real cat, its output sent to /dev/full when that output is a file
        # SSH_TEST_FULL matches, so the one write it names meets the kernel's
        # own ENOSPC and cat's own report of it.
        full = self.root / "full-bin"
        self.executable(full / "cat", '''#!/usr/bin/env bash
out=$(readlink -- "/proc/$$/fd/1") || out=
if [[ $# -eq 0 && "$out" == $SSH_TEST_FULL ]]; then exec "$REAL_CAT" >/dev/full; fi
exec "$REAL_CAT" "$@"
''')
        env = dict(PATH=str(full) + os.pathsep + self.env["PATH"], REAL_CAT=shutil.which("cat"))

        def write(verb, where):
            target.write_bytes(b'{"id":"kept"}\n')
            return self.call(verb, "--item", "TEST-1", "--", str(target), data=b'{"id":"lost"}\n',
                             SSH_TEST_FULL=where, **env)

        def staged():
            return sorted(p.name for p in target.parent.glob("to-lane.jsonl.kendex-*"))

        # Fields: the verb, the file whose write the disk refuses: the staging
        # copy each verb makes, or the mailbox the library appends to.
        rows = (("append", "*.kendex-append.*"), ("append", "*/to-lane.jsonl"), ("put", "*.kendex-put.*"))
        for verb, where in rows:
            with self.subTest(verb=verb, where=where):
                refused = write(verb, where)
                self.assertEqual(refused.returncode, 1, refused.stderr)
                self.assertIn(f"lane-host-ssh: {verb}-failed path={target} reason=no-space\n".encode(),
                              refused.stderr)
                self.assertIn(b"No space left on device", refused.stderr)
                self.assertEqual(target.read_bytes(), b'{"id":"kept"}\n')
                self.assertEqual(staged(), [])

    def test_append_names_a_clone_that_predates_the_verb(self):
        """The control machine and the host's clone update apart."""
        self.assertEqual(self.create().returncode, 0)
        library = Path(self.row["clone"]) / ".agents/skills/orch/scripts/lib/mailbox-append.sh"
        target = self.root / "lane/tmp/lane-mail/TEST-1/to-lane.jsonl"
        target.parent.mkdir(parents=True)
        kept = library.read_bytes()
        library.unlink()
        self.addCleanup(library.write_bytes, kept)
        refused = self.call("append", "--item", "TEST-1", "--", str(target), data=b'{"id":"nowhere"}\n')
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn(f"lane-host-ssh: append-library-missing path={library}\n".encode(), refused.stderr)
        self.assertIn(b"predates the append verb", refused.stderr)
        self.assertFalse(target.exists())
        self.assertEqual(list(target.parent.glob("*.kendex-append.*")), [])

    def test_cat_tells_an_absent_path_from_one_it_cannot_read(self):
        """Exit 2 is "not there"; every other read failure keeps its own status."""
        self.assertEqual(self.create().returncode, 0)
        absent = self.call("cat", "--item", "TEST-1", "--", str(self.root / "nothing-here"))
        self.assertEqual(absent.returncode, 2, absent.stderr)
        sealed = self.root / "sealed"
        sealed.write_bytes(b"secret\n")
        sealed.chmod(0o000)
        unreadable = self.call("cat", "--item", "TEST-1", "--", str(sealed))
        sealed.chmod(0o600)
        self.assertNotIn(unreadable.returncode, (0, 2), unreadable.stderr)
        # The control: a cat with no presence test, where a missing path is
        # the same status as one it could not read.
        original = self.script.read_text()
        fragment = 'test -e "$1" || exit 2\\ncat -- "$1"'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, 'cat -- "$1"'))
        blind = self.call("cat", "--item", "TEST-1", "--", str(self.root / "nothing-here"))
        self.script.write_text(original)
        self.assertEqual(blind.returncode, 1, blind.stderr)

    def test_relaunch_recreates_missing_worktree(self):
        first = self.create("--relaunch")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertTrue(Path(self.row["clone"] + "-worktree").exists())
        self.assertEqual(self.call("close", "--item", "TEST-1").returncode, 0)
        self.assertFalse(Path(self.row["clone"] + "-worktree").exists())
        second = self.create("--relaunch")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, first.stdout)
        self.assertEqual(self.call("close", "--item", "TEST-1").returncode, 0)

    def test_clone_without_committed_render_refuses_create(self):
        """A render script absent from the checkout, or present but not
        committed at HEAD, is named before create makes a worktree."""
        git = [self.env["REAL_GIT"], "-C", str(self.source)]
        commit = ["-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm"]
        render = self.root / "render"
        shutil.copytree(self.source / ".agents", render, symlinks=True)
        # Per rule: the path the source drops, the clones it applies to, and
        # the keyed line and the script it names.
        rules = (
            ("orch/scripts/sync-base", ("new", "existing"), "render-missing", "orch/scripts/sync-base"),
            ("worktree/scripts/worktree", ("new", "existing"), "render-missing", "worktree/scripts/worktree"),
            (None, ("untracked",), "render-untracked", "orch/scripts/sync-base"),
        )
        for dropped, kinds, key, named in rules:
            relative = ".agents/skills/" + dropped if dropped else ".agents"
            subprocess.run([*git, "rm", "-rq", "--", relative], check=True)
            subprocess.run([*git, *commit, "drop " + relative], check=True)
            for kind in kinds:
                with self.subTest(rule=key, named=named, clone=kind):
                    self.row["clone"] = str(self.root / f"{named.split('/')[0]}-{kind}")
                    self.inventory.write_text(json.dumps([self.row]))
                    if kind != "new":
                        subprocess.run([self.env["REAL_GIT"], "clone", "-q", str(self.source), self.row["clone"]], check=True)
                    if kind == "untracked":
                        # What the retired bootstrap's refresh left behind.
                        shutil.copytree(render, Path(self.row["clone"], ".agents"), symlinks=True)
                    result = self.create()
                    line = f"lane-host-ssh: {key} path={self.row['clone']}/.agents/skills/{named}".encode()
                    self.assertIn(line, result.stderr.splitlines(), result.stderr)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertFalse(Path(self.row["clone"] + "-worktree").exists())
            subprocess.run([*git, "checkout", "-q", "HEAD~1", "--", relative], check=True)
            subprocess.run([*git, *commit, "restore " + relative], check=True)

    def test_file_lifecycle_and_dirty_close(self):
        self.assertEqual(self.create().returncode, 0)
        path = self.row["clone"] + "-worktree/bytes ' $ file"
        data = b"binary\x00\xff\n"
        Path(path).write_text("old")
        Path(path).chmod(0o644)
        self.assertEqual(self.call("put", "--item", "TEST-1", path, data=data).returncode, 0)
        read = self.call("cat", "--item", "TEST-1", path)
        self.assertEqual((read.returncode, read.stdout), (0, data))
        self.assertEqual(Path(path).stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.call("touch", "--item", "TEST-1").returncode, 0)
        self.assertEqual(self.call("list").stdout, b"owner/repo/TEST-1\thosted\t-\tlane.example\n")
        dirty = self.call("close", "--item", "TEST-1")
        self.assertEqual(dirty.returncode, 3)
        self.assertIn(b"close-refused path=", dirty.stderr)
        self.assertEqual(Path(path).read_bytes(), data)
        Path(path).unlink()
        closed = self.call("close", "--item", "TEST-1")
        # The launch opened this lane's mailbox under the worktree's tmp, so a
        # clean close has records to keep and reports where it put them.
        self.assertEqual(closed.returncode, 0, closed.stderr)
        self.assertTrue(closed.stdout.startswith(b"kept="), closed.stdout)
        self.assertTrue(Path(self.row["clone"]).exists())
        self.assertFalse(Path(self.row["clone"] + "-worktree").exists())
        self.assertEqual(self.call("list").stdout, b"owner/repo/TEST-1\tavailable\t-\tlane.example\n")

    @unittest.skipUnless(sys.platform.startswith("linux"), "provider stop integration requires procfs")
    def test_stop_signals_only_the_named_harness_in_the_owned_worktree(self):
        self.assertEqual(self.create().returncode, 0)
        worktree = Path(self.row["clone"] + "-worktree")
        clone = Path(self.row["clone"])
        shutil.copy2(shutil.which("bash"), self.bin / "claude")
        (self.bin / "claude").chmod(0o755)

        def harness(cwd):
            return subprocess.Popen([str(self.bin / "claude"), "-c",
                                     "trap 'exit 0' TERM; while :; do sleep 1; done"],
                                    cwd=cwd, env=self.env)

        holder = subprocess.Popen(
            [sys.executable, "-c",
             "import os,sys,time; p=os.fork(); "
             "os.execl(sys.argv[1],sys.argv[1],'-c','exit 0') if p == 0 else "
             "(print(p,flush=True),time.sleep(30))", str(self.bin / "claude")],
            cwd=worktree, env=self.env, stdout=subprocess.PIPE, text=True)
        zombie = int(holder.stdout.readline())
        holder.stdout.close()
        for _ in range(100):
            state = Path(f"/proc/{zombie}/stat").read_text().rsplit(")", 1)[1].split()[0]
            if state == "Z":
                break
            time.sleep(0.01)
        self.assertEqual(state, "Z")

        lane = harness(worktree)
        lane_two = harness(worktree)
        outside = harness(clone)
        try:
            stopped = self.call("stop", "--item", "TEST-1", "--harness", "claude")
            self.assertEqual((stopped.returncode, stopped.stdout),
                             (0, b"stopped item=TEST-1 processes=2\n"), stopped.stderr)
            lane.wait(timeout=2)
            lane_two.wait(timeout=2)
            self.assertIsNone(outside.poll())

            library = clone / ".agents/skills/orch/scripts/lib/lane-state.sh"
            library_original = library.read_text()
            library.write_text(library_original + f'\nlane_owned_processes() {{ LANE_OWNED_PROCESS_PIDS="{zombie}"; }}\n')
            raced = self.call("stop", "--item", "TEST-1", "--harness", "claude")
            self.assertEqual((raced.returncode, raced.stdout),
                             (0, b"stopped item=TEST-1 processes=0\n"), raced.stderr)

            library.write_text(library_original)
            inverse = self.call("stop", "--item", "TEST-1", "--harness", "codex")
            self.assertEqual((inverse.returncode, inverse.stdout),
                             (0, b"stopped item=TEST-1 processes=0\n"), inverse.stderr)
        finally:
            if 'library_original' in locals():
                library.write_text(library_original)
            for process in (lane, lane_two, outside, holder):
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=2)

    @unittest.skipUnless(sys.platform.startswith("linux"), "provider stop integration requires procfs")
    def test_stop_refuses_a_process_that_left_the_worktree(self):
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        shutil.copy2(shutil.which("bash"), self.bin / "claude")
        (self.bin / "claude").chmod(0o755)
        # The ownership read named this pid, and by the signal its directory is
        # the clone, not the worktree: a process that moved, or a reused pid.
        moved = subprocess.Popen([str(self.bin / "claude"), "-c", "trap 'exit 0' TERM; while :; do sleep 1; done"],
                                 cwd=clone, env=self.env)
        self.addCleanup(moved.wait, 2)
        self.addCleanup(lambda: moved.poll() is None and moved.kill())
        library = clone / ".agents/skills/orch/scripts/lib/lane-state.sh"
        library_original = library.read_text()
        staged = f'\nlane_owned_processes() {{ LANE_OWNED_PROCESS_PIDS="{moved.pid}"; }}\n'
        library.write_text(library_original + staged)
        refused = self.call("stop", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((refused.returncode, f"stop-owner-changed item=TEST-1 pid={moved.pid}\n".encode() in refused.stderr),
                         (1, True), refused.stderr)
        self.assertIsNone(moved.poll())

    def test_stop_refuses_an_unreadable_owned_process_set(self):
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        library = clone / ".agents/skills/orch/scripts/lib/lane-state.sh"
        library_original = library.read_text()
        library.write_text(library_original + '\nunset -f lane_stop_owned\n')
        missing = self.call("stop", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((missing.returncode, b"stop-operation-missing" in missing.stderr), (1, True), missing.stderr)
        library.write_text(library_original + '\nlane_owned_processes() { return 2; }\n')
        refused = self.call("stop", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((refused.returncode, b"stop-process-read-failed item=TEST-1\n" in refused.stderr),
                         (1, True), refused.stderr)

    def test_stop_answers_a_removed_worktree_with_its_own_status(self):
        # merge-pr removes the item's worktree before its lane goes idle, and
        # lane-close reads exit 4 as a stop to skip, so no remote-failed line
        # may sit above its stop-skipped line. stop's control is the guard
        # removed.
        self.assertEqual(self.create().returncode, 0)
        worktree = Path(self.row["clone"] + "-worktree")
        subprocess.run([self.env["REAL_GIT"], "-C", self.row["clone"], "worktree", "remove", "--force", str(worktree)],
                       check=True, capture_output=True)
        removed = self.call("stop", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((removed.returncode, removed.stdout, b"stop-worktree-removed item=TEST-1\n" in removed.stderr,
                          b"remote-failed" in removed.stderr),
                         (4, b"", True, False), removed.stderr)
        original = self.script.read_text()
        guard = """  if test "$LANE_STOP_CAUSE" = worktree-removed; then exit 4; fi
"""
        self.assertEqual(original.count(guard), 1)
        self.script.write_text(original.replace(guard, ""))
        mutant = self.call("stop", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((mutant.returncode, b"stop-worktree-removed item=TEST-1\n" in mutant.stderr),
                         (1, True), mutant.stderr)

    @unittest.skipUnless(sys.platform.startswith("linux"), "a removed directory's /proc spelling is Linux's")
    def test_stop_ends_a_harness_still_in_a_removed_worktree(self):
        # The harness outlives the worktree its lane's close-out removed, and
        # the host reads its directory as the removed hosted path, which still
        # names it. The item's own path by then is the issue-keyed one, whose
        # base dir no create made.
        self.assertEqual(self.create().returncode, 0)
        worktree = Path(self.row["clone"] + "-worktree")
        shutil.copy2(shutil.which("bash"), self.bin / "claude")
        (self.bin / "claude").chmod(0o755)
        subprocess.run([self.env["REAL_GIT"], "-C", self.row["clone"], "worktree", "remove", "--force", str(worktree)],
                       check=True, capture_output=True)
        worktree.mkdir()
        process = subprocess.Popen([str(self.bin / "claude"), "-c", "trap 'exit 0' TERM; while :; do sleep 0.1; done"],
                                   cwd=worktree, env=self.env, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        for _ in range(100):
            if os.readlink(f"/proc/{process.pid}/cwd") == str(worktree.resolve()):
                break
            time.sleep(0.02)
        worktree.rmdir()
        stopped = self.call("stop", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((stopped.returncode, stopped.stdout), (0, b"stopped item=TEST-1 processes=1\n"),
                         stopped.stderr)
        self.assertEqual(process.wait(2), 0)

    @unittest.skipUnless(sys.platform.startswith("linux"), "provider stop integration requires procfs")
    def test_stop_refuses_when_a_signaled_process_stays_live(self):
        self.assertEqual(self.create().returncode, 0)
        worktree = Path(self.row["clone"] + "-worktree")
        shutil.copy2(shutil.which("bash"), self.bin / "claude")
        (self.bin / "claude").chmod(0o755)
        process = subprocess.Popen([str(self.bin / "claude"), "-c",
                                    "trap '' TERM; while :; do sleep 1; done"],
                                   cwd=worktree, env=self.env)
        self.addCleanup(process.wait, 2)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        library = Path(self.row["clone"]) / ".agents/skills/orch/scripts/lib/lane-state.sh"
        library_original = library.read_text()
        library.write_text(library_original + f'\nlane_owned_processes() {{ LANE_OWNED_PROCESS_PIDS="{process.pid}"; }}\nkill() {{ return 1; }}\n')
        signal_refused = self.call("stop", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((signal_refused.returncode, b"stop-signal-refused" in signal_refused.stderr),
                         (1, True), signal_refused.stderr)
        library.write_text(library_original)
        refused = self.call("stop", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((refused.returncode, f"stop-timeout item=TEST-1 pid={process.pid}".encode() in refused.stderr),
                         (1, True), refused.stderr)

    def test_close_preserves_and_restores_only_traced_render_drift(self):
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        generated = clone / ".agents/skills/orch/scripts/lane-marker"
        original = generated.read_text()
        generated.write_text(original + "# rendered drift\n")
        (clone / ".kendex-generated.json").write_text('[\n  ".agents/skills/orch/scripts/lane-marker",\n  ".agents/skills/orch/scripts/new-render"\n]\n')
        untracked = clone / ".agents/skills/orch/scripts/new-render"
        untracked.write_text("new rendered file\n")
        owned = json.dumps([".agents/skills/orch/scripts/lane-marker",
                            ".agents/skills/orch/scripts/new-render", ".kendex-generated.json"])
        closed = self.call("close", "--item", "TEST-1", SSH_TEST_GENERATED_PATHS=owned)
        self.assertEqual(closed.returncode, 0, closed.stderr)
        self.assertEqual(generated.read_text(), original)
        self.assertFalse(untracked.exists())
        archive = Path(closed.stdout.decode().strip().removeprefix("kept="))
        with tarfile.open(archive) as saved:
            patches = [name for name in saved.getnames() if "/tmp/render-drift-TEST-1-clone-" in name]
            self.assertEqual(len(patches), 1)
            patch = saved.extractfile(patches[0]).read()
            self.assertIn(b"rendered drift", patch)
            self.assertIn(b"new rendered file", patch)

        self.assertEqual(self.create().returncode, 0)
        private = Path(self.row["clone"]) / "private.txt"
        private.write_text("keep\n")
        refused = self.call("close", "--item", "TEST-1")
        self.assertEqual(refused.returncode, 3)
        self.assertIn(b"close-refused path=", refused.stderr)
        self.assertTrue(private.exists())

    def test_close_refuses_shared_settings_and_restores_removed_renders(self):
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        settings = clone / ".claude/settings.json"
        settings.parent.mkdir(exist_ok=True)
        settings.write_text('{"person":true}\n')
        with (clone / ".kendex-generated.json").open("w") as inventory:
            json.dump([".agents/skills/orch/scripts/lane-marker", ".claude/settings.json"], inventory)
        refused = self.call("close", "--item", "TEST-1",
                            SSH_TEST_GENERATED_PATHS='[".kendex-generated.json"]')
        self.assertEqual(refused.returncode, 3, refused.stderr)
        self.assertEqual(settings.read_text(), '{"person":true}\n')

        settings.unlink()
        subprocess.run([self.env["REAL_GIT"], "-C", str(clone), "restore", ".kendex-generated.json"], check=True)
        removed = clone / ".agents/skills/orch/scripts/lane-marker"
        removed.unlink()
        closed = self.call("close", "--item", "TEST-1",
                           SSH_TEST_GENERATED_PATHS='[".agents/skills/orch/scripts/lane-marker"]')
        self.assertEqual(closed.returncode, 0, closed.stderr)
        self.assertTrue(removed.exists())

    def test_close_refuses_a_drift_patch_that_does_not_carry_the_path(self):
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        generated = clone / ".agents/skills/orch/scripts/lane-marker"
        drifted = generated.read_text() + "# preserve first\n"
        generated.write_text(drifted)
        owned = '[".agents/skills/orch/scripts/lane-marker"]'
        closed = self.call("close", "--item", "TEST-1", SSH_TEST_GENERATED_PATHS=owned)
        self.assertEqual(closed.returncode, 0, closed.stderr)
        archive = Path(closed.stdout.decode().strip().removeprefix("kept="))
        with tarfile.open(archive) as saved:
            patches = [name for name in saved.getnames() if "/tmp/render-drift-TEST-1-clone-" in name]
            self.assertEqual(len(patches), 1)
            self.assertIn(b"preserve first", saved.extractfile(patches[0]).read())

    def test_close_saves_an_untracked_render_link_to_a_directory(self):
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        target = self.root / "rendered-skill"
        (target / "nested").mkdir(parents=True)
        link = clone / ".claude/skills/rendered"
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target)
        owned = json.dumps([".claude/skills/rendered"])
        closed = self.call("close", "--item", "TEST-1", SSH_TEST_GENERATED_PATHS=owned)
        self.assertEqual(closed.returncode, 0, closed.stderr)
        self.assertFalse(link.is_symlink())
        archive = Path(closed.stdout.decode().strip().removeprefix("kept="))
        with tarfile.open(archive) as saved:
            patches = [name for name in saved.getnames() if "/tmp/render-drift-TEST-1-clone-" in name]
            self.assertEqual(len(patches), 1)
            patch = saved.extractfile(patches[0]).read()
        self.assertIn(b"new file mode 120000", patch)
        self.assertIn(str(target).encode(), patch)

    def test_close_refuses_when_the_patch_drops_one_of_several_paths(self):
        # The accented name is the fixture for core.quotePath=false as well:
        # apply --numstat prints the C-quoted spelling without it, which never
        # equals the raw path the carry comparison holds.
        render = ".agents/skills/orch/scripts/caf\u00e9-render"
        self.seed_source(render, "rendered\n")
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        marker = clone / ".agents/skills/orch/scripts/lane-marker"
        accented = clone / render
        owned = json.dumps([".agents/skills/orch/scripts/lane-marker", render])
        marker_drift = marker.read_text() + "# marker drift\n"
        accented_drift = accented.read_text(encoding="utf-8") + "# accented drift\n"

        def drift():
            marker.write_text(marker_drift)
            accented.write_text(accented_drift, encoding="utf-8")

        drift()
        closed = self.call("close", "--item", "TEST-1", SSH_TEST_GENERATED_PATHS=owned)
        self.assertEqual(closed.returncode, 0, closed.stderr)
        self.assertNotEqual(marker.read_text(), marker_drift)
        self.assertNotEqual(accented.read_text(encoding="utf-8"), accented_drift)

    @unittest.skipIf(os.geteuid() == 0, "mode 000 does not stop root from reading the file")
    def test_close_refuses_an_untracked_render_the_index_cannot_read(self):
        # No production edit reddens this case on its own: a render git add
        # cannot index leaves the patch without that path, so deleting the
        # add refusal only moves the exit 3 down to the carry comparison. The
        # case holds the contract, that close refuses and keeps both files.
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        marker = clone / ".agents/skills/orch/scripts/lane-marker"
        drifted = marker.read_text() + "# marker drift\n"
        marker.write_text(drifted)
        unreadable = clone / ".agents/skills/orch/scripts/new-render"
        unreadable.write_text("new rendered file\n")
        self.addCleanup(unreadable.chmod, 0o644)
        unreadable.chmod(0o000)
        owned = json.dumps([".agents/skills/orch/scripts/lane-marker",
                            ".agents/skills/orch/scripts/new-render"])
        refused = self.call("close", "--item", "TEST-1", SSH_TEST_GENERATED_PATHS=owned)
        self.assertEqual((refused.returncode, b"close-refused path=" in refused.stderr),
                         (3, True), refused.stderr)
        self.assertTrue(unreadable.exists())
        self.assertEqual(marker.read_text(), drifted)

    def test_close_refuses_when_generated_path_ownership_cannot_be_read(self):
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        generated = clone / ".agents/skills/orch/scripts/lane-marker"
        changed = generated.read_text() + "# keep on owner failure\n"
        generated.write_text(changed)
        refused = self.call("close", "--item", "TEST-1", SSH_TEST_GENERATED_PATHS_STATUS="127")
        self.assertEqual(refused.returncode, 1, refused.stderr)
        self.assertEqual(generated.read_text(), changed)

    def test_forced_host_tty_preserves_binary_reads_and_archive(self):
        self.assertEqual(self.create().returncode, 0)
        path = Path(self.row["clone"] + "-worktree/tmp/binary.dat")
        data = b"record\x00\xff\nnext\n"
        self.assertEqual(self.call("put", "--item", "TEST-1", str(path), data=data,
                                   SSH_TEST_REQUEST_TTY="force").returncode, 0)
        read = self.call("cat", "--item", "TEST-1", str(path), SSH_TEST_REQUEST_TTY="force")
        self.assertEqual((read.returncode, read.stdout), (0, data))
        closed = self.call("close", "--item", "TEST-1", SSH_TEST_REQUEST_TTY="force")
        self.assertEqual(closed.returncode, 0, closed.stderr)
        self.assertTrue(closed.stdout.startswith(b"kept="), closed.stdout)
        with tarfile.open(Path(closed.stdout.decode().strip().removeprefix("kept="))) as archive:
            self.assertEqual(archive.extractfile(str(path).lstrip("/")).read(), data)

    def test_claude_launch_keeps_token_out_of_exec_arguments(self):
        result = self.create()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.env.update(REAL_BASH=shutil.which("bash"), REAL_ENV=shutil.which("env"),
                        EXEC_TRACE=str(self.root / "exec-trace"), LAUNCH_RESULT=str(self.root / "launch-result"))
        for name in ("bash", "env"):
            self.executable(self.bin / name, '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["EXEC_TRACE"], "a") as trace:
    trace.write(json.dumps(sys.argv) + "\\n")
os.execv(os.environ["REAL_" + os.path.basename(sys.argv[0]).upper()], sys.argv)
''')
        harness = self.root / "harness"
        self.executable(harness, '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["LAUNCH_RESULT"], "w") as result:
    json.dump({"argv": sys.argv, "token": os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")}, result)
''')

        def launch(output):
            Path(self.env["EXEC_TRACE"]).write_text("")
            Path(self.env["LAUNCH_RESULT"]).unlink(missing_ok=True)
            prefix = dict(field.split("=", 1) for field in output.decode().strip().split("\t"))["remote-prefix"]
            return subprocess.run([self.env["REAL_BASH"], "-c", prefix + " " + shlex.quote("exec " + shlex.quote(str(harness)))],
                                  env=self.env, capture_output=True)

        launched = launch(result.stdout)
        self.assertEqual(launched.returncode, 0, launched.stderr)
        self.assertEqual(json.loads(Path(self.env["LAUNCH_RESULT"]).read_text())["token"], "claude-secret-fixture")
        self.assertNotIn("claude-secret-fixture", Path(self.env["EXEC_TRACE"]).read_text())
        (Path(self.row["account"]) / "setup-token").unlink()
        self.assertNotEqual(launch(result.stdout).returncode, 0)
        self.assertFalse(Path(self.env["LAUNCH_RESULT"]).exists())

    def test_existing_clone_finishes_real_worktree_setup(self):
        scripts = self.source / ".agents/skills/worktree/scripts"
        shutil.copytree(PACKAGE.parent / "worktree/scripts", scripts, dirs_exist_ok=True)
        (self.source / "kendex.settings.toml").write_text('[env]\nWORKTREE_DEFAULT_BRANCH = "main"\nWORKTREE_SYMLINKS = ".env.local .agents"\nWORKTREE_COPIES = "copy-config"\n')
        with (self.source / ".gitignore").open("a") as ignore:
            ignore.write("copy-config\ncopy-added\n")
        for args in (("branch", "-M", "main"), ("add", "."), ("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "worktree fixture")):
            subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), *args], check=True, capture_output=True)
        self.row["clone"] = str(self.root / "production")
        self.inventory.write_text(json.dumps([self.row]))
        subprocess.run([self.env["REAL_GIT"], "clone", "-q", str(self.source), self.row["clone"]], check=True)
        # Host-local files the clone holds untracked, for the copy settings to reach.
        for local, text in (("copy-config", "copied"), ("copy-added", "added")):
            Path(self.row["clone"], local).write_text(text)
        result = self.create()
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(dict(field.split("=", 1) for field in result.stdout.decode().strip().split("\t"))["path"])
        # The hosted lane path, the same in every lane of the repository.
        self.assertEqual(path, self.root.resolve() / ".worktrees/production/lane")
        self.assertEqual((path / ".env.local").read_bytes(), (Path(self.row["clone"]) / ".env.local").read_bytes())
        # The first setup, before preparation, already copies it.
        self.assertEqual((path / "copy-config").read_text(), "copied")
        self.assertFalse((path / "copy-added").exists())
        self.source.joinpath("kendex.settings.toml").write_text('[env]\nWORKTREE_DEFAULT_BRANCH = "main"\nWORKTREE_SYMLINKS = ".env.local .agents"\nWORKTREE_COPIES = "copy-config copy-added"\n')
        subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), "add", "kendex.settings.toml"], check=True)
        subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "new remote settings"], check=True)
        updated = self.create("--reuse")
        self.assertEqual(updated.returncode, 0, updated.stderr)
        self.assertIn('copy-added', Path(self.row["clone"]).joinpath("kendex.settings.toml").read_text())
        self.assertEqual((path / "copy-added").read_text(), "added")
        before = (Path(self.row["clone"]) / ".env.local").read_bytes()
        (self.source / ".env.local").write_text("SECRET=changed\n")
        refused = self.create()
        self.assertEqual(refused.returncode, 75, refused.stderr)
        self.assertEqual((Path(self.row["clone"]) / ".env.local").read_bytes(), before)

    def test_close_after_lane_removes_worktree(self):
        self.assertEqual(self.create().returncode, 0)
        subprocess.run([self.env["REAL_GIT"], "-C", self.row["clone"], "worktree", "remove", self.row["clone"] + "-worktree"], check=True)
        dirty = Path(self.row["clone"]) / "untracked"
        dirty.write_text("keep")
        self.assertEqual(self.call("close", "--item", "TEST-1").returncode, 3)
        self.assertEqual(dirty.read_text(), "keep")
        dirty.unlink()
        self.assertEqual(self.call("close", "--item", "TEST-1").returncode, 0)
        self.assertEqual(self.call("list").stdout, b"owner/repo/TEST-1\tavailable\t-\tlane.example\n")

    def test_close_requires_provider_marker_before_worktree_lookup(self):
        self.assertEqual(self.create().returncode, 0)
        marker = Path(self.row["clone"]) / ".git/lane-host-item"
        worktree = Path(self.row["clone"] + "-worktree")
        private = worktree / "tmp/private.json"
        private.parent.mkdir(exist_ok=True)
        private.write_text("keep")
        for owner in (None, "OTHER-1"):
            with self.subTest(owner=owner):
                if owner is None:
                    marker.unlink()
                else:
                    marker.write_text(owner + "\n")
                before = (self.root / "calls").read_text()
                refused = self.call("close", "--item", "TEST-1")
                self.assertEqual(refused.returncode, 75, refused.stderr)
                self.assertIn(b"close-unowned item=TEST-1", refused.stderr)
                self.assertNotIn("worktree path TEST-1", (self.root / "calls").read_text()[len(before):])
                self.assertEqual(private.read_text(), "keep")
                self.assertFalse((Path(self.env["FLEET_DIR"]) / "archive/repo/TEST-1").exists())

    def test_existing_clone_refuses_other_repository(self):
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        before = (self.root / "calls").read_text()
        refused = self.create("--reuse", SSH_TEST_REPO_NAME="other/repo")
        self.assertEqual(refused.returncode, 1, refused.stderr)
        self.assertIn(b"origin-mismatch expected=owner/repo actual=other/repo", refused.stderr)
        self.assertNotIn("worktree create TEST-1", (self.root / "calls").read_text()[len(before):])
        self.assertEqual((clone / ".git/lane-host-item").read_text(), "TEST-1\n")

    def test_close_archives_before_delete(self):
        for state in ("present", "removed"):
            with self.subTest(state=state):
                self.row["clone"] = str(self.root / state)
                self.inventory.write_text(json.dumps([self.row]))
                self.assertEqual(self.create().returncode, 0)
                clone = Path(self.row["clone"])
                worktree = Path(self.row["clone"] + "-worktree")
                for directory in (clone / "tmp", worktree / "tmp"):
                    directory.mkdir(exist_ok=True)
                (clone / "tmp/clone.json").write_bytes(b'"clone-record"\n')
                (worktree / "tmp/return.json").write_bytes(b'"worktree-record"\n')
                (worktree / "tmp/linked.json").symlink_to(clone / "tmp/clone.json")
                if state == "removed":
                    subprocess.run([self.env["REAL_GIT"], "-C", str(clone), "worktree", "remove", "--force", str(worktree)], check=True)
                output = self.root / (state + ".stdout")
                with output.open("wb") as stream:
                    closed = subprocess.run([str(self.script), "close", "--item", "TEST-1"], cwd=self.root,
                                            env={**self.env, "SSH_TEST_CLOSE_STDOUT": str(output)}, stdout=stream, stderr=subprocess.PIPE)
                self.assertEqual(closed.returncode, 0, closed.stderr)
                line = output.read_text().strip()
                self.assertTrue(line.startswith("kept="), line)
                archive = Path(line.removeprefix("kept="))
                self.assertEqual(archive.parent, Path(self.env["FLEET_DIR"]) / "archive/repo/TEST-1")
                self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
                with tarfile.open(archive) as saved:
                    self.assertEqual(saved.extractfile(str(clone / "tmp/clone.json").lstrip("/")).read(), b'"clone-record"\n')
                    member = str(worktree / "tmp/return.json").lstrip("/")
                    if state == "removed":
                        self.assertNotIn(member, saved.getnames())
                    else:
                        self.assertEqual(saved.extractfile(member).read(), b'"worktree-record"\n')
                        self.assertEqual(saved.extractfile(str(worktree / "tmp/linked.json").lstrip("/")).read(), b'"clone-record"\n')
                self.assertFalse(worktree.exists())
                self.assertFalse((clone / ".git/lane-host-item").exists())
                if state == "present":
                    self.assertIn("before-delete:" + line, (self.root / "calls").read_text())

    def test_archive_failures_preserve_remote_records(self):
        for failure in ("tar", "storage"):
            with self.subTest(failure=failure):
                self.row["clone"] = str(self.root / failure)
                self.inventory.write_text(json.dumps([self.row]))
                self.assertEqual(self.create().returncode, 0)
                worktree = Path(self.row["clone"] + "-worktree")
                (worktree / "tmp").mkdir(exist_ok=True)
                record = worktree / "tmp/return.json"
                record.write_text("keep")
                env = {}
                if failure == "tar":
                    self.executable(self.bin / "tar", '#!/usr/bin/env bash\nexit 23\n')
                else:
                    blocked = self.root / "storage-blocked"
                    blocked.write_text("file")
                    env["FLEET_DIR"] = str(blocked)
                closed = self.call("close", "--item", "TEST-1", **env)
                self.assertEqual(closed.returncode, {"tar": 23, "storage": 1}[failure], closed.stderr)
                self.assertTrue(record.exists())
                self.assertTrue((Path(self.row["clone"]) / ".git/lane-host-item").exists())
                self.assertEqual(closed.stdout, b"")
                if failure == "storage":
                    self.assertIn(b"archive-write-failed path=", closed.stderr)
                (self.bin / "tar").unlink(missing_ok=True)

    def test_inventory_refusals(self):
        cases = [
            ("inventory-fields", [{**self.row, "target": "bad\nvalue"}]),
            ("inventory-duplicate", [self.row, self.row]),
            ("inventory-path", [{**self.row, "clone": "relative"}]),
            ("inventory-repo", [self.row, {**self.row, "item": "TEST-2", "repo": "owner/other", "clone": "/other"}]),
        ]
        for key, rows in cases:
            with self.subTest(key=key):
                self.inventory.write_text(json.dumps(rows))
                result = self.call("list")
                self.assertEqual(result.returncode, 2)
                self.assertIn((key + " path=" + str(self.inventory)).encode(), result.stderr)
                self.assertFalse((self.root / "calls").exists())

    def test_control_inventory_guard(self):
        original = self.script.read_text()
        fragment = 'if len({r["item"] for r in rows}) != len(rows) or len({(r["target"], r["clone"]) for r in rows}) != len(rows):'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, 'if False:'))
        self.inventory.write_text(json.dumps([self.row, self.row]))
        self.assertNotEqual(self.call("list").returncode, 2)

    def test_failures_stop_preparation(self):
        for overrides, code in (({"SSH_TEST_FAIL": "255"}, 255), ({"SSH_TEST_CLONE_FAIL": "23"}, 23)):
            with self.subTest(overrides=overrides):
                result = self.create(**overrides)
                self.assertEqual(result.returncode, code)
                self.assertEqual(result.stdout, b"")
                self.assertFalse(Path(self.row["clone"] + "-worktree").exists())

    def test_control_dirty_guard_removal_turns_refusal_red(self):
        self.assertEqual(self.create().returncode, 0)
        path = Path(self.row["clone"]) / "untracked"
        path.write_text("keep")
        original = self.script.read_text()
        fragment = 'if test -n "$dirty"; then'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, 'if false; then'))
        result = self.call("close", "--item", "TEST-1")
        self.assertNotEqual(result.returncode, 3)


if __name__ == "__main__":
    unittest.main()
