#!/usr/bin/env bash
# Why this is pinned by line number rather than by reading the workflow:
# both ways the gate goes quiet leave it present and correct-looking.
#
# Below `### Fix Delegation` it reads identically and fires once the round
# it exists to prevent has been launched. Named in caller context but absent
# from the delegation template, it is decided and never delivered, because
# the agent reads the delegation, not the workflow. Neither is visible in
# review, so order and delivery are checked mechanically and each check
# carries a planted control.

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

GATE_RE='converge before delegating'

# The gate is only load-bearing where it sits above the delegation, so the
# comparison is on position rather than presence.
line_of() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }

GATE_AT="$(line_of "$REVIEW_PR_WF" "$GATE_RE" || true)"
DELEG_AT="$(line_of "$REVIEW_PR_WF" 'Run Workflow.*dev-fix.md' || true)"
if [[ -n "$GATE_AT" && -n "$DELEG_AT" ]] && (( GATE_AT < DELEG_AT )); then
  pass "review-pr.md gates the fix round before delegating it"
else
  fail "the gate does not sit above the delegation (gate ${GATE_AT:-absent}, delegation ${DELEG_AT:-absent})"
fi

# The phrase alone is not the contract: a gate that fires at two or four, or
# that names no cycle at all, reads the same and bounds nothing.
GATE_LINE="$(grep -m1 "$GATE_RE" "$REVIEW_PR_WF" || true)"
if printf '%s' "$GATE_LINE" | grep -q '`cycles` at 2'; then
  pass "the gate names the counter value the third round enters with"
else
  fail "the gate does not pin a threshold, so it bounds nothing"
fi

# Every round the cap allows must pass through the gate; a threshold that
# lets the last one through converges nothing that matters.
if grep -q 'when `cycles` reaches 4' "$REVIEW_PR_WF"; then
  pass "the cap the gate has to cover still stops the loop at four rounds"
else
  fail "the cap moved, so the gate's threshold no longer covers every round it allows"
fi

# The cycle count is per issue, so a review re-entered on a fresh diff can
# arrive past the threshold on its first round. Without the exception the gate
# forces that round into a cut it has no grounds for.
if printf '%s' "$GATE_LINE" | grep -q 'first round on this diff'; then
  pass "the gate exempts a genuine first round on a fresh diff"
else
  fail "a carried counter forces a fresh diff's first round to converge"
fi

# A finding that leaves items is disposed of one way or the other; absent from
# both records it reads as declined, which is how a live blocker goes quiet.
if sed -n '/### Fix Delegation/,/Run Workflow.*dev-fix.md/p' "$REVIEW_PR_WF" \
  | grep -q 'never dropped'; then
  pass "the gate says findings leaving items are disposed of"
else
  fail "findings can leave items with nothing saying what becomes of them"
fi

# Accepted in caller context and absent from the template is the same as not
# accepted: the agent reads the delegation, not the workflow.
dev_fix_template() { awk '/<delegation_format>/{on=1} on; /<\/delegation_format>/{on=0}' "$1"; }

if dev_fix_template "$DEV_FIX_WF" | grep -qi 'Convergence:'; then
  pass "dev-fix.md renders the decision in the delegation it emits"
else
  fail "dev-fix.md accepts the decision but never puts it in the delegation"
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

# Each control must fail the check it targets, or that check is passing for a
# reason other than the property it claims to pin.
plant() {
  local name="$1"
  local prog="$2"
  local scratch="$TMP_ROOT/pr-$name.md"
  sed "$prog" "$REVIEW_PR_WF" > "$scratch"
  printf '%s' "$scratch"
}

CTRL_THRESHOLD="$(plant threshold 's/.cycles. at 2/no particular count/')"
CTRL_LINE="$(grep -m1 "$GATE_RE" "$CTRL_THRESHOLD" || true)"
if printf '%s' "$CTRL_LINE" | grep -q '`cycles` at 2'; then
  fail "control: a gate with its threshold removed still reads as pinned"
else
  pass "control: a gate with no threshold is detectable"
fi

CTRL_EXCEPTION="$(plant exception 's/first round on this diff/some other reason/')"
CTRL_EXC_LINE="$(grep -m1 "$GATE_RE" "$CTRL_EXCEPTION" || true)"
if printf '%s' "$CTRL_EXC_LINE" | grep -q 'first round on this diff'; then
  fail "control: a gate with the exception removed still reads as exempting it"
else
  pass "control: a gate with no fresh-diff exception is detectable"
fi

CTRL_MISSING="$(plant missing "/$GATE_RE/d")"
if [[ -z "$(line_of "$CTRL_MISSING" "$GATE_RE" || true)" ]]; then
  pass "control: a removed gate is detectable"
else
  fail "control: removing the gate did not change what the lint sees"
fi

# A gate below the delegation fires after the round it exists to prevent.
CTRL_LATE="$TMP_ROOT/pr-late.md"
grep -v "$GATE_RE" "$REVIEW_PR_WF" > "$CTRL_LATE"
printf '\n**From the third fix round on, converge before delegating it** — moved below.\n' >> "$CTRL_LATE"
gate_late="$(line_of "$CTRL_LATE" "$GATE_RE" || true)"
deleg_late="$(line_of "$CTRL_LATE" 'Run Workflow.*dev-fix.md' || true)"
if [[ -n "$gate_late" && -n "$deleg_late" ]] && (( gate_late > deleg_late )); then
  pass "control: a gate placed after the delegation is detectable"
else
  fail "control: the order check cannot see a late gate"
fi

CTRL_PROSE="$TMP_ROOT/dev-fix-prose.md"
awk '/<delegation_format>/{on=1} { if (on && /Convergence:/) next } { print } /<\/delegation_format>/{on=0}' \
  "$DEV_FIX_WF" > "$CTRL_PROSE"
if dev_fix_template "$CTRL_PROSE" | grep -qi 'Convergence:'; then
  fail "control: the check passes on a template with the line removed"
else
  pass "control: a decision accepted in prose but absent from the template is detectable"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
