#!/usr/bin/env bash
# Regression lint for KEN-878. A delegated agent's shell does not reliably
# start in the worktree it was delegated: two lanes on 2026-08-30 each ran
# bare-relative commands — `tools/guard` among them — against another lane's
# worktree, and both noticed only after a confusing downstream failure.
#
# The cure is a precondition the agent runs before anything repo-relative:
# every `Worktree: [PLACEHOLDER]` line inside a `<delegation_format>` block
# is followed immediately by a `Worktree Check:` line naming that SAME
# placeholder. `pwd` reports where the shell actually is, so the check can
# fail; a line that merely restates the delegated path cannot.
#
# This lint is the answer to the recurrence, not to the eleven sites: a new
# delegation block that carries `Worktree:` without its check fails here
# rather than shipping the silent-wrong-tree hazard again.
#
# Scoped to `<delegation_format>` blocks in orch's workflows. A `Worktree:`
# mention in prose or in a fenced example is not a delegation and is not
# scanned.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# scan_worktree_precondition <file>
# Emits one "file:line: ..." line per defect. Inside a <delegation_format>
# block, a `Worktree: [TOKEN]` line must be followed on the very next line by
# a `Worktree Check:` line whose text contains `[TOKEN]` — the same
# placeholder, so a filled delegation compares against its own path and not
# another site's. Lines outside a delegation block are never scanned.
scan_worktree_precondition() {
  awk -v f="$1" '
    /^[[:space:]]*<delegation_format>[[:space:]]*$/ { indel = 1; pending = 0; next }
    /^[[:space:]]*<\/delegation_format>[[:space:]]*$/ {
      if (pending) printf "%s:%d: Worktree: [%s] ends the delegation with no Worktree Check line\n", f, pendline, token
      indel = 0; pending = 0; next
    }
    indel {
      if (pending) {
        if ($0 !~ /^[[:space:]]*Worktree Check:/) {
          printf "%s:%d: Worktree: [%s] is not followed by a Worktree Check line\n", f, pendline, token
        } else if (index($0, "[" token "]") == 0) {
          printf "%s:%d: Worktree Check names no [%s] to compare pwd against\n", f, NR, token
        }
        pending = 0
      }
      if (match($0, /^[[:space:]]*Worktree:[[:space:]]*\[[A-Za-z_][A-Za-z0-9_]*\][[:space:]]*$/)) {
        line = $0
        sub(/^[[:space:]]*Worktree:[[:space:]]*\[/, "", line)
        sub(/\].*$/, "", line)
        token = line; pendline = NR; pending = 1
      }
    }
  ' "$1"
}

echo "=== orch delegation worktree-cwd-precondition lint ==="

# --- Part a: every shipped delegation block carries the precondition -------
DOCS="$(ls "$SKILLS_ROOT"/orch/workflows/*.md)"
offenders=""
sites=0
for doc in $DOCS; do
  out="$(scan_worktree_precondition "$doc")"
  [ -n "$out" ] && offenders="$offenders$out"$'\n'
  n="$(grep -c '^[[:space:]]*Worktree Check:' "$doc" || true)"
  sites=$((sites + n))
done
if [ -z "$offenders" ]; then
  pass "every delegated Worktree: line is followed by its Worktree Check"
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

# --- Part b: the lint has teeth -------------------------------------------

# probe <name> <body> → prints scratch-file path.
# Writes a standalone delegation block containing <body> (printf %b, so \n
# splits it into lines) under $TMP_ROOT, removed by the EXIT trap.
probe() {
  scratch="$TMP_ROOT/probe-$1.md"
  printf '<delegation_format>\n%b\n</delegation_format>\n' "$2" > "$scratch"
  printf '%s' "$scratch"
}

CHECK='Worktree Check: `pwd` before any repo-relative command. It must print [WORKTREE_PATH].'

# b.1 — the reported shape (a bare Worktree: line, as all eleven sites read
# before this change) IS flagged.
if [ -n "$(scan_worktree_precondition "$(probe bare 'Issue: [ISSUE_ID]\nWorktree: [WORKTREE_PATH]\nRound ID: [DEV_ROUND_ID]')" )" ]; then
  pass "lint flags a Worktree: line with no Worktree Check"
else
  fail "lint MISSED a bare Worktree: line (no teeth)"
fi

# b.2 — the fixed shape is NOT flagged.
if [ -z "$(scan_worktree_precondition "$(probe fixed "Worktree: [WORKTREE_PATH]\n$CHECK")" )" ]; then
  pass "lint accepts Worktree: followed by its Worktree Check"
else
  fail "lint false-flagged the fixed shape"
fi

# b.3 — a check naming a DIFFERENT placeholder IS flagged: a filled
# delegation would compare pwd against a path this block never carries.
if [ -n "$(scan_worktree_precondition "$(probe crossed 'Worktree: [WT_PATH]\nWorktree Check: `pwd` must print [WORKTREE_PATH].')" )" ]; then
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

# b.5 — a Worktree: mention outside a delegation block is NOT scanned.
PROSE="$TMP_ROOT/probe-prose.md"
printf 'Fill the delegation Worktree: [WORKTREE_PATH] from the claim output.\n' > "$PROSE"
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
