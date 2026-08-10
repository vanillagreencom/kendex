#!/usr/bin/env bash
# review-risk helper contract: one checked invocation the review-pr workflow
# can call under restrictive approval policies. Exit 0 + validated level,
# exit 3 when the opt-in key is unset, exit 1 (loud stderr) on any classifier
# failure or contract violation — callers fail open to the full fleet.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_RISK="$(cd "$TEST_DIR/.." && pwd)/scripts/review-risk"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

WT="$TMP_ROOT/wt"
mkdir -p "$WT"

echo "=== review-risk helper contract ==="

# Unset key: exit 3, no output.
set +e
out=$(REVIEW_RISK_COMMAND="" "$REVIEW_RISK" "$WT" 2>/dev/null)
rc=$?
set -e
assert_eq "$rc" "3" "unset REVIEW_RISK_COMMAND exits 3"
assert_eq "$out" "" "unset key prints nothing"

# Valid answers, whitespace tolerated.
for level in high medium low; do
  out=$(REVIEW_RISK_COMMAND="printf '%s\n' $level" "$REVIEW_RISK" "$WT")
  assert_eq "$out" "$level" "classifier '$level' passes through"
done
out=$(REVIEW_RISK_COMMAND="printf '  low \n'" "$REVIEW_RISK" "$WT")
assert_eq "$out" "low" "padded output is trimmed"

# The classifier runs IN the worktree.
mkdir -p "$WT/only-here"
out=$(REVIEW_RISK_COMMAND='test -d only-here && echo low' "$REVIEW_RISK" "$WT")
assert_eq "$out" "low" "classifier runs from the worktree root"

# Contract violations: garbage output, failing command — exit 1, stderr names
# the command.
set +e
out=$(REVIEW_RISK_COMMAND="echo critical" "$REVIEW_RISK" "$WT" 2>"$TMP_ROOT/err1")
rc=$?
set -e
assert_eq "$rc" "1" "unrecognized level exits 1"
grep -q "high|medium|low" "$TMP_ROOT/err1" || { FAIL=$((FAIL + 1)); printf '  FAIL  contract error names the expected levels\n'; }

set +e
REVIEW_RISK_COMMAND="exit 7" "$REVIEW_RISK" "$WT" 2>"$TMP_ROOT/err2"
rc=$?
set -e
assert_eq "$rc" "1" "failing classifier exits 1"
grep -q "failed" "$TMP_ROOT/err2" || { FAIL=$((FAIL + 1)); printf '  FAIL  failure error says the command failed\n'; }

set +e
REVIEW_RISK_COMMAND="echo low" "$REVIEW_RISK" "$TMP_ROOT/missing" 2>/dev/null
rc=$?
set -e
assert_eq "$rc" "1" "missing worktree exits 1"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
