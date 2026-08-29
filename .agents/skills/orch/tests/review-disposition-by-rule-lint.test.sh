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
# This suite covers two things only, per review-bots.md.
#
# The absence of the menu shape, which is what a pattern can honestly decide: a
# menu has to be written to be present, and no rephrasing hides one.
#
# And the presence of structural elements — the Declined heading, the metric
# row, the audit-issues route. That a section or a route is THERE, never that
# the prose around it says anything in particular.
#
# It does not cover the disposition rule or the decline-derivation rule
# themselves. Those are claims written in prose, and prose negates or qualifies
# around any literal: `mode-independent` was tried as a pin and a § 4 reading
# "`mode-independent` only in `auto-recommended`" satisfied it while inverting
# the rule. A substring pin cannot establish a claim, so those rules are
# uncovered here rather than covered in appearance.
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
#
# Every call feeds grep through a herestring, never a pipe: `grep -q` exits at
# the first match, a pipe would deliver SIGPIPE to awk, and `pipefail` would
# promote awk's 141 into a failed check for a contract that is present. Whether
# the race is lost depends on how much awk still has buffered, so it grows with
# the section's length.
section_4() { awk '/^## 4\./{on=1;next} /^## 5\./{on=0} on' "$1"; }
section_7() { awk '/^## 7\./{on=1;next} /^## 8\./{on=0} on' "$1"; }

MENU_RE='(multi-select|Apply fixes\?|Create issues for these\?|items selected|Fix blockers\?|Apply fix suggestions\?|Ignore and proceed|resolve the decision mode|ORCH_DECISION_MODE ask)'

has_menu() { grep -qEi "$MENU_RE" <<<"$(section_4 "$1")"; }
s4_has()   { grep -qF -e "$2" <<<"$(section_4 "$1")"; }

check_no_menu() {
  local doc="$1" label="$2"
  if has_menu "$doc"; then
    fail "$label"
    return 1
  fi
  pass "$label"
}

check_no_menu "$REVIEW_WF" "review.md § 4 presents no selection menu over findings"

# review-pr.md is the PR-gating twin: same findings, same reviewers, so the
# same rule. § 4 handles review items, § 7 the QA items by explicit reference
# to the § 4 pattern — both must stay menu-free.
check_no_menu "$REVIEW_PR_WF" "review-pr.md § 4 presents no selection menu over findings"

if grep -qEi "$MENU_RE" <<<"$(section_7 "$REVIEW_PR_WF")"; then
  fail "review-pr.md § 7 presents a selection menu or gates QA fixes on a decision mode"
else
  pass "review-pr.md § 7 presents no selection menu over QA findings"
fi

# The positive statement, so a future edit cannot quietly drop the rule and
# leave only the absence of a menu (which a truncated file would also satisfy).
# The section where declines are reported must exist to report them into.
if grep -q '^### 🚫 DECLINED$' "$REVIEW_PR_WF"; then
  pass "review-pr.md § 8 carries the declined report section"
else
  fail "review-pr.md § 8 lost the declined report section"
fi

# The metric row and the section a decline is reported into. Their presence is
# what this establishes — whether a run fills them in is not a fact about text.
if grep -q '^| Declined |' "$REVIEW_WF" && grep -q '^### Declined$' "$REVIEW_WF"; then
  pass "review.md § 5 carries the Declined metric row and report section"
else
  fail "review.md § 5 lost the Declined metric row or report section"
fi

# § 4 names the audit-issues route. A structural fact about the workflow, not a
# claim that the routing behaves: what audit-issues does with its approval gate
# is asserted where that gate lives, never from this file's text.
if s4_has "$REVIEW_WF" 'workflows/audit-issues.md'; then
  pass "review.md § 4 names the audit-issues route"
else
  fail "review.md § 4 lost the audit-issues route"
fi

# --- planted controls: prove each check can fail ----------------------------
echo
echo "--- planted controls ---"

# Each planter writes $CTRL in the PARENT shell and returns whether it changed
# anything: a program that matches nothing leaves the fixture identical to the
# source, and the control would then report a lint miss for a guard that
# works. Say so instead — the fixture, not the lint, is what broke.

MENU_LINE='Ask `Apply fixes?` as a multi-select over the blockers.'

# $1 = source, $2 = control name, $3 = heading the menu is planted under.
plant_menu() {
  CTRL="$TMP_ROOT/$2.md"
  awk -v anchor="$3" -v line="$MENU_LINE" '
    { print }
    index($0, anchor) == 1 && !done { print ""; print line; done = 1 }
    END { exit(done ? 0 : 1) }
  ' "$1" > "$CTRL"
}

# $1 = source, $2 = control name, $3 = fixed token whose lines are deleted.
plant_drop() {
  CTRL="$TMP_ROOT/$2.md"
  awk -v tok="$3" '
    index($0, tok) { hit = 1; next }
    { print }
    END { exit(hit ? 0 : 1) }
  ' "$1" > "$CTRL"
}


if ! plant_menu "$REVIEW_WF" menu '## 4. Present And Fix'; then
  fail "menu control planted nothing — its § 4 heading was not found"
elif has_menu "$CTRL"; then
  pass "lint flags a reintroduced Apply fixes? multi-select"
else
  fail "lint MISSED a reintroduced Apply fixes? multi-select"
fi


if ! plant_drop "$REVIEW_WF" declined '| Declined |'; then
  fail "declined control planted nothing — the metric row was not found"
elif grep -q '^| Declined |' "$CTRL"; then
  fail "lint MISSED a dropped Declined metric row"
else
  pass "lint flags a dropped Declined metric row"
fi

if ! plant_drop "$REVIEW_WF" audit 'workflows/audit-issues.md'; then
  fail "audit control planted nothing — the workflow path was not found"
elif s4_has "$CTRL" 'workflows/audit-issues.md'; then
  fail "lint MISSED a dropped audit-issues route"
else
  pass "lint flags a dropped audit-issues route"
fi

# Scoping control: an ask OUTSIDE § 4 must not trip the lint, or ordinary
# edits elsewhere in the workflow would fail it for the wrong reason.
if ! plant_menu "$REVIEW_WF" scope '## 5. Summary'; then
  fail "scoping control planted nothing — its § 5 heading was not found"
elif has_menu "$CTRL"; then
  fail "lint false-flagged a multi-select outside § 4"
else
  pass "lint scopes the menu check to § 4"
fi

if ! plant_menu "$REVIEW_PR_WF" pr-mode '## 4. Handle Review Items'; then
  fail "review-pr menu control planted nothing — its § 4 heading was not found"
elif has_menu "$CTRL"; then
  pass "lint flags a menu reintroduced in review-pr § 4"
else
  fail "lint MISSED a menu reintroduced in review-pr § 4"
fi

if ! plant_menu "$REVIEW_PR_WF" pr-qa '## 7. Handle QA Items'; then
  fail "review-pr QA control planted nothing — its § 7 heading was not found"
elif grep -qEi "$MENU_RE" <<<"$(section_7 "$CTRL")"; then
  pass "lint flags a menu reintroduced in review-pr § 7"
else
  fail "lint MISSED a menu reintroduced in review-pr § 7"
fi


if ! plant_drop "$REVIEW_PR_WF" pr-declined '### 🚫 DECLINED'; then
  fail "review-pr declined control planted nothing — the heading was not found"
elif grep -q '^### 🚫 DECLINED$' "$CTRL"; then
  fail "lint MISSED a dropped review-pr DECLINED section"
else
  pass "lint flags a dropped review-pr DECLINED section"
fi


# Scoping control for review-pr: dev-fix's own standalone ask lives in a
# different workflow and must not be dragged in by these checks.
if ! plant_menu "$REVIEW_PR_WF" pr-scope '## 5. Verdict Pass'; then
  fail "review-pr scoping control planted nothing — its § 5 heading was not found"
elif has_menu "$CTRL"; then
  fail "lint false-flagged a menu outside review-pr § 4"
else
  pass "lint scopes the review-pr menu check to § 4"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
