#!/usr/bin/env bash
# Regression lint for KEN-878. A delegated agent's shell does not reliably
# start in the worktree it was delegated: two lanes each ran bare-relative
# commands — `tools/guard` among them — against another lane's worktree,
# and both noticed only after a confusing downstream failure.
#
# The cure is a precondition the agent runs before anything repo-relative,
# and this lint holds it as ONE canonical sentence rather than as a set of
# shape rules. Every shipped check line is byte-identical apart from the
# block's own placeholder token, so the test carries that sentence in
# $CANON with `@TOKEN@` where the token goes, and each site must equal it
# with its own token substituted in. Equality is the whole predicate:
# nothing infers "opens with a command", "mentions pwd", or "names the
# token", so no prose mutation can satisfy the letter of a heuristic while
# leaving the agent with nothing to run. A future wording change is made in
# $CANON and at every site together, or the lint reds.
#
# Two rules are enforced inside a `<delegation_format>` block:
#
#   1. A `Worktree: [TOKEN]` line is followed on the very next line by the
#      canonical `Worktree Check:` line for that same TOKEN.
#   2. A block that hands the delegate a repo-relative path — a bare path
#      opening `.agents/`, `skills/` or `tools/` — carries that pair at
#      all. Without it the delegate runs those paths wherever its shell
#      happens to be. A block whose paths are all placeholders is out of
#      scope: the caller resolves those, and the lint cannot judge them.
#
# Scope is every skill doc that can carry a delegation, not one directory.
# Tests are excluded: their probe fixtures carry deliberately broken
# blocks. A `Worktree:` mention in prose or in a fenced example is not a
# delegation and is not scanned.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# The canonical check line, with @TOKEN@ standing in for the block's own
# placeholder name. This is the single source of truth for the sentence;
# the shipped docs must match it character for character.
CANON='Worktree Check: `pwd` before any repo-relative command. It must print [@TOKEN@]; your shell can start in another lane'"'"'s worktree, where a bare `git status` or `tools/guard` answers confidently about the wrong tree. On any other path, report where the shell started and give every later command an absolute path under [@TOKEN@], because a bare `cd` may not survive into the next tool call.'

# scan_worktree_precondition <file>
# Emits one "file:line: ..." line per defect, per the two rules above.
# Lines outside a delegation block are never scanned.
scan_worktree_precondition() {
  awk -v f="$1" -v canon="$CANON" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*<delegation_format>[[:space:]]*$/ {
      indel = 1; pending = 0; haswt = 0; relline = 0; relpath = ""; next
    }
    /^[[:space:]]*<\/delegation_format>[[:space:]]*$/ {
      if (pending) printf "%s:%d: Worktree: [%s] ends the delegation with no Worktree Check line\n", f, pendline, token
      if (indel && !haswt && relline) printf "%s:%d: delegation hands over the repo-relative path %s but carries no Worktree:/Worktree Check: pair\n", f, relline, relpath
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
      if (!relline) {
        probe = " " $0
        if (match(probe, /[^A-Za-z0-9_.\/-](\.agents|skills|tools)\/[A-Za-z0-9._\/-]+/)) {
          relline = NR
          relpath = substr(probe, RSTART + 1, RLENGTH - 1)
        }
      }
    }
  ' "$1"
}

# count_guarded_relpath_blocks <file>
# Prints the number of delegation blocks that name a repo-relative path AND
# carry a Worktree: line — the population rule 2 is meant to hold.
count_guarded_relpath_blocks() {
  awk '
    /^[[:space:]]*<delegation_format>[[:space:]]*$/ { indel = 1; haswt = 0; hasrel = 0; next }
    /^[[:space:]]*<\/delegation_format>[[:space:]]*$/ { if (indel && haswt && hasrel) n++; indel = 0; next }
    indel {
      if ($0 ~ /^[[:space:]]*Worktree:[[:space:]]*\[[A-Za-z_][A-Za-z0-9_]*\][[:space:]]*$/) haswt = 1
      probe = " " $0
      if (match(probe, /[^A-Za-z0-9_.\/-](\.agents|skills|tools)\/[A-Za-z0-9._\/-]+/)) hasrel = 1
    }
    END { print n + 0 }
  ' "$1"
}

echo "=== orch delegation worktree-cwd-precondition lint ==="

# --- Part a: every shipped delegation block carries the precondition -------
# Every skill doc, not one skill's workflows: a delegation that hands over a
# worktree is checked wherever it lives. Tests are excluded — their probe
# fixtures carry deliberately broken blocks.
DOCS="$(find "$SKILLS_ROOT" -name '*.md' -not -path '*/tests/*' | sort)"
offenders=""
sites=0
guarded=0
for doc in $DOCS; do
  out="$(scan_worktree_precondition "$doc")"
  [ -n "$out" ] && offenders="$offenders$out"$'\n'
  n="$(grep -c '^[[:space:]]*Worktree Check:' "$doc" || true)"
  sites=$((sites + n))
  guarded=$((guarded + $(count_guarded_relpath_blocks "$doc")))
done
if [ -z "$offenders" ]; then
  pass "every delegated Worktree: line is followed by its canonical Worktree Check"
else
  fail "delegation blocks missing the worktree cwd precondition:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# The precondition is worth nothing if no delegation carries it: a lint that
# passes over zero sites is the vacuous case this asserts against.
if [ "$sites" -gt 0 ]; then
  pass "the scan read $sites delegated Worktree Check line(s)"
else
  fail "no Worktree Check lines found — the scan matched nothing to check"
fi

# The same guard for rule 2: with no shipped block naming a repo-relative
# path, the repo-path rule passed over an empty population and proves
# nothing.
if [ "$guarded" -gt 0 ]; then
  pass "the scan read $guarded repo-relative delegation block(s) carrying the pair"
else
  fail "no repo-relative delegation blocks found — the repo-path rule matched nothing"
fi

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

# b.13 — RULE 2. A block that hands over a repo-relative path with no
# Worktree:/Worktree Check: pair IS flagged: the delegate runs that path
# wherever its shell happens to be.
if [ -n "$(scan_worktree_precondition "$(probe relpath 'Follow workflow: .agents/skills/project-management/workflows/tpm-audit.md\n\nArguments: --project-order')" )" ]; then
  pass "lint flags a delegation naming a repo-relative path with no Worktree pair"
else
  fail "lint MISSED a repo-relative delegation with no Worktree pair"
fi

# b.14 — the same block WITH the pair is not flagged.
if [ -z "$(scan_worktree_precondition "$(probe relok "Follow workflow: .agents/skills/x/y.md\nWorktree: [WORKTREE_PATH]\n$CHECK")" )" ]; then
  pass "lint accepts a repo-relative delegation carrying the pair"
else
  fail "lint false-flagged a repo-relative delegation that carries the pair"
fi

# b.15 — a block whose paths are ALL placeholders is out of scope: the
# caller resolves them, and the lint cannot judge where they land.
if [ -z "$(scan_worktree_precondition "$(probe placeholders 'Read: [RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md\nWrite: [INPUT_FILE_PATH]')" )" ]; then
  pass "lint ignores a delegation whose paths are all placeholders"
else
  fail "lint false-flagged a placeholder-only delegation"
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

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
