#!/usr/bin/env bash
# bash-runtime: 3.2
# Output selection across render, check, adopt, ownership and orphan cleanup.
# Inputs: scripts/, SKILL.md, schemas/, tests/lib/harness.sh, tests/fixtures/.

. "$(dirname "$0")/lib/harness.sh"
export MSYS=winsymlinks:nativestrict

repo="$(bi_new_repo output-mode)" || exit 1
if python3 -B - "$BI_ROOT/skills/bot-instructions" "$repo" "$BI_TMP" <<'PY'
import json
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

source, fixture, scratch = map(Path, sys.argv[1:])


def install(root, package=source):
    # The install path is deliberately unrelated to any harness directory.
    target = root / "catalog/review-tools"
    target.mkdir(parents=True)
    for name in ("SKILL.md", "schemas", "scripts"):
        item = package / name
        if item.is_dir():
            shutil.copytree(item, target / name)
        else:
            shutil.copy2(item, target / name)
    return target / "scripts/bot-instructions"


def invoke(launcher, root, *args):
    return subprocess.run([str(launcher), *args, "--repo", str(root)],
                          capture_output=True, text=True)


def snapshot(root):
    return {p.relative_to(root).as_posix():
            ("link", p.readlink().as_posix()) if p.is_symlink() else
            ("file", p.read_bytes()) if p.is_file() else ("dir", None)
            for p in root.rglob("*") if ".git" not in p.relative_to(root).parts}


def local_contract(root, launcher, *selection):
    before = snapshot(root)
    adopted = invoke(launcher, root, "adopt", "--output", "local", *selection)
    assert adopted.returncode == 1 and "agents-region:" in adopted.stderr, adopted
    checked = invoke(launcher, root, "check", "--output", "local", *selection)
    assert checked.returncode == 1 and "drift:" in checked.stderr, checked
    # Execute the command the operator copies from the shipped check.
    commands = [shlex.split(text) for text in re.findall(r"`([^`]+)`", checked.stderr)]
    repair, = [args for args in commands if len(args) > 1 and args[1] == "render"]
    rendered = subprocess.run(repair, cwd=root, capture_output=True, text=True)
    assert rendered.returncode == 0, rendered
    after = snapshot(root)
    changed = {p for p in before.keys() | after.keys() if before.get(p) != after.get(p)}
    assert changed == {"AGENTS.md"}, changed
    agents = (root / "AGENTS.md").read_text()
    assert "catalog/review-tools/SKILL.md#doc" in agents, agents
    target = next(word for word in agents.split() if word.startswith("catalog/review-tools/"))
    assert target.endswith("#doctrine") and (root / target.split("#")[0]).is_file(), target
    assert "## Doctrine\n" in (root / target.split("#")[0]).read_text(), target
    assert agents.split("## Code Review Rules")[0] == before["AGENTS.md"][1].decode().split("## Code Review Rules")[0]
    assert agents.split("## Something else")[1] == before["AGENTS.md"][1].decode().split("## Something else")[1]
    checked = invoke(launcher, root, "check", "--output", "local", "--json", *selection)
    assert checked.returncode == 0, checked
    assert json.loads(checked.stdout) == {"version": 1, "paths": []}, checked
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
    checked = invoke(launcher, root, "check", "--output", "local", "--staged", "--json", *selection)
    assert checked.returncode == 0 and json.loads(checked.stdout)["paths"] == [], checked
    assert invoke(launcher, root, "adopt", "--output", "local", *selection).returncode == 0
    assert snapshot(root) == after
    (root / "AGENTS.md").write_text(agents.replace(target, "wrong.md"))
    checked = invoke(launcher, root, "check", "--output", "local", *selection)
    assert checked.returncode == 1 and "drift:" in checked.stderr, checked


for world in ("absent", "remote-files", "remote-symlink", "installed-symlink", "named-symlink", "canonical-spec"):
    root = scratch / world
    shutil.copytree(fixture, root)
    launcher = install(root)
    selection = ()
    if world in ("installed-symlink", "named-symlink", "canonical-spec"):
        package = scratch / f"package-{world}"
        shutil.move(str(launcher.parent.parent), package)
        (root / "catalog/review-tools").symlink_to(package, target_is_directory=True)
        assert (root / "catalog/review-tools").is_symlink()
        if world == "named-symlink":
            selection = ("--spec", str(root / "catalog/review-tools"))
            launcher = source / "scripts/bot-instructions"
        elif world == "canonical-spec":
            selection = ("--spec", str(package))
    if world in ("remote-files", "remote-symlink"):
        full = invoke(launcher, root, "adopt")
        assert full.returncode == 1 and "agents-region:" in full.stderr, full
        assert invoke(launcher, root, "render").returncode == 0
        # Restore the hand-written region for the local adoption assertion.
        (root / "AGENTS.md").write_bytes((fixture / "AGENTS.md").read_bytes())
        remote = root / ".github/copilot-instructions.md"
        remote.write_bytes(b"hand edit\xff\n")
        orphan = root / ".github/instructions/retired.md"
        orphan.write_bytes((root / ".github/instructions/code-review.md").read_bytes())
        # Local mode must not load a remote bot's schema or compare its files.
        (root / ".bot-instructions/coderabbit-schema.json").unlink()
        if world == "remote-symlink":
            remote.unlink()
            remote.symlink_to(root / "README.md")
    local_contract(root, launcher, *selection)
    print(f"  ok   local output contract: {world}")

# A marked remote file is outside local ownership even with no bot table.
root = scratch / "unconfigured-local"
shutil.copytree(fixture, root)
launcher = install(root)
assert invoke(launcher, root, "adopt").returncode == 1
assert invoke(launcher, root, "render").returncode == 0
(root / "AGENTS.md").write_bytes((fixture / "AGENTS.md").read_bytes())
(root / "kendex.toml").write_text("schema = 7\n")
before = snapshot(root)
for verb in ("render", "check"):
    result = invoke(launcher, root, verb, "--output", "local",
                    *(["--json"] if verb == "check" else []))
    assert result.returncode == 0, result
assert snapshot(root) == before
print("  ok   local unconfigured ownership excludes marked remote files")


def external_refusal(root, launcher, package):
    before = snapshot(root)
    result = invoke(launcher, root, "adopt", "--output", "local", "--spec", str(package))
    assert result.returncode == 2, result
    assert result.stderr.splitlines()[0] == f"bot-instructions: spec={package}/SKILL.md", result
    assert snapshot(root) == before


# An external --spec without the matching checkout install has no portable pointer.
root = scratch / "external-spec"
shutil.copytree(fixture, root)
external_refusal(root, source / "scripts/bot-instructions", source)
print("  ok   external local spec refuses without writing")
for mode in ((), ("--output", "full")):
    assert invoke(source / "scripts/bot-instructions", root, "adopt", *mode,
                  "--spec", str(source)).returncode == (0 if mode else 1)
    assert invoke(source / "scripts/bot-instructions", root, "render", *mode,
                  "--spec", str(source)).returncode == 0
    assert invoke(source / "scripts/bot-instructions", root, "check", *mode,
                  "--spec", str(source)).returncode == 0
    if not mode:
        full_bytes = snapshot(root)
    else:
        assert snapshot(root) == full_bytes
print("  ok   external spec retains default and explicit full bytes")

# Local output is empty when Codex is off, even with remote bots enabled.
root = scratch / "local-codex-off"
shutil.copytree(fixture, root)
launcher = install(root)
manifest = root / "kendex.toml"
text = manifest.read_text()
for bot in ("codex", "copilot", "coderabbit"):
    assert text.count(f"{bot} = true") == 1
    text = text.replace(f"{bot} = true", f"{bot} = false")
manifest.write_text(text)
before = snapshot(root)
for flags in ((), ("--dry-run",)):
    result = invoke(launcher, root, "render", "--output", "local", *flags)
    assert result.returncode == 0, result
    assert snapshot(root) == before
    print(result.stdout.splitlines()[0])
print("  ok   local output stays empty with Codex off and remote bots on")


def controlled_copy(name, file, old, new):
    mutant = scratch / name
    shutil.copytree(source, mutant)
    path = mutant / file
    text = path.read_text()
    assert text.count(old) == 1, (path, old)
    changed = text.replace(old, new)
    assert changed != text
    path.write_text(changed)
    return mutant


for name, file, old, new, contract in (
    ("repair-mutant", "scripts/lib/render.py",
     'return verb if self.remote else f"{verb} --output local"', 'return verb', "local"),
    ("canonical-pointer-mutant", "scripts/lib/run.py",
     'os.path.join(installed_spec, "SKILL.md"), root',
     'os.path.join(os.path.realpath(installed_spec), "SKILL.md"), root', "symlink"),
    ("remote-pointer-mutant", "scripts/lib/render.py",
     "result.review_path = model.code_review_path if result.remote else local_review_path",
     "result.review_path = model.code_review_path", "local"),
    ("refusal-mutant", "scripts/lib/cli.py",
     "    return None\n", "    return spec_root\n", "refusal"),
):
    mutant = controlled_copy(name, file, old, new)
    root = scratch / f"control-{name}"
    shutil.copytree(fixture, root)
    launcher = install(root, mutant)
    if contract == "symlink":
        package = scratch / f"store-{name}"
        shutil.move(str(launcher.parent.parent), package)
        (root / "catalog/review-tools").symlink_to(package, target_is_directory=True)
        assert (root / "catalog/review-tools").is_symlink()
    try:
        if contract == "refusal":
            external_refusal(root, launcher, mutant)
        else:
            local_contract(root, launcher)
    except AssertionError:
        print(f"  ok   control: {name} rejected")
    else:
        raise AssertionError(f"contract accepted {name}")

PY
then
  ok 'output selection contracts and pointer control pass'
else
  bad 'output selection contracts and pointer control pass'
fi

bi_summary
