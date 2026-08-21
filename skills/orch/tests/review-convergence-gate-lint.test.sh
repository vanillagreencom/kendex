#!/usr/bin/env bash
# Regression lint: the round-three convergence gate runs before the fix round
# it gates, and its decision reaches the round.
#
# A PR that keeps yielding new defects is usually carrying a surface nothing
# asked for, and answering it comment by comment fixes each finding correctly
# while the surface stays. The gate exists to force that question one cycle
# before the cap, when the answer can still change what happens.
#
# Two ways it goes quiet without anyone noticing, both of which happened while
# it was being written:
#
#   1. Placed after `### Fix Delegation`, it fires once the round it exists to
#      prevent has already been launched — a decision arriving a cycle late.
#   2. Recorded in `rereview_panel`, which the panel-scoping step overwrites a
#      few lines later, and read by nothing: the decision is made and lost.
#
# So this pins ORDER and DELIVERY, not the wording.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
REVIEW_PR_WF="$SKILL_DIR/workflows/review-pr.md"
DEV_FIX_WF="$SKILL_DIR/workflows/dev-fix.md"
SKILL_MD="$SKILL_DIR/SKILL.md"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== orch review convergence-gate lint ==="

GATE_RE='At `cycles` 3, converge'

# Line numbers are the whole point here: the gate is only load-bearing if it
# sits between the delegation heading and the delegation itself.
line_of() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }

check_order() {
  local doc="$1" label="$2"
  local gate deleg
  gate="$(line_of "$doc" "$GATE_RE" || true)"
  deleg="$(line_of "$doc" 'Run Workflow.*dev-fix.md' || true)"
  if [[ -z "$gate" ]]; then
    fail "$label (gate absent)"
    return
  fi
  if [[ -z "$deleg" ]]; then
    fail "$label (delegation absent)"
    return
  fi
  if (( gate < deleg )); then
    pass "$label"
  else
    fail "$label (gate at $gate, delegation at $deleg)"
  fi
}

check_order "$REVIEW_PR_WF" "review-pr.md gates the fix round before delegating it"

# The decision has to land somewhere the panel-scoping write does not clobber.
if grep -q "workflow-state set \[ISSUE_ID\] convergence" "$REVIEW_PR_WF"; then
  pass "review-pr.md records the decision in its own key"
else
  fail "review-pr.md does not record the convergence decision durably"
fi

if grep -q "rereview_panel" "$REVIEW_PR_WF" \
  && sed -n "/$GATE_RE/,/Run Workflow.*dev-fix.md/p" "$REVIEW_PR_WF" \
     | grep -q "set \[ISSUE_ID\] rereview_panel"; then
  fail "the convergence decision is stored in rereview_panel, which is later overwritten"
else
  pass "the convergence decision is not stored in the key that gets overwritten"
fi

# Recorded and never read is the same as not recorded.
if grep -q 'convergence' "$DEV_FIX_WF"; then
  pass "dev-fix.md accepts the convergence decision"
else
  fail "dev-fix.md does not read the convergence decision, so the gate is decorative"
fi

if sed -n "/Run Workflow.*dev-fix.md/p" "$REVIEW_PR_WF" | grep -q 'convergence'; then
  pass "review-pr.md passes the decision into the delegation"
else
  fail "review-pr.md records the decision but never passes it to the fix round"
fi

if grep -q 'Review must converge' "$SKILL_MD"; then
  pass "SKILL.md states the convergence rule the workflow implements"
else
  fail "SKILL.md lost the convergence rule"
fi

# Planted controls: each must fail the check it targets, or the check is
# passing for a reason other than the property it claims to pin.
plant() {
  local name="$1"
  local prog="$2"
  local scratch="$TMP_ROOT/pr-$name.md"
  sed "$prog" "$REVIEW_PR_WF" > "$scratch"
  printf '%s' "$scratch"
}

CTRL_MISSING="$(plant missing "/$GATE_RE/d")"
if [[ -z "$(line_of "$CTRL_MISSING" "$GATE_RE" || true)" ]]; then
  pass "control: a removed gate is detectable"
else
  fail "control: removing the gate did not change what the lint sees"
fi

# Moving the gate below the delegation is the exact regression that shipped.
CTRL_LATE="$TMP_ROOT/pr-late.md"
grep -v "$GATE_RE" "$REVIEW_PR_WF" > "$CTRL_LATE"
printf '\n**At `cycles` 3, converge before delegating this round** — moved below.\n' >> "$CTRL_LATE"
gate_late="$(line_of "$CTRL_LATE" "$GATE_RE" || true)"
deleg_late="$(line_of "$CTRL_LATE" 'Run Workflow.*dev-fix.md' || true)"
if [[ -n "$gate_late" && -n "$deleg_late" ]] && (( gate_late > deleg_late )); then
  pass "control: a gate placed after the delegation is detectable"
else
  fail "control: the order check cannot see a late gate"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
