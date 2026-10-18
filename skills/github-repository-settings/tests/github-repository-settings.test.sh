#!/usr/bin/env bash
# bash-runtime: 3.2
# Inputs: scripts/, ../bot-instructions/, ../review-gate/scripts/lib/settings.sh,
# ../review-gate/scripts/lib/diagnostics.sh. Exercises the package's library calls.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
export MSYS=winsymlinks:nativestrict
export PYTHONDONTWRITEBYTECODE=1
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo 'github-repository-settings-test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'github-repository-settings-test: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'github-repository-settings-test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

python3 -B - "$SCRIPT_DIR/../.." "$TMP_ROOT" "$BASH" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

skills, scratch = map(Path, sys.argv[1:3])
bash = sys.argv[3]
environment = {key: os.environ[key] for key in ("PATH", "SYSTEMROOT", "MSYS") if key in os.environ}
environment["PYTHONDONTWRITEBYTECODE"] = "1"
agents_bytes = b"# Local rules\n\nKeep this prefix.\n\n## Code Review Rules\n\nHand edit.\n\n## Other rules\n\nKeep this suffix.\n"


def fixture(name):
    root = scratch / name
    installed = root / "catalog"
    for package in ("github-repository-settings", "bot-instructions", "review-gate"):
        shutil.copytree(skills / package, installed / package,
                        ignore=shutil.ignore_patterns("tests", "__pycache__"))
    (root / "kendex.toml").write_text('''[bot-instructions]
schema = 1
[bot-instructions.repo]
name = "fixture"
summary = "A repository fixture."
[bot-instructions.bots]
codex = true
copilot = true
coderabbit = false
qodo = false
qodo_best_practices = false
qodo_review_md = false
macroscope = false
''')
    (root / "AGENTS.md").write_bytes(agents_bytes)
    (root / "unrelated.bin").write_bytes(bytes(range(256)))
    for arguments in (("init", "-q"), ("config", "gc.auto", "0"),
                      ("config", "maintenance.auto", "false"), ("add", "-A")):
        subprocess.run(["git", "-C", str(root), *arguments], env=environment,
                       check=True, capture_output=True)
    result = subprocess.run([str(installed / "bot-instructions/scripts/bot-instructions"),
                             "adopt", "--repo", str(root), "--output", "local"],
                            env=environment, capture_output=True, text=True)
    assert result.returncode == 1 and "agents-region:" in result.stderr, result
    return root


def launcher(root):
    return root / "catalog/github-repository-settings/scripts/github-repository-settings"


def invoke(root, verb, *args, setting="off", location="local", library=False):
    env = dict(environment)
    if setting is not None:
        env["GITHUB_STANDARD_BOT_REVIEW"] = setting
    if location is not None:
        env["GITHUB_STANDARD_CHECK_LOCATION"] = location
    command = ([str(root / "catalog/bot-instructions/scripts/bot-instructions")]
               if library else [bash, str(launcher(root))])
    return subprocess.run([*command, verb, "--repo", str(root), *args],
                          cwd=scratch, env=env, text=True, capture_output=True)


def snapshot(root):
    return {str(path.relative_to(root)):
            ("link", str(path.readlink())) if path.is_symlink() else
            ("file", path.read_bytes()) if path.is_file() else ("dir", None)
            for path in root.rglob("*")}


def preview(root):
    (root / "AGENTS.md").write_bytes(agents_bytes)
    before = snapshot(root)
    result = invoke(root, "adopt", "--dry-run")
    # This is the library's structured finding used by its existing CLI consumers.
    assert result.returncode == 1 and "agents-region:" in result.stderr, result
    assert snapshot(root) == before


def symlink(root):
    agents = root / "AGENTS.md"
    agents.rename(root / "personal.md")
    agents.symlink_to("personal.md")
    assert agents.is_symlink()
    before = snapshot(root)
    result = invoke(root, "adopt", "--dry-run")
    assert result.returncode == 2, result
    assert snapshot(root) == before


def rendered(root, review="off"):
    result = invoke(root, "render", setting=review)
    assert result.returncode == 0, result


def selection(root):
    before = snapshot(root)
    # No process value: the package must use its off default.
    result = invoke(root, "render", setting=None)
    assert result.returncode == 0, result
    after = snapshot(root)
    changed = {p for p in before.keys() | after.keys() if before.get(p) != after.get(p)}
    assert changed == {"AGENTS.md"}, changed
    original = before["AGENTS.md"][1]
    current = (root / "AGENTS.md").read_bytes()
    assert current.split(b"## Code Review Rules")[0] == original.split(b"## Code Review Rules")[0]
    assert current.split(b"## Other rules")[1] == original.split(b"## Other rules")[1]
    assert b"catalog/bot-instructions/SKILL.md#doctrine" in current
    rendered(root, "on")
    assert (root / ".github/copilot-instructions.md").is_file()
    assert (root / ".github/instructions/code-review.md").is_file()
    for path in (".coderabbit.yaml", ".pr_agent.toml", "best_practices.md", "REVIEW.md", ".macroscope"):
        assert not (root / path).exists(), path
    # Existing remote files stay outside local output, even when edited.
    remote = root / ".github/copilot-instructions.md"
    remote.write_text(remote.read_text() + "\nPersonal edit.\n")
    before = snapshot(root)
    rendered(root)
    after = snapshot(root)
    assert {p for p in before.keys() | after.keys() if before.get(p) != after.get(p)} == {"AGENTS.md"}
    assert remote.read_bytes() == before[".github/copilot-instructions.md"][1]


def equality(root):
    for review, output in (("off", "local"), ("on", "full")):
        rendered(root, review)
        actual = snapshot(root)
        result = invoke(root, "render", "--output", output, library=True)
        assert result.returncode == 0, result
        assert snapshot(root) == actual


def checking(root):
    rendered(root)
    for stale in (False, True):
        if stale:
            path = root / "AGENTS.md"
            path.write_text(path.read_text().replace("SKILL.md#doctrine", "missing.md"))
        before = snapshot(root)
        result = invoke(root, "check", "--json")
        assert result.returncode == (1 if stale else 0), result
        if not stale:
            assert json.loads(result.stdout) == {"version": 1, "paths": []}
        assert snapshot(root) == before


def locations(root):
    for location, status in ((None, 2), ("hosted", 1), ("local", 1)):
        before = snapshot(root)
        result = invoke(root, "adopt", "--dry-run", location=location)
        assert result.returncode == status, result
        if location is None:
            assert "github-repository-settings: setting=GITHUB_STANDARD_CHECK_LOCATION" in result.stderr
        assert snapshot(root) == before
    rendered(root)
    for location in (None, "hosted", "local"):
        result = invoke(root, "check", location=location)
        assert result.returncode == 0, result
        # This record is the wrapper's documented check-report protocol.
        assert f"github-standard-check-location={location or 'unset'}\n" in result.stderr
    assert not (root / ".github/workflows").exists()


def settings(root):
    (root / "kendex.settings.toml").write_text('[env]\nGITHUB_STANDARD_CHECK_LOCATION = "hosted"\nGITHUB_STANDARD_BOT_REVIEW = "on"\n')
    result = invoke(root, "render", setting=None, location=None)
    assert result.returncode == 0 and (root / ".github/copilot-instructions.md").exists(), result
    result = invoke(root, "check", setting=None, location=None)
    assert result.returncode == 0 and "github-standard-check-location=hosted\n" in result.stderr, result
    for key, kwargs in (("GITHUB_STANDARD_CHECK_LOCATION", {"location": "invalid"}),
                        ("GITHUB_STANDARD_BOT_REVIEW", {"setting": "invalid"})):
        result = invoke(root, "render", **kwargs)
        assert result.returncode == 2 and f"setting={key}\n" in result.stderr, result
    (root / "kendex.settings.toml").write_text('[env]\nGITHUB_STANDARD_BOT_REVIEW = true\n')
    assert invoke(root, "render").returncode == 2


contracts = {"preview": preview, "symlink": symlink, "selection": selection,
             "equality": equality, "checking": checking, "locations": locations,
             "settings": settings}
for name, contract in contracts.items():
    contract(fixture(name))
    print(f"pass: {name}")

root = fixture("linked-installation")
store = scratch / "package-store"
shutil.move(str(root / "catalog"), store)
(root / "catalog").mkdir()
for package in ("github-repository-settings", "bot-instructions", "review-gate"):
    (root / "catalog" / package).symlink_to(store / package, target_is_directory=True)
    assert (root / "catalog" / package).is_symlink()
selection(root)
print("pass: linked installation")

# Each control changes a disposable production copy and reuses its contract.
for name, contract, path, old, new in (
    ("symlink-refusal", symlink, "bot-instructions/scripts/lib/writer.py",
     'if dry_run and os.path.islink(os.path.join(root, rel)):', 'if False:'),
    ("divergence", preview, "bot-instructions/scripts/lib/verbs.py",
     '_region_finding(ctx, seen[0], findings, dry_run)', 'None'),
    ("preview-write", preview, "bot-instructions/scripts/lib/writer.py",
     '    if dry_run:\n        return True', '    if False:\n        return True'),
    ("ignore-review", selection, "github-repository-settings/scripts/github-repository-settings",
     'off) output=local', 'off) output=full'),
    ("library-bytes", equality, "github-repository-settings/scripts/github-repository-settings",
     '--output "$output"', '--output full'),
    ("check-write", checking, "bot-instructions/scripts/lib/verbs.py",
     'def check_verb(ctx):\n', 'def check_verb(ctx):\n    open(ctx.root + "/check-write", "w").close()\n'),
    ("location-gate", locations, "github-repository-settings/scripts/github-repository-settings",
     '[ "$verb" = adopt ] && [ -z "$location" ]', '[ "$verb" = never ] && [ -z "$location" ]'),
):
    root = fixture(f"control-{name}")
    target = root / "catalog" / path
    assert not target.is_symlink()
    text = target.read_text()
    assert text.count(old) == 1, (name, old)
    changed = text.replace(old, new)
    assert changed != text
    # Git Bash must reach the mutant, not fail on rewritten CRLF script lines.
    target.write_text(changed, newline="")
    try:
        contract(root)
    except AssertionError:
        print(f"control rejected: {name}")
    else:
        raise AssertionError(f"control survived: {name}")
PY
