"""Run the provider's remote commands in local repositories through an SSH stub."""
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import tarfile
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
[[ "${SSH_TEST_INSTALL_FAIL:-0}" == 0 ]] || exit "$SSH_TEST_INSTALL_FAIL"
if [[ "$1" == refresh && -n "${SSH_TEST_INSTALL_ROOT:-}" ]]; then
  mkdir -p .agents; cp -R "$SSH_TEST_INSTALL_ROOT/." .agents/
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
  if [[ -d "$path" ]]; then [[ "${3:-}" == --reuse ]] || exit 75
  else
    [[ "${3:-}" != --reuse ]] || exit 1
    git worktree add --detach "$path" >&2
  fi
  printf '%s\\n' "$path" ;;
exists) if [[ -d "$path" ]]; then printf 'true\\n'; else printf 'false\\n'; fi ;;
path) printf '%s\\n' "$path" ;;
remove)
  if [[ -n "${SSH_TEST_CLOSE_STDOUT:-}" ]]; then
    printf 'before-delete:%s\\n' "$(cat -- "$SSH_TEST_CLOSE_STDOUT")" >> "$SSH_TEST_LOG"
  fi
  git worktree remove --force "$path" ;;
esac
''')
        scripts = self.source / ".agents/skills/orch/scripts"
        scripts.mkdir(parents=True)
        for name in ("resolve-base-branch", "sync-base"):
            shutil.copy2(PACKAGE / "scripts" / name, scripts / name)
        self.executable(self.source / ".agents/skills/github/scripts/git-https-auth", '''#!/usr/bin/env bash
exec git "$@"
''')
        (self.source / ".gitignore").write_text(".env.local\n.cache/\n.kendex-lock.json\ntmp/\n")
        (self.source / "kendex.toml").write_text("")
        for args in (("init", "-q"), ("add", "."), ("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "seed")):
            subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), *args], check=True, capture_output=True)
        (self.source / ".env.local").write_bytes(b"SECRET=private-fixture\n")
        cache = self.source / ".cache/linear"
        cache.mkdir(parents=True)
        (cache / "issues.json").write_text('{"cached":true}')
        (cache / "sync.lock").write_text("local lock")
        (self.source / ".kendex-lock.json").write_text("machine-specific-ledger")
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

    def test_prepare_reuse_and_account_protocol(self):
        first = self.create()
        self.assertEqual(first.returncode, 0, first.stderr)
        clone = Path(self.row["clone"])
        self.assertEqual((clone / ".env.local").read_bytes(), (self.source / ".env.local").read_bytes())
        self.assertEqual((clone / ".cache/linear/issues.json").read_text(), '{"cached":true}')
        self.assertFalse((clone / ".cache/linear/sync.lock").exists())
        self.assertFalse((clone / ".kendex-lock.json").exists())
        calls = (self.root / "calls").read_text()
        self.assertLess(calls.index("kendex update-pi --leave"), calls.index("kendex refresh --yes --leave"))
        self.assertLess(calls.index("kendex refresh --yes --leave"), calls.index("worktree create TEST-1"))
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

    def test_create_places_per_harness_pre_approval(self):
        """The overseer's trust file lands where each harness reads it; Claude's merges."""
        seed = b'{"userID": "kept", "projects": {"/c": {"allowedTools": ["Bash"], "hasTrustDialogAccepted": false}}}'
        merged = {"userID": "kept", "hasCompletedOnboarding": True, "projects": {"/c": {"allowedTools": ["Bash"], "hasTrustDialogAccepted": True}}}
        rows = (("claude", ".claude.json", self.root / ".claude.json", b'{"hasCompletedOnboarding": true, "projects": {"/c": {"hasTrustDialogAccepted": true}}}', json.loads, merged),
                ("codex", "config.toml", Path(self.row["account"]) / "config.toml", b'[projects."/c"]\ntrust_level = "trusted"\n', bytes, None),
                ("pi", "trust.json", Path(self.row["account"]) / "trust.json", b'{"/c": true}\n', bytes, None))
        (self.account / "lane-host").mkdir()
        (self.root / ".claude.json").write_bytes(seed)
        for harness, name, landed, data, parse, expected in rows:
            with self.subTest(harness=harness):
                (self.account / "lane-host" / name).write_bytes(data)
                result = self.create("--reuse", harness=harness)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(parse(landed.read_bytes()), expected or data)
        # The controls: a provider without the placement lands nothing, and
        # one that puts the Claude snapshot whole drops the host's own keys.
        original = self.script.read_text()
        fragment = "    if approval.exists():"
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, "    if False:"))
        for harness, _, landed, *_ in rows:
            with self.subTest(control=harness):
                landed.unlink()
                self.assertEqual(self.create("--reuse", harness=harness).returncode, 0)
                self.assertFalse(landed.exists())
        fragment = "            data = json.dumps(claude_state("
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, "            data = data or json.dumps(claude_state("))
        (self.root / ".claude.json").write_bytes(seed)
        self.assertEqual(self.create("--reuse").returncode, 0)
        self.assertNotIn("userID", json.loads((self.root / ".claude.json").read_bytes()))

    def test_fresh_clone_uses_host_github_protocol(self):
        self.assertEqual(self.create(SSH_TEST_GIT_PROTOCOL="ssh").returncode, 0)
        self.assertIn("gh repo clone owner/repo " + self.row["clone"], (self.root / "calls").read_text())
        original = self.script.read_text()
        fragment = 'gh repo clone "$2" "$1" >&2'
        self.assertEqual(original.count(fragment), 1)
        self.row["clone"] = str(self.root / "forced-https")
        self.inventory.write_text(json.dumps([self.row]))
        self.script.write_text(original.replace(fragment, 'git clone -- "https://github.com/$2.git" "$1" >&2'))
        mutant = self.create(SSH_TEST_GIT_PROTOCOL="ssh")
        self.assertEqual(mutant.returncode, 17, mutant.stderr)
        self.assertFalse(Path(self.row["clone"]).exists())

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
        original = self.script.read_text()
        fragment = 'chmod 600 "$permission_path"'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, 'chmod 600 -- "$1"'))
        refused = self.call("put", "--item", "TEST-1", "--", str(self.root / "mutant"),
                            data=b"secret\n", SSH_TEST_BSD_CHMOD="1")
        self.assertEqual(refused.returncode, 97, refused.stderr)

    def test_put_keeps_the_target_when_a_transfer_is_cut(self):
        """A put whose stream dies mid-feed leaves the previous bytes standing."""
        self.assertEqual(self.create().returncode, 0)
        target = self.root / "mailbox"
        self.assertEqual(self.call("put", "--item", "TEST-1", "--", str(target),
                                   data=b"first answer\n").returncode, 0)
        cut = self.call("put", "--item", "TEST-1", "--", str(target),
                        data=b"a much longer second answer\n", SSH_TEST_CUT="5")
        self.assertNotEqual(cut.returncode, 0)
        self.assertEqual(target.read_bytes(), b"first answer\n")
        self.assertEqual(list(target.parent.glob("mailbox.kendex-put.*")), [])
        # The control: a provider that renames whatever arrived. The staged
        # write and the rename stay, so only the count check is removed.
        original = self.script.read_text()
        fragment = 'if [ "$((arrived + 0))" -ne "$2" ]; then'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, 'if false; then'))
        self.call("put", "--item", "TEST-1", "--", str(target),
                  data=b"a much longer second answer\n", SSH_TEST_CUT="5")
        self.assertEqual(target.read_bytes(), b"a muc")
        self.script.write_text(original)

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
        original = self.script.read_text()
        fragment = 'if present == b"false\\n":\n        return []'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, 'if present == b"false\\n":\n        return ["--reuse"]'))
        refused = self.create("--relaunch")
        self.assertEqual(refused.returncode, 1, refused.stderr)
        self.assertFalse(Path(self.row["clone"] + "-worktree").exists())

    def test_retained_manifest_only_clone_bootstraps_before_helpers(self):
        install = (self.source / ".agents").rename(self.root / "install")
        subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qam", "manifest only"], check=True)
        self.env["SSH_TEST_INSTALL_ROOT"] = str(install)
        clone = Path(self.row["clone"])
        subprocess.run([self.env["REAL_GIT"], "clone", "-q", str(self.source), str(clone)], check=True)
        extra = str(clone) + "-other"
        subprocess.run([self.env["REAL_GIT"], "-C", str(clone), "worktree", "add", "--detach", extra], check=True, capture_output=True)
        self.assertEqual(self.create().returncode, 75)
        self.assertFalse((clone / ".agents").exists())
        subprocess.run([self.env["REAL_GIT"], "-C", str(clone), "worktree", "remove", extra], check=True)
        (clone / "kendex.toml").write_text("dirty")
        dirty = self.create()
        self.assertEqual((dirty.returncode, b"bootstrap-dirty path=" in dirty.stderr), (3, True))
        (clone / "kendex.toml").write_text("")
        self.assertEqual(self.create(SSH_TEST_INSTALL_FAIL="19").returncode, 19)
        ready = self.create()
        self.assertEqual(ready.returncode, 0, ready.stderr)
        subprocess.run([self.env["REAL_GIT"], "-C", str(clone), "worktree", "remove", str(clone) + "-worktree"], check=True)
        shutil.rmtree(clone / ".agents")
        original = self.script.read_text()
        fragment = 'if ready == b"bootstrap":\n            install(row)'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, 'if ready == b"bootstrap":\n            pass'))
        self.assertNotEqual(self.create().returncode, 0)

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
        self.assertEqual((closed.returncode, closed.stdout), (0, b""))
        self.assertTrue(Path(self.row["clone"]).exists())
        self.assertFalse(Path(self.row["clone"] + "-worktree").exists())
        self.assertEqual(self.call("list").stdout, b"owner/repo/TEST-1\tavailable\t-\tlane.example\n")

    def test_forced_host_tty_preserves_binary_reads_and_archive(self):
        self.assertEqual(self.create().returncode, 0)
        path = Path(self.row["clone"] + "-worktree/tmp/binary.dat")
        data = b"record\x00\xff\nnext\n"
        self.assertEqual(self.call("put", "--item", "TEST-1", str(path), data=data,
                                   SSH_TEST_REQUEST_TTY="force").returncode, 0)
        read = self.call("cat", "--item", "TEST-1", str(path), SSH_TEST_REQUEST_TTY="force")
        self.assertEqual((read.returncode, read.stdout), (0, data))
        original = self.script.read_text()
        fragment = '["ssh", "-T", "-o", "BatchMode=yes"'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, '["ssh", "-o", "BatchMode=yes"'))
        mutant = self.call("cat", "--item", "TEST-1", str(path), SSH_TEST_REQUEST_TTY="force")
        self.assertEqual((mutant.returncode, mutant.stdout), (0, data.replace(b"\n", b"\r\n")))
        self.script.write_text(original)
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

        original = self.script.read_text()
        fragment = '''prefix = "exec " + shlex.join(["bash", "-c",
            'CLAUDE_CODE_OAUTH_TOKEN=$(< "$1") && export CLAUDE_CODE_OAUTH_TOKEN && exec bash -lc "$2"',
            "lane-host", remote_account + "/setup-token"])'''
        replacement = '''prefix = 'exec env CLAUDE_CODE_OAUTH_TOKEN="$(cat -- ' + shlex.quote(remote_account + "/setup-token") + ')" bash -lc' '''.rstrip()
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, replacement))
        mutant = self.create("--reuse")
        self.assertEqual(mutant.returncode, 0, mutant.stderr)
        self.assertEqual(launch(mutant.stdout).returncode, 0)
        self.assertIn("claude-secret-fixture", Path(self.env["EXEC_TRACE"]).read_text())
        (Path(self.row["account"]) / "setup-token").unlink()
        self.assertEqual(launch(mutant.stdout).returncode, 0)
        self.assertTrue(Path(self.env["LAUNCH_RESULT"]).exists())

    def test_existing_clone_finishes_real_worktree_setup(self):
        scripts = self.source / ".agents/skills/worktree/scripts"
        shutil.copytree(PACKAGE.parent / "worktree/scripts", scripts, dirs_exist_ok=True)
        (self.source / "kendex.settings.toml").write_text('[env]\nWORKTREE_DEFAULT_BRANCH = "main"\nWORKTREE_SYMLINKS = ".env.local .agents"\nWORKTREE_COPIES = "copy-config"\n')
        with (self.source / ".gitignore").open("a") as ignore:
            ignore.write("copy-config\ncopy-added\n.agents/skills/prepared/\n")
        for args in (("branch", "-M", "main"), ("add", "."), ("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "worktree fixture")):
            subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), *args], check=True, capture_output=True)
        self.executable(self.bin / "kendex", '''#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == refresh ]]; then
  mkdir -p .agents/skills/prepared
  printf ready > .agents/skills/prepared/SKILL.md
  printf copied > copy-config
  printf added > copy-added
fi
''')
        original = self.script.read_text()
        fragment = 'made = worktree(row, "create", args.item, *flags)'
        self.assertEqual(original.count(fragment), 1)
        for name, repair in (("control", False), ("production", True)):
            with self.subTest(name=name):
                self.row["clone"] = str(self.root / name)
                self.inventory.write_text(json.dumps([self.row]))
                subprocess.run([self.env["REAL_GIT"], "clone", "-q", str(self.source), self.row["clone"]], check=True)
                self.script.write_text(original if repair else original.replace(fragment, 'made = subprocess.CompletedProcess([], 0)'))
                result = self.create()
                self.assertEqual(result.returncode, 0, result.stderr)
                path = Path(dict(field.split("=", 1) for field in result.stdout.decode().strip().split("\t"))["path"])
                for entry in (".env.local", ".agents/skills/prepared/SKILL.md", "copy-config"):
                    with self.subTest(entry=entry):
                        self.assertEqual((path / entry).exists(), repair)
                        if repair:
                            self.assertEqual((path / entry).read_bytes(), (Path(self.row["clone"]) / entry).read_bytes())
                self.assertFalse((path / "copy-added").exists())
                if repair:
                    self.source.joinpath("kendex.settings.toml").write_text('[env]\nWORKTREE_DEFAULT_BRANCH = "main"\nWORKTREE_SYMLINKS = ".env.local .agents"\nWORKTREE_COPIES = "copy-config copy-added"\n')
                    subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), "add", "kendex.settings.toml"], check=True)
                    subprocess.run([self.env["REAL_GIT"], "-C", str(self.source), "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "new remote settings"], check=True)
                    sync_call = '"$1/.agents/skills/orch/scripts/sync-base" "$1" >&2'
                    self.assertEqual(original.count(sync_call), 1)
                    self.script.write_text(original.replace(sync_call, 'git -C "$1" fetch origin >&2'))
                    stale = self.create("--reuse")
                    self.assertEqual(stale.returncode, 0, stale.stderr)
                    with self.assertRaises(AssertionError):
                        self.assertTrue((path / "copy-added").exists())
                    self.script.write_text(original)
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
        original = self.script.read_text()
        fragment = 'if test "$dir" = "$2" && ! test -e "$dir" && ! test -L "$dir"; then continue; fi'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, 'if false; then continue; fi'))
        self.assertNotEqual(self.call("close", "--item", "TEST-1").returncode, 0)
        self.assertTrue((Path(self.row["clone"]) / ".git/lane-host-item").exists())
        self.script.write_text(original)
        self.assertEqual(self.call("close", "--item", "TEST-1").returncode, 0)
        self.assertEqual(self.call("list").stdout, b"owner/repo/TEST-1\tavailable\t-\tlane.example\n")

    def test_close_requires_provider_marker_before_worktree_lookup(self):
        self.assertEqual(self.create().returncode, 0)
        marker = Path(self.row["clone"]) / ".git/lane-host-item"
        worktree = Path(self.row["clone"] + "-worktree")
        private = worktree / "tmp/private.json"
        private.parent.mkdir()
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
        original = self.script.read_text()
        start = original.index('        owned = remote(row,')
        end = original.index('        path = worktree(row, "path", args.item)', start)
        self.script.write_text(original[:start] + original[end:])
        self.assertNotEqual(self.call("close", "--item", "TEST-1").returncode, 75)
        self.assertFalse(private.exists())

    def test_existing_clone_refuses_other_repository(self):
        self.assertEqual(self.create().returncode, 0)
        clone = Path(self.row["clone"])
        original = self.script.read_text()
        fragment = 'if test "$actual" != "$2"; then'
        self.assertEqual(original.count(fragment), 1)
        before = (self.root / "calls").read_text()
        refused = self.create("--reuse", SSH_TEST_REPO_NAME="other/repo")
        self.assertEqual(refused.returncode, 1, refused.stderr)
        self.assertIn(b"origin-mismatch expected=owner/repo actual=other/repo", refused.stderr)
        self.assertNotIn("worktree create TEST-1", (self.root / "calls").read_text()[len(before):])
        self.assertEqual((clone / ".git/lane-host-item").read_text(), "TEST-1\n")
        self.script.write_text(original.replace(fragment, 'if false; then'))
        accepted = self.create("--reuse", SSH_TEST_REPO_NAME="other/repo")
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

    def test_close_archives_before_delete(self):
        original = self.script.read_text()
        fragment = 'print(f"kept={kept}", flush=True)'
        self.assertEqual(original.count(fragment), 1)
        for state in ("present", "removed", "buffered-control"):
            with self.subTest(state=state):
                self.row["clone"] = str(self.root / state)
                self.inventory.write_text(json.dumps([self.row]))
                self.script.write_text(original if state != "buffered-control" else original.replace(fragment, 'print(f"kept={kept}", flush=False)'))
                self.assertEqual(self.create().returncode, 0)
                clone = Path(self.row["clone"])
                worktree = Path(self.row["clone"] + "-worktree")
                for directory in (clone / "tmp", worktree / "tmp"):
                    directory.mkdir()
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
                if state != "removed":
                    self.assertEqual(("before-delete:" + line) in (self.root / "calls").read_text(), state == "present")

    def test_archive_failures_preserve_remote_records(self):
        original = self.script.read_text()
        fragment = '        archive_tmp(row, args.item, path)'
        self.assertEqual(original.count(fragment), 1)
        for failure in ("tar", "storage", "skip-control"):
            with self.subTest(failure=failure):
                self.row["clone"] = str(self.root / failure)
                self.inventory.write_text(json.dumps([self.row]))
                self.script.write_text(original if failure != "skip-control" else original.replace(fragment, '        # archive_tmp(row, args.item, path)'))
                self.assertEqual(self.create().returncode, 0)
                worktree = Path(self.row["clone"] + "-worktree")
                (worktree / "tmp").mkdir()
                record = worktree / "tmp/return.json"
                record.write_text("keep")
                env = {}
                if failure in ("tar", "skip-control"):
                    self.executable(self.bin / "tar", '#!/usr/bin/env bash\nexit 23\n')
                else:
                    blocked = self.root / "storage-blocked"
                    blocked.write_text("file")
                    env["FLEET_DIR"] = str(blocked)
                closed = self.call("close", "--item", "TEST-1", **env)
                expected = {"tar": 23, "storage": 1, "skip-control": 0}[failure]
                self.assertEqual(closed.returncode, expected, closed.stderr)
                self.assertEqual(record.exists(), failure != "skip-control")
                self.assertEqual((Path(self.row["clone"]) / ".git/lane-host-item").exists(), failure != "skip-control")
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

    def test_controls_inventory_guards(self):
        original = self.script.read_text()
        cases = [
            ('if not isinstance(rows, list) or any(', 'if False and any(', [{**self.row, "target": "bad\nvalue"}]),
            ('if len({r["item"] for r in rows}) != len(rows) or len({(r["target"], r["clone"]) for r in rows}) != len(rows):', 'if False:', [self.row, self.row]),
            ('if any(not r["clone"].startswith("/") or not r["account"].startswith("/") for r in rows):', 'if False:', [{**self.row, "clone": "relative"}]),
            ('if len({r["repo"] for r in rows}) > 1:', 'if False:', [self.row, {**self.row, "item": "TEST-2", "repo": "owner/other", "clone": "/other"}]),
        ]
        for fragment, replacement, rows in cases:
            with self.subTest(fragment=fragment):
                self.assertEqual(original.count(fragment), 1)
                self.script.write_text(original.replace(fragment, replacement))
                self.inventory.write_text(json.dumps(rows))
                self.assertNotEqual(self.call("list").returncode, 2)

    def test_failures_stop_preparation(self):
        for overrides, code in (({"SSH_TEST_FAIL": "255"}, 255), ({"SSH_TEST_CLONE_FAIL": "23"}, 23), ({"SSH_TEST_INSTALL_FAIL": "19"}, 19)):
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

    def test_control_host_ownership_guard(self):
        self.assertEqual(self.create().returncode, 0)
        marker = Path(self.row["clone"]) / ".git/lane-host-item"
        marker.write_text("OTHER-1\n")
        original = self.script.read_text()
        fragment = 'if test "$owner" != "$3"; then exit 75; fi'
        self.assertEqual(original.count(fragment), 1)
        self.script.write_text(original.replace(fragment, 'if false; then exit 75; fi'))
        self.assertNotEqual(self.create("--reuse").returncode, 75)


if __name__ == "__main__":
    unittest.main()
