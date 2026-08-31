#!/usr/bin/env bash
# Regression lint for KEN-878. A delegated agent's shell does not reliably
# start in the worktree it was delegated: two lanes each ran bare-relative
# commands — `tools/guard` among them — against another lane's worktree,
# and both noticed only after a confusing downstream failure.
#
# The cure is a precondition the agent runs before anything repo-relative,
# and it HALTS: a tool like `tools/guard` re-derives the repo from the
# process cwd, so no path spelling makes a wrong-tree shell safe and there
# is no remedy for the check to get right. This lint holds the precondition
# as ONE canonical sentence rather than as a set of shape rules. Every
# shipped check line is byte-identical apart from the block's own
# placeholder token, so the test carries that sentence in $CANON with
# `@TOKEN@` where the token goes, and each site must equal it with its own
# token substituted in. Equality is the whole predicate:
# nothing infers "opens with a command", "mentions pwd", or "names the
# token", so no prose mutation can satisfy the letter of a heuristic while
# leaving the agent with nothing to run. A future wording change is made in
# $CANON and at every site together, or the lint reds.
#
# Two rules are enforced inside a `<delegation_format>` block:
#
#   1. A `Worktree: [TOKEN]` line is followed on the very next line by the
#      canonical `Worktree Check:` line for that same TOKEN.
#   2. EVERY block carries that pair. No path matcher decides which
#      delegations need it: judging "does this delegate touch the repo"
#      from the block's literal text missed blocks with no pair at all,
#      then missed blocks whose paths are placeholders the caller fills.
#      The pair costs two lines on a delegation that never touches the
#      repo, and uniform is the only rule that cannot be wrong.
#
# Scope is every skill doc that can carry a delegation, in BOTH trees: the
# `skills/` source and the `.agents/skills/` render agents actually load.
# Deriving the scan root from this file's own location would leave each
# copy scanning only its own half, and CI runs the source copy alone — the
# render would ship unguarded with the suite green. Tests are excluded:
# their probe fixtures carry deliberately broken blocks. A `Worktree:`
# mention in prose or in a fenced example is not a delegation and is not
# scanned.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The nearest ancestor holding both trees. Walked, not counted in `../`,
# so the source copy and the render copy resolve to the same repo root and
# scan the same two directories.
REPO_ROOT="$TEST_DIR"
while [ "$REPO_ROOT" != "/" ]; do
  if [ -d "$REPO_ROOT/skills" ] && [ -d "$REPO_ROOT/.agents/skills" ]; then break; fi
  REPO_ROOT="$(dirname "$REPO_ROOT")"
done
if [ "$REPO_ROOT" = "/" ]; then
  printf 'FAIL  no ancestor of %s holds both skills/ and .agents/skills/\n' "$TEST_DIR" >&2
  exit 1
fi
SOURCE_ROOT="$REPO_ROOT/skills"
RENDER_ROOT="$REPO_ROOT/.agents/skills"

TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# The canonical check line, with @TOKEN@ standing in for the block's own
# placeholder name. This is the single source of truth for the sentence;
# the shipped docs must match it character for character.
CANON='Worktree Check: `pwd` before any repo-relative command. It must print [@TOKEN@]; your shell can start in another lane'"'"'s worktree, and `git status` or `tools/guard` resolves the repo from the process cwd, so an absolute path does not redirect it. On any other path, stop and report where the shell started; do not attempt recovery.'

# scan_worktree_precondition <file>
# Emits one "file:line: ..." line per defect, per the two rules above.
# Lines outside a delegation block are never scanned.
scan_worktree_precondition() {
  awk -v f="$1" -v canon="$CANON" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*<delegation_format>[[:space:]]*$/ {
      indel = 1; pending = 0; haswt = 0; delline = NR; next
    }
    /^[[:space:]]*<\/delegation_format>[[:space:]]*$/ {
      if (pending) printf "%s:%d: Worktree: [%s] ends the delegation with no Worktree Check line\n", f, pendline, token
      if (indel && !haswt) printf "%s:%d: delegation carries no Worktree:/Worktree Check: pair\n", f, delline
      indel = 0; pending = 0; next
    }
    indel {
      if (pending) {
        want = canon
        gsub(/@TOKEN@/, token, want)
        if (trim($0) != want) {
          printf "%s:%d: the line after Worktree: [%s] is not the canonical Worktree Check (got: %s)\n", f, NR, token, trim($0)
        }
        pending = 0
      }
      if (match($0, /^[[:space:]]*Worktree:[[:space:]]*\[[A-Za-z_][A-Za-z0-9_]*\][[:space:]]*$/)) {
        line = $0
        sub(/^[[:space:]]*Worktree:[[:space:]]*\[/, "", line)
        sub(/\].*$/, "", line)
        token = line; pendline = NR; pending = 1; haswt = 1
      }
    }
  ' "$1"
}

# scan_trees <root>...
# Emits every defect line found in every non-test *.md under the given
# roots. A missing root is itself a defect: the caller asked for a tree
# that is not there, and reporting nothing would read as clean.
scan_trees() {
  for root in "$@"; do
    if [ ! -d "$root" ]; then
      printf '%s: scan root does not exist\n' "$root"
      continue
    fi
    find "$root" -name '*.md' -not -path '*/tests/*' | sort | while IFS= read -r doc; do
      scan_worktree_precondition "$doc"
    done
  done
}

# count_blocks <root> — delegation blocks the scan opened under one tree.
# Counting blocks rather than shipped check lines guards the scanner's own
# unit: if the block opener stopped matching, every rule would pass on an
# empty population while the docs still read as full of check lines.
count_blocks() {
  find "$1" -name '*.md' -not -path '*/tests/*' -exec grep -c '^[[:space:]]*<delegation_format>[[:space:]]*$' {} + 2>/dev/null |
    awk -F: '{ n += $NF } END { print n + 0 }'
}

echo "=== orch delegation worktree-cwd-precondition lint ==="

# --- Part a: every shipped delegation block carries the precondition -------
# Every skill doc in BOTH trees, not one skill's workflows and not the half
# this copy of the test sits in: a delegation that hands over a worktree is
# checked wherever it lives. Tests are excluded — their probe fixtures carry
# deliberately broken blocks.
offenders="$(scan_trees "$SOURCE_ROOT" "$RENDER_ROOT")"
if [ -z "$offenders" ]; then
  pass "every delegated Worktree: line is followed by its canonical Worktree Check"
else
  fail "delegation blocks missing the worktree cwd precondition:"
  printf '%s\n' "$offenders" | sed 's/^/          /'
fi

# The precondition is worth nothing if no delegation carries it, and one
# tree going missing is the same vacuity a level up — so each tree is
# counted on its own and an empty population in EITHER reds.
for root in "$SOURCE_ROOT" "$RENDER_ROOT"; do
  label="${root#$REPO_ROOT/}"
  blocks="$(count_blocks "$root")"
  if [ "$blocks" -gt 0 ]; then
    pass "$label: the scan opened $blocks delegation block(s)"
  else
    fail "$label: no delegation blocks found — the scan matched nothing to check"
  fi
done

# --- Part b: the lint has teeth -------------------------------------------

# probe <name> <body> → prints scratch-file path.
# Writes a standalone delegation block containing <body> (printf %b, so \n
# splits it into lines) under $TMP_ROOT, removed by the EXIT trap.
probe() {
  scratch="$TMP_ROOT/probe-$1.md"
  printf '<delegation_format>\n%b\n</delegation_format>\n' "$2" > "$scratch"
  printf '%s' "$scratch"
}

CHECK="${CANON//@TOKEN@/WORKTREE_PATH}"

# b.1 — the reported shape (a bare Worktree: line, as every site read before
# this change) IS flagged.
if [ -n "$(scan_worktree_precondition "$(probe bare 'Issue: [ISSUE_ID]\nWorktree: [WORKTREE_PATH]\nRound ID: [DEV_ROUND_ID]')" )" ]; then
  pass "lint flags a Worktree: line with no Worktree Check"
else
  fail "lint MISSED a bare Worktree: line (no teeth)"
fi

# b.2 — the canonical shape is NOT flagged.
if [ -z "$(scan_worktree_precondition "$(probe fixed "Worktree: [WORKTREE_PATH]\n$CHECK")" )" ]; then
  pass "lint accepts Worktree: followed by the canonical Worktree Check"
else
  fail "lint false-flagged the canonical shape"
fi

# b.3 — a check naming a DIFFERENT placeholder IS flagged: a filled
# delegation would compare pwd against a path this block never carries.
if [ -n "$(scan_worktree_precondition "$(probe crossed "Worktree: [WT_PATH]\n$CHECK")" )" ]; then
  pass "lint flags a Worktree Check naming the wrong placeholder"
else
  fail "lint MISSED a cross-wired placeholder"
fi

# b.4 — a Worktree: line ending the block with no check IS flagged.
if [ -n "$(scan_worktree_precondition "$(probe last 'Branch: [BRANCH]\nWorktree: [WORKTREE_PATH]')" )" ]; then
  pass "lint flags a Worktree: line that closes the delegation"
else
  fail "lint MISSED a trailing Worktree: line"
fi

# b.7 — the leading command replaced by prose, everything after it left
# intact. The line still carries its placeholder AND still says `pwd` later,
# so a placeholder check and an anywhere-on-the-line `pwd` check both pass
# it. Equality does not.
MUTANT='Worktree: [WORKTREE_PATH]\nWorktree Check: trust the path. It must print [WORKTREE_PATH]; a bare `git status` answers about the wrong tree. Any other path — `cd "[WORKTREE_PATH]"`, re-run `pwd`, and report where it started.'
if [ -n "$(scan_worktree_precondition "$(probe mutant "$MUTANT")" )" ]; then
  pass "lint flags a check whose leading command was replaced by prose"
else
  fail "lint MISSED a check that runs nothing"
fi

# b.10 — prose in front, a backticked `pwd` behind it: the first backticked
# span on the line IS `pwd`, so an unanchored shape match accepts a check
# that demotes the command to optional.
DEMOTED='Worktree: [WORKTREE_PATH]\nWorktree Check: trust the path; optional check: `pwd` must print [WORKTREE_PATH].'
if [ -n "$(scan_worktree_precondition "$(probe demoted "$DEMOTED")" )" ]; then
  pass "lint flags a check whose pwd sits behind leading prose"
else
  fail "lint MISSED a backticked pwd demoted behind prose"
fi

# b.11 — the token is present and the line opens with a backticked `pwd`,
# but nothing binds one to the other: the check tells the agent to ignore
# what it just measured. Every shape heuristic passes this; equality is the
# only predicate that does not.
UNBOUND='Worktree: [WORKTREE_PATH]\nWorktree Check: `pwd` before any repo-relative command. Ignore [WORKTREE_PATH].'
if [ -n "$(scan_worktree_precondition "$(probe unbound "$UNBOUND")" )" ]; then
  pass "lint flags a check whose pwd and placeholder are unbound"
else
  fail "lint MISSED an unbound pwd and placeholder"
fi

# b.8 — a check opening with the WRONG command is flagged. `pwd` has to be
# the first executable step; a different command does not report the cwd.
if [ -n "$(scan_worktree_precondition "$(probe wrongcmd 'Worktree: [WORKTREE_PATH]\nWorktree Check: `git status` before any repo-relative command. It must print [WORKTREE_PATH].')" )" ]; then
  pass "lint flags a check opening with a command other than pwd"
else
  fail "lint MISSED a check opening with the wrong command"
fi

# b.9 — an unbackticked mention is not a command. Without the code span
# there is nothing marked for the agent to run.
if [ -n "$(scan_worktree_precondition "$(probe unmarked 'Worktree: [WORKTREE_PATH]\nWorktree Check: run pwd before any repo-relative command. It must print [WORKTREE_PATH].')" )" ]; then
  pass "lint flags a check whose pwd is not a marked command"
else
  fail "lint MISSED an unbackticked pwd"
fi

# b.12 — the recovery clause must not rest on a bare `cd`. A harness that
# spawns a fresh shell per tool call drops it, and the agent resumes
# repo-relative work in the wrong tree believing it recovered.
STALE_CD='Worktree: [WORKTREE_PATH]\nWorktree Check: `pwd` before any repo-relative command. It must print [WORKTREE_PATH]. Any other path — `cd "[WORKTREE_PATH]"`, re-run `pwd`, and report where it started.'
if [ -n "$(scan_worktree_precondition "$(probe stalecd "$STALE_CD")" )" ]; then
  pass "lint flags a check whose remedy is a bare cd"
else
  fail "lint MISSED a remedy resting on a cd that may not persist"
fi

# b.16 — nor on an absolute path. `tools/guard` re-derives the repo from
# the process cwd on its own first line, so the path it is invoked by never
# reaches that decision and a wrong-tree shell still judges the wrong lane.
# The canonical sentence halts instead, and any remedy written in its place
# reds.
ABS_REMEDY='Worktree: [WORKTREE_PATH]\nWorktree Check: `pwd` before any repo-relative command. It must print [WORKTREE_PATH]. Any other path — give every later command an absolute path under [WORKTREE_PATH].'
if [ -n "$(scan_worktree_precondition "$(probe absremedy "$ABS_REMEDY")" )" ]; then
  pass "lint flags a remedy resting on an absolute path"
else
  fail "lint MISSED a remedy an absolute path cannot deliver"
fi

# b.13 — RULE 2. A block with no Worktree:/Worktree Check: pair at all IS
# flagged, whatever it hands over: a placeholder the caller fills with a
# repo path is invisible to any matcher, so no block is out of scope.
if [ -n "$(scan_worktree_precondition "$(probe nopair 'Read: [RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md\n\nArguments: --project-order')" )" ]; then
  pass "lint flags a delegation carrying no Worktree pair"
else
  fail "lint MISSED a delegation with no Worktree pair"
fi

# b.5 — a Worktree: mention outside a delegation block is NOT scanned.
PROSE="$TMP_ROOT/probe-prose.md"
printf 'Fill the delegation Worktree: [WORKTREE_PATH] from the claim output, per .agents/skills/orch/SKILL.md.\n' > "$PROSE"
if [ -z "$(scan_worktree_precondition "$PROSE")" ]; then
  pass "lint ignores a Worktree: mention outside a delegation block"
else
  fail "lint false-flagged a prose mention"
fi

# b.6 — an indented delegation block (dev-fix.md nests one in a numbered
# step) is scanned, not skipped for its leading whitespace.
if [ -n "$(scan_worktree_precondition "$(probe indented '   Worktree: [WORKTREE_PATH]\n   Round ID: [DEV_ROUND_ID]')" )" ]; then
  pass "lint scans an indented delegation block"
else
  fail "lint MISSED a bare Worktree: line inside an indented block"
fi

# --- Part c: both trees are actually scanned ------------------------------
# A scan root derived from this file's own location would give the source
# copy only skills/ and the render copy only .agents/skills/, and CI runs
# the source copy alone — a check deleted from the render would ship with
# the suite green. The fixture below is a repo root in miniature, a source
# half and a render half, and a defect planted in EITHER half must red.
TWO="$TMP_ROOT/two-trees"
mkdir -p "$TWO/skills/x" "$TWO/.agents/skills/x"
GOOD="Worktree: [WORKTREE_PATH]\n$CHECK"
BROKEN='Worktree: [WORKTREE_PATH]'
write_half() { printf '<delegation_format>\n%b\n</delegation_format>\n' "$2" > "$TWO/$1/x/y.md"; }

# c.1 — control: both halves carry the check, nothing is flagged. Without
# this the two probes below could red for any reason at all.
write_half skills "$GOOD"
write_half .agents/skills "$GOOD"
if [ -z "$(scan_trees "$TWO/skills" "$TWO/.agents/skills")" ]; then
  pass "two-tree scan is clean when both halves carry the check"
else
  fail "two-tree scan false-flagged two correct halves"
fi

# c.2 — the render half loses its check. This is the case a source-rooted
# scan cannot see: the tree agents load, unguarded, with CI passing.
write_half .agents/skills "$BROKEN"
if [ -n "$(scan_trees "$TWO/skills" "$TWO/.agents/skills")" ]; then
  pass "two-tree scan reds on a check deleted from the render half"
else
  fail "two-tree scan MISSED a check deleted from the render half"
fi

# c.3 — and symmetrically, the source half.
write_half .agents/skills "$GOOD"
write_half skills "$BROKEN"
if [ -n "$(scan_trees "$TWO/skills" "$TWO/.agents/skills")" ]; then
  pass "two-tree scan reds on a check deleted from the source half"
else
  fail "two-tree scan MISSED a check deleted from the source half"
fi

# c.4 — a root that is not there is reported, not passed over. A renamed or
# unrendered tree would otherwise contribute zero defects and read as clean.
if [ -n "$(scan_trees "$TWO/skills" "$TWO/nonexistent")" ]; then
  pass "two-tree scan reds on a missing scan root"
else
  fail "two-tree scan MISSED a missing scan root"
fi

# c.5 — the real run reached both trees, so parts a and b judged the shipped
# render and not just the source.
if [ "$(count_blocks "$SOURCE_ROOT")" -gt 0 ] && [ "$(count_blocks "$RENDER_ROOT")" -gt 0 ]; then
  pass "the shipped scan covered skills/ and .agents/skills/ alike"
else
  fail "one of the two shipped trees carried no delegation block"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
