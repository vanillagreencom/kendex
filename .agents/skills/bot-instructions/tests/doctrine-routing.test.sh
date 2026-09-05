#!/usr/bin/env bash
# `doctrine-routing`: one red control per rejection clause.
#
# Every control is a **fixture spec copy** passed with `--spec`, never an edit
# to the running copy: a suite that edited the tree it grades would be grading
# itself. They run `render --dry-run`, which validates and writes nothing —
# `drift` is skipped on render, and a doctrine change is a byte change by
# definition, so on `check` every fixture here would red `drift` as well.

. "$(dirname "$0")/lib/harness.sh"

repo="$(bi_rendered_repo routing)" || exit 1
PKG="$BI_ROOT/skills/bot-instructions"

# A spec copy is `SKILL.md` plus `schemas/renders.md`, and one flag names both
# because this validator holds the headings in one against the rows in the
# other.
new_spec() {
  local dir
  dir="$BI_TMP/spec-$1"
  rm -rf -- "${dir:?}"
  mkdir -p "$dir/schemas"
  cp "$PKG/SKILL.md" "$dir/SKILL.md"
  cp "$PKG/schemas/renders.md" "$dir/schemas/renders.md"
  printf '%s\n' "$dir"
}

expect_green "the running copy's own doctrine and routing agree" \
  render --dry-run --repo "$repo"

# 1. A `###` block id with no row: an unrouted block is an error, never a
#    silent drop.
spec="$(new_spec unrouted)"
python3 - "$spec/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("\n## Adding a repo\n", "\n### unrouted\n\nA block no column carries.\n\n## Adding a repo\n")
open(p, "w").write(s)
PY
expect_red doctrine-routing 'a doctrine block with no routing row' \
  render --dry-run --repo "$repo" --spec "$spec"

# 2. A routing row naming an id the doctrine source does not define. Set
#    equality in both directions: the one-directional half leaves the orphaned
#    row unchecked.
spec="$(new_spec ghost-row)"
python3 - "$spec/schemas/renders.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
row = "| `trust-model` |"
ghost = "| `no-such-block` | – | – | – | – | – | – | – | – |\n"
s = s.replace(row, ghost + row, 1)
open(p, "w").write(s)
PY
expect_red doctrine-routing 'a routing row naming no doctrine heading' \
  render --dry-run --repo "$repo" --spec "$spec"

# 3. A position repeated inside a column.
spec="$(new_spec repeat)"
python3 - "$spec/schemas/renders.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("| `rounds` | 2 |", "| `rounds` | 1 |", 1)
open(p, "w").write(s)
PY
expect_red doctrine-routing 'a position repeated inside a column' \
  render --dry-run --repo "$repo" --spec "$spec"

# 4. A gap in a column's positions, which must run 1..n.
spec="$(new_spec gap)"
python3 - "$spec/schemas/renders.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("| `rounds` | 2 |", "| `rounds` | 9 |", 1)
open(p, "w").write(s)
PY
expect_red doctrine-routing 'a gap in a column, whose positions must run 1..n' \
  render --dry-run --repo "$repo" --spec "$spec"

# 5/6. A missing block in a column that carries every block. Delete the `8`
#    from reply-contract's AGENTS.md cell and Codex loses the reply contract
#    with every other validator green.
spec="$(new_spec agents-hole)"
python3 - "$spec/schemas/renders.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("| `reply-contract` | 8 |", "| `reply-contract` | – |", 1)
open(p, "w").write(s)
PY
expect_red doctrine-routing 'a block missing from the AGENTS.md column' \
  render --dry-run --repo "$repo" --spec "$spec"

spec="$(new_spec macroscope-hole)"
python3 - "$spec/schemas/renders.md" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"(\| `reply-contract` \|.*\| )8 \|\n", r"\1– |\n", s, count=1)
open(p, "w").write(s)
PY
expect_red doctrine-routing 'a block missing from the macroscope doctrine.md column' \
  render --dry-run --repo "$repo" --spec "$spec"

# 7. The frozen-id invariant. Renaming a heading and its row together leaves
#    both sets agreeing, so a comparison of the pair passes and a consuming
#    repo's `[bot-instructions.doctrine.append]` on the old id silently reaches nothing. The
#    comparison is against the frozen set, which lives in the implementation.
spec="$(new_spec renamed-pair)"
python3 - "$spec/SKILL.md" "$spec/schemas/renders.md" <<'PY'
import sys
skill, renders = sys.argv[1], sys.argv[2]
s = open(skill).read().replace("\n### severity\n", "\n### severity-honesty\n", 1)
open(skill, "w").write(s)
r = open(renders).read().replace("| `severity` |", "| `severity-honesty` |", 1)
open(renders, "w").write(r)
PY
expect_red doctrine-routing 'a heading and its row renamed together, against the frozen set' \
  render --dry-run --repo "$repo" --spec "$spec"

# A spec copy with no readable version: a doctrine change would otherwise land
# under a stamp naming doctrine it does not carry.
spec="$(new_spec no-version)"
python3 - "$spec/SKILL.md" <<'PY'
import sys, re
p = sys.argv[1]
s = re.sub(r'\n  version: "[^"]*"', "", open(p).read(), count=1)
open(p, "w").write(s)
PY
expect_message "no \`version:\` under metadata" 'a spec copy with no readable version' \
  render --dry-run --repo "$repo" --spec "$spec"

# The version is interpolated into a comment. One carrying `-->` or a newline
# would end that comment and put the rest into a generated file as live
# reviewer instructions.
spec="$(new_spec unsafe-version)"
python3 - "$spec/SKILL.md" <<'PY'
import re, sys
p = sys.argv[1]
s = re.sub(r'(\n  version: ")([^"]*)(")', r'\g<1>\g<2> --> <!-- x\3', open(p).read(), count=1)
open(p, "w").write(s)
PY
expect_message "is outside [A-Za-z0-9.+-]" 'a spec version that would close its own comment' \
  render --dry-run --repo "$repo" --spec "$spec"

# Two `## Doctrine` sections, or none, is an error rather than a guess.
spec="$(new_spec two-sections)"
python3 - "$spec/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("\n## Adding a repo\n", "\n## Doctrine\n\n### x\n\ny\n\n## Adding a repo\n", 1)
open(p, "w").write(s)
PY
expect_message "exactly one is required" 'two `## Doctrine` sections' \
  render --dry-run --repo "$repo" --spec "$spec"

# Doctrine text is under the same content refusals as repo text, applied where
# it is read: `renders.md` § Render-side second checks. A `---` under a text
# line renders into `.github/copilot-instructions.md`, where blocks are `###`
# subsections with paragraphs preserved, and markdown reads the pair as a
# setext heading — a forged section in the file whose escaping rule exists to
# stop exactly that.
spec="$(new_spec doctrine-setext)"
python3 - "$spec/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("### scope\n\nRaise a defect", "### scope\n\nForged\n---\n\nRaise a defect", 1)
open(p, "w").write(s)
PY
expect_message "heading refusal" 'a `---` line under text in doctrine, which forges a section' \
  render --dry-run --repo "$repo" --spec "$spec"

spec="$(new_spec doctrine-heading)"
python3 - "$spec/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
# A level-4 heading: it does not end the `## Doctrine` section the way a
# level-1 or -2 one would, so this control reaches the refusal rather than
# the section parse.
s = open(p).read().replace("### scope\n\nRaise a defect", "### scope\n\n  #### Forged\n\nRaise a defect", 1)
open(p, "w").write(s)
PY
expect_message "heading refusal" 'a heading line in doctrine text, which ends the owned region' \
  render --dry-run --repo "$repo" --spec "$spec"

# The other side of the heading predicate: `#` with NO whitespace after it is
# a heading to no reader, and this repo writes pull request numbers that way.
# Read the block back rather than asserting the run exits 0 — a section parse
# ending at such a line drops the rest of the block and still reports success.
spec="$(new_spec doctrine-pr-number)"
python3 - "$spec/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "### scope\n\nRaise a defect"
assert anchor in s, "fixture shape changed"
open(p, "w").write(s.replace(anchor, "### scope\n\n#1917 is a pull request.\n\nRaise a defect", 1))
PY
expect_green 'a doctrine block carrying a #<digits> line renders' \
  render --dry-run --repo "$repo" --spec "$spec"
if python3 - "$BI_ROOT/skills/bot-instructions" "$spec" <<'PROBE'; then
import os, sys
PKG, SPEC = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(PKG, "scripts"))
from lib import spec as spec_mod, tree
blocks = spec_mod.load(tree.Worktree(SPEC), "SKILL.md", "schemas/renders.md").blocks
body = blocks["scope"]
if "#1917 is a pull request." not in body:
    sys.exit(f"the line was dropped from the block: {body[:120]!r}")
if "Raise a defect" not in body:
    sys.exit(f"the block was truncated at that line: {body[:120]!r}")
PROBE
  ok 'and the block keeps that line and everything below it'
else
  bad 'and the block keeps that line and everything below it'
fi

# The same predicate one character class wider: a `#` run closed by a no-break
# space is a heading to nobody. Read the block back, for the reason above.
spec="$(new_spec doctrine-nbsp)"
python3 - "$spec/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "### scope\n\nRaise a defect"
assert anchor in s, "fixture shape changed"
open(p, "w").write(s.replace(anchor, "### scope\n\n##\u00a0not a heading.\n\nRaise a defect", 1))
PY
expect_green 'a doctrine block carrying ## before a no-break space renders' \
  render --dry-run --repo "$repo" --spec "$spec"
if python3 - "$BI_ROOT/skills/bot-instructions" "$spec" <<'PROBE'; then
import os, sys
PKG, SPEC = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(PKG, "scripts"))
from lib import spec as spec_mod, tree
blocks = spec_mod.load(tree.Worktree(SPEC), "SKILL.md", "schemas/renders.md").blocks
body = blocks["scope"]
if "not a heading." not in body:
    sys.exit(f"the line was dropped from the block: {body[:120]!r}")
if "Raise a defect" not in body:
    sys.exit(f"the block was truncated at that line: {body[:120]!r}")
PROBE
  ok 'and that block keeps the line and everything below it too'
else
  bad 'and that block keeps the line and everything below it too'
fi

# A block's ORIGIN decides whether its paragraphs are joined. Doctrine from
# the spec copy is this package's own prose, hard-wrapped for that file, so
# joining it is right; a `[bot-instructions.doctrine.replace]` is a repo author's bytes, and
# `renders.md` § Common rules says repo text is never reflowed.
#
# Both halves in one fixture: the overridden block must survive intact and a
# block NOT overridden must still arrive joined, or simply never joining would
# read as coverage.
fenced="$(bi_new_repo doctrine-fenced)"
{
  cat "$BI_FIXTURES/canonical.toml"
  cat <<'OVERRIDE'

[bot-instructions.doctrine.replace]
severity = """
Rank a finding by what it costs, not by how easy it was to see.

```
severity = consequence * reach
```

Say which term you could not measure.
"""
render-out-of-scope = """
Vendored trees are read, never reviewed.

```
git ls-files -- ':(glob)vendor'
```
"""
OVERRIDE
} > "$fenced/kendex.toml"
# The package copy's own doctrine is one paragraph per line, so the joining
# half needs a spec copy with a wrap planted in it: one line break inside the
# `rounds` block, the rest byte-identical.
wrapped_spec="$BI_TMP/wrapped-spec"
mkdir -p "$wrapped_spec" || exit 1
cp -R "$PKG/SKILL.md" "$PKG/schemas" "$wrapped_spec/"
python3 - "$wrapped_spec/SKILL.md" <<'PLANT' || exit 1
import re, sys
p = sys.argv[1]
s = open(p).read()
pattern = r"(?m)(^### rounds\n\n)([^\n]+)"
matches = list(re.finditer(pattern, s))
assert len(matches) == 1, "fixture needs one rounds block"
body = matches[0].group(2)
assert " " in body, "fixture needs a rounds paragraph to wrap"
wrapped = body.replace(" ", "\n", 1)
changed = s[:matches[0].start(2)] + wrapped + s[matches[0].end(2):]
assert changed != s, "fixture did not plant a wrap"
open(p, "w").write(changed)
PLANT
bi_must adopt --repo "$fenced" --spec "$wrapped_spec" || exit 1
bi_must render --repo "$fenced" --spec "$wrapped_spec" || exit 1
if python3 - "$BI_ROOT/skills/bot-instructions" "$fenced" "$wrapped_spec" <<'PROBE'; then
import os, sys
PKG, repo, SPEC = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(PKG, "scripts"))
from lib import run, spec as spec_mod, tree

FENCE = "```\nseverity = consequence * reach\n```"
CARRIERS = (".github/copilot-instructions.md", "REVIEW.md",
            ".macroscope/correctness/doctrine.md", ".pr_agent.toml")
for rel in CARRIERS:
    if FENCE not in open(os.path.join(repo, rel)).read():
        sys.exit(f"{rel}: the overridden block's fence was reflowed away")

# The catch-all CodeRabbit entry carries a block through a different helper,
# which collapsed every newline in it unconditionally. `render-out-of-scope`
# is the block it carries, so the fixture overrides that one too.
OUT_OF_SCOPE = "```\ngit ls-files -- \':(glob)vendor\'\n```"
ctx = run.Context(repo, tree.Worktree(repo), tree.Worktree(SPEC),
                  ("SKILL.md", "schemas/renders.md"), "check",
                  ("SKILL.md", "schemas/renders.md"))
doc = ctx.build.data[".coderabbit.yaml"]
catch_all = [e for e in doc["reviews"]["path_instructions"] if e["path"] == "**"]
if not catch_all:
    sys.exit(".coderabbit.yaml: no catch-all path_instructions entry to judge")
entry = catch_all[0]["instructions"]
if OUT_OF_SCOPE not in entry:
    sys.exit(f".coderabbit.yaml: the catch-all entry reflowed the override: {entry[:120]!r}")
depth = 0
for line in entry.split("\n"):
    if line.strip().startswith("```"):
        depth = 1 - depth
    elif "Those paths here:" in line and depth:
        sys.exit(".coderabbit.yaml: the exclusion paths landed inside the fence")
if depth:
    sys.exit(".coderabbit.yaml: the catch-all entry leaves a fence open")

# The other half: a block the repo did NOT override still arrives joined, so
# the spec copy's own wrapping is not carried into the outputs as line breaks.
blocks = spec_mod.load(tree.Worktree(SPEC), "SKILL.md", "schemas/renders.md").blocks
wrapped = [b for b, t in blocks.items() if "\n" in t.strip() and b != "severity"]
if "rounds" not in wrapped:
    sys.exit("the planted wrap in the rounds block did not register, so the pair proves nothing")
copilot = open(os.path.join(repo, CARRIERS[0])).read()
for bid in wrapped:
    first = blocks[bid].strip().split("\n")[0]
    if first + "\n" in copilot:
        sys.exit(f"{bid}: a package-authored block kept the spec copy's wrapping")
PROBE
  ok 'an overridden block keeps its line breaks, and a package one is still joined'
else
  bad 'an overridden block keeps its line breaks, and a package one is still joined'
fi

# --- the sweep rules reach Codex --------------------------------------------
# Root rules from a declined-finding sweep. `AGENTS.md` is the one surface
# Codex reads, so each sentence has to land in the owned region as written.
repo="$(bi_rendered_repo doctrine-sweep)" || exit 1
region="$(python3 - "$repo/AGENTS.md" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
start = lines.index("## Code Review Rules")
end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
print("\n".join(lines[start:end]))
PY
)"
while IFS= read -r sentence; do
  if printf '%s\n' "$region" | grep -qF -- "$sentence"; then
    ok "AGENTS.md § Code Review Rules carries: $sentence"
  else
    bad "AGENTS.md § Code Review Rules carries: $sentence"
  fi
done <<'EOF'
Report an input only after establishing that a shipped producer emits it in normal use; a full disk or a value past 2^53 is not one.
Name the user-visible consequence in every finding.
Report a gap only after establishing that nothing already covers it: a required CI context, a shipped hook, the file's own stated contract, or the platform's documentation.
EOF

bi_summary
