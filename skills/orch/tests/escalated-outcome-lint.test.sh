#!/usr/bin/env bash
# Regression lint for vstack#970. The `escalated_items` workflow-state bucket
# used to conflate two dev outcomes — items dev was BLOCKED on and items dev
# deliberately SKIPPED — distinguishable only via free-text `reason`. Downstream,
# review-pr § 9 fed the bucket wholesale into audit input as `origin:
# "escalated"` ("blockers dev couldn't fix"), so under
# ORCH_DECISION_MODE=auto-recommended skipped low-priority residue was filed as
# if it were unfixable blockers.
#
# The fix threads the dev round's typed per-item decision through the
# state-write boundary as an `outcome` field ("blocked"|"skipped") and maps it
# to distinct audit origins (blocked/absent → "escalated", skipped →
# "skipped"). This lint pins each link of that chain in the instruction docs.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
PM_SCHEMA="$SKILL_DIR/../project-management/schemas/audit-issues-input.md"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== orch escalated_items outcome lint (vstack#970) ==="

# --- a: the state write carries the typed outcome ---------------------------
# The dev-fix escalated_items append must include the outcome field so the
# Blocked/Skipped distinction survives the state-write boundary.
if grep -E 'workflow-state append \[ISSUE_ID\] escalated_items' "$SKILL_DIR/workflows/dev-fix.md" \
   | grep -q '"outcome":'; then
  pass "dev-fix escalated_items append carries the \"outcome\" field"
else
  fail "dev-fix escalated_items append lost the \"outcome\" field"
fi

# --- b: audit-input builders map outcome to distinct origins ----------------
for wf in review-pr review; do
  doc="$SKILL_DIR/workflows/$wf.md"
  if grep -q '`"skipped"` → `origin: "skipped"`' "$doc" \
     && grep -q '`origin: "escalated"`' "$doc"; then
    pass "$wf.md maps outcome → origin (skipped vs escalated)"
  else
    fail "$wf.md lost the outcome → origin mapping"
  fi
done

# --- c: legacy entries (no outcome field) stay backward compatible ----------
# Both builders must say entries WITHOUT an outcome field map to "escalated",
# so pre-#970 state files keep their original meaning.
for wf in review-pr review; do
  doc="$SKILL_DIR/workflows/$wf.md"
  if grep -q 'no `outcome` field' "$doc"; then
    pass "$wf.md keeps legacy no-outcome entries mapped to escalated"
  else
    fail "$wf.md lost the legacy no-outcome → escalated rule"
  fi
done

# --- d: the audit-input schema knows the skipped origin ---------------------
if grep -q 'suggestion|escalated|skipped|planned|discovered' "$PM_SCHEMA"; then
  pass "audit-issues-input origin enum includes skipped"
else
  fail "audit-issues-input origin enum lost skipped"
fi
if grep -q 'outcome "skipped" → origin: "skipped"' "$PM_SCHEMA" \
   && grep -q 'outcome "blocked" (or no outcome field' "$PM_SCHEMA"; then
  pass "audit-issues-input documents the outcome → origin mapping"
else
  fail "audit-issues-input lost the outcome → origin mapping"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
