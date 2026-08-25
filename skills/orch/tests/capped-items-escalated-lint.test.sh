#!/usr/bin/env bash
# Regression lint for KEN-518. When review-pr § 4 hit the cycle cap, the
# verification pass's outstanding blockers routed to § 5 without ever landing
# in `fixed_items` or `escalated_items`. § 8's decline derivation ("in a
# json_paths artifact but in neither bucket → declined") then reported live
# blockers as declined with `reason: not recorded` and dropped them from the
# filing candidates — nothing filed them.
#
# The fix records each outstanding item in `escalated_items` (outcome
# "blocked", so the audit builder maps it to origin "escalated") before the
# route to § 5. This lint pins that append inside the Bounded Re-Review
# section, its outcome field, and the schema's coverage of the cap path.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
REVIEW_PR_WF="$SKILL_DIR/workflows/review-pr.md"
STATE_SCHEMA="$SKILL_DIR/schemas/workflow-state.md"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== review-pr capped items escalated lint (KEN-518) ==="

# The cap rule lives in § 4's Bounded Re-Review subsection, before § 5.
bounded_rereview() { awk '/^### Bounded Re-Review/{on=1;next} /^## 5\./{on=0} on' "$1"; }

# --- a: the cap paragraph records outstanding items as escalated ------------
if bounded_rereview "$REVIEW_PR_WF" \
   | grep -q 'workflow-state append \[ISSUE_ID\] escalated_items'; then
  pass "Bounded Re-Review appends capped items to escalated_items before § 5"
else
  fail "Bounded Re-Review lost the escalated_items append for capped items"
fi

# --- b: the append carries the typed outcome so audit maps it to escalated --
if bounded_rereview "$REVIEW_PR_WF" \
   | grep -E 'workflow-state append \[ISSUE_ID\] escalated_items' \
   | grep -q '"outcome":"blocked"'; then
  pass "the capped-item append writes outcome \"blocked\""
else
  fail "the capped-item append lost outcome \"blocked\""
fi

# --- c: the rule states the disposition, not just the mechanics -------------
# Without the stated contract, a future edit can keep an append somewhere while
# reverting to report-only routing at the cap.
if bounded_rereview "$REVIEW_PR_WF" | grep -q 'Capped items are escalated, never dropped'; then
  pass "Bounded Re-Review states the capped-items-are-escalated contract"
else
  fail "Bounded Re-Review lost the capped-items-are-escalated contract"
fi

# --- d: the schema documents the cap path into escalated_items --------------
if grep -qE '\|\s*`escalated_items`.*cycle cap' "$STATE_SCHEMA"; then
  pass "workflow-state schema covers the cycle-cap path into escalated_items"
else
  fail "workflow-state schema lost the cycle-cap path for escalated_items"
fi

# --- planted controls: prove each check can fail ----------------------------
echo
echo "--- planted controls ---"

plant_pr() {
  # $1 = control name, $2 = sed program applied to review-pr.md
  local scratch="$TMP_ROOT/pr-$1.md"
  sed "$2" "$REVIEW_PR_WF" > "$scratch"
  printf '%s' "$scratch"
}

# The pre-fix shape: outstanding items reported, never recorded.
CTRL="$(plant_pr append '/workflow-state append \[ISSUE_ID\] escalated_items/d')"
if bounded_rereview "$CTRL" | grep -q 'workflow-state append \[ISSUE_ID\] escalated_items'; then
  fail "lint MISSED a dropped capped-item escalated_items append"
else
  pass "lint flags a dropped capped-item escalated_items append"
fi

CTRL="$(plant_pr outcome 's/"outcome":"blocked",//')"
if bounded_rereview "$CTRL" \
   | grep -E 'workflow-state append \[ISSUE_ID\] escalated_items' \
   | grep -q '"outcome":"blocked"'; then
  fail "lint MISSED a dropped outcome field on the capped-item append"
else
  pass "lint flags a dropped outcome field on the capped-item append"
fi

CTRL="$(plant_pr contract 's/\*\*Capped items are escalated, never dropped\.\*\* Record every blocker.*$/At the cap, report the outstanding items after that pass and proceed to § 5./')"
if bounded_rereview "$CTRL" | grep -q 'Capped items are escalated, never dropped'; then
  fail "lint MISSED a reverted report-only cap rule"
else
  pass "lint flags a reverted report-only cap rule"
fi

# Scoping control: an escalated_items append elsewhere (dev-fix's § 6 pattern
# quoted in another section) must not satisfy check a. Two passes, because a
# single sed program that both plants and deletes collides in the pattern
# space and removes the plant along with the § 5 heading.
CTRL="$TMP_ROOT/pr-scope.md"
sed '/^### Bounded Re-Review/,/^## 5\./{/workflow-state append \[ISSUE_ID\] escalated_items/d}' "$REVIEW_PR_WF" \
  | sed 's|^## 5\. Verdict Pass$|## 5. Verdict Pass\n\n.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] escalated_items placeholder|' > "$CTRL"
if ! grep -q 'escalated_items placeholder' "$CTRL"; then
  fail "scoping fixture planted no append outside Bounded Re-Review — control is vacuous"
elif bounded_rereview "$CTRL" | grep -q 'workflow-state append \[ISSUE_ID\] escalated_items'; then
  fail "lint credits an escalated_items append outside Bounded Re-Review"
else
  pass "lint scopes the append check to Bounded Re-Review"
fi

SCRATCH_SCHEMA="$TMP_ROOT/schema.md"
sed 's/, plus items still outstanding when review-pr'\''s cycle cap ends the fix loop//; s/; the cap path always writes this//' "$STATE_SCHEMA" > "$SCRATCH_SCHEMA"
if grep -qE '\|\s*`escalated_items`.*cycle cap' "$SCRATCH_SCHEMA"; then
  fail "lint MISSED a schema that lost the cycle-cap path"
else
  pass "lint flags a schema that lost the cycle-cap path"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
