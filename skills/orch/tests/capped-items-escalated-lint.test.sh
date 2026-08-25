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
# section, its outcome field, the selection clause deciding which items it
# covers, the schema's coverage of the cap path, and the same contract in
# workflow-state's cap-refusal message — the instruction an orchestrator
# receives at the instant the cap fires.
#
# The section is read with HTML comments stripped, and the pre-fix
# report-only sentence is rejected outright, so a rule that is present but
# inert does not satisfy the greps.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
REVIEW_PR_WF="$SKILL_DIR/workflows/review-pr.md"
STATE_SCHEMA="$SKILL_DIR/schemas/workflow-state.md"
WS_SCRIPT="$SKILL_DIR/scripts/workflow-state"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== review-pr capped items escalated lint (KEN-518) ==="

# The cap rule lives in § 4's Bounded Re-Review subsection, before § 5. Text
# inside an HTML comment is removed: a commented-out instruction is not an
# instruction, and the greps below must not credit it.
bounded_rereview() {
  awk '
    /^### Bounded Re-Review/ { on = 1; next }
    /^## 5\./               { on = 0 }
    !on { next }
    {
      line = $0; out = ""
      while (length(line) > 0) {
        if (incomment) {
          p = index(line, "-->")
          if (p == 0) { line = ""; break }
          incomment = 0
          line = substr(line, p + 3)
        } else {
          p = index(line, "<!--")
          if (p == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, p - 1)
          incomment = 1
          line = substr(line, p + 4)
        }
      }
      print out
    }
  ' "$1"
}

# The refusal `workflow-state set … rereview_panel` prints once cycles is
# past the cap.
cap_refusal() { grep -F 'cycles is past the cap' "$1"; }

# The pre-fix instruction: route and report, record nothing.
REPORT_ONLY='At the cap, report the outstanding items'

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

# --- d: a re-found item an earlier round called fixed is still recorded -----
# The cap is reached when fixes are not converging, so the ordinary content of
# the final pass is a blocker whose recorded fix did not hold. Excluding it
# leaves § 8 printing a live blocker as ✅ FIXED against a stale SHA.
if bounded_rereview "$REVIEW_PR_WF" | grep -q 'whose fix did not hold'; then
  pass "the selection clause keeps an item whose recorded fix did not hold"
else
  fail "the selection clause lost the re-found fixed_items case"
fi

# --- e: § 4 declines stay declined -----------------------------------------
# A decline sits in neither bucket, exactly like an unrecorded capped item, so
# the clause must separate them by name or it sweeps declines into escalated.
if bounded_rereview "$REVIEW_PR_WF" | grep -qF 'a decline is terminal'; then
  pass "the selection clause excludes § 4 declines"
else
  fail "the selection clause lost the decline exclusion"
fi

# --- f: the dedup key is named, not left to the reader ----------------------
if bounded_rereview "$REVIEW_PR_WF" | grep -qF '(location, description)'; then
  pass "the selection clause names the (location, description) match key"
else
  fail "the selection clause lost the match key"
fi

# --- g: the pre-fix report-only instruction is gone -------------------------
if bounded_rereview "$REVIEW_PR_WF" | grep -qF "$REPORT_ONLY"; then
  fail "Bounded Re-Review carries the pre-fix report-only instruction again"
else
  pass "Bounded Re-Review carries no report-only cap instruction"
fi

# --- h: the schema documents the cap path into escalated_items --------------
if grep -qE '\|\s*`escalated_items`.*cycle cap' "$STATE_SCHEMA"; then
  pass "workflow-state schema covers the cycle-cap path into escalated_items"
else
  fail "workflow-state schema lost the cycle-cap path for escalated_items"
fi

# --- i: the cap refusal says record-then-route, matching § 4 ----------------
# This stderr is what the orchestrator reads at the moment the cap bites; a
# route-only message reproduces the defect with § 4 fixed.
if cap_refusal "$WS_SCRIPT" | grep -q 'escalated_items'; then
  pass "the cap refusal names the escalated_items recording step"
else
  fail "the cap refusal lost the escalated_items recording step"
fi

# --- planted controls: prove each check can fail ----------------------------
echo
echo "--- planted controls ---"

# $1 = control name, $2 = sed program applied to review-pr.md. Sets CTRL to
# the fixture path and reports whether the program changed anything: one that
# matches nothing leaves the source untouched, and the control then proves
# nothing. This runs in the parent shell, never a command substitution, so its
# verdict reaches the counters.
plant_pr() {
  CTRL="$TMP_ROOT/pr-$1.md"
  sed "$2" "$REVIEW_PR_WF" > "$CTRL"
  ! cmp -s "$CTRL" "$REVIEW_PR_WF"
}

# The pre-fix shape: outstanding items reported, never recorded.
if ! plant_pr append '/workflow-state append \[ISSUE_ID\] escalated_items/d'; then
  fail "append control planted nothing — its sed program matched no text"
elif bounded_rereview "$CTRL" | grep -q 'workflow-state append \[ISSUE_ID\] escalated_items'; then
  fail "lint MISSED a dropped capped-item escalated_items append"
else
  pass "lint flags a dropped capped-item escalated_items append"
fi

if ! plant_pr outcome 's/"outcome":"blocked",//'; then
  fail "outcome control planted nothing — its sed program matched no text"
elif bounded_rereview "$CTRL" \
   | grep -E 'workflow-state append \[ISSUE_ID\] escalated_items' \
   | grep -q '"outcome":"blocked"'; then
  fail "lint MISSED a dropped outcome field on the capped-item append"
else
  pass "lint flags a dropped outcome field on the capped-item append"
fi

if ! plant_pr contract "s/\*\*Capped items are escalated, never dropped\.\*\* Record every blocker.*$/$REPORT_ONLY after that pass and proceed to § 5./"; then
  fail "contract control planted nothing — its sed program matched no text"
elif bounded_rereview "$CTRL" | grep -q 'Capped items are escalated, never dropped'; then
  fail "lint MISSED a reverted report-only cap rule"
else
  pass "lint flags a reverted report-only cap rule"
fi

if ! plant_pr refound 's/ whose fix did not hold//'; then
  fail "re-found control planted nothing — its sed program matched no text"
elif bounded_rereview "$CTRL" | grep -q 'whose fix did not hold'; then
  fail "lint MISSED a selection clause that drops the re-found fixed_items case"
else
  pass "lint flags a selection clause that drops the re-found fixed_items case"
fi

if ! plant_pr decline 's/; a decline is terminal//'; then
  fail "decline control planted nothing — its sed program matched no text"
elif bounded_rereview "$CTRL" | grep -qF 'a decline is terminal'; then
  fail "lint MISSED a selection clause that drops the decline exclusion"
else
  pass "lint flags a selection clause that drops the decline exclusion"
fi

if ! plant_pr key 's/ Match on (location, description), the § 8 key\.//'; then
  fail "match-key control planted nothing — its sed program matched no text"
elif bounded_rereview "$CTRL" | grep -qF '(location, description)'; then
  fail "lint MISSED a selection clause that drops the match key"
else
  pass "lint flags a selection clause that drops the match key"
fi

# Inverse control: the rule's text is preserved verbatim but made inert — the
# whole cap rule wrapped in an HTML comment, with the pre-fix report-only
# sentence re-added after it. Every text-presence check must still go red.
INERT="$TMP_ROOT/pr-inert.md"
awk -v report_only="$REPORT_ONLY after that pass and proceed to § 5." '
  st == 0 && /\*\*Capped items are escalated/ {
    i = index($0, "**Capped items are escalated")
    print substr($0, 1, i - 1) "<!-- " substr($0, i)
    st = 1
    next
  }
  st == 1 && /^```$/ { print $0 " -->"; print ""; print report_only; st = 2; next }
  { print }
' "$REVIEW_PR_WF" > "$INERT"
if ! grep -qF '<!-- **Capped items are escalated' "$INERT"; then
  fail "inert-rule control planted nothing — the cap rule was not commented out"
elif bounded_rereview "$INERT" | grep -q 'workflow-state append \[ISSUE_ID\] escalated_items'; then
  fail "lint credits an escalated_items append that sits inside an HTML comment"
elif bounded_rereview "$INERT" | grep -q 'Capped items are escalated, never dropped'; then
  fail "lint credits a contract sentence that sits inside an HTML comment"
elif ! bounded_rereview "$INERT" | grep -qF "$REPORT_ONLY"; then
  fail "lint does not see the restored report-only instruction"
else
  pass "lint flags a cap rule commented out and replaced by report-only routing"
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
if cmp -s "$SCRATCH_SCHEMA" "$STATE_SCHEMA"; then
  fail "schema control planted nothing — its sed program matched no text"
elif grep -qE '\|\s*`escalated_items`.*cycle cap' "$SCRATCH_SCHEMA"; then
  fail "lint MISSED a schema that lost the cycle-cap path"
else
  pass "lint flags a schema that lost the cycle-cap path"
fi

SCRATCH_WS="$TMP_ROOT/workflow-state"
sed 's/in escalated_items (outcome/in the state (outcome/' "$WS_SCRIPT" > "$SCRATCH_WS"
if cmp -s "$SCRATCH_WS" "$WS_SCRIPT"; then
  fail "refusal control planted nothing — its sed program matched no text"
elif cap_refusal "$SCRATCH_WS" | grep -q 'escalated_items'; then
  fail "lint MISSED a cap refusal that routes without recording"
else
  pass "lint flags a cap refusal that routes without recording"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
