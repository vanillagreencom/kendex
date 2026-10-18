#!/usr/bin/env bash
# bash-runtime: 3.2
# Output selection across render, check, adopt, ownership and orphan cleanup.
# Inputs: scripts/, SKILL.md, schemas/, tests/lib/harness.sh, tests/fixtures/.

. "$(dirname "$0")/lib/harness.sh"

repo="$(bi_new_repo output-mode)" || exit 1
if python3 -B - "$BI_ROOT/skills/bot-instructions" "$repo" "$BI_TMP" <<'PY'
import json
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


def local_contract(root, launcher):
    before = snapshot(root)
    adopted = invoke(launcher, root, "adopt", "--output", "local")
    assert adopted.returncode == 1 and "agents-region:" in adopted.stderr, adopted
    rendered = invoke(launcher, root, "render", "--output", "local")
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
    checked = invoke(launcher, root, "check", "--output", "local", "--json")
    assert checked.returncode == 0, checked
    assert json.loads(checked.stdout) == {"version": 1, "paths": []}, checked
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
    checked = invoke(launcher, root, "check", "--output", "local", "--staged", "--json")
    assert checked.returncode == 0 and json.loads(checked.stdout)["paths"] == [], checked
    assert invoke(launcher, root, "adopt", "--output", "local").returncode == 0
    assert snapshot(root) == after
    (root / "AGENTS.md").write_text(agents.replace(target, "wrong.md"))
    checked = invoke(launcher, root, "check", "--output", "local")
    assert checked.returncode == 1 and "drift:" in checked.stderr, checked


for world in ("absent", "remote-files", "remote-symlink"):
    root = scratch / world
    shutil.copytree(fixture, root)
    launcher = install(root)
    if world != "absent":
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
    local_contract(root, launcher)
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

# The pointer assertion must reject the full-mode target in a local build.
mutant = scratch / "pointer-mutant"
shutil.copytree(source, mutant)
path = mutant / "scripts/lib/render.py"
text = path.read_text()
old = "result.review_path = model.code_review_path if result.remote else local_review_path"
assert text.count(old) == 1
path.write_text(text.replace(old, "result.review_path = model.code_review_path"))
root = scratch / "wrong-local-pointer"
shutil.copytree(fixture, root)
launcher = install(root, mutant)
try:
    local_contract(root, launcher)
except AssertionError:
    print("  ok   control: local contract rejects an unwritten remote pointer")
else:
    raise AssertionError("local contract accepted the full-mode pointer")
PY
then
  ok 'output selection contracts and pointer control pass'
else
  bad 'output selection contracts and pointer control pass'
fi

bi_summary
