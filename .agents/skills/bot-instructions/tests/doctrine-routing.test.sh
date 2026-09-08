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

# One spec mutation per row: `label~file~old~new~verdict`, `~`-separated
# because the routing rows the mutations edit carry `|`. `old` and `new` are
# literal text with `\n` for a newline; an `re:` prefix on `old` makes it a
# regular expression and `new` a `re.sub` template (`\g<n>` groups, and no
# other backslash escape). The
# edit asserts exactly one match, so a fixture the running copy has moved
# away from fails as a fixture rather than passing on a defect never planted.
# `verdict` is `red:<validator>:<clause>` (exit 1, that validator alone, the
# finding naming the clause, since `doctrine-routing` has six clauses and a
# fixture can trip two) or `msg:<value>` (exit 2, the message names that
# value). A table that asserted no row exits 2 from its own counter.
spec_edit() { # SPEC-FILE OLD NEW — one asserted replacement
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if old.startswith("re:"):
    n = len(re.findall(old[3:], s))
    out = re.sub(old[3:], new, s, count=1)
else:
    old = old.replace("\\n", "\n")
    new = new.replace("\\n", "\n")
    n = s.count(old)
    out = s.replace(old, new, 1)
if n != 1:
    sys.exit(f"{path}: expected one match of {old[:60]!r}, found {n}")
if out == s:
    sys.exit(f"{path}: the edit changed nothing")
open(path, "w").write(out)
PY
}

spec_table() {
  local rows="$1" row label file old new verdict spec field n=0 before
  before=$((BI_PASS + BI_FAIL))
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='~' read -r label file old new verdict <<EOF
$row
EOF
    for field in "$label" "$file" "$old" "$verdict"; do
      [ -n "$field" ] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    n=$((n + 1))
    spec="$(new_spec "row-$n")"
    spec_edit "$spec/$file" "$old" "$new" || { printf 'fixture: %s\n' "$label" >&2; exit 1; }
    case "$verdict" in
      red:*:*)
        verdict="${verdict#red:}"
        expect_clause "${verdict%%:*}" "${verdict#*:}" "$label" render --dry-run --repo "$repo" --spec "$spec" ;;
      msg:*) expect_message "${verdict#msg:}" "$label" render --dry-run --repo "$repo" --spec "$spec" ;;
      *) printf 'unknown verdict: %s\n' "$verdict" >&2; exit 1 ;;
    esac
  done <<EOF
$rows
EOF
  [ "$((BI_PASS + BI_FAIL))" -gt "$before" ] || { printf 'no row was asserted\n' >&2; exit 2; }
}

# An unrouted block is an error, never a silent drop. A row naming no
# heading: set equality in both directions, since the one-directional half
# leaves the orphaned row unchecked. Positions in a column run 1..n once
# each. The two all-eight columns lose a block and Codex or Macroscope loses
# it with every other validator green. A spec copy with no readable version
# would land a doctrine change under a stamp naming doctrine it does not
# carry; a version carrying `-->` would close the marker comment and put the
# rest into a generated file as live reviewer instructions. Two `## Doctrine`
# sections, or none, is an error rather than a guess. Doctrine text is under
# the same content refusals as repo text, applied where it is read
# (`renders.md` § Render-side second checks): a `---` under a text line is a
# setext heading in `.github/copilot-instructions.md`, a forged section, and
# an indented level-4 heading reaches the refusal rather than the section
# parse, which a level-1 or -2 one would end.
# `read -d ''` rather than `$(cat <<'ROWS' ...)`: Bash 3.2 scans a here-document
# inside a command substitution for quotes, and a row carrying an odd number
# of double quotes runs its parse past the closing parenthesis.
IFS= read -r -d '' rows <<'ROWS'
a doctrine block with no routing row~SKILL.md~\n## Adding a repo\n~\n### unrouted\n\nA block no column carries.\n\n## Adding a repo\n~red:doctrine-routing:doctrine block 'unrouted' has no row in the routing table
a routing row naming no doctrine heading~schemas/renders.md~| `trust-model` |~| `no-such-block` | – | – | – | – | – | – | – | – |\n| `trust-model` |~red:doctrine-routing:routing table row 'no-such-block' names no `###` heading
a position repeated inside a column~schemas/renders.md~| `rounds` | 2 |~| `rounds` | 1 |~red:doctrine-routing:column 'AGENTS.md' repeats a position
a gap in a column, whose positions must run 1..n~schemas/renders.md~| `rounds` | 2 |~| `rounds` | 9 |~red:doctrine-routing:column 'AGENTS.md' positions are [1, 3, 4, 5, 6, 7, 8, 9], not 1..n
a block missing from the AGENTS.md column~schemas/renders.md~| `reply-contract` | 8 |~| `reply-contract` | – |~red:doctrine-routing:column 'AGENTS.md' omits 'reply-contract'
a block missing from the macroscope doctrine.md column~schemas/renders.md~re:(\| `reply-contract` \|.*\| )8 \|\n~\g<1>– |\n~red:doctrine-routing:column 'macroscope doctrine.md' omits 'reply-contract'
a spec copy with no readable version~SKILL.md~re:\n  version: "[^"]*"~~msg:no `version:` under metadata
a spec version that would close its own comment~SKILL.md~re:(\n  version: ")([^"]*)(")~\g<1>\g<2> --> <!-- x\g<3>~msg:is outside [A-Za-z0-9.+-]
two `## Doctrine` sections~SKILL.md~\n## Adding a repo\n~\n## Doctrine\n\n### x\n\ny\n\n## Adding a repo\n~msg:exactly one is required
a `---` line under text in doctrine, which forges a section~SKILL.md~### scope\n\nRaise a defect~### scope\n\nForged\n---\n\nRaise a defect~msg:heading refusal
a heading line in doctrine text, which ends the owned region~SKILL.md~### scope\n\nRaise a defect~### scope\n\n  #### Forged\n\nRaise a defect~msg:heading refusal
ROWS
spec_table "$rows"

# The frozen-id invariant, the one mutation that edits both files. Renaming a
# heading and its row together leaves both sets agreeing, so a comparison of
# the pair passes and a consuming repo's `[bot-instructions.doctrine.append]`
# on the old id silently reaches nothing. The comparison is against the
# frozen set, which lives in the implementation.
spec="$(new_spec renamed-pair)"
spec_edit "$spec/SKILL.md" '\n### severity\n' '\n### severity-honesty\n' || exit 1
spec_edit "$spec/schemas/renders.md" '| `severity` |' '| `severity-honesty` |' || exit 1
expect_clause doctrine-routing "block id 'severity' is frozen and the doctrine source no longer defines it" \
  'a heading and its row renamed together, against the frozen set' \
  render --dry-run --repo "$repo" --spec "$spec"
# The other direction of the same comparison, on the same fixture: the new
# id is outside the frozen set, which is what makes adding a `###` heading a
# deliberate edit to the constant a reviewer reads.
expect_clause doctrine-routing "block id 'severity-honesty' is not in the frozen set" \
  'and the renamed block is not in the frozen set either' \
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

# --- every block the AGENTS.md column routes lands in the owned region ------
# `AGENTS.md` is the one surface Codex reads, so each block the routing
# table sends there has to arrive as written. The rows are derived from the
# spec copy rather than copied here: the column names the blocks, and each
# block's paragraphs, joined the way the region joins a bullet, must appear
# in the region, each block after the one the column routes before it, so a
# dropped, truncated or reordered block shows in its row. The `reply-contract`
# block's `<issue>` placeholder becomes
# `<PREFIX>-<n>` under `[bot-instructions.repo] tracker` (`renders.md`
# § Common rules; the canonical fixture's tracker is `FIX`), so a paragraph
# is held with that substitution made. The floor is the column's own length:
# a column routing no block, a block with no paragraph, or a region that
# cannot be located fails as a fixture before any row is counted.
repo="$(bi_rendered_repo doctrine-agents)" || exit 1
if python3 - "$BI_ROOT/skills/bot-instructions" "$repo" > "$BI_TMP/agents-rows" <<'PY'; then
import os, sys
PKG, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(PKG, "scripts"))
from lib import render, spec as spec_mod, tree
doctrine = spec_mod.load(tree.Worktree(PKG), "SKILL.md", "schemas/renders.md")
region = render.region_of(open(os.path.join(repo, "AGENTS.md")).read())
if region is None:
    sys.exit("the rendered AGENTS.md has no owned region")
blocks = doctrine.routing["AGENTS.md"]
if not blocks:
    sys.exit("the AGENTS.md column routes no block")
at = 0
for bid in blocks:
    paras = [" ".join(p.split()).replace("<issue>", "<FIX-n>")
             for p in doctrine.blocks[bid].split("\n\n") if p.strip()]
    if not paras:
        sys.exit(f"{bid}: no paragraph to hold against the region")
    verdict = "ok"
    for para in paras:
        found = region.find(para, at)
        if found == -1:
            verdict = "missing-or-out-of-order"
            break
        at = found + len(para)
    print(f"{verdict}\t{bid}\t{len(paras)}")
PY
  before=$((BI_PASS + BI_FAIL))
  while IFS="$(printf '\t')" read -r verdict bid count; do
    if [ "$verdict" = ok ]; then
      ok "AGENTS.md § Code Review Rules carries block $bid in its routed order ($count paragraph(s))"
    else
      bad "AGENTS.md § Code Review Rules carries block $bid in its routed order ($count paragraph(s))" "$verdict"
    fi
  done < "$BI_TMP/agents-rows"
  [ "$((BI_PASS + BI_FAIL))" -gt "$before" ] || { printf 'no block row was asserted\n' >&2; exit 2; }
else
  bad 'the AGENTS.md block rows could be derived from the spec copy' "$(cat "$BI_TMP/agents-rows")"
fi

bi_summary
