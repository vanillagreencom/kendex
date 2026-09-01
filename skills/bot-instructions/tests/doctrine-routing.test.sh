#!/usr/bin/env bash
# `doctrine-routing`: one red control per rejection clause.
#
# The silent failure: the routing table is the generator's single routing
# input, so a block reaches a surface only through a cell. A heading with no
# row renders into nothing at all; a row naming a heading that does not exist
# renders a hole. Both render clean.
#
# Every control here is a **fixture spec copy** passed with `--spec`, never an
# edit to the running copy — a suite that edited the tree it also grades would
# be grading itself. `--spec` is also the shape the prescribed CI lane uses,
# where the spec copy comes from the tree under judgment while the code runs
# from the trusted default-branch checkout.
#
# They run `render --dry-run`, which validates and writes nothing: `drift` is
# skipped on render, and a doctrine change is a byte change by definition, so
# on `check` every fixture here would red `drift` as well.

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
#    repo's `[doctrine.append]` on the old id silently reaches nothing. The
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

# The version is interpolated into a comment that names this package. A
# version carrying `-->` or a newline would end that comment and put the rest
# into a generated markdown file as live reviewer instructions, so the package
# validates the shape of its own spec copy rather than trusting it.
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
# it is read: `renders.md` § Render-side second checks. A `---` line in a
# doctrine block renders into `.github/copilot-instructions.md`, where blocks
# are `##` subsections with paragraphs preserved, and markdown reads `---`
# under a text line as a setext heading underline — forging a section in the
# one file whose escaping rule exists to stop exactly that.
spec="$(new_spec doctrine-frontmatter)"
python3 - "$spec/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("### scope\n\nRaise a defect", "### scope\n\nForged\n---\n\nRaise a defect", 1)
open(p, "w").write(s)
PY
expect_message "frontmatter refusal" 'a `---` line in doctrine text, which forges a section' \
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

# The other side of that predicate: `#` with NO whitespace after it is a
# heading to no reader, and this repo writes pull request numbers that way.
# Read the block back rather than asserting the run exits 0 — the section
# parse used to END at such a line, dropping the rest of the block with the
# render reporting success, and a green run is exactly what that looked like.
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

# The same predicate at the same site, one character class wider: a `#` run
# closed by a no-break space is a heading to nobody, and reading it as one
# ended the section and dropped the rest of the block with the render
# reporting success. Read the block back, for the reason above.
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

bi_summary
