#!/usr/bin/env bash
# Regression lint for vstack#968. audit-issues.md is a user-facing wrapper with
# an interactive § 6 approval gate, but the orch call sites said "run the
# workflow" without saying WHERE, and orchestrators delegated the whole wrapper
# to a tpm subagent. A subagent runner structurally skips the gate: it cannot
# present the § 6 multi-select, and one observed run (CC-935) executed § 7 —
# creating 5 issues and 6 relations — on a scope-reaffirming follow-up message,
# before the primary session obtained user approval.
#
# The fix declares the wrapper primary-session-only, names the tpm-audit.md
# analysis as the ONLY delegable part at the orch call sites, and makes § 6
# fail closed (with a § 7 hard precondition) for runners without interactive
# question capability. This lint pins each statement.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
AUDIT_WF="$SKILL_DIR/../project-management/workflows/audit-issues.md"
PM_SKILL="$SKILL_DIR/../project-management/SKILL.md"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== audit-issues primary-session gate lint (vstack#968) ==="

# --- a: the wrapper declares itself primary-session-only --------------------
if grep -q 'Primary-session wrapper — never delegate this workflow itself' "$AUDIT_WF"; then
  pass "audit-issues.md declares primary-session-only"
else
  fail "audit-issues.md lost the primary-session-only declaration"
fi

# --- b: § 6 fails closed for non-interactive runners ------------------------
if grep -q 'Fail closed without interactive capability' "$AUDIT_WF" \
   && grep -q 'MUST STOP here' "$AUDIT_WF"; then
  pass "audit-issues.md § 6 contains the fail-closed stop instruction"
else
  fail "audit-issues.md § 6 lost the fail-closed stop instruction"
fi

# --- c: § 7 states the in-session approval hard precondition ----------------
if grep -q 'Hard precondition — § 6 approval obtained in-session' "$AUDIT_WF"; then
  pass "audit-issues.md § 7 guards on in-session § 6 approval"
else
  fail "audit-issues.md § 7 lost the in-session approval precondition"
fi

# --- d: orch call sites name tpm-audit.md as the only delegable part --------
for wf in review-pr review; do
  doc="$SKILL_DIR/workflows/$wf.md"
  if grep -q 'primary-session wrapper' "$doc" \
     && grep -q 'the only delegable part is the `tpm-audit.md` analysis' "$doc"; then
    pass "$wf.md names tpm-audit.md as the only delegable part"
  else
    fail "$wf.md lost the primary-session call-site contract"
  fi
done

# --- e: the skill index carries the same contract ---------------------------
if grep -q 'primary-session only' "$PM_SKILL"; then
  pass "project-management SKILL.md marks audit-issues primary-session only"
else
  fail "project-management SKILL.md lost the primary-session marker"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
