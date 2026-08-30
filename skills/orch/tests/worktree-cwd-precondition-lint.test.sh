#!/usr/bin/env bash
# Regression lint for KEN-878. A delegated agent's shell does not reliably
# start in the worktree it was delegated: two lanes on 2026-08-30 each ran
# bare-relative commands — `tools/guard` among them — against another lane's
# worktree, and both noticed only after a confusing downstream failure.
#
# The cure is a precondition the agent runs before anything repo-relative:
# every `Worktree: [PLACEHOLDER]` line inside a `<delegation_format>` block
# is followed immediately by a `Worktree Check:` line that OPENS with a
# backticked `pwd` and names that SAME placeholder. `pwd` reports where the
# shell actually is, so the check can fail; a line that merely restates the
# delegated path cannot.
#
# All three conditions are load-bearing, and the command one is the reason
# this lint was rewritten twice. Matching the label and the placeholder
# alone is fail-open: replacing the opening of a real check with `Worktree
# Check: trust the path.` left the whole suite green, because the rest of
# the line still carried its placeholder. Matching `pwd` ANYWHERE on the
# line is the same hole one step further in — that mutation still said
# "re-run `pwd`" in its remedy clause. Matching the FIRST backticked span
# wherever it falls is that hole a third time: a check opening with prose
# and offering `pwd` later still passes, because the first span found is a
# later one. So the match is anchored to the start of the line: what has to
# hold is that the first executable step IS the command, asserted by
# position rather than by mention.
#
# This lint is the answer to the recurrence, not to the individual sites: a
# new delegation block that carries `Worktree:` without a working check
# fails here rather than shipping the silent-wrong-tree hazard again.
#
# Scope is every skill doc that can carry a delegation, not one directory —
# scoping the first sweep to orch/workflows is what let the
# project-management site sit unguarded. Tests are excluded: their probe
# fixtures carry deliberately broken blocks. A `Worktree:` mention in prose
# or in a fenced example is not a delegation and is not scanned.
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
# a `Worktree Check:` line that (a) BEGINS with a backticked `pwd` — the
# match is anchored, so nothing may precede the code span and the agent's
# first executable step is the command that reports where the shell
# actually is — and (b) contains `[TOKEN]`, the same placeholder, so a
# filled delegation compares against its own path and not another site's.
# Lines outside a delegation block are never scanned.
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
        } else {
          rest = $0
          sub(/^[[:space:]]*Worktree Check:[[:space:]]*/, "", rest)
          cmd = ""
          if (match(rest, /^`[^`]*`/)) cmd = substr(rest, RSTART + 1, RLENGTH - 2)
          if (cmd != "pwd") {
            printf "%s:%d: Worktree Check does not open with a backticked pwd (first command: %s)\n", f, NR, (cmd == "" ? "none" : cmd)
          }
          if (index($0, "[" token "]") == 0) {
            printf "%s:%d: Worktree Check names no [%s] to compare pwd against\n", f, NR, token
          }
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
# Every skill doc, not one skill's workflows: a delegation that hands over a
# worktree is checked wherever it lives. Tests are excluded — their probe
# fixtures carry deliberately broken blocks.
DOCS="$(find "$SKILLS_ROOT" -name '*.md' -not -path '*/tests/*' | sort)"
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

# b.7 — THE REPORTED FAIL-OPEN. The exact mutation two reviewers landed
# independently: the opening command replaced by prose, everything after it
# left intact. The line still carries its placeholder AND still says `pwd` in
# the remedy clause, so both a placeholder check and an anywhere-on-the-line
# `pwd` check pass it. Only asserting the line's OPENING span catches it.
MUTANT='Worktree: [WORKTREE_PATH]\nWorktree Check: trust the path. It must print [WORKTREE_PATH]; a bare `git status` answers about the wrong tree. Any other path — `cd "[WORKTREE_PATH]"`, re-run `pwd`, and report where it started.'
if [ -n "$(scan_worktree_precondition "$(probe mutant "$MUTANT")" )" ]; then
  pass "lint flags a check whose leading command was replaced by prose"
else
  fail "lint MISSED the reported fail-open (a check that runs nothing)"
fi

# b.10 — THE ROUND-THREE FAIL-OPEN. Prose in front, a backticked `pwd`
# behind it: the first backticked span on the line IS `pwd`, so an unanchored
# match accepts a check that demotes the command to optional. Only anchoring
# to the start of the line rejects it.
DEMOTED='Worktree: [WORKTREE_PATH]\nWorktree Check: trust the path; optional check: `pwd` must print [WORKTREE_PATH].'
if [ -n "$(scan_worktree_precondition "$(probe demoted "$DEMOTED")" )" ]; then
  pass "lint flags a check whose pwd sits behind leading prose"
else
  fail "lint MISSED a backticked pwd demoted behind prose"
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
