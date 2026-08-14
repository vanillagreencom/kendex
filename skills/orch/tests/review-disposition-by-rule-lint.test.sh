#!/usr/bin/env bash
# Regression lint: `orch review` disposes findings by rule, never by prompt.
#
# The standalone review workflow used to present an `Apply fixes?` multi-select
# over its own blockers and fix suggestions, and a second multi-select over the
# issue candidates. Both are mechanics questions the disposition rules already
# answer, so the menu only added a stall: an unattended run had nothing to
# select with, and an attended one re-litigated a classification the reviewers
# had already made. The rest of the stack disposes by rule and asks only about
# product or experience.
#
# This lint pins the no-prompt shape at the one place it regressed, and pins
# that the surviving user-facing gate (audit-issues' own approval step) is
# still what governs issue creation.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
REVIEW_WF="$SKILL_DIR/workflows/review.md"
REVIEW_PR_WF="$SKILL_DIR/workflows/review-pr.md"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== orch review disposition-by-rule lint ==="

# Selection-menu shapes, matched only in the fix-disposition section (§ 4).
# Scoping to § 4 keeps an unrelated ask elsewhere in the workflow from
# tripping this, and keeps the lint honest about WHERE the regression lands.
section_4() { awk '/^## 4\./{on=1;next} /^## 5\./{on=0} on' "$1"; }
section_7() { awk '/^## 7\./{on=1;next} /^## 8\./{on=0} on' "$1"; }

MENU_RE='(multi-select|Apply fixes\?|Create issues for these\?|items selected|Fix blockers\?|Apply fix suggestions\?|Ignore and proceed|resolve the decision mode|ORCH_DECISION_MODE ask)'

check_no_menu() {
  local doc="$1" label="$2"
  if section_4 "$doc" | grep -qEi "$MENU_RE"; then
    fail "$label"
    return 1
  fi
  pass "$label"
}

check_no_menu "$REVIEW_WF" "review.md § 4 presents no selection menu over findings"

# review-pr.md is the PR-gating twin: same findings, same reviewers, so the
# same rule. § 4 handles review items, § 7 the QA items by explicit reference
# to the § 4 pattern — both must stay menu-free.
if section_4 "$REVIEW_PR_WF" | grep -qEi "$MENU_RE"; then
  fail "review-pr.md § 4 presents a selection menu or gates fixes on a decision mode"
else
  pass "review-pr.md § 4 presents no selection menu over findings"
fi

if section_7 "$REVIEW_PR_WF" | grep -qEi "$MENU_RE"; then
  fail "review-pr.md § 7 presents a selection menu or gates QA fixes on a decision mode"
else
  pass "review-pr.md § 7 presents no selection menu over QA findings"
fi

if section_4 "$REVIEW_PR_WF" | grep -q 'Disposition is by rule, not by prompt'; then
  pass "review-pr.md § 4 states the disposition-by-rule contract"
else
  fail "review-pr.md § 4 lost the disposition-by-rule contract"
fi

# EVERY decision mode, not just auto-recommended — the regression this pins is
# a mode check creeping back in front of the fix round.
if section_4 "$REVIEW_PR_WF" | grep -q 'in EVERY decision mode'; then
  pass "review-pr.md § 4 binds the rule to every decision mode"
else
  fail "review-pr.md § 4 lost the every-decision-mode binding"
fi

# Declines must reach the report, and must be derivable from disk rather than
# from a conversation a compaction can drop.
if grep -q '^### 🚫 DECLINED$' "$REVIEW_PR_WF" \
   && grep -q 'Declined items are re-derived, not remembered' "$REVIEW_PR_WF"; then
  pass "review-pr.md § 8 reports declined items and derives them from artifacts"
else
  fail "review-pr.md § 8 lost the declined reporting or its artifact derivation"
fi

# The positive statement, so a future edit cannot quietly drop the rule and
# leave only the absence of a menu (which a truncated file would also satisfy).
if grep -q 'Disposition is by rule, not by prompt' "$REVIEW_WF"; then
  pass "review.md § 4 states the disposition-by-rule contract"
else
  fail "review.md § 4 lost the disposition-by-rule contract"
fi

# ORCH_DECISION_MODE must not be documented as a way back to the menu.
if grep -q 'does not reintroduce the menu' "$REVIEW_WF"; then
  pass "review.md § 4 excludes ORCH_DECISION_MODE from restoring the menu"
else
  fail "review.md § 4 lost the ORCH_DECISION_MODE exclusion"
fi

# Declines must still surface — dropping a finding silently is the failure
# mode that makes an unattended disposition rule untrustworthy.
if grep -q '^| Declined |' "$REVIEW_WF" && grep -q '^### Declined$' "$REVIEW_WF"; then
  pass "review.md § 5 reports declined findings and their rationale"
else
  fail "review.md § 5 lost the declined reporting"
fi

# Issue creation keeps a real user gate — audit-issues' own approval step.
if grep -q 'primary-session wrapper' "$REVIEW_WF"; then
  pass "review.md routes issue creation through the audit-issues approval gate"
else
  fail "review.md lost the audit-issues approval-gate routing"
fi

# --- planted controls: prove each check can fail ----------------------------
echo
echo "--- planted controls ---"

plant() {
  # $1 = control name, $2 = sed program applied to review.md
  local scratch="$TMP_ROOT/$1.md"
  sed "$2" "$REVIEW_WF" > "$scratch"
  printf '%s' "$scratch"
}

plant_pr() {
  # $1 = control name, $2 = sed program applied to review-pr.md
  local scratch="$TMP_ROOT/pr-$1.md"
  sed "$2" "$REVIEW_PR_WF" > "$scratch"
  printf '%s' "$scratch"
}

CTRL="$(plant menu 's/^Omit empty categories\. \*\*Disposition is by rule.*$/Omit empty categories, then ask `Apply fixes?` as a multi-select over blockers and fix suggestions./')"
if section_4 "$CTRL" | grep -qEi "$MENU_RE"; then
  pass "lint flags a reintroduced Apply fixes? multi-select"
else
  fail "lint MISSED a reintroduced Apply fixes? multi-select"
fi

CTRL="$(plant contract 's/Disposition is by rule, not by prompt/Disposition is up to you/')"
if grep -q 'Disposition is by rule, not by prompt' "$CTRL"; then
  fail "lint MISSED a dropped disposition-by-rule contract"
else
  pass "lint flags a dropped disposition-by-rule contract"
fi

CTRL="$(plant declined '/^| Declined |/d')"
if grep -q '^| Declined |' "$CTRL"; then
  fail "lint MISSED a dropped Declined metric row"
else
  pass "lint flags a dropped Declined metric row"
fi

# Scoping control: an ask OUTSIDE § 4 must not trip the lint, or ordinary
# edits elsewhere in the workflow would fail it for the wrong reason.
CTRL="$(plant scope 's/^## 5\. Summary$/## 5. Summary\n\nAsk `Keep going?` as a multi-select./')"
if section_4 "$CTRL" | grep -qEi "$MENU_RE"; then
  fail "lint false-flagged a multi-select outside § 4"
else
  pass "lint scopes the menu check to § 4"
fi

CTRL="$(plant_pr mode 's/^\*\*Disposition is by rule.*$/Resolve the decision mode with orch-env ORCH_DECISION_MODE ask, then ask `Fix blockers?`./')"
if section_4 "$CTRL" | grep -qEi "$MENU_RE"; then
  pass "lint flags a decision-mode gate reintroduced in review-pr § 4"
else
  fail "lint MISSED a decision-mode gate reintroduced in review-pr § 4"
fi

CTRL="$(plant_pr qa 's/^Follow the § 4 pattern — collect, present, delegate.*$/Follow the § 4 pattern — collect, present, resolve the decision mode, delegate./')"
if section_7 "$CTRL" | grep -qEi "$MENU_RE"; then
  pass "lint flags a decision-mode gate reintroduced in review-pr § 7"
else
  fail "lint MISSED a decision-mode gate reintroduced in review-pr § 7"
fi

CTRL="$(plant_pr every 's/in EVERY decision mode/under auto-recommended/')"
if section_4 "$CTRL" | grep -q 'in EVERY decision mode'; then
  fail "lint MISSED a narrowed decision-mode binding"
else
  pass "lint flags a narrowed decision-mode binding"
fi

CTRL="$(plant_pr declined '/^### 🚫 DECLINED$/d')"
if grep -q '^### 🚫 DECLINED$' "$CTRL"; then
  fail "lint MISSED a dropped review-pr DECLINED section"
else
  pass "lint flags a dropped review-pr DECLINED section"
fi

CTRL="$(plant_pr derive 's/Declined items are re-derived, not remembered/Declined items are whatever you recall/')"
if grep -q 'Declined items are re-derived, not remembered' "$CTRL"; then
  fail "lint MISSED a dropped artifact-derivation rule"
else
  pass "lint flags a dropped artifact-derivation rule"
fi

# Scoping control for review-pr: dev-fix's own standalone ask lives in a
# different workflow and must not be dragged in by these checks.
CTRL="$(plant_pr scope 's/^## 5\. Verdict Pass$/## 5. Verdict Pass\n\nAsk `Fix blockers?` here./')"
if section_4 "$CTRL" | grep -qEi "$MENU_RE"; then
  fail "lint false-flagged a menu outside review-pr § 4"
else
  pass "lint scopes the review-pr menu check to § 4"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
