#!/usr/bin/env bash
# bash-runtime: 3.2
# Inputs: SKILL.md, scripts/, ../../tools/ci-job-set, ../bot-instructions/, ../review-gate/scripts/lib/settings.sh,
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

skills = Path(sys.argv[1]).resolve()
scratch = Path(sys.argv[2])
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
    # Unit fixtures model an already armed scope; lifecycle proof uses real core.
    record = root / ".git/kendex/armed/github-repository-settings/-record"
    record.parent.mkdir(parents=True)
    record.write_text("fixture\n")
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


def assert_not_adopted(result):
    assert result.returncode == 0 and result.stdout == "", result
    # Command callers consume these diagnostic records, not the English line.
    assert result.stderr.splitlines()[:2] == [
        "github-standard-check-location=unset",
        "github-repository-settings: not-adopted=unset",
    ], result
    assert "bot-instructions:" not in result.stderr, result


def adoption(root):
    rendered(root, "on")
    # Full output differs from the local default even before the stale edit.
    path = root / "AGENTS.md"
    original = path.read_text()
    assert original.count(".github/instructions/code-review.md") == 1
    path.write_text(original.replace(".github/instructions/code-review.md", "missing.md"))
    assert path.read_text() != original
    subprocess.run(["git", "-C", str(root), "add", "-A"], env=environment, check=True)
    for review, location, status in ((None, None, 0), ("", "", 0),
                                     (None, "", 0), ("", None, 0),
                                     ("on", None, 1), ("off", None, 1),
                                     (None, "hosted", 1), ("", "local", 1)):
        for args in ((), ("--staged",)):
            before = snapshot(root)
            result = invoke(root, "check", "--json", *args, setting=review, location=location)
            if status == 0:
                assert_not_adopted(result)
            else:
                assert result.returncode == status, (review, location, result)
            assert snapshot(root) == before


def staged(root):
    # Expected output and exit classes are independent of the wrapper's selection.
    for name, status, review, private, process, output, nested, location in (
        ("clean", 0, "off", "", {}, "local", None, "hosted"),
        ("stale", 1, "off", "", {}, "local", None, "hosted"),
        ("incomplete", 2, "off", "", {}, "local", None, "hosted"),
        ("absent-settings", 0, None, "", {}, "full", None, "unset"),
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
         "full", None, "unset"),
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
        if name in ("absent-settings", "root-symlink-defaults"):
            assert_not_adopted(result)
            assert snapshot(root) == before, name
            continue
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
    for verb, args, review, status in (("adopt", ("--dry-run",), None, 1),
                                       ("adopt", ("--dry-run",), "", 2),
                                       ("render", (), "", 2), ("render", (), None, 0)):
        before = snapshot(root)
        result = invoke(root, verb, *args, setting=review)
        assert result.returncode == status, (verb, review, result)
        if verb == "adopt" or status == 2:
            assert snapshot(root) == before
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
    for failure in ("syntax", "unreadable", "bot-instructions", "review-gate"):
        broken = fixture(f"settings-{failure}")
        if failure == "syntax":
            (broken / "kendex.settings.toml").write_text('[env]\nOTHER = true\n')
        elif failure == "unreadable":
            (broken / "kendex.settings.toml").symlink_to("missing-settings.toml")
        elif failure == "bot-instructions":
            (broken / "catalog/bot-instructions/scripts/bot-instructions").unlink()
        else:
            (broken / "catalog/review-gate/scripts/lib/settings.sh").unlink()
        subprocess.run(["git", "-C", str(broken), "add", "-A"], env=environment, check=True)
        for args in ((), ("--staged",)):
            before = snapshot(broken)
            result = invoke(broken, "check", *args, setting=None, location=None)
            assert result.returncode == 2, (failure, args, result)
            assert "github-repository-settings: not-adopted=" not in result.stderr, result
            assert snapshot(broken) == before


def write_boundary(root):
    record = root / ".git/kendex/armed/github-repository-settings/-record"
    record.unlink()
    for verb, args in (("render", ()), ("adopt", ()), ("retire", ()),
                       ("retire", ("--dry-run",)), ("retire", ("--json",))):
        before = snapshot(root)
        result = invoke(root, verb, *args)
        assert result.returncode == 2, (verb, args, result)
        if not args:
            assert "not-set-up=github-repository-settings" in result.stderr, result
        assert snapshot(root) == before
    # Core's declared installer may run before core records arming.
    result = invoke(root, "setup-install", location=None)
    assert result.returncode == 2 and "setting=GITHUB_STANDARD_CHECK_LOCATION" in result.stderr, result
    before = snapshot(root)
    result = invoke(root, "setup-install")
    assert result.returncode == 0, result
    assert not record.exists()
    assert {p for p in before.keys() | snapshot(root).keys()
            if before.get(p) != snapshot(root).get(p)} == {"AGENTS.md"}


def retirement(root, command="retire", armed=True):
    rendered(root, "on")
    extra = root / ".github/instructions/personal.instructions.md"
    extra.write_text("Personal review instructions.\n")
    if not armed:
        (root / ".git/kendex/armed/github-repository-settings/-record").unlink()
    before = snapshot(root)
    result = invoke(root, command)
    assert result.returncode == 0, result
    after = snapshot(root)
    # Expected paths are the enabled fixture contract, not the retire discovery.
    assert set(before) - set(after) == {".github/copilot-instructions.md",
                                       ".github/instructions/code-review.md",
                                       ".github/instructions/docs-architecture.instructions.md"}
    for path in set(before) & set(after) - {"AGENTS.md"}:
        assert before[path] == after[path], path
    current = (root / "AGENTS.md").read_bytes()
    assert current.split(b"## Code Review Rules")[0] == agents_bytes.split(b"## Code Review Rules")[0]
    assert current.split(b"## Other rules")[1] == agents_bytes.split(b"## Other rules")[1]
    assert b"generated by" not in current


def automatic_render(root):
    # Both automatic armed render and unarmed render_once use this declaration.
    for name, path, armed in (("file-armed", ".github/copilot-instructions.md", True),
                              ("region-armed", "AGENTS.md", True),
                              ("file-once", ".github/copilot-instructions.md", False),
                              ("region-once", "AGENTS.md", False)):
        sample = fixture(root.name + "-" + name)
        rendered(sample, "on")
        personal = agents_bytes if path == "AGENTS.md" else b"Personal instructions.\n"
        (sample / path).write_bytes(personal)
        if not armed:
            (sample / ".git/kendex/armed/github-repository-settings/-record").unlink()
        result = invoke(sample, "setup-install", setting="on")
        assert result.returncode == 2 and "bot-instructions: render=" in result.stderr, result
        assert (sample / path).read_bytes() == personal, (name, result)


def region_bounds(root):
    # Core supplies a snapshot outside the repository; neither settings nor
    # a worktree arming record licenses this read-only byte-range operation.
    (root / ".git/kendex/armed/github-repository-settings/-record").unlink()
    (root / "catalog/review-gate/scripts/lib/settings.sh").unlink()
    prefix = b"# Prefix\n\n## Code Review Rules\n"
    body = "\nReview café.\n\n".encode()
    suffix = b"## Personal\n\nKeep this.\n"
    for name, raw, status in (("valid", prefix + body + suffix, 0),
                               ("no-heading", b"Personal instructions.\n", 2),
                               ("not-utf8", b"\xff", 2)):
        supplied = scratch / (root.name + "-" + name + ".md")
        supplied.write_bytes(raw)
        before = snapshot(root)
        result = invoke(root, "region-bounds", "--input", str(supplied),
                        setting="invalid", location="invalid")
        assert result.returncode == status, (name, result)
        if status == 0:
            # OwnedRegion consumes exactly this byte range protocol.
            assert result.stdout == f"region bounds\t{len(prefix)}\t{len(prefix + body)}\n", result
            assert result.stderr == "", result
        else:
            assert result.stdout == "" and result.stderr.startswith("bot-instructions: region-input="), result
        assert snapshot(root) == before and supplied.read_bytes() == raw


def arming_states(root, states=None):
    # Core's normal removal reaches plain projects and clones without records;
    # broken metadata/configuration and unreadable records must refuse cleanup.
    states = states or (("clone", 0), ("plain", 0), ("broken-git", 2),
                        ("invalid-config", 2), ("unreadable-record", 2))
    for state, status in states:
        sample = fixture(root.name + "-" + state)
        rendered(sample, "on")
        record = sample / ".git/kendex/armed/github-repository-settings/-record"
        record.unlink()
        if state in ("plain", "broken-git"):
            shutil.rmtree(sample / ".git")
            if state == "broken-git":
                (sample / ".git").write_text("gitdir: missing-git-directory\n")
        elif state == "invalid-config":
            (sample / ".git/config").write_text("[invalid\n")
        elif state == "unreadable-record":
            old_record = sample / ".git/kendex/armed/bot-instructions/-record"
            old_record.mkdir(parents=True)
        before = snapshot(sample)
        result = invoke(sample, "setup-retire")
        assert result.returncode == status, (state, result)
        if status:
            assert "github-repository-settings: core-retire-failed=" in result.stderr, result
            assert snapshot(sample) == before, state
        else:
            current = (sample / "AGENTS.md").read_bytes()
            assert b"generated by" not in current, state
            assert current.split(b"## Code Review Rules")[0] == agents_bytes.split(b"## Code Review Rules")[0]
            assert current.split(b"## Other rules")[1] == agents_bytes.split(b"## Other rules")[1]
            after = snapshot(sample)
            assert set(before) - set(after) == {".github/copilot-instructions.md",
                                               ".github/instructions/code-review.md",
                                               ".github/instructions/docs-architecture.instructions.md"}, state
            for path in set(before) & set(after) - {"AGENTS.md"}:
                assert before[path] == after[path], (state, path)


def core_cleanup(root):
    partial = fixture(root.name + "-partial")
    (partial / ".git/kendex/armed/github-repository-settings/-record").unlink()
    personal = partial / ".github/instructions/code-review.md"
    personal.parent.mkdir(parents=True)
    personal.write_bytes(b"Personal doctrine.\n")
    before_personal = personal.read_bytes()
    before_unrelated = (partial / "unrelated.bin").read_bytes()
    # The real renderer replaces copilot first, then refuses the unmanaged
    # doctrine. This is a reachable partial install, with no new arming.
    result = invoke(partial, "setup-install", setting="on")
    assert result.returncode == 2 and "bot-instructions: render=" in result.stderr, result
    produced = partial / ".github/copilot-instructions.md"
    assert produced.read_bytes().startswith(b"<!-- generated by bot-instructions"), result
    result = invoke(partial, "setup-retire", setting="invalid", location="invalid")
    assert result.returncode == 0, result
    assert not produced.exists()
    assert personal.read_bytes() == before_personal
    assert (partial / "unrelated.bin").read_bytes() == before_unrelated
    assert not (partial / ".git/kendex/armed/github-repository-settings/-record").exists()


class RecoveryFailed(AssertionError):
    pass


def lifecycle_engine():
    # The existing Linux suite owner supplies checkout kendex, and the released
    # package leg supplies its release. An explicit path binds this same fixture
    # to v1.21.0 for the recorded release-interface proof, without downloading.
    override = os.environ.get("GITHUB_REPOSITORY_SETTINGS_KENDEX", "")
    binary = override or shutil.which("kendex", path=environment.get("PATH"))
    if binary:
        binary = str(Path(binary).resolve())
        assert os.access(binary, os.X_OK), binary
        return binary
    policy = subprocess.run([bash, str(skills.parent / "tools/ci-job-set"),
                             "--suite-kendex", "macOS" if sys.platform == "darwin" else "Linux",
                             "skills/github-repository-settings/tests/github-repository-settings.test.sh"],
                            env=environment, capture_output=True, text=True)
    assert policy.returncode == 0 and policy.stdout.strip() == "none", policy
    print("not-run: core recovery fixture; suite policy supplies no kendex on this platform")
    return None


def core_recovery(binary, name, break_cleanup=False):
    home = scratch / name
    root = home / "project"
    catalog = root / "catalog/skills"
    root.mkdir(parents=True)
    for package in ("github-repository-settings", "bot-instructions", "review-gate"):
        shutil.copytree(skills / package, catalog / package,
                        ignore=shutil.ignore_patterns("tests", "__pycache__"))
    for package in ("reviewer", "harness-ci"):
        dependency = catalog / package
        dependency.mkdir()
        (dependency / "SKILL.md").write_text(
            f"---\nname: {package}\ndescription: Inert fixture dependency\n---\nFixture.\n")
    if break_cleanup:
        target = catalog / "github-repository-settings/scripts/github-repository-settings"
        source = target.read_text()
        original = 'if operation == "core-retire" and armed(root, "bot-instructions"):'
        assert source.count(original) == 1
        changed = source.replace(original, 'if False and armed(root, "bot-instructions"):')
        assert changed != source
        target.write_text(changed, newline="")
    # Record the actual old render exit, including core's recovery invocation.
    # The original renderer still executes; this is not a simulated transfer.
    old = catalog / "bot-instructions/scripts/bot-instructions"
    source = old.read_text()
    original = 'exec python3 -B "$here/lib/main.py" "$@"'
    assert source.count(original) == 1
    changed = source.replace(original, '''status=0
python3 -B "$here/lib/main.py" "$@" || status=$?
if [ "${1:-}" = render ]; then printf '%s\\n' "$status" > old-render.exit; fi
exit "$status"''')
    assert changed != source
    old.write_text(changed, newline="")
    (root / "kendex.toml").write_text('''schema = 7
[install]
harnesses = ["codex"]
method = "copy"
[sources.cat]
path = "catalog"
[bot-instructions]
schema = 1
[bot-instructions.repo]
name = "fixture"
summary = "Recovery fixture."
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
    (root / "personal.bin").write_bytes(bytes(range(256)))
    env = dict(environment, HOME=str(home), KENDEX_REAL_HOME=str(home),
               XDG_CONFIG_HOME=str(home / ".config"),
               XDG_DATA_HOME=str(home / ".local/share"), XDG_CACHE_HOME=str(home / ".cache"),
               KENDEX_UI="plain", KENDEX_BACKGROUND_REFRESH="off", GIT_CONFIG_NOSYSTEM="1",
               GIT_CEILING_DIRECTORIES=str(home))
    for args in (("init", "-q"), ("config", "gc.auto", "0"),
                 ("config", "maintenance.auto", "false")):
        subprocess.run(["git", "-C", str(root), *args], env=env, check=True, capture_output=True)
    adopted = subprocess.run([bash, str(old), "adopt", "--repo", str(root)],
                             env=env, capture_output=True, text=True)
    assert adopted.returncode == 1 and "agents-region:" in adopted.stderr, adopted

    def cli(*args):
        return subprocess.run([binary, *args], cwd=root, env=env, capture_output=True, text=True)

    version = cli("--version")
    assert version.returncode == 0, version
    print("recovery engine=" + version.stdout.strip())
    installed = cli("add", "cat", "--skill", "bot-instructions", "--yes", "--leave",
                    "--allow-repo-effects", "--throwaway")
    assert installed.returncode == 0, installed
    old_record = root / ".git/kendex/armed/bot-instructions/-record"
    new_record = root / ".git/kendex/armed/github-repository-settings/-record"
    assert old_record.is_file() and not new_record.exists()
    personal = root / ".github/instructions/personal.instructions.md"
    personal.write_bytes(b"Personal extension.\n")

    def review_files():
        result = {str(p.relative_to(root)): p.read_bytes()
                  for p in (root / ".github").rglob("*") if p.is_file()}
        result["AGENTS.md"] = (root / "AGENTS.md").read_bytes()
        assert ".github/copilot-instructions.md" in result
        return result

    canonical = review_files()
    # Deliberately marked edits are replaced by recovery's ordinary full render.
    copilot = root / ".github/copilot-instructions.md"
    copilot.write_bytes(copilot.read_bytes() + b"\nMarked personal edit.\n")
    agents = root / "AGENTS.md"
    before = agents.read_bytes()
    assert before.count(b"## Other rules") == 1
    agents.write_bytes(before.replace(b"## Other rules", b"Marked personal edit.\n\n## Other rules"))
    before_failure = review_files()
    # An absent choice must refuse before any installer write, independently
    # of core's later recovery rendering.
    refused = subprocess.run([bash, str(catalog / "github-repository-settings/scripts/github-repository-settings"),
                              "setup-install", "--repo", str(root)],
                             env=env, capture_output=True, text=True)
    assert refused.returncode == 2 and "setting=GITHUB_STANDARD_CHECK_LOCATION" in refused.stderr, refused
    assert review_files() == before_failure
    (root / "old-render.exit").unlink()
    failed = cli("add", "cat", "--skill", "github-repository-settings", "--yes", "--leave",
                 "--allow-repo-effects", "--throwaway")
    assert failed.returncode != 0 and "setting=GITHUB_STANDARD_CHECK_LOCATION" in failed.stderr, failed
    recovery_exit = (root / "old-render.exit").read_text()
    if recovery_exit != "0\n":
        raise RecoveryFailed(f"old recovery exit={recovery_exit!r}; {failed.stderr}")
    assert old_record.is_file() and not new_record.exists()
    assert review_files() == canonical
    assert (root / "personal.bin").read_bytes() == bytes(range(256))
    # Compare with an executing ordinary old full render on the same inputs.
    ordinary = subprocess.run([bash, str(root / ".agents/skills/bot-instructions/scripts/bot-instructions"),
                               "render", "--repo", str(root)], cwd=root, env=env, capture_output=True, text=True)
    assert ordinary.returncode == 0 and review_files() == canonical, ordinary


contracts = {"arming-states": arming_states,
             "automatic-render": automatic_render, "region-bounds": region_bounds,
             "core-cleanup": core_cleanup, "write-boundary": write_boundary, "retirement": retirement, "preview": preview, "symlink": symlink, "selection": selection,
             "equality": equality, "checking": checking, "adoption": adoption,
             "staged": staged, "locations": locations,
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

# One control proves the contracts go red: a preview that writes.
old, new = '    if dry_run:\n        return True', '    if False:\n        return True'
root = fixture("control-preview-write")
target = root / "catalog" / "bot-instructions/scripts/lib/writer.py"
assert not target.is_symlink()
text = target.read_text()
assert text.count(old) == 1, old
changed = text.replace(old, new)
assert changed != text
# Git Bash must reach the mutant, not fail on rewritten CRLF script lines.
target.write_text(changed, newline="")
try:
    preview(root)
except AssertionError:
    completed += 1
    print("control rejected: preview-write")
else:
    raise AssertionError("control survived: preview-write")

# The ordinary-write guard must reject a checkout where core recorded nothing.
root = fixture("control-unarmed-write")
target = launcher(root)
text = target.read_text()
old = 'effects armed "$PWD" "$skills_dir"'
assert text.count(old) == 1
changed = text.replace(old, 'true')
assert changed != text
target.write_text(changed, newline="")
try:
    write_boundary(root)
except AssertionError:
    completed += 1
    print("control rejected: unarmed-write")
else:
    raise AssertionError("control survived: unarmed-write")

# Prove the plain-project removal row detects loss of absence handling.
root = fixture("control-absent-repository")
target = launcher(root)
text = target.read_text()
old = '            return False\n        raise OSError(f"probe repository'
assert text.count(old) == 1
changed = text.replace(old, '            raise OSError("absence control")\n        raise OSError(f"probe repository')
assert changed != text
target.write_text(changed, newline="")
# arming_states creates its own installation from the package source. Point
# its fixture source at this disposable catalog so the mutation is exercised.
original_skills = skills
skills = root / "catalog"
try:
    arming_states(root, (("plain", 0),))
except AssertionError:
    completed += 1
    print("control rejected: absent-repository")
else:
    raise AssertionError("control survived: absent-repository")
finally:
    skills = original_skills

binary = lifecycle_engine()
if binary is not None:
    core_recovery(binary, "core-recovery")
    completed += 1
    print("pass: core recovery preserves the armed predecessor")
    try:
        core_recovery(binary, "control-core-recovery", break_cleanup=True)
    except RecoveryFailed:
        completed += 1
        print("control rejected: cleanup removed old armed region")
    else:
        raise AssertionError("control survived: cleanup removed old armed region")

# skills/orch/tests/run-all.sh reads this numeric suite summary.
print(f"{completed} passed, 0 failed")
PY
