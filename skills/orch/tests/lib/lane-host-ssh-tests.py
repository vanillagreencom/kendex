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
from unittest import mock

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
                        HOME=str(self.root),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.git_env = {key: self.env[key] for key in ("HOME", "PATH", "REAL_GIT")}
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
        # Every item's tree sits at the clone's one hosted path, as the real
        # command places it. Like the real command, exists answers for the
        # item the tree there was created for, recorded beside it.
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
    printf '%s\\n' "$2" > "$path.item"
  fi
  printf '%s\\n' "$path" ;;
exists)
  if [[ -d "$path" && ( ! -f "$path.item" || "$(cat -- "$path.item")" == "$2" ) ]]; then printf 'true\\n'
  else printf 'false\\n'; fi ;;
path) if [[ -d "$path" ]]; then printf '%s\\n' "$path"; else printf '%s\\n' "$PWD/configured-$2"; fi ;;
remove)
  if [[ -n "${SSH_TEST_CLOSE_STDOUT:-}" ]]; then
    printf 'before-delete:%s\\n' "$(cat -- "$SSH_TEST_CLOSE_STDOUT")" >> "$SSH_TEST_LOG"
  fi
  git worktree remove --force "$path"
  rm -f -- "$path.item" ;;
esac
''')
        # create reads the clone's settings through the worktree command's own loader.
        (wt.parent / "lib").mkdir()
        shutil.copy2(PACKAGE.parent / "worktree/scripts/lib/kendex-env.sh", wt.parent / "lib/kendex-env.sh")
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
        # A source checkout can still hold the retired Linear store; a clone never receives it.
        retired = self.source / ".cache/linear"
        retired.mkdir(parents=True)
        (retired / "issues.json").write_text('{"cached":true}')
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

    def connection_reuse(self):
        """Model key exchanges at the OpenSSH option boundary, not real SSH latency."""
        self.executable(self.bin / "ssh", '''#!/usr/bin/env python3
import hashlib, os, pathlib, subprocess, sys
words = sys.argv[1:]
options = dict(words[i + 1].split("=", 1) for i, word in enumerate(words) if word == "-o")
target = words[words.index("--") + 1]
path = options.get("ControlPath")
socket = pathlib.Path(path.replace("%C", hashlib.sha1(target.encode()).hexdigest())) if path else None
reuse = options.get("ControlMaster") == "auto" and int(options.get("ControlPersist", "0")) > 20
if not reuse or socket is None or not socket.exists():
    with open(os.environ["SSH_TEST_EXCHANGES"], "a") as log:
        log.write("exchange\\n")
    if reuse and socket is not None:
        socket.touch()
child_env = {key: os.environ[key] for key in ("HOME", "PATH")}
sys.exit(subprocess.run([os.environ["SSH_TEST_BASH"], "-c", words[-1]], env=child_env).returncode)
''')
        path = self.root / "read-file"
        path.write_bytes(b"remote bytes\n")
        log = self.root / "exchanges"
        env = dict(SSH_TEST_EXCHANGES=str(log), SSH_TEST_BASH=shutil.which("bash"))
        for _ in range(2):
            result = self.call("cat", "--item", "TEST-1", str(path), **env)
            self.assertEqual((result.returncode, result.stdout), (0, path.read_bytes()), result.stderr)
        return log, path, env

    def test_cat_reuses_connection_and_reconnects_after_socket_removal(self):
        log, path, env = self.connection_reuse()
        self.assertEqual(log.read_text().splitlines(), ["exchange"])
        directory = self.root / ".cache/kendex-ssh"
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        for socket in directory.iterdir():
            socket.unlink()
        result = self.call("cat", "--item", "TEST-1", str(path), **env)
        self.assertEqual((result.returncode, result.stdout), (0, path.read_bytes()), result.stderr)
        self.assertEqual(log.read_text().splitlines(), ["exchange", "exchange"])

    def test_control_cat_without_connection_reuse_exchanges_each_time(self):
        original = self.script.read_text()
        rule = '"ControlMaster=auto"'
        self.assertEqual(original.count(rule), 1)
        with tempfile.TemporaryDirectory() as control:
            self.script = Path(control) / "lane-host-ssh"
            self.executable(self.script, original.replace(rule, '"ControlMaster=no"'))
            log, _, _ = self.connection_reuse()
        self.assertEqual(log.read_text().splitlines(), ["exchange", "exchange"])

    def test_prepare_reuse_and_account_protocol(self):
        first = self.create()
        self.assertEqual(first.returncode, 0, first.stderr)
        clone = Path(self.row["clone"])
        self.assertEqual((clone / ".env.local").read_bytes(), (self.source / ".env.local").read_bytes())
        self.assertFalse((clone / ".cache/linear").exists())
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
        result = self.create("--reuse", harness="codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"CODEX_HOME", result.stdout)
        self.assertEqual((Path(self.row["account"]) / "auth.json").read_bytes(), (self.account / "auth.json").read_bytes())
        self.assertFalse((clone / ".cache/linear").exists())
        result = self.create("--reuse", harness="pi")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"PI_CODING_AGENT_DIR", result.stdout)
        # The root open-terminal reads the lane's Pi settings under.
        fields = dict(word.split("=", 1) for word in result.stdout.decode().strip().split("\t"))
        self.assertEqual(fields["pi-root"], self.row["account"])
        self.assertNotIn("pi-root", dict(word.split("=", 1) for word in first.stdout.decode().strip().split("\t")))
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

    def copilot_create(self):
        """A copilot create's fields, on a host whose login profile exports every token again."""
        result = self.create(harness="copilot")
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.root / ".bash_profile").write_text(
            "export GH_TOKEN=profile-token COPILOT_GITHUB_TOKEN=profile-placeholder GITHUB_TOKEN=profile-actions-token\n")
        return dict(word.split("=", 1) for word in result.stdout.decode().strip().split("\t"))

    def copilot_run(self, fields, library=None):
        """The create's prefix running the command open-terminal hands it, under LIBRARY's launch policy or none."""
        probe = ('printf "%s|%s|%s|%s|%s|%s" "${COPILOT_GITHUB_TOKEN-unset}" "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}"'
                 ' "$COPILOT_HOME" "$COPILOT_SKILLS_DIRS" "$COPILOT_ALLOW_ALL"')
        words = ""
        if library:
            # The launch policy's one owner, as open-terminal's hosted arm calls it
            # for a command carrying --allow-all.
            words = subprocess.run(["bash", "-c", '. "$1" && lane_copilot_env "$2" "$3"', "_",
                                    str(library), "copilot --allow-all", '"$HOME/.agents/skills"'],
                                   check=True, capture_output=True).stdout.decode().strip() + " "
        command = "cd / && exec " + words + "sh -c " + shlex.quote(probe)
        return subprocess.run(["bash", "-c", fields["remote-prefix"] + " " + shlex.quote(command)],
                              env={**self.env, "COPILOT_GITHUB_TOKEN": "placeholder", "GH_TOKEN": "app-token",
                                   "GITHUB_TOKEN": "actions-token", "HOME": str(self.root)},
                              capture_output=True)

    def test_create_runs_copilot_on_its_stored_login(self):
        """A copilot lane copies no credential, its provider selects COPILOT_HOME, and the launch policy clears the COPILOT_GITHUB_TOKEN the host's profile exports while GH_TOKEN and GITHUB_TOKEN reach the lane."""
        before = sorted(p.name for p in Path(self.row["account"]).iterdir()) if Path(self.row["account"]).exists() else []
        fields = self.copilot_create()
        run = self.copilot_run(fields, PACKAGE / "scripts/lib/lane-launch.sh")
        after = sorted(p.name for p in Path(self.row["account"]).iterdir()) if Path(self.row["account"]).exists() else []
        self.assertEqual(after, before)
        self.assertEqual(run.stdout.decode(), "|".join(["unset", "profile-token", "profile-actions-token", self.row["account"],
                                                        str(self.root / ".agents/skills"), "true"]), run.stderr)

    def test_control_copilot_command_without_its_policy(self):
        """Control: the same prefix running the command with no launch policy leaves the profile's tokens on the lane."""
        run = self.copilot_run(self.copilot_create())
        self.assertEqual(run.stdout.decode().split("|")[:3],
                         ["profile-placeholder", "profile-token", "profile-actions-token"], run.stderr)

    def test_control_copilot_policy_without_its_clearing(self):
        """Control: the clearing cut from a copy of the policy leaves the profile's COPILOT_GITHUB_TOKEN on the lane."""
        fields = self.copilot_create()
        clearing = "printf 'env -u COPILOT_GITHUB_TOKEN COPILOT_SKILLS_DIRS"
        lib = self.root / "policy-copy"
        shutil.copytree(PACKAGE / "scripts/lib", lib)
        library = lib / "lane-launch.sh"
        original = library.read_text()
        self.assertEqual(original.count(clearing), 1)
        library.write_text(original.replace(clearing, "printf 'env COPILOT_SKILLS_DIRS"))
        self.assertNotIn(clearing, library.read_text())
        run = self.copilot_run(fields, library)
        self.assertEqual(run.stdout.decode(), "|".join(["profile-placeholder", "profile-token", "profile-actions-token",
                                                        self.row["account"], str(self.root / ".agents/skills"), "true"]),
                         run.stderr)

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

    def test_create_names_a_clone_without_the_identity_recorder(self):
        # The clone's library is what every prefix sources to record its
        # identity, so one older than the recorder would end the prefix at
        # bash's 127 with nothing naming what the clone is missing.
        library = ".agents/skills/orch/scripts/lib/lane-state.sh"
        text = (self.source / library).read_text()
        self.seed_source(library, text + "\nunset -f lane_identity_record\n")
        refused = self.create()
        path = Path(self.row["clone"]) / library
        self.assertEqual((refused.returncode, refused.stdout,
                          f"lane-host-ssh: identity-recorder-missing path={path}\n".encode() in refused.stderr),
                         (1, b"", True), refused.stderr)
        original = self.script.read_text()
        probe = 'declare -F lane_identity_record >/dev/null'
        self.assertEqual(original.count(probe), 1)
        self.script.write_text(original.replace(probe, 'true'))
        self.assertEqual(self.create().returncode, 0)

    def test_prefix_names_an_identity_it_could_not_record(self):
        # A record that fails ends the prefix there: the harness never starts,
        # and the pane carries the line naming the file.
        created = self.create(harness="codex")
        self.assertEqual(created.returncode, 0, created.stderr)
        prefix = dict(word.split("=", 1) for word in created.stdout.decode().strip().split("\t"))["remote-prefix"]
        identity = Path(self.row["clone"]) / ".git/lane-host-pid"
        identity.mkdir()
        run = subprocess.run(["bash", "-c", prefix + " " + shlex.quote("printf started")],
                             env={**self.env, "HOME": str(self.root)}, capture_output=True)
        self.assertEqual((run.returncode, run.stdout,
                          f"lane-host-ssh: identity-record-failed path={identity}\n".encode() in run.stderr),
                         (1, b"", True), run.stderr)

    def hosted_state_launch(self, harness="claude"):
        """Run delegation and recovery through create's actual hosted prefix."""
        scripts = self.source / ".agents/skills/orch/scripts"
        for name in ("workflow-state", "git-context", "round-recover", "round-prune", "orch-env"):
            shutil.copy2(PACKAGE / "scripts" / name, scripts / name)
        shutil.copytree(PACKAGE.parent / "github/scripts/lib",
                        self.source / ".agents/skills/github/scripts/lib", dirs_exist_ok=True)
        for args in (("config", "gc.auto", "0"), ("config", "maintenance.auto", "false"),
                     ("add", "."), ("-c", "user.name=Test", "-c", "user.email=test@example.org",
                                    "commit", "--allow-empty", "-qm", "state scripts")):
            subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), *args],
                           env=self.git_env, check=True, capture_output=True)
        # The prune's disk decision is independent of this machine's free space.
        self.executable(self.bin / "df", "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 100 1 99 1%% /\\n'\n")
        created = self.create(harness=harness)
        self.assertEqual(created.returncode, 0, created.stderr)
        fields = dict(word.split("=", 1) for word in created.stdout.decode().strip().split("\t"))
        path = Path(fields["path"])
        self.assertTrue(path.is_absolute(), path)
        self.assertFalse((Path(self.row["clone"]) / "tmp").exists())
        probe = self.root / "state-probe.sh"
        probe.write_text('''set -euo pipefail
export PATH="$1:$PATH"
scripts="$PWD/.agents/skills/orch/scripts"
state="$scripts/workflow-state"
"$state" init TEST-1 --worktree "$PWD" --branch test-1 >/dev/null
"$state" set-git-head TEST-1 pre_delegate_sha "$PWD" >/dev/null
round=$("$state" new-round-id TEST-1 dev_round_id)
"$state" set-now TEST-1 dev_delegated_at >/dev/null
rc=0
"$scripts/round-recover" --worktree "$PWD" --issue TEST-1 --round-id "$round" || rc=$?
[[ "$rc" -eq 3 ]]
"$scripts/round-prune" TEST-1
"$state" set-now TEST-1 dev_delegated_at >/dev/null
"$state" get TEST-1
''')
        bash = shutil.which("bash", path=self.env["PATH"])
        command = "cd " + shlex.quote(str(path)) + " && exec " + shlex.join([bash, str(probe), str(self.bin)])
        run = self.hosted_prefix_run(fields, command)
        return fields, path, run

    def hosted_prefix_run(self, fields, command):
        child_env = {key: self.env[key] for key in
                     ("HOME", "PATH", "REAL_GIT", "REAL_CHMOD", "REAL_PYTHON", "SSH_TEST_LOG", "SSH_TEST_SOURCE")}
        # A control-host directory must not reach the lane in place of its own.
        child_env["ORCH_STATE_DIR"] = str(self.root / "control-state")
        return subprocess.run([shutil.which("bash", path=self.env["PATH"]), "-c",
                               fields["remote-prefix"] + " " + shlex.quote(command)],
                              env=child_env, capture_output=True, timeout=60)

    def assert_hosted_state(self, fields, path, run):
        self.assertEqual(run.returncode, 0, run.stderr)
        state_file = path / "tmp/workflow-state-TEST-1.json"
        self.assertTrue(state_file.is_file(), state_file)
        state = json.loads(state_file.read_bytes())
        self.assertEqual(state["worktree"], str(path))
        self.assertEqual(state["pre_delegate_sha"], subprocess.run(
            [self.env["REAL_GIT"], "-C", str(path), "rev-parse", "HEAD"],
            env=self.git_env, check=True, capture_output=True).stdout.decode().strip())
        self.assertEqual(state["recovery_round_id"], state["dev_round_id"])
        self.assertEqual(state["round_prunes"][state["dev_round_id"]],
                         dict(action="below-mark", used_pct=1, mark_pct=75, bytes=0))
        self.assertIsInstance(state["dev_delegated_at"], int)
        self.assertFalse((Path(self.row["clone"]) / "tmp").exists())
        self.assertFalse((self.root / "control-state").exists())
        # Without the launch variable the same linked checkout reaches the
        # state-missing branch, rather than another script or fixture failure.
        command = "cd " + shlex.quote(str(path)) + " && unset ORCH_STATE_DIR && exec .agents/skills/orch/scripts/round-prune TEST-1"
        refused = self.hosted_prefix_run(fields, command)
        self.assertEqual(refused.returncode, 2, refused.stderr)
        self.assertIn(b"round-prune: state-missing=dev_round_id\n", refused.stderr)

    def test_hosted_prefix_carries_state_for_each_harness(self):
        caller_home = self.root / "caller-home"
        caller_home.mkdir()
        caller_config = caller_home / ".gitconfig"
        caller_config.write_text("[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = " +
                                 str(caller_home / "missing-signer") + "\n")
        with mock.patch.dict(os.environ, HOME=str(caller_home), GIT_CONFIG_GLOBAL=str(caller_config)):
            for harness in ("claude", "codex", "pi", "copilot"):
                with self.subTest(harness=harness):
                    fields, path, run = self.hosted_state_launch(harness)
                    self.assert_hosted_state(fields, path, run)
                    closed = self.call("close", "--item", "TEST-1")
                    self.assertEqual(closed.returncode, 0, closed.stderr)

    def test_control_prefix_without_state_export_fails_the_state_contract(self):
        original = self.script.read_text()
        export = 'prefix = "exec env " + shlex.quote("ORCH_STATE_DIR=" + path + "/tmp") + " " + prefix'
        self.assertEqual(original.count(export), 1)
        with tempfile.TemporaryDirectory() as control:
            self.script = Path(control) / "lane-host-ssh"
            self.executable(self.script, original.replace(export, 'prefix = "exec " + prefix'))
            fields, path, run = self.hosted_state_launch()
            with self.assertRaises(AssertionError):
                self.assert_hosted_state(fields, path, run)
        self.assertTrue((self.root / "control-state/workflow-state-TEST-1.json").is_file())
        self.assertFalse((path / "tmp/workflow-state-TEST-1.json").exists())

    def hosted_state_read(self, path, library):
        scratch = self.root / "state-read"
        scratch.mkdir(exist_ok=True)
        child_env = {key: self.env[key] for key in
                     ("HOME", "PATH", "REAL_GIT", "SSH_TEST_SOURCE", "SSH_TEST_LOG",
                      "LANE_HOST_SSH_SOURCE", "LANE_HOST_SSH_INVENTORY")}
        return subprocess.run([shutil.which("bash", path=self.env["PATH"]), "-c",
                               'set -euo pipefail; . "$1"; lane_hosted_item_state "$2" TEST-1 "$3" "$4"; printf "%s" "$LANE_ITEM_STATE"',
                               "hosted-reader", str(library), str(self.script), str(path), str(scratch)],
                              env=child_env, capture_output=True, timeout=60)

    def test_hosted_state_read_and_archive_keep_the_prefix_state(self):
        fields, path, run = self.hosted_state_launch()
        self.assert_hosted_state(fields, path, run)
        expected = json.loads((path / "tmp/workflow-state-TEST-1.json").read_bytes())
        read = self.hosted_state_read(path, PACKAGE / "scripts/lib/lane-gitfile.sh")
        self.assertEqual(read.returncode, 0, read.stderr)
        self.assertEqual(json.loads(read.stdout), expected)
        closed = self.call("close", "--item", "TEST-1")
        self.assertEqual(closed.returncode, 0, closed.stderr)
        archive = Path(closed.stdout.decode().strip().removeprefix("kept="))
        with tarfile.open(archive) as saved:
            member = str(path / "tmp/workflow-state-TEST-1.json").lstrip("/")
            self.assertEqual(saved.extractfile("lane-host-state").read(), member.encode() + b"\n")
            self.assertEqual(json.loads(saved.extractfile(member).read()), expected)

    def test_control_hosted_reader_without_launch_state_reads_no_rounds(self):
        fields, path, run = self.hosted_state_launch()
        self.assert_hosted_state(fields, path, run)
        with tempfile.TemporaryDirectory() as control:
            lib = Path(control) / "orch/scripts/lib"
            shutil.copytree(PACKAGE / "scripts/lib", lib)
            shutil.copytree(PACKAGE.parent / "github/scripts/lib", Path(control) / "github/scripts/lib")
            library = lib / "lane-gitfile.sh"
            original = library.read_text()
            rule = 'lane_hosted_state_path "$LANE_HOSTED_CLONE" "$3/tmp" "$2"'
            self.assertEqual(original.count(rule), 1)
            library.write_text(original.replace(rule, 'lane_hosted_state_path "$LANE_HOSTED_CLONE" tmp "$2"'))
            read = self.hosted_state_read(path, library)
            self.assertEqual((read.returncode, read.stdout), (0, b""), read.stderr)

    def test_control_archive_without_launch_state_records_no_state(self):
        fields, path, run = self.hosted_state_launch()
        self.assert_hosted_state(fields, path, run)
        original = self.script.read_text()
        rule = 'state="$2/tmp/workflow-state-$3.json"'
        self.assertEqual(original.count(rule), 1)
        with tempfile.TemporaryDirectory() as control:
            self.script = Path(control) / "lane-host-ssh"
            self.executable(self.script, original.replace(rule, 'state="$1/tmp/workflow-state-$3.json"'))
            closed = self.call("close", "--item", "TEST-1")
            self.assertEqual(closed.returncode, 0, closed.stderr)
            archive = Path(closed.stdout.decode().strip().removeprefix("kept="))
            with tarfile.open(archive) as saved:
                self.assertEqual(saved.extractfile("lane-host-state").read(), b"\n")
                member = str(path / "tmp/workflow-state-TEST-1.json").lstrip("/")
                self.assertIsNotNone(saved.extractfile(member))

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
        appends = []
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        for identity in ("first", "second"):
            append = subprocess.Popen(
                [str(self.script), "append", "--item", "TEST-1", "--", str(target)],
                cwd=self.root, env=self.env, stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            append.stdin.write((json.dumps(dict(id=identity, kind="directive", at=stamp,
                                               **{"from": "owner"}, text="one report")) + "\n").encode())
            append.stdin.close()
            appends.append(append)
        # Both transfers wait behind the holder before either can append.
        time.sleep(2)
        during = len(target.read_bytes().splitlines())
        release.write_bytes(b"")
        reports = [append.stderr.read() for append in appends]
        codes = sorted(append.wait() for append in appends)
        holder.wait()
        rows = [json.loads(line) for line in target.read_bytes().splitlines()]
        self.assertEqual((during, len(rows), codes), (0, 1, [0, 4]))
        self.assertIn(f"duplicate id={rows[0]['id']}\n".encode(), b"".join(reports))
        self.assertEqual(list(target.parent.glob("to-lane.jsonl.kendex-append.*")), [])
        # The provider must pass its staged envelope to the shared guard.
        original = self.script.read_text()
        rule = 'mailbox_append_locked "$1" 30 "" "$staged"'
        self.assertEqual(original.count(rule), 1)
        self.addCleanup(self.script.write_text, original)
        self.script.write_text(original.replace(rule, rule.replace('"$staged"', '""')))
        identity = "second" if rows[0]["id"] == "first" else "first"
        repeated = (json.dumps(dict(id=identity, kind="directive", at=stamp,
                                   **{"from": "owner"}, text="one report")) + "\n").encode()
        result = self.call("append", "--item", "TEST-1", "--", str(target), data=repeated)
        self.assertEqual((result.returncode, len(target.read_bytes().splitlines())), (0, 2))

    def test_append_compares_sender_stamps_on_a_lagging_host(self):
        """Sequential UTC envelopes repeat even when the provider clock lags."""
        self.assertEqual(self.create().returncode, 0)
        library = Path(self.row["clone"]) / ".agents/skills/orch/scripts/lib/mailbox-append.sh"
        original = library.read_text()
        self.addCleanup(library.write_text, original)
        rule = '| ($candidate.at | at_epoch) as $now'
        self.assertEqual(original.count(rule), 1)
        # The control restores the provider's clock without removing the judge.
        mutant = original.replace(rule, '| 1699999999 as $now # ' + rule)
        self.assertNotEqual(mutant, original)
        target = self.root / "lane/tmp/lane-mail/TEST-1/to-lane.jsonl"
        target.parent.mkdir(parents=True)
        envelope = dict(id="first", kind="directive", at="2023-11-14T22:13:20Z",
                        **{"from": "owner"}, text="one report")
        for clock, source, expected in ((1700000000, original, (4, 1)),
                                        (1699999999, original, (4, 1)),
                                        (1699999999, mutant, (0, 2))):
            with self.subTest(clock=clock, control=source == mutant):
                self.executable(self.bin / "date", f"#!/bin/sh\nprintf '%s\\n' {clock}\n")
                library.write_text(source)
                target.write_bytes(b"")
                first = self.call("append", "--item", "TEST-1", "--", str(target),
                                  data=(json.dumps(envelope) + "\n").encode())
                self.assertEqual(first.returncode, 0, first.stderr)
                self.assertEqual(first.stderr, b"")
                self.assertEqual(target.read_bytes(), (json.dumps(envelope) + "\n").encode())
                second = self.call("append", "--item", "TEST-1", "--", str(target),
                                   data=(json.dumps(envelope) + "\n").encode())
                self.assertEqual((second.returncode, len(target.read_bytes().splitlines())), expected,
                                 second.stderr)
                if expected == (4, 1):
                    self.assertEqual(second.stderr, b"duplicate id=first\n")
        # An unconditional compatibility warning breaks the current-library row.
        original = self.script.read_text()
        rule = 'if ! declare -F mailbox_duplicate_id >/dev/null; then'
        self.assertEqual(original.count(rule), 1)
        changed = original.replace(rule, 'if true; then # ' + rule)
        self.assertNotEqual(changed, original)
        self.script.write_text(changed)
        target.write_bytes(b"")
        result = self.call("append", "--item", "TEST-1", "--", str(target), data=(json.dumps(envelope) + "\n").encode())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, f"lane-host-ssh: append-library-outdated path={library} repeat-check=skipped\n".encode())

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

    def test_append_delivers_to_an_old_but_present_library(self):
        """An existing host clone can retain append without the repeat guard."""
        self.assertEqual(self.create().returncode, 0)
        library = Path(self.row["clone"]) / ".agents/skills/orch/scripts/lib/mailbox-append.sh"
        old = library.read_text()
        # Model the old library: it accepts surplus arguments without judging them.
        for rule, replacement in (("mailbox_duplicate_id()", "legacy_duplicate_id()"),
                                  ('if [ -n "${4:-}" ]; then', 'if false; then')):
            self.assertEqual(old.count(rule), 1)
            changed = old.replace(rule, replacement)
            self.assertNotEqual(changed, old)
            old = changed
        library.write_text(old)
        target = self.root / "lane/tmp/lane-mail/TEST-1/to-lane.jsonl"
        result = self.call("append", "--item", "TEST-1", "--", str(target), data=b'{"id":"nowhere"}\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_bytes(), b'{"id":"nowhere"}\n')
        self.assertEqual(result.stderr, f"lane-host-ssh: append-library-outdated path={library} repeat-check=skipped\n".encode())
        self.assertEqual(list(target.parent.glob("*.kendex-append.*")), [])
        # Restoring the refusal loses delivery to the old host clone.
        original = self.script.read_text()
        rule = '"$lib/mailbox-append.sh" >&2\n'
        self.assertEqual(original.count(rule), 1)
        changed = original.replace(rule, rule + '  exit 1\n')
        self.assertNotEqual(changed, original)
        self.script.write_text(changed)
        result = self.call("append", "--item", "TEST-1", "--", str(target), data=b'{"id":"nowhere"}\n')
        self.assertEqual((result.returncode, target.read_bytes()), (1, b'{"id":"nowhere"}\n'))

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

    def fake_npm(self):
        """An npm that logs its call, its directory, and a project setting it
        should not see, then fills node_modules as ci does; under
        SSH_TEST_NPM_FAIL it leaves node_modules emptied, as a failed ci does,
        and exits with that status."""
        self.executable(self.bin / "npm", '''#!/usr/bin/env bash
set -euo pipefail
printf 'npm %s in %s%s\\n' "$*" "$PWD" "${WORKTREE_SYMLINKS+ project-env}" >> "$SSH_TEST_LOG"
clone=$(git rev-parse --show-toplevel)
for root in "$clone" "$clone-worktree"; do
  for name in .env.local "${SSH_TEST_PRIVATE_RELATIVE:-.env.local}" "${SSH_TEST_SECOND_PRIVATE_RELATIVE:-.env.local}" "${SSH_TEST_TARGET_RELATIVE:-.env.local}" "${SSH_TEST_COPY_RELATIVE:-.env.local}"; do
    if [[ -e "$root/$name" || -L "$root/$name" ]]; then exit 91; fi
  done
done
if [[ -n "${SECRET:-}" ]]; then exit 91; fi
rm -rf node_modules
mkdir node_modules
[[ "${SSH_TEST_NPM_FAIL:-0}" == 0 ]] || exit "$SSH_TEST_NPM_FAIL"
touch node_modules/dep
''')

    def log_since(self, mark):
        return (self.root / "calls").read_text().splitlines()[mark:]

    def install_steps(self):
        """Create through changed and unchanged lockfiles, a create the live
        worktree refuses, and a failed install; yield each step's name, its
        exit status, the installs expected, and the log lines its create
        wrote."""
        self.fake_npm()
        self.seed_source("kendex.settings.toml", '[env]\nWORKTREE_SYMLINKS = ".env.local"\n')
        (self.source / ".env.local").write_text('SECRET=private-fixture\nWORKTREE_SYMLINKS=".env.local ui/node_modules"\n')
        self.seed_source("ui/package-lock.json", '{"lockfileVersion": 3}\n')
        install = f"npm ci --no-audit --no-fund in {Path(self.row['clone']) / 'ui'}"
        # Per step: its flags, the lockfile the source commits before it
        # (None keeps the last), its environment, its exit status, and the
        # installs it runs. A create without --reuse meets the live worktree
        # and is refused before it may touch the shared node_modules; the
        # changed lockfile it synced installs at the next create that holds
        # the item. A failed install fails create and records nothing, so the
        # next create installs again.
        steps = (
            ("fresh clone", (), None, {}, 0, [install]),
            ("unchanged lockfile", ("--relaunch",), None, {}, 0, []),
            ("refused create", (), '{"lockfileVersion": 3, "changed": 1}\n', {}, 75, []),
            ("changed lockfile", ("--reuse",), None, {}, 0, [install]),
            ("unchanged again", ("--reuse",), None, {}, 0, []),
            ("failed install", ("--reuse",), '{"lockfileVersion": 3, "changed": 2}\n', {"SSH_TEST_NPM_FAIL": "7"}, 7, [install]),
            ("install after a failure", ("--reuse",), None, {}, 0, [install]),
        )
        for name, flags, lockfile, env, code, installs in steps:
            if lockfile is not None:
                self.seed_source("ui/package-lock.json", lockfile)
            mark = len(self.log_since(0)) if (self.root / "calls").exists() else 0
            result = self.create(*flags, **env)
            self.assertEqual(result.returncode, code, (name, result.stderr))
            clone = Path(self.row["clone"])
            self.assertEqual((clone / ".env.local").read_bytes(), (self.source / ".env.local").read_bytes())
            if name == "fresh clone":
                (Path(str(clone) + "-worktree") / ".env.local").symlink_to(clone / ".env.local")
            yield name, code, installs, self.log_since(mark)

    def test_create_installs_a_linked_node_modules_once_per_lockfile(self):
        """The clone, the lane's main checkout, installs what a node_modules
        entry links once create holds the item and before the final setup
        pass, without the project's settings, and again only when the
        committed lockfile changes or the last install failed."""
        for name, code, installs, log in self.install_steps():
            with self.subTest(step=name):
                self.assertEqual([line for line in log if line.startswith("npm ")], installs)
                if installs and code == 0:
                    creates = [i for i, line in enumerate(log) if line.startswith("worktree create ")]
                    self.assertLess(log.index(installs[0]), creates[-1])

    def test_control_install_can_read_a_private_env_left_in_the_clone(self):
        original = self.script.read_text()
        fragment = 'if test -e "$path" || test -L "$path"; then'
        self.assertEqual(original.count(fragment), 1)
        # Mutate only a disposable executable outside the worktree.
        with tempfile.TemporaryDirectory() as control:
            self.script = Path(control) / "lane-host-ssh"
            self.executable(self.script, original.replace(fragment, 'if false && { test -e "$path" || test -L "$path"; }; then'))
            self.assertNotEqual(self.script.read_text(), original)
            with self.assertRaises(AssertionError):
                self.test_create_installs_a_linked_node_modules_once_per_lockfile()
            exposed = self.create("--reuse")
            self.assertEqual(exposed.returncode, 91, exposed.stderr)
            self.assertFalse((Path(self.row["clone"]) / "ui/node_modules/.lane-host-install").exists())

    def private_install_cases(self):
        """Exercise files present in reused clones, including copies made by
        the first worktree setup pass before npm starts."""
        self.fake_npm()
        relative = "config/private file.env"
        second_relative = "config/worktree.env"
        wt = self.source / ".agents/skills/worktree/scripts/worktree"
        original = wt.read_text()
        fragment = '  printf \'%s\\n\' "$path" ;;'
        self.assertEqual(original.count(fragment), 1)
        provisioning = '''  if [[ "${SSH_TEST_PROVISION_PRIVATE:-}" == copy ]]; then
    for name in .env.local "$SSH_TEST_PRIVATE_RELATIVE" "${SSH_TEST_SECOND_PRIVATE_RELATIVE:-.env.local}"; do
      if [[ -f "$PWD/$name" ]]; then
        mkdir -p -- "$(dirname -- "$path/$name")"
        cp -p -- "$PWD/$name" "$path/$name"
      fi
    done
  elif [[ ( "${SSH_TEST_PROVISION_PRIVATE:-}" == relative || "${SSH_TEST_PROVISION_PRIVATE:-}" == alias-copy ) && -f "$PWD/shared.env" ]]; then
    "$PWD/.agents/skills/worktree/scripts/provision" fix-links "$path" >&2
  fi
'''
        self.seed_source(str(wt.relative_to(self.source)), original.replace(fragment, provisioning + fragment))
        # Use the shipped copy and relative-link producer for that table row.
        provision_script = ".agents/skills/worktree/scripts/provision"
        self.executable(self.source / provision_script, (PACKAGE.parent / "worktree/scripts/worktree").read_text())
        self.seed_source(provision_script, (self.source / provision_script).read_text())
        for library in (PACKAGE.parent / "worktree/scripts/lib").glob("*.sh"):
            if library.name != "kendex-env.sh":
                self.seed_source(f".agents/skills/worktree/scripts/lib/{library.name}", library.read_text())
        self.seed_source(".gitignore", ".env.local\nconfig/\nalias\n.cache/\ntmp/\n")
        rows = (
            ("root settings", "root", "none", 0, False),
            ("nested settings with copies", "nested", "copy", 0, False),
            ("parent selector with copies and failed npm", "parent", "copy", 7, False),
            ("linked private files", "root", "link", 0, False),
            ("private file changes the selector", "root", "copy", 0, True),
            ("different clone and worktree selectors", "divergent", "copy", 0, False),
            ("different selectors with failed npm", "divergent", "copy", 7, False),
            ("shipped copy and relative link", "root", "relative", 0, False),
            ("shipped copy and relative link with failed npm", "root", "relative", 7, False),
            ("named link with a different target", "root", "target-link", 0, False),
            ("shipped copy through a directory alias", "root", "alias-copy", 0, False),
            ("directory-alias copy with failed npm", "root", "alias-copy", 7, False),
        )
        for index, (name, selector, provision, status, changes_selector) in enumerate(rows):
            chosen_name = ".env.local" if provision == "relative" else relative
            if provision == "alias-copy":
                chosen_name = "config/private.env"
            settings = f'[env]\nWORKTREE_SYMLINKS = ".env.local ui/node_modules"\nINSTALL_CASE = "{index}"\n'
            if provision == "relative":
                settings = (f'[env]\nWORKTREE_SYMLINKS = "ui/node_modules"\nINSTALL_CASE = "{index}"\n'
                            'WORKTREE_COPIES = "shared.env"\nWORKTREE_RELATIVE_SYMLINKS = ".env.local=shared.env"\n')
            elif provision == "alias-copy":
                settings = (f'[env]\nWORKTREE_SYMLINKS = "ui/node_modules"\nINSTALL_CASE = "{index}"\n'
                            'WORKTREE_COPIES = ".env.local config/private.env alias/shared.env"\n')
            selection = f'KENDEX_ENV_FILE = "{chosen_name}"\n'
            self.seed_source("kendex.settings.toml", settings + (selection if selector in ("root", "divergent") else ""))
            self.seed_source(".kendex/settings.toml", f'[env]\nINSTALL_CASE = "{index}"\n' + (selection if selector == "nested" else ""))
            self.seed_source("ui/package-lock.json", '{"lockfileVersion": 3}\n')
            self.row["clone"] = str(self.root / f"private-clone-{index}")
            self.inventory.write_text(json.dumps([self.row]))
            env = {"SSH_TEST_PRIVATE_RELATIVE": chosen_name, "SSH_TEST_PROVISION_PRIVATE": provision}
            if selector == "divergent":
                env["SSH_TEST_SECOND_PRIVATE_RELATIVE"] = second_relative
            if selector == "parent":
                env["KENDEX_ENV_FILE"] = relative
            made = self.create(**env)
            self.assertEqual(made.returncode, 0, (name, made.stderr))
            clone = Path(self.row["clone"])
            tree = Path(str(clone) + "-worktree")
            chosen = clone / chosen_name
            chosen.parent.mkdir(exist_ok=True)
            contents = b"SECRET=named-private-fixture\n"
            if provision == "relative":
                contents = (self.source / ".env.local").read_bytes()
            if changes_selector:
                contents += b"KENDEX_ENV_FILE=config/changed.env\n"
            if provision in ("relative", "target-link", "alias-copy"):
                target = clone / "shared.env"
                target.write_bytes(contents)
                target.chmod(0o600)
                if provision in ("target-link", "alias-copy"):
                    if chosen.exists():
                        chosen.unlink()
                    chosen.symlink_to(os.path.relpath(target, chosen.parent))
                env["SSH_TEST_TARGET_RELATIVE"] = "shared.env"
                if provision == "alias-copy":
                    (clone / "alias").symlink_to(".", target_is_directory=True)
                    env["SSH_TEST_COPY_RELATIVE"] = "alias/shared.env"
                if provision == "target-link":
                    shutil.copy2(target, tree / "shared.env")
                    copied = tree / chosen_name
                    copied.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(target, copied)
            else:
                chosen.write_bytes(contents)
                chosen.chmod(0o600)
            private_names = tuple(dict.fromkeys((".env.local", chosen_name)))
            if provision in ("relative", "target-link", "alias-copy"):
                private_names += ("shared.env",)
            if selector == "divergent":
                # The clone advances its settings while the reused tree keeps its selection.
                self.seed_source("kendex.settings.toml", settings + f'KENDEX_ENV_FILE = "{second_relative}"\n')
                private_names += (second_relative,)
                (clone / second_relative).write_bytes(b"SECRET=second-private-fixture\n")
                (clone / second_relative).chmod(0o640)
                for private_name in private_names:
                    target = tree / private_name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(clone / private_name, target)
            if provision == "link":
                for private_name in (".env.local", relative):
                    link = tree / private_name
                    link.parent.mkdir(parents=True, exist_ok=True)
                    link.symlink_to(clone / private_name)
            self.seed_source("ui/package-lock.json", '{"lockfileVersion": 3, "changed": 1}\n')
            expected = {private_name: ((clone / private_name).read_bytes(), (clone / private_name).stat().st_mode)
                        for private_name in private_names}
            expected_links = {private_name: os.readlink(clone / private_name)
                              for private_name in private_names if (clone / private_name).is_symlink()}
            mark = len(self.log_since(0))
            installed = self.create("--reuse", **env, SSH_TEST_NPM_FAIL=str(status))
            self.assertEqual(installed.returncode, status, (name, installed.stderr))
            calls = [line for line in self.log_since(mark) if line.startswith("npm ")]
            self.assertEqual(calls, [f"npm ci --no-audit --no-fund in {clone / 'ui'}"])
            for private_name in private_names:
                original_file = clone / private_name
                self.assertEqual((original_file.read_bytes(), original_file.stat().st_mode), expected[private_name])
                self.assertEqual(original_file.is_symlink(), private_name in expected_links)
                if private_name in expected_links:
                    self.assertEqual(os.readlink(original_file), expected_links[private_name])
                if provision != "none" and (provision != "target-link" or private_name != ".env.local") and (provision != "alias-copy" or private_name != "shared.env"):
                    restored = tree / private_name
                    self.assertEqual(restored.read_bytes(), original_file.read_bytes())
                    linked = provision == "link" or (provision == "relative" and private_name == chosen_name)
                    self.assertEqual(restored.is_symlink(), linked)
                    if provision == "link":
                        self.assertEqual(os.readlink(restored), str(original_file))
                    elif linked:
                        self.assertEqual(os.readlink(restored), os.path.relpath(tree / "shared.env", restored.parent))
                    else:
                        self.assertEqual(restored.stat().st_mode, original_file.stat().st_mode)
            self.assertEqual(chosen.stat().st_mode & 0o777, 0o600)
            if provision == "alias-copy":
                copied = tree / "alias/shared.env"
                self.assertFalse(copied.is_symlink())
                self.assertEqual(copied.read_bytes(), contents)
                self.assertEqual(copied.stat().st_mode & 0o777, 0o600)
                self.assertEqual(os.readlink(clone / "alias"), ".")
            self.assertEqual((clone / "ui/node_modules/.lane-host-install").exists(), status == 0)

    def test_install_hides_selected_private_files_and_worktree_copies(self):
        self.private_install_cases()

    def test_control_install_leaving_selected_targets_exposes_credentials(self):
        original = self.script.read_text()
        fragment = '      target=$(readlink -- "$path") || return 1'
        self.assertEqual(original.count(fragment), 1)
        with tempfile.TemporaryDirectory() as control:
            self.script = Path(control) / "lane-host-ssh"
            self.executable(self.script, original.replace(fragment, '      return 0'))
            self.assertNotEqual(self.script.read_text(), original)
            with self.assertRaises(AssertionError):
                self.private_install_cases()

    def test_control_install_leaving_directory_alias_copies_exposes_credentials(self):
        original = self.script.read_text()
        fragment = 'if test "$copy_root/$copy" -ef "$path"; then'
        self.assertEqual(original.count(fragment), 1)
        with tempfile.TemporaryDirectory() as control:
            self.script = Path(control) / "lane-host-ssh"
            self.executable(self.script, original.replace(fragment, 'if false; then'))
            self.assertNotEqual(self.script.read_text(), original)
            with self.assertRaises(AssertionError):
                self.private_install_cases()

    def test_install_refuses_private_targets_outside_both_checkouts(self):
        self.fake_npm()
        self.seed_source("kendex.settings.toml", '[env]\nWORKTREE_SYMLINKS = "ui/node_modules"\nKENDEX_ENV_FILE = "config/selected.env"\n')
        self.seed_source("ui/package-lock.json", '{"lockfileVersion": 3}\n')
        made = self.create()
        self.assertEqual(made.returncode, 0, made.stderr)
        clone = Path(self.row["clone"])
        outside = self.root / "outside.env"
        outside.write_bytes(b"SECRET=outside-fixture\n")
        outside.chmod(0o600)
        selected = clone / "config/selected.env"
        selected.parent.mkdir()
        # The spelling starts in the clone, but its final directory is outside.
        selected.symlink_to(str(clone / ".." / outside.name))
        mark = len(self.log_since(0))
        result = self.create("--reuse")
        self.assertEqual(result.returncode, 1, result.stderr)
        fields = [line.split() for line in result.stderr.splitlines()
                  if line.startswith(b"lane-host-ssh: private-protection-unsafe ")]
        self.assertEqual(fields, [[b"lane-host-ssh:", b"private-protection-unsafe",
                                  f"path={outside}".encode(), b"cause=outside-roots"]])
        self.assertTrue(selected.is_symlink())
        self.assertEqual(outside.read_bytes(), b"SECRET=outside-fixture\n")
        self.assertEqual(outside.stat().st_mode & 0o777, 0o600)
        self.assertEqual([line for line in self.log_since(mark) if line.startswith("npm ")], [])

    def test_control_install_without_containment_moves_an_outside_target(self):
        original = self.script.read_text()
        fragment = 'if test "$contained" != true; then'
        self.assertEqual(original.count(fragment), 1)
        with tempfile.TemporaryDirectory() as control:
            self.script = Path(control) / "lane-host-ssh"
            self.executable(self.script, original.replace(fragment, 'if false; then'))
            self.assertNotEqual(self.script.read_text(), original)
            with self.assertRaises(AssertionError):
                self.test_install_refuses_private_targets_outside_both_checkouts()

    def test_install_refuses_unprotectable_default_paths_with_controls(self):
        self.fake_npm()
        self.seed_source("kendex.settings.toml", '[env]\nWORKTREE_SYMLINKS = "ui/node_modules"\nKENDEX_ENV_FILE = "config/selected.env"\n')
        self.seed_source("ui/package-lock.json", '{"lockfileVersion": 3}\n')
        made = self.create()
        self.assertEqual(made.returncode, 0, made.stderr)
        tree = Path(self.row["clone"] + "-worktree")
        default = tree / ".env.local"
        original = self.script.read_text()
        # Relative-link provisioning can leave an unresolved link or a cycle.
        # A retained directory cannot be protected as a private settings file.
        rows = (("unresolved-link", "missing.env"), ("link-cycle", ".env.local"), ("not-file", None))
        for cause, target in rows:
            with self.subTest(cause=cause):
                if target is None:
                    default.mkdir()
                else:
                    default.symlink_to(target)
                result = self.create("--reuse")
                self.assertEqual(result.returncode, 1, result.stderr)
                fields = [line.split() for line in result.stderr.splitlines()
                          if line.startswith(b"lane-host-ssh: private-protection-unsafe ")]
                refused_path = tree / target if cause == "unresolved-link" else default
                self.assertEqual(fields, [[b"lane-host-ssh:", b"private-protection-unsafe",
                                          *f"path={refused_path}".encode().split(), f"cause={cause}".encode()]])
                indent = "      " if cause == "not-file" else "        "
                fragment = f"cause={cause}\\\\n' \"$path\" >&2\n{indent}return 1"
                self.assertEqual(original.count(fragment), 1)
                with tempfile.TemporaryDirectory() as control:
                    mutant = Path(control) / "lane-host-ssh"
                    self.executable(mutant, original.replace(fragment, fragment.replace("return 1", "return 0")))
                    self.assertNotEqual(mutant.read_text(), original)
                    script = self.script
                    self.script = mutant
                    try:
                        control_result = self.create("--reuse")
                    finally:
                        self.script = script
                    self.assertEqual(control_result.returncode, 0, control_result.stderr)
                    with self.assertRaises(AssertionError):
                        self.assertEqual(control_result.returncode, 1, control_result.stderr)
                if target is None:
                    default.rmdir()
                else:
                    self.assertEqual(os.readlink(default), target)
                    default.unlink()

    def test_control_install_hiding_only_default_private_names_exposes_the_selected_file(self):
        original = self.script.read_text()
        fragment = 'if test -e "$path" || test -L "$path"; then'
        self.assertEqual(original.count(fragment), 1)
        with tempfile.TemporaryDirectory() as control:
            self.script = Path(control) / "lane-host-ssh"
            self.executable(self.script, original.replace(fragment,
                'if [[ "$path" == */.env.local ]] && { test -e "$path" || test -L "$path"; }; then'))
            self.assertNotEqual(self.script.read_text(), original)
            with self.assertRaises(AssertionError):
                self.test_install_hides_selected_private_files_and_worktree_copies()
            exposed = self.create("--reuse", SSH_TEST_PRIVATE_RELATIVE="config/private file.env")
            self.assertEqual(exposed.returncode, 91, exposed.stderr)

    def test_control_install_hiding_only_clone_files_exposes_worktree_copies(self):
        original = self.script.read_text()
        fragment = '  roots+=("$tree")'
        self.assertEqual(original.count(fragment), 1)
        with tempfile.TemporaryDirectory() as control:
            self.script = Path(control) / "lane-host-ssh"
            self.executable(self.script, original.replace(fragment, ': # ' + fragment.strip()))
            self.assertNotEqual(self.script.read_text(), original)
            with self.assertRaises(AssertionError):
                self.test_install_hides_selected_private_files_and_worktree_copies()
            exposed = self.create("--reuse", SSH_TEST_PRIVATE_RELATIVE="config/private file.env",
                                  SSH_TEST_PROVISION_PRIVATE="copy")
            self.assertEqual(exposed.returncode, 91, exposed.stderr)

    def test_control_install_ignoring_one_selected_name_exposes_its_clone_copy(self):
        original = self.script.read_text()
        fragment = '  private_names+=("${selected[1]}")'
        self.assertEqual(original.count(fragment), 1)
        with tempfile.TemporaryDirectory() as control:
            self.script = Path(control) / "lane-host-ssh"
            self.executable(self.script, original.replace(fragment, ': # ' + fragment.strip()))
            self.assertNotEqual(self.script.read_text(), original)
            with self.assertRaises(AssertionError):
                self.private_install_cases()
            exposed = self.create("--reuse", SSH_TEST_PRIVATE_RELATIVE="config/private file.env",
                                  SSH_TEST_SECOND_PRIVATE_RELATIVE="config/worktree.env",
                                  SSH_TEST_PROVISION_PRIVATE="copy")
            self.assertEqual(exposed.returncode, 91, exposed.stderr)

    def test_install_refuses_a_remote_loader_without_selected_path_output(self):
        loader = self.source / ".agents/skills/worktree/scripts/lib/kendex-env.sh"
        original = loader.read_text()
        capability = '''kendex_project_env_supports() { # CAPABILITY
  [[ "$1" == selected-private-path ]]
}
'''
        output = '''  if [[ -n "${2:-}" ]]; then
    printf -v "$2" '%s' "$_kendex_private_file"
  fi
'''
        self.assertEqual(original.count(capability), 1)
        self.assertEqual(original.count(output), 1)
        old_loader = original.replace(capability, "").replace(output, "")
        self.fake_npm()
        self.seed_source("kendex.settings.toml", '[env]\nWORKTREE_SYMLINKS = "ui/node_modules"\nKENDEX_ENV_FILE = "config/private.env"\n')
        self.seed_source("ui/package-lock.json", '{"lockfileVersion": 3}\n')
        for capability_body, collision in (("", "selected_private=.env.local\n"), ("", ""),
                                           (capability.replace('[[ "$1" == selected-private-path ]]', "return 1"),
                                            "selected_private=.env.local\n")):
            if loader.read_text() != old_loader + capability_body:
                self.seed_source(str(loader.relative_to(self.source)), old_loader + capability_body)
            self.seed_source("config/private.env", collision + 'touch "$SSH_TEST_LOADER_MARKER"\n')
            self.row["clone"] = str(self.root / f"old-loader-{time.time_ns()}")
            self.inventory.write_text(json.dumps([self.row]))
            marker = self.root / "project-settings-loaded"
            result = self.create(SSH_TEST_LOADER_MARKER=str(marker),
                                 **{"BASH_FUNC_kendex_project_env_supports%%": "() { return 0; }"})
            self.assertEqual(result.returncode, 1, result.stderr)
            remote_loader = Path(self.row["clone"]) / loader.relative_to(self.source)
            fields = [line.split() for line in result.stderr.splitlines()
                      if line.startswith(b"lane-host-ssh: loader-private-path-missing ")]
            # The control plane consumes this stable capability diagnostic.
            self.assertEqual(fields, [[b"lane-host-ssh:", b"loader-private-path-missing",
                                      *f"path={remote_loader}".encode().split(), b"output=selected-private-path"]])
            self.assertFalse(marker.exists())
            self.assertEqual([line for line in self.log_since(0) if line.startswith("npm ")], [])

    def test_control_missing_loader_output_loses_the_capability_diagnostic(self):
        original = self.script.read_text()
        fragment = '''if ! declare -F kendex_project_env_supports >/dev/null ||
     ! kendex_project_env_supports selected-private-path; then'''
        self.assertEqual(original.count(fragment), 1)
        with tempfile.TemporaryDirectory() as control:
            self.script = Path(control) / "lane-host-ssh"
            self.executable(self.script, original.replace(fragment, 'if false; then'))
            self.assertNotEqual(self.script.read_text(), original)
            with self.assertRaises(AssertionError):
                self.test_install_refuses_a_remote_loader_without_selected_path_output()

    def test_control_install_without_its_lockfile_marker_runs_every_create(self):
        original = self.script.read_text()
        fragment = 'if test "$installed" = "$blob"; then continue; fi'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, ""))
        unchanged = {name: log for name, _, _, log in self.install_steps()}["unchanged lockfile"]
        self.assertTrue(any(line.startswith("npm ") for line in unchanged))

    def test_create_installs_nothing_an_entry_does_not_ask_for(self):
        """No node_modules entry, or one with no committed lockfile, runs no
        install; the second names the lockfile it found missing."""
        # Per row: the WORKTREE_SYMLINKS value, and the key line create prints.
        rows = (
            (".env.local", None),
            (".env.local ui/node_modules",
             b"lane-host-ssh: dependency-install-skipped path=ui/package-lock.json cause=no-committed-lockfile"),
        )
        self.fake_npm()
        self.seed_source("package-lock.json", '{"lockfileVersion": 3}\n')
        for n, (links, line) in enumerate(rows):
            with self.subTest(links=links):
                self.seed_source("kendex.settings.toml", f'[env]\nWORKTREE_SYMLINKS = "{links}"\n')
                self.row["clone"] = str(self.root / f"clone-{n}")
                self.inventory.write_text(json.dumps([self.row]))
                result = self.create()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([call for call in self.log_since(0) if call.startswith("npm ")], [])
                keyed = [entry for entry in result.stderr.splitlines() if entry.startswith(b"lane-host-ssh: dependency-install")]
                self.assertEqual(keyed, [] if line is None else [line])

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

    def test_relaunch_opens_origin_only_landing_branch(self):
        """A cloud handoff pushes its branch before a static host has a tree."""
        scripts = self.source / ".agents/skills/worktree/scripts"
        shutil.copytree(PACKAGE.parent / "worktree/scripts", scripts, dirs_exist_ok=True)
        shutil.copytree(PACKAGE.parent / "github/scripts", self.source / ".agents/skills/github/scripts",
                        dirs_exist_ok=True)
        # The installed helper must admit each GitHub network operation. The
        # Git stub supplies a local transport only after its HTTPS auth config.
        self.executable(self.bin / "git", '''#!/usr/bin/env bash
set -euo pipefail
network=false
credential=false
rewrite=false
for arg in "$@"; do
  case "$arg" in
    fetch|ls-remote) network=true ;;
    'credential.helper=!gh auth git-credential') credential=true ;;
    'url.https://github.com/.insteadOf=git@github.com:') rewrite=true ;;
  esac
done
if [[ "$network" == true ]]; then
  [[ "$credential" == true && "$rewrite" == true ]] || exit 19
  printf 'authenticated-git %s\\n' "$*" >> "$SSH_TEST_LOG"
  exec "$REAL_GIT" -c "url.$SSH_TEST_SOURCE.insteadOf=git@github.com:owner/repo" "$@"
fi
exec "$REAL_GIT" "$@"
''')
        self.executable(self.bin / "gh", '''#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == auth && "$2" == status ]]; then exit 0; fi
if [[ "$1" == repo && "$2" == view ]]; then printf 'owner/repo\\n'; exit 0; fi
if [[ "$1" == pr && "$2" == list ]]; then exit 0; fi
exit 9
''')
        self.seed_source("kendex.settings.toml", '[env]\nWORKTREE_DEFAULT_BRANCH = "main"\nWORKTREE_SYMLINKS = ".env.local .agents"\n')
        git = [self.env["REAL_GIT"], "-C", str(self.source)]
        for args in (("config", "gc.auto", "0"), ("config", "maintenance.auto", "false"),
                     ("branch", "-M", "main"), ("add", ".agents"),
                     ("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "real worktree fixture"),
                     ("checkout", "-qb", "test-1")):
            subprocess.run([*git, *args], check=True, capture_output=True)
        self.seed_source("cloud-change", "cloud landing\n")
        head = subprocess.run([*git, "rev-parse", "HEAD"], check=True, capture_output=True).stdout
        subprocess.run([*git, "checkout", "-q", "main"], check=True, capture_output=True)
        clone = Path(self.row["clone"])
        subprocess.run([self.env["REAL_GIT"], "clone", "-q", str(self.source), str(clone)],
                       check=True, capture_output=True)
        clone_git = [self.env["REAL_GIT"], "-C", str(clone)]
        for key, value in (("gc.auto", "0"), ("maintenance.auto", "false")):
            subprocess.run([*clone_git, "config", key, value], check=True, capture_output=True)
        subprocess.run([*clone_git, "remote", "set-url", "origin", "git@github.com:owner/repo"],
                       check=True, capture_output=True)
        self.assertEqual(subprocess.run([*clone_git, "show-ref", "--verify", "--quiet", "refs/heads/test-1"],
                                        capture_output=True).returncode, 1)
        self.assertEqual(subprocess.run([*clone_git, "rev-parse", "refs/remotes/origin/test-1"],
                                        check=True, capture_output=True).stdout, head)
        self.assertFalse((clone / ".git/lane-host-item").exists())
        self.assertEqual(subprocess.run([*clone_git, "worktree", "list", "--porcelain"],
                                        check=True, capture_output=True).stdout.count(b"worktree "), 1)

        original = self.script.read_text()
        admission = 'return ["--base", branch] if existing.returncode == 0 else []'
        self.assertEqual(original.count(admission), 1)
        self.script.write_text(original.replace(admission, "return []"))
        self.assertNotEqual(self.script.read_text(), original)
        refused = self.create("--relaunch")
        self.assertEqual((refused.returncode, refused.stdout), (75, b""), refused.stderr)
        self.assertFalse((clone / ".git/lane-host-item").exists())
        self.script.write_text(original)

        probe = '\"$1/.agents/skills/github/scripts/git-https-auth\" -C \"$1\" ls-remote'
        self.assertEqual(original.count(probe), 1)
        self.script.write_text(original.replace(probe, 'git -C "$1" ls-remote'))
        self.assertNotEqual(self.script.read_text(), original)
        unauthenticated = self.create("--relaunch")
        self.assertEqual((unauthenticated.returncode, unauthenticated.stdout), (19, b""),
                         unauthenticated.stderr)
        self.assertFalse((clone / ".git/lane-host-item").exists())
        self.script.write_text(original)

        result = self.create("--relaunch")
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(dict(field.split("=", 1) for field in result.stdout.decode().strip().split("\t"))["path"])
        for args, expected in ((("branch", "--show-current"), b"test-1\n"), (("rev-parse", "HEAD"), head)):
            self.assertEqual(subprocess.run([self.env["REAL_GIT"], "-C", str(path), *args],
                                            check=True, capture_output=True).stdout, expected)
        self.assertEqual((path / "cloud-change").read_text(), "cloud landing\n")
        authenticated = [line.split() for line in self.log_since(0) if line.startswith("authenticated-git ")]
        self.assertTrue(any("ls-remote" in words and "--exit-code" in words and "refs/heads/test-1" in words
                            for words in authenticated), authenticated)
        self.assertEqual(subprocess.run([*clone_git, "config", "--get", "remote.origin.url"],
                                        check=True, capture_output=True).stdout, b"git@github.com:owner/repo\n")

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
    def test_status_reads_the_owned_harness_and_refuses_failed_reads(self):
        self.assertEqual(self.create().returncode, 0)
        shutil.copy2(shutil.which("bash"), self.bin / "claude")
        lane = subprocess.Popen([str(self.bin / "claude"), "-c", "printf 'ready\\n'; read -r line"],
                                cwd=Path(self.row["clone"] + "-worktree"), env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        try:
            self.assertEqual(lane.stdout.readline(), b"ready\n")
            for harness, expected in (("claude", b"running\n"), ("codex", b"exited\n")):
                with self.subTest(harness=harness):
                    result = self.call("status", "--item", "TEST-1", "--harness", harness)
                    self.assertEqual((result.returncode, result.stdout, lane.poll()), (0, expected, None), result.stderr)
            original = self.script.read_text()
            rule = 'if test -n "$LANE_OWNED_PROCESS_PIDS"; then printf'
            self.assertEqual(original.count(rule), 1)
            self.script.write_text(original.replace(rule, rule.replace("test -n", "test -z")))
            self.assertNotEqual(self.call("status", "--item", "TEST-1", "--harness", "claude").stdout, b"running\n")
            self.script.write_text(original)
        finally:
            lane.stdin.close()
            lane.stdout.close()
            lane.wait(timeout=2)
        self.assertEqual(self.call("status", "--item", "TEST-1", "--harness", "claude").stdout, b"exited\n")
        library = Path(self.row["clone"]) / ".agents/skills/orch/scripts/lib/lane-state.sh"
        library.write_text(library.read_text() + '\nlane_owned_processes() { return 2; }\n')
        for env in ({}, {"SSH_TEST_FAIL": "7"}):
            result = self.call("status", "--item", "TEST-1", "--harness", "claude", **env)
            self.assertEqual((result.returncode != 0, result.stdout), (True, b""), (env, result.stderr))

    @unittest.skipUnless(sys.platform.startswith("linux"), "deleted cwd integration requires procfs")
    def test_status_follows_the_launch_root_through_merge_cleanup(self):
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        worktree = Path(self.row["clone"] + "-worktree")
        shutil.copy2(shutil.which("bash"), self.bin / "claude")
        lane = subprocess.Popen([str(self.bin / "claude"), "-c", "printf 'ready\\n'; read -r line"],
                                cwd=worktree, env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        library = clone / ".agents/skills/orch/scripts/lib/lane-state.sh"
        original = library.read_text()
        try:
            self.assertEqual(lane.stdout.readline(), b"ready\n")
            # merge-pr removes the registered tree before its harness exits.
            subprocess.run([self.env["REAL_GIT"], "-C", str(clone), "worktree", "remove", "--force", str(worktree)],
                           check=True, capture_output=True, env=self.env)
            result = self.call("status", "--item", "TEST-1", "--harness", "claude")
            self.assertEqual((result.returncode, result.stdout, lane.poll()), (0, b"running\n", None), result.stderr)
            controls = (
                ('launch-record) root="$1";', 'launch-record) root="$(cd -- "$1" && pwd -P)" || return 2;'),
                ('"$cwd" == "$root (deleted)"', '"$cwd" == "$root"'),
            )
            for old, new in controls:
                self.assertEqual(original.count(old), 1)
                library.write_text(original.replace(old, new))
                mutant = self.call("status", "--item", "TEST-1", "--harness", "claude")
                self.assertNotEqual((mutant.returncode, mutant.stdout), (0, b"running\n"), mutant.stderr)
            for failure in ('lane_process_table() { return 1; }', 'lane_process_cwd() { return 1; }'):
                library.write_text(original + '\n' + failure + '\n')
                failed = self.call("status", "--item", "TEST-1", "--harness", "claude")
                self.assertEqual((failed.returncode, failed.stdout), (1, b""), failed.stderr)
            library.write_text(original)
        finally:
            library.write_text(original)
            lane.stdin.close()
            lane.stdout.close()
            lane.wait(timeout=2)
        exited = self.call("status", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((exited.returncode, exited.stdout), (0, b"exited\n"), exited.stderr)
        marker = clone / ".git/lane-mail/test-1"
        marker.unlink()
        unknown = self.call("status", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((unknown.returncode, unknown.stdout), (1, b""), unknown.stderr)
        marker.write_text(str(worktree) + '\n')
        closed = self.call("close", "--item", "TEST-1", "--merged")
        self.assertEqual(closed.returncode, 0, closed.stderr)
        self.assertEqual(self.call("list").stdout, b"owner/repo/TEST-1\tavailable\t-\tlane.example\n")

    def launch_lane(self, on_term="exit 0", name="codex"):
        """A codex lane started through its create's own prefix, a process named NAME in the worktree.

        The prefix records the launch identity of the shell it execs into the
        harness, so the returned process's pid is the one recorded. The harness
        waits in a builtin read on a FIFO nothing writes, never forking: a
        forked child is named for the harness until it execs, and a stop that
        reads the process table then counts it beside the harness."""
        created = self.create(harness="codex")
        self.assertEqual(created.returncode, 0, created.stderr)
        prefix = dict(word.split("=", 1) for word in created.stdout.decode().strip().split("\t"))["remote-prefix"]
        shutil.copy2(shutil.which("bash"), self.bin / name)
        (self.bin / name).chmod(0o755)
        idle = self.root / f"{name}-idle"
        os.mkfifo(idle)
        command = (f"cd {shlex.quote(self.row['clone'] + '-worktree')} && exec {shlex.quote(str(self.bin / name))} -c "
                   + shlex.quote(f"exec 3<>{shlex.quote(str(idle))}; trap {shlex.quote(on_term)} TERM; printf 'ready\\n'; "
                                 "while :; do read -r -t 0.1 -u 3 _; done"))
        lane = subprocess.Popen(["bash", "-c", prefix + " " + shlex.quote(command)],
                                env={**self.env, "HOME": str(self.root)}, stdout=subprocess.PIPE)
        self.addCleanup(lane.wait, 2)
        self.addCleanup(lambda: lane.poll() is None and lane.kill())
        self.addCleanup(lane.stdout.close)
        self.assertEqual(lane.stdout.readline(), b"ready\n")
        return lane

    @unittest.skipUnless(sys.platform.startswith("linux"), "provider stop integration requires procfs")
    def test_stop_without_an_identity_signals_only_the_named_harness_in_the_owned_worktree(self):
        # A lane launched before its prefix recorded an identity holds none,
        # as a create whose prefix nothing ran does: stop finds its harness by
        # the worktree, as every stop did before identities were recorded.
        self.assertEqual(self.create().returncode, 0)
        self.assertFalse((Path(self.row["clone"]) / ".git/lane-host-pid").exists())
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
        guard = """if ! test -d "$1"; then
  printf 'lane-host-ssh: stop-worktree-removed item=%s\\n' "$4" >&2
  exit 4
fi
"""
        self.assertEqual(original.count(guard), 1)
        self.script.write_text(original.replace(guard, ""))
        mutant = self.call("stop", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((mutant.returncode, b"stop-worktree-read-failed item=TEST-1" in mutant.stderr),
                         (1, True), mutant.stderr)

    @unittest.skipUnless(sys.platform.startswith("linux"), "provider stop integration requires procfs")
    def test_stop_signals_the_recorded_harness(self):
        lane = self.launch_lane()
        identity = Path(self.row["clone"]) / ".git/lane-host-pid"
        self.assertEqual(identity.read_text().split(" ", 1)[0], str(lane.pid))
        outside = subprocess.Popen([str(self.bin / "codex"), "-c", "trap 'exit 0' TERM; while :; do sleep 0.1; done"],
                                   cwd=Path(self.row["clone"] + "-worktree"), env=self.env)
        self.addCleanup(outside.wait, 2)
        self.addCleanup(lambda: outside.poll() is None and outside.kill())
        other = self.call("stop", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((other.returncode, other.stdout, lane.poll()),
                         (0, b"stopped item=TEST-1 processes=0\n", None), other.stderr)
        stopped = self.call("stop", "--item", "TEST-1", "--harness", "codex")
        self.assertEqual((stopped.returncode, stopped.stdout), (0, b"stopped item=TEST-1 processes=1\n"), stopped.stderr)
        lane.wait(timeout=2)
        self.assertIsNone(outside.poll())
        # The recorded harness gone, its identity is stale: the stop says so
        # and takes the worktree rule, which finds the harness left there.
        gone = self.call("stop", "--item", "TEST-1", "--harness", "codex")
        self.assertEqual((gone.returncode, gone.stdout, f"stop-identity-stale item=TEST-1 pid={lane.pid}\n".encode() in gone.stderr),
                         (0, b"stopped item=TEST-1 processes=1\n", True), gone.stderr)
        outside.wait(timeout=2)

    @unittest.skipUnless(sys.platform.startswith("linux"), "provider stop integration requires procfs")
    def test_stop_signals_the_recorded_harness_after_its_worktree_is_gone(self):
        # merge-pr removes the item's worktree before its lane goes idle, and a
        # later create may make a tree at the same path: neither hides the
        # recorded harness. The control is the removed-worktree guard the
        # stop once ran, put back into a copy of the script.
        lane = self.launch_lane()
        worktree = Path(self.row["clone"] + "-worktree")
        subprocess.run([self.env["REAL_GIT"], "-C", self.row["clone"], "worktree", "remove", "--force", str(worktree)],
                       check=True, capture_output=True)
        original = self.script.read_text()
        anchor = '''owned(row, item, "stop")
    result = remote(row, \'\'\''''
        self.assertEqual(original.count(anchor), 1)
        self.script.write_text(original.replace(anchor, anchor + '''if ! test -d "$2-worktree"; then
  printf 'lane-host-ssh: stop-worktree-removed item=%s\\\\n' "$3" >&2
  exit 4
fi
'''))
        mutant = self.call("stop", "--item", "TEST-1", "--harness", "codex")
        self.assertEqual((mutant.returncode, b"stop-worktree-removed item=TEST-1\n" in mutant.stderr, lane.poll()),
                         (4, True, None), mutant.stderr)
        self.script.write_text(original)
        worktree.mkdir()
        stopped = self.call("stop", "--item", "TEST-1", "--harness", "codex")
        self.assertEqual((stopped.returncode, stopped.stdout), (0, b"stopped item=TEST-1 processes=1\n"), stopped.stderr)
        lane.wait(timeout=2)

    @unittest.skipUnless(sys.platform.startswith("linux"), "provider stop integration requires procfs")
    def test_stop_leaves_a_pid_that_started_at_another_time(self):
        # The pid now names a later process: it is never signalled by the
        # identity, and the worktree rule then answers for the lane, here a
        # worktree its close-out removed.
        lane = self.launch_lane()
        identity = Path(self.row["clone"]) / ".git/lane-host-pid"
        identity.write_text(f"{lane.pid} Thu Jan 1 00:00:00 1970\n")
        worktree = Path(self.row["clone"] + "-worktree")
        subprocess.run([self.env["REAL_GIT"], "-C", self.row["clone"], "worktree", "remove", "--force", str(worktree)],
                       check=True, capture_output=True)
        reused = self.call("stop", "--item", "TEST-1", "--harness", "codex")
        self.assertEqual((reused.returncode, reused.stdout, f"stop-identity-stale item=TEST-1 pid={lane.pid}\n".encode() in reused.stderr,
                          b"stop-worktree-removed item=TEST-1\n" in reused.stderr, lane.poll()),
                         (4, b"", True, True, None), reused.stderr)

    def test_stop_refuses_an_identity_it_cannot_use(self):
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        identity = clone / ".git/lane-host-pid"
        identity.write_text("not-a-pid\n")
        invalid = self.call("stop", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((invalid.returncode, invalid.stdout,
                          f"stop-identity-invalid item=TEST-1 path={identity}\n".encode() in invalid.stderr),
                         (1, b"", True), invalid.stderr)
        library = clone / ".agents/skills/orch/scripts/lib/lane-state.sh"
        library_original = library.read_text()
        library.write_text(library_original + '\nunset -f lane_stop_identity\n')
        identity.write_text("1 Thu Jan 1 00:00:00 1970\n")
        missing = self.call("stop", "--item", "TEST-1", "--harness", "claude")
        self.assertEqual((missing.returncode, f"stop-operation-missing path={library}\n".encode() in missing.stderr),
                         (1, True), missing.stderr)

    @unittest.skipUnless(sys.platform.startswith("linux"), "provider stop integration requires procfs")
    def test_stop_refuses_when_a_signaled_process_stays_live(self):
        lane = self.launch_lane(on_term="")
        library = Path(self.row["clone"]) / ".agents/skills/orch/scripts/lib/lane-state.sh"
        library_original = library.read_text()
        library.write_text(library_original + '\nkill() { return 1; }\n')
        signal_refused = self.call("stop", "--item", "TEST-1", "--harness", "codex")
        self.assertEqual((signal_refused.returncode, f"stop-signal-refused item=TEST-1 pid={lane.pid}".encode() in signal_refused.stderr),
                         (1, True), signal_refused.stderr)
        library.write_text(library_original)
        refused = self.call("stop", "--item", "TEST-1", "--harness", "codex")
        self.assertEqual((refused.returncode, f"stop-timeout item=TEST-1 pid={lane.pid}".encode() in refused.stderr, lane.poll()),
                         (1, True, None), refused.stderr)

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

    def test_close_archives_the_state_the_lane_settings_place_outside_tmp(self):
        # The lane's settings name a state directory outside both tmp trees;
        # its close archives the item's state there, which oversee-cycle reads
        # once the sandbox is gone.
        state_dir = self.root / "lane-state"
        scripts = self.source / ".agents/skills/orch/scripts"
        for name in ("workflow-state", "git-context"):
            shutil.copy2(PACKAGE / "scripts" / name, scripts / name)
        (self.source / "kendex.settings.toml").write_text(f'[env]\nORCH_STATE_DIR = "{state_dir}"\n')
        for args in (("add", "."), ("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "state dir")):
            subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), *args], check=True, capture_output=True)
        self.assertEqual(self.create().returncode, 0)
        state_dir.mkdir()
        (state_dir / "workflow-state-TEST-1.json").write_text('{"cycles": 4}')
        # An older copy in the clone's tmp, from before the settings moved it.
        (Path(self.row["clone"]) / "tmp").mkdir(exist_ok=True)
        (Path(self.row["clone"]) / "tmp/workflow-state-TEST-1.json").write_text('{"cycles": 9}')
        closed = self.call("close", "--item", "TEST-1")
        self.assertEqual(closed.returncode, 0, closed.stderr)
        archive = Path(closed.stdout.decode().strip().removeprefix("kept="))
        with tarfile.open(archive) as saved:
            member = str(state_dir / "workflow-state-TEST-1.json").lstrip("/")
            self.assertEqual(saved.extractfile("lane-host-state").read(), member.encode() + b"\n")
            self.assertEqual(saved.extractfile(member).read(), b'{"cycles": 4}')

    def test_close_records_a_dotted_state_directory_as_tar_names_it(self):
        # A relative setting such as ../lane-state resolves to a path holding
        # .. components; the record names the member tar writes for it. The
        # kept= path is absolute though FLEET_DIR is relative, since tempfile
        # makes the archive's directory absolute, which oversee-cycle's read
        # of the kept= row relies on.
        scripts = self.source / ".agents/skills/orch/scripts"
        for name in ("workflow-state", "git-context"):
            shutil.copy2(PACKAGE / "scripts" / name, scripts / name)
        (self.source / "kendex.settings.toml").write_text('[env]\nORCH_STATE_DIR = "../lane-state"\n')
        for args in (("add", "."), ("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "state dir")):
            subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), *args], check=True, capture_output=True)
        self.assertEqual(self.create().returncode, 0)
        state_dir = Path(self.row["clone"]).parent / "lane-state"
        state_dir.mkdir()
        (state_dir / "workflow-state-TEST-1.json").write_text('{"cycles": 6}')
        closed = self.call("close", "--item", "TEST-1", FLEET_DIR="fleet-relative")
        self.assertEqual(closed.returncode, 0, closed.stderr)
        archive = Path(closed.stdout.decode().strip().removeprefix("kept="))
        self.assertTrue(archive.is_absolute(), archive)
        with tarfile.open(archive) as saved:
            member = saved.extractfile("lane-host-state").read().decode().rstrip("\n")
            self.assertEqual(member, str(state_dir / "workflow-state-TEST-1.json").lstrip("/"))
            self.assertEqual(saved.extractfile(member).read(), b'{"cycles": 6}')

    def test_close_follows_a_symlink_before_dots_in_the_state_directory(self):
        # tmp/link/../lane-state names the directory beside link's target, as
        # the filesystem follows it; collapsing link/.. first names
        # tmp/lane-state, which here holds another copy, so the record would
        # name a file that is not the lane's state.
        scripts = self.source / ".agents/skills/orch/scripts"
        for name in ("workflow-state", "git-context"):
            shutil.copy2(PACKAGE / "scripts" / name, scripts / name)
        (self.source / "kendex.settings.toml").write_text('[env]\nORCH_STATE_DIR = "tmp/link/../lane-state"\n')
        for args in (("add", "."), ("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "state dir")):
            subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), *args], check=True, capture_output=True)
        self.assertEqual(self.create().returncode, 0)
        target = self.root / "elsewhere/inner"
        target.mkdir(parents=True)
        (Path(self.row["clone"]) / "tmp").mkdir(exist_ok=True)
        (Path(self.row["clone"]) / "tmp/link").symlink_to(target)
        (Path(self.row["clone"]) / "tmp/lane-state").mkdir()
        (Path(self.row["clone"]) / "tmp/lane-state/workflow-state-TEST-1.json").write_text('{"cycles": 9}')
        state_dir = (self.root / "elsewhere/lane-state").resolve()
        state_dir.mkdir()
        (state_dir / "workflow-state-TEST-1.json").write_text('{"cycles": 2}')
        closed = self.call("close", "--item", "TEST-1")
        self.assertEqual(closed.returncode, 0, closed.stderr)
        archive = Path(closed.stdout.decode().strip().removeprefix("kept="))
        with tarfile.open(archive) as saved:
            member = saved.extractfile("lane-host-state").read().decode().rstrip("\n")
            self.assertEqual(member, str(state_dir / "workflow-state-TEST-1.json").lstrip("/"))
            self.assertEqual(saved.extractfile(member).read(), b'{"cycles": 2}')

    def test_close_archives_the_state_the_lane_private_env_places(self):
        # The lane's workflow-state loads its private env file over its
        # settings; close resolves the state the way the lane does.
        scripts = self.source / ".agents/skills/orch/scripts"
        for name in ("workflow-state", "git-context"):
            shutil.copy2(PACKAGE / "scripts" / name, scripts / name)
        for args in (("add", "."), ("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "state reader")):
            subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), *args], check=True, capture_output=True)
        created = self.create()
        self.assertEqual(created.returncode, 0, created.stderr)
        path = Path(dict(field.split("=", 1) for field in created.stdout.decode().strip().split("\t"))["path"])
        state_dir = (self.root / "private-state").resolve()
        state_dir.mkdir()
        (state_dir / "workflow-state-TEST-1.json").write_text('{"cycles": 5}')
        (path / ".env.local").write_text(f'ORCH_STATE_DIR="{state_dir}"\n')
        closed = self.call("close", "--item", "TEST-1")
        self.assertEqual(closed.returncode, 0, closed.stderr)
        archive = Path(closed.stdout.decode().strip().removeprefix("kept="))
        with tarfile.open(archive) as saved:
            member = saved.extractfile("lane-host-state").read().decode().rstrip("\n")
            self.assertEqual(member, str(state_dir / "workflow-state-TEST-1.json").lstrip("/"))
            self.assertEqual(saved.extractfile(member).read(), b'{"cycles": 5}')

    def test_close_stops_when_the_state_directory_does_not_resolve(self):
        # A clone whose workflow-state fails leaves the item's state unplaced:
        # close stops before the worktree goes, rather than archive without it.
        scripts = self.source / ".agents/skills/orch/scripts"
        self.executable(scripts / "workflow-state", "#!/usr/bin/env bash\necho 'workflow-state: settings broken' >&2\nexit 1\n")
        for args in (("add", "."), ("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "broken state")):
            subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), *args], check=True, capture_output=True)
        created = self.create()
        self.assertEqual(created.returncode, 0, created.stderr)
        path = Path(dict(field.split("=", 1) for field in created.stdout.decode().strip().split("\t"))["path"])
        closed = self.call("close", "--item", "TEST-1")
        self.assertNotEqual(closed.returncode, 0, closed.stderr)
        self.assertIn(b"lane-host-ssh: state-unresolved item=TEST-1", closed.stderr)
        self.assertEqual((closed.stdout, path.is_dir()), (b"", True))

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

    def test_a_clone_holding_nothing_of_the_item_answers_each_verb_empty(self):
        """A finished close leaves nothing of TEST-1, and so does a create for
        another item on the same clone after it: stop, status and close each
        give the empty answer the protocol states, resolve no worktree path and
        leave the other item's marker and worktree as they were. One control
        is the marker test below, a missing or other marker beside TEST-1's
        standing worktree still refusing as unowned; the other is the mutant
        here, without the absent answer."""
        self.assertEqual(self.create().returncode, 0)
        self.assertEqual(self.call("close", "--item", "TEST-1").returncode, 0)
        clone = Path(self.row["clone"])
        worktree = Path(self.row["clone"] + "-worktree")
        # verb|arguments|stdout
        answers = (("stop", ("--harness", "claude"), b"stopped item=TEST-1 processes=0\n"),
                   ("status", ("--harness", "claude"), b"exited\n"),
                   ("close", ("--merged",), b"closed=absent item=TEST-1\n"))

        def ask(verb, extra):
            before = (self.root / "calls").read_text()
            result = self.call(verb, "--item", "TEST-1", *extra)
            return result, (self.root / "calls").read_text()[len(before):]

        for holder in (None, "OTHER-1"):
            if holder:
                self.inventory.write_text(json.dumps([{**self.row, "item": holder}]))
                made = self.call("create", "--item", holder, "--repo", "owner/repo", "--harness", "claude",
                                 "--account", str(self.account))
                self.assertEqual(made.returncode, 0, made.stderr)
                self.inventory.write_text(json.dumps([self.row]))
                (worktree / "tmp").mkdir(exist_ok=True)
                (worktree / "tmp/other.json").write_text("keep")
            for verb, extra, expected in answers:
                with self.subTest(holder=holder, verb=verb):
                    result, calls = ask(verb, extra)
                    self.assertEqual((result.returncode, result.stdout), (0, expected), result.stderr)
                    self.assertNotIn("worktree path TEST-1", calls)
        self.assertEqual((clone / ".git/lane-host-item").read_text(), "OTHER-1\n")
        self.assertEqual((worktree / "tmp/other.json").read_text(), "keep")
        original = self.script.read_text()
        answer = 'if owner == b"other" and not worktree_exists(row, item):'
        self.assertEqual(original.count(answer), 1)
        self.script.write_text(original.replace(answer, "if False:"))
        for verb, extra, _ in answers:
            with self.subTest(control=verb):
                result, _ = ask(verb, extra)
                self.assertEqual((result.returncode, result.stdout), (75, b""), result.stderr)
        self.script.write_text(original)

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

    def test_close_accepts_merged_and_keeps_the_whole_archive(self):
        # lane-close passes --merged on a merged full close; a static host cuts
        # nothing, so every tmp record stays in the archive. The control is the
        # parser without the flag, which refuses the close.
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        worktree = Path(self.row["clone"] + "-worktree")
        for directory in (clone / "tmp", worktree / "tmp"):
            directory.mkdir(exist_ok=True)
        (clone / "tmp/clone.json").write_bytes(b'"clone-record"\n')
        (worktree / "tmp/return.json").write_bytes(b'"worktree-record"\n')
        original = self.script.read_text()
        flag = '        if verb == "close":\n            action.add_argument("--merged", action="store_true")\n'
        self.assertEqual(original.count(flag), 1)
        self.script.write_text(original.replace(flag, ""))
        mutant = self.call("close", "--item", "TEST-1", "--merged")
        self.assertEqual(mutant.returncode, 2, mutant.stderr)
        self.script.write_text(original)
        closed = self.call("close", "--item", "TEST-1", "--merged")
        self.assertEqual(closed.returncode, 0, closed.stderr)
        line = closed.stdout.decode().strip()
        self.assertTrue(line.startswith("kept="), line)
        with tarfile.open(line.removeprefix("kept=")) as saved:
            self.assertEqual(saved.extractfile(str(clone / "tmp/clone.json").lstrip("/")).read(), b'"clone-record"\n')
            self.assertEqual(saved.extractfile(str(worktree / "tmp/return.json").lstrip("/")).read(),
                             b'"worktree-record"\n')
        self.assertFalse(worktree.exists())

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
