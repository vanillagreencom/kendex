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


def invoke(root, verb, *args, setting="off", location="local", library=False, extra_env=None):
    env = dict(environment)
    if setting is not None:
        env["GITHUB_STANDARD_BOT_REVIEW"] = setting
    if location is not None:
        env["GITHUB_STANDARD_CHECK_LOCATION"] = location
    env.update(extra_env or {})
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


def staged(root):
    # Expected output and exit classes are independent of the wrapper's selection.
    for name, status, review, private, process, output, nested, location in (
        ("clean", 0, "off", "", {}, "local", None, "hosted"),
        ("stale", 1, "off", "", {}, "local", None, "hosted"),
        ("incomplete", 2, "off", "", {}, "local", None, "hosted"),
        ("absent-settings", 0, None, "", {}, "local", None, "unset"),
        ("private", 0, "on", "GITHUB_STANDARD_BOT_REVIEW=off\n", {}, "local", None, "hosted"),
        ("process", 0, "off", "GITHUB_STANDARD_BOT_REVIEW=off\n",
         {"GITHUB_STANDARD_BOT_REVIEW": "on", "GITHUB_STANDARD_CHECK_LOCATION": "hosted",
          "KENDEX_ENV_FILE": "process.env"}, "full", None, "hosted"),
        ("nested-tracked", 0, "off", "", {}, "full", "tracked", "local"),
        ("nested-untracked", 0, "off", "", {}, "full", "untracked", "local"),
        ("nested-private", 0, "off", "", {}, "local", "private", "local"),
        ("nested-deleted", 0, "off", "", {}, "local", "deleted", "hosted"),
        ("nested-symlink", 2, "off", "", {}, "local", "symlink", "local"),
        ("root-symlink", 2, "on", "", {}, "local", None, "hosted"),
        ("root-symlink-explicit", 0, "on", "", {"REVIEW_GATE_SETTINGS_FILE": "explicit.toml"},
         "local", None, "hosted"),
        ("root-symlink-defaults", 0, "on", "", {"REVIEW_GATE_SETTINGS_FILE": "/dev/null"},
         "local", None, "unset"),
    ):
        config = root / "kendex.settings.toml"
        config.unlink(missing_ok=True)
        if review is not None:
            config.write_text('[env]\nGITHUB_STANDARD_CHECK_LOCATION = "hosted"\n'
                              f'GITHUB_STANDARD_BOT_REVIEW = "{review}"\n'
                              'KENDEX_ENV_FILE = "staged.env"\n')
        (root / "staged.env").write_text(private)
        (root / "tree.env").write_text("GITHUB_STANDARD_BOT_REVIEW=on\nGITHUB_STANDARD_CHECK_LOCATION=local\n")
        (root / "process.env").write_text("GITHUB_STANDARD_BOT_REVIEW=off\nGITHUB_STANDARD_CHECK_LOCATION=local\n")
        (root / "explicit.toml").write_text('[env]\nGITHUB_STANDARD_BOT_REVIEW = "off"\n'
                                           'GITHUB_STANDARD_CHECK_LOCATION = "hosted"\n')
        nested_config = root / ".kendex/settings.toml"
        if nested is not None:
            nested_config.parent.mkdir(exist_ok=True)
            nested_config.write_text('[env]\nGITHUB_STANDARD_BOT_REVIEW = "on"\n'
                                     'GITHUB_STANDARD_CHECK_LOCATION = "local"\n'
                                     'KENDEX_ENV_FILE = "nested.env"\n')
            (root / "nested.env").write_text("GITHUB_STANDARD_BOT_REVIEW=off\n" if nested == "private" else "")
        else:
            nested_config.unlink(missing_ok=True)
        link = nested_config if nested == "symlink" else config if name.startswith("root-symlink") else None
        if link is not None:
            target = root / "linked-settings.toml"
            target.write_bytes(link.read_bytes())
            link.unlink()
            link.symlink_to("../linked-settings.toml" if link == nested_config else "linked-settings.toml")
            assert link.is_symlink(), name
        rendered(root, "on" if output == "full" else "off")
        if name == "stale":
            path = root / "AGENTS.md"
            path.write_text(path.read_text().replace("SKILL.md#doctrine", "missing.md"))
        subprocess.run(["git", "-C", str(root), "add", "-A"], env=environment, check=True)
        if nested == "deleted":
            subprocess.run(["git", "-C", str(root), "-c", "user.name=Fixture", "-c",
                            "user.email=fixture@example.invalid", "commit", "-qm", "nested settings"],
                           env=environment, check=True, capture_output=True)
        if nested in ("untracked", "deleted"):
            subprocess.run(["git", "-C", str(root), "rm", "--cached", ".kendex/settings.toml"],
                           env=environment, check=True, capture_output=True)
        elif nested is not None and nested != "symlink":
            nested_config.write_text('[env]\nGITHUB_STANDARD_BOT_REVIEW = "off"\n'
                                     'GITHUB_STANDARD_CHECK_LOCATION = "hosted"\n'
                                     'KENDEX_ENV_FILE = "tree.env"\n')
        if name == "incomplete":
            # A staged package deletion leaves the doctrine unavailable.
            subprocess.run(["git", "-C", str(root), "rm", "--cached", "catalog/bot-instructions/SKILL.md"],
                           env=environment, check=True, capture_output=True)
        config.write_text('[env]\nGITHUB_STANDARD_CHECK_LOCATION = "local"\n'
                          'GITHUB_STANDARD_BOT_REVIEW = "on"\nKENDEX_ENV_FILE = "tree.env"\n')
        before = snapshot(root)
        result = invoke(root, "check", "--staged", "--json", setting=None,
                        location=None, extra_env=process)
        if status == 2 and link is not None:
            assert result.returncode == status and result.stdout == "", (name, result)
            # Command callers read the shared diagnostics protocol.
            assert result.stderr.splitlines()[0] == f"review-gate-error=settings-index-mode value={link.relative_to(root)}", (name, result)
            assert snapshot(root) == before, name
            continue
        expected = invoke(root, "check", "--staged", "--json", "--output", output, library=True)
        assert result.returncode == expected.returncode == status, (name, result, expected)
        assert result.stdout == expected.stdout, (name, result, expected)
        # The check-report protocol is consumed by command callers.
        assert result.stderr == f"github-standard-check-location={location}\n" + expected.stderr, (name, result)
        assert snapshot(root) == before, name
    for verb, args in (("render", ()), ("adopt", ("--dry-run",))):
        before = snapshot(root)
        result = invoke(root, verb, "--staged", *args)
        assert result.returncode == 2 and "usage=--staged\n" in result.stderr, result
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
             "equality": equality, "checking": checking, "staged": staged, "locations": locations,
             "settings": settings}
completed = 0
for name, contract in contracts.items():
    contract(fixture(name))
    completed += 1
    print(f"pass: {name}")

root = fixture("linked-installation")
store = scratch / "package-store"
shutil.move(str(root / "catalog"), store)
(root / "catalog").mkdir()
for package in ("github-repository-settings", "bot-instructions", "review-gate"):
    (root / "catalog" / package).symlink_to(store / package, target_is_directory=True)
    assert (root / "catalog" / package).is_symlink()
selection(root)
completed += 1
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
    ("staged-settings", staged, "github-repository-settings/scripts/github-repository-settings",
     'rg_settings_index_sources "$staged_settings" || exit 2', ':'),
    ("nested-settings", staged, "review-gate/scripts/lib/settings.sh",
     'rg_settings_nested_source=$nested', 'rg_settings_nested_source="$dir/absent.toml"'),
    ("staged-source-mode", staged, "review-gate/scripts/lib/settings.sh",
     "*) entry='' ;;", "*) : ;;"),
    ("staged-option", staged, "github-repository-settings/scripts/github-repository-settings",
     'staged=true; args+=("$1")', 'staged=true'),
    ("staged-status", staged, "github-repository-settings/scripts/github-repository-settings",
     'exit "$status"', 'exit 0'),
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
        completed += 1
        print(f"control rejected: {name}")
    else:
        raise AssertionError(f"control survived: {name}")

# skills/orch/tests/run-all.sh reads this numeric suite summary.
print(f"{completed} passed, 0 failed")
PY
