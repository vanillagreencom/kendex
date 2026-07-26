#!/usr/bin/env bash
# Regression tests for `refix-route` (vstack#875).
#
# Review routing used `git-diff-summary`'s `scope` as a risk proxy, so ANY
# `support`-scope fix round skipped re-review — regardless of diff size, and
# regardless of whether the round existed to clear blockers. The reported case
# (hyprtrade CC-1143) was 14 files / 996 insertions / 143 deletions resolving 8
# blockers, classified `support` with no risk flags; the re-review that a human
# asked for found 3 more blockers, two of them new false-greens.
#
# These tests pin the decision, the class, and the ordering of the reasons.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
ROUTE="$SKILL_DIR/scripts/refix-route"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

summary() {
  local name="$1" json="$2"
  printf '%s\n' "$json" >"$TMP_ROOT/$name.json"
  printf '%s\n' "$TMP_ROOT/$name.json"
}

# Runs refix-route with a fixed threshold so the tests do not depend on the
# ambient repo's [env] settings.
route() {
  local file="$1" blockers="${2:-0}"
  PR_REVIEW_REFIX_MAX_LINES=200 "$ROUTE" --summary-file "$file" --blockers-fixed "$blockers"
}

assert_field() {
  local out="$1" field="$2" want="$3" name="$4" got
  got="$(jq -r ".$field" <<<"$out")"
  if [[ "$got" == "$want" ]]; then pass "$name"
  else fail "$name (want $field=$want, got $got)"; fi
}

CC1143="$(summary cc1143 '{"files_changed":14,"insertions":996,"deletions":143,"scope":"support","domains":{},"risk_flags":[]}')"
SMALL="$(summary small   '{"files_changed":2,"insertions":30,"deletions":5,"scope":"support","domains":{},"risk_flags":[]}')"
ZERO="$(summary zero     '{"files_changed":0,"scope":"support","domains":{},"risk_flags":[]}')"
PROD="$(summary prod     '{"files_changed":2,"insertions":10,"deletions":1,"scope":"production","domains":{},"risk_flags":[]}')"
RISK="$(summary risk     '{"files_changed":1,"insertions":3,"deletions":0,"scope":"support","domains":{},"risk_flags":["migration"]}')"
EDGE="$(summary edge     '{"files_changed":3,"insertions":200,"deletions":0,"scope":"support","domains":{},"risk_flags":[]}')"
OVER="$(summary over     '{"files_changed":3,"insertions":201,"deletions":0,"scope":"support","domains":{},"risk_flags":[]}')"

echo "=== the reported regression: a blocker-clearing support round ==="

OUT="$(route "$CC1143" 8)"
assert_field "$OUT" decision "rereview" "CC-1143 shape with 8 blockers re-reviews"
assert_field "$OUT" class    "blockers" "…and attributes it to the blockers"
assert_field "$OUT" blockers_fixed "8" "…and reports the blocker count"

# Even a one-line support fix gets looked at again when a blocker prompted it —
# the signal is that the round was written under blocker pressure, not its size.
OUT="$(route "$SMALL" 1)"
assert_field "$OUT" decision "rereview" "a small support round that fixed a blocker re-reviews"
assert_field "$OUT" class    "blockers" "…classified as blockers, not size"

echo "=== size backstop for rounds no blocker prompted ==="

OUT="$(route "$CC1143" 0)"
assert_field "$OUT" decision "rereview" "a large support round re-reviews with zero blockers"
assert_field "$OUT" class    "size"     "…classified as size"
assert_field "$OUT" changed_lines "1139" "…counting insertions plus deletions"

OUT="$(route "$EDGE" 0)"
assert_field "$OUT" decision "skip" "exactly at the threshold still skips"
OUT="$(route "$OVER" 0)"
assert_field "$OUT" decision "rereview" "one line over the threshold re-reviews"

echo "=== unchanged behaviour for the rows that already routed correctly ==="

OUT="$(route "$ZERO" 0)"
assert_field "$OUT" decision "skip" "no files changed skips"
assert_field "$OUT" class    "none" "…classified as none"

OUT="$(route "$PROD" 0)"
assert_field "$OUT" decision "rereview" "production scope re-reviews"
assert_field "$OUT" class    "production" "…classified as production"

OUT="$(route "$RISK" 0)"
assert_field "$OUT" decision "rereview" "risk flags re-review"
assert_field "$OUT" class    "risk" "…classified as risk"

# Risk flags outrank everything: the reason an operator reads should be the
# first thing that made the change risky.
OUT="$(route "$RISK" 5)"
assert_field "$OUT" class "risk" "risk flags outrank blockers in the reported reason"

echo "=== a genuinely small, blocker-free support round still skips ==="

OUT="$(route "$SMALL" 0)"
assert_field "$OUT" decision "skip"  "small blocker-free support round skips"
assert_field "$OUT" class    "small" "…classified as small"
if [[ -n "$(jq -r '.reason' <<<"$OUT")" ]]; then
  pass "the skip carries a reason string for the operator log"
else
  fail "the skip carries a reason string for the operator log"
fi

echo "=== threshold is tunable and validated ==="

OUT="$(PR_REVIEW_REFIX_MAX_LINES=10000 "$ROUTE" --summary-file "$CC1143" --blockers-fixed 0)"
assert_field "$OUT" decision "skip" "raising PR_REVIEW_REFIX_MAX_LINES suppresses the size trigger"
assert_field "$OUT" threshold_lines "10000" "…and the effective threshold is reported"

# A non-numeric setting must not silently disable the backstop; orch-env falls
# back to the documented default.
OUT="$(PR_REVIEW_REFIX_MAX_LINES=banana "$ROUTE" --summary-file "$CC1143" --blockers-fixed 0)"
assert_field "$OUT" threshold_lines "200" "a non-numeric threshold falls back to the default"
assert_field "$OUT" decision "rereview" "…so the backstop still fires"

set +e
"$ROUTE" --summary-file "$CC1143" --blockers-fixed -3 >/dev/null 2>&1
neg_status=$?
"$ROUTE" --summary-file "$TMP_ROOT/does-not-exist.json" >/dev/null 2>&1
missing_status=$?
set -e
[[ "$neg_status" -eq 2 ]] && pass "a negative blocker count is rejected" || fail "a negative blocker count is rejected"
[[ "$missing_status" -eq 2 ]] && pass "a missing summary file is rejected" || fail "a missing summary file is rejected"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
