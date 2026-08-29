#!/usr/bin/env bash
# Regression lint for kendex#970. The `escalated_items` workflow-state bucket
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
# "skipped"). This lint pins the tokens that chain carries in the instruction
# docs — the `outcome` field, its two values, and the origins they map to.
# The absent-field half of the rule is prose only and has no pin.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
PM_SCHEMA="$SKILL_DIR/../project-management/schemas/audit-issues-input.md"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== orch escalated_items outcome lint (kendex#970) ==="

# --- a: the state write carries the typed outcome ---------------------------
# The dev-fix escalated entry must include the outcome field so the
# Blocked/Skipped distinction survives the state-write boundary. The entry is
# written to a file and bound into the write, so the field sits in the entry
# shape and the write is the command that appends it.
DEV_FIX="$SKILL_DIR/workflows/dev-fix.md"
if grep -qE '^\s*\{"description":.*"outcome":' "$DEV_FIX" \
   && grep -qE 'workflow-state update \[ISSUE_ID\].*\.escalated_items \+=' "$DEV_FIX"; then
  pass "dev-fix escalated entry carries the \"outcome\" field into its write"
else
  fail "dev-fix escalated entry lost the \"outcome\" field or its write"
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

# No check here for the legacy rule that an entry WITHOUT an `outcome` field
# maps to origin "escalated". Both builders state it in prose around the
# `outcome` token the mapping check above already reads, so no token is
# present only while the rule holds. It is uncovered in review-pr.md, in
# review.md, and in the audit-issues-input schema.

# --- d: the audit-input schema knows the skipped origin ---------------------
if grep -q 'suggestion|escalated|skipped|planned|discovered' "$PM_SCHEMA"; then
  pass "audit-issues-input origin enum includes skipped"
else
  fail "audit-issues-input origin enum lost skipped"
fi
if grep -q 'outcome "skipped" → origin: "skipped"' "$PM_SCHEMA" \
   && grep -q 'outcome "blocked"' "$PM_SCHEMA" \
   && grep -q 'origin: "escalated"' "$PM_SCHEMA"; then
  pass "audit-issues-input documents the outcome → origin mapping"
else
  fail "audit-issues-input lost the outcome → origin mapping"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
