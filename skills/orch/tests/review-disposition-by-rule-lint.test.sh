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
# What this pins are TOKENS, never sentences: review-bots.md holds markdown
# contract lints to setting keys, command names, headings, table rows and
# stable inline code literals, so an editorial rephrase must not fail a suite
# while the contract holds.
#
# A token earns a pin only when its presence cannot be true while the rule is
# false. `ORCH_DECISION_MODE` and its two values fail that test: they name what
# the rule talks about, so a § 4 rewritten to say `ask` prompts for each fix
# and `auto-recommended` fixes automatically keeps every one of them while
# inverting the rule, and generic prompt wording slips past MENU_RE. So each
# rule carries a token stating its own claim — `mode-independent` for
# disposition, `artifact-derived` for declines — which an edit has to delete in
# order to lie. The setting key, the mode values and the `reason: not recorded`
# fallback stay pinned underneath as the enumeration the claim ranges over,
# each with a control, and the Declined heading, the metric row and the
# audit-issues path are operative tokens that carry their own claims.
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
# `mode-independent` is the rule's own claim: an edit that hands the decision
# back to the mode has to delete it, whatever it does to the surrounding prose.
for doc_pair in "$REVIEW_PR_WF|review-pr.md" "$REVIEW_WF|review.md"; do
  doc="${doc_pair%%|*}"
  name="${doc_pair##*|}"
  if s4_has "$doc" '`mode-independent`'; then
    pass "$name § 4 states the disposition-by-rule contract"
  else
    fail "$name § 4 lost the disposition-by-rule contract"
  fi

  # The enumeration the claim ranges over: the setting and BOTH its values, so
  # a rule narrowed to a single mode has to drop a value name to say so.
  if s4_has "$doc" 'ORCH_DECISION_MODE' \
     && s4_has "$doc" '`ask`' && s4_has "$doc" '`auto-recommended`'; then
    pass "$name § 4 binds the rule to every decision mode"
  else
    fail "$name § 4 lost the setting or a decision-mode value from the binding"
  fi
done

# Declines must reach the report, and must be derivable from disk rather than
# from a conversation a compaction can drop. `artifact-derived` is that rule's
# own claim; the `reason: not recorded` fallback is what the derivation prints
# when the reason is gone, and it outlives the rule, so it cannot stand in.
if grep -q '^### 🚫 DECLINED$' "$REVIEW_PR_WF" \
   && grep -qF -e '`artifact-derived`' "$REVIEW_PR_WF"; then
  pass "review-pr.md § 8 reports declined items and derives them from artifacts"
else
  fail "review-pr.md § 8 lost the declined reporting or its artifact derivation"
fi

if grep -qF -e 'reason: not recorded' "$REVIEW_PR_WF"; then
  pass "review-pr.md § 8 keeps the unrecorded-reason fallback"
else
  fail "review-pr.md § 8 lost the unrecorded-reason fallback"
fi

# Declines must still surface — dropping a finding silently is the failure
# mode that makes an unattended disposition rule untrustworthy.
if grep -q '^| Declined |' "$REVIEW_WF" && grep -q '^### Declined$' "$REVIEW_WF"; then
  pass "review.md § 5 reports declined findings and their rationale"
else
  fail "review.md § 5 lost the declined reporting"
fi

# Issue creation keeps a real user gate — audit-issues' own approval step. The
# route to that workflow is the token; § 4 is where review.md files from.
if s4_has "$REVIEW_WF" 'workflows/audit-issues.md'; then
  pass "review.md routes issue creation through the audit-issues approval gate"
else
  fail "review.md lost the audit-issues approval-gate routing"
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

# $1 = source, $2 = control name, $3 = fixed token, $4 = its replacement.
# Rebuilds each line left to right, so a replacement containing the token
# cannot send the scan round again.
plant_sub() {
  CTRL="$TMP_ROOT/$2.md"
  awk -v from="$3" -v to="$4" '
    {
      line = $0; out = ""
      while ((p = index(line, from)) > 0) {
        out = out substr(line, 1, p - 1) to
        line = substr(line, p + length(from))
        hit = 1
      }
      print out line
    }
    END { exit(hit ? 0 : 1) }
  ' "$1" > "$CTRL"
}

# $1 = source, $2 = control name, $3 = fixed token anchoring the line to
# replace, $4 = the line that replaces it. Anchoring on the token rather than
# on the prose is what keeps a control planting after an editorial rewrite.
plant_line() {
  CTRL="$TMP_ROOT/$2.md"
  awk -v tok="$3" -v repl="$4" '
    index($0, tok) && !done { print repl; done = 1; next }
    { print }
    END { exit(done ? 0 : 1) }
  ' "$1" > "$CTRL"
}

# The mutation the token pins exist to catch: the rule handed back to the
# decision mode, with the setting and both its values still named. Nothing here
# matches MENU_RE — `ORCH_DECISION_MODE` and `ask` are separated by backticks,
# and "prompts for each fix" is not one of its shapes — so only a token stating
# the rule's own claim can catch it.
GATED_LINE='Disposition follows the decision mode: `ORCH_DECISION_MODE` `ask` prompts for each fix, and `auto-recommended` fixes automatically.'
RECALLED_LINE='**Declined items are whatever this session recalls.** A blocker or `category == "fix"` suggestion you remember setting aside was declined in § 4 or § 7; where a compaction lost its reason, report `reason: not recorded`.'

# $1 = fixture, $2 = control name. Fails the control, not the lint, when the
# fixture did not keep every incidental token or tripped MENU_RE: either way it
# would no longer prove the claim token is what does the catching.
retains_mode_tokens() {
  local ctrl="$1" name="$2"
  if ! s4_has "$ctrl" 'ORCH_DECISION_MODE' \
     || ! s4_has "$ctrl" '`ask`' || ! s4_has "$ctrl" '`auto-recommended`'; then
    fail "$name control dropped an incidental mode token — it proves nothing about the claim token"
    return 1
  fi
  if has_menu "$ctrl"; then
    fail "$name control tripped the menu check — it proves nothing about the claim token"
    return 1
  fi
  return 0
}

if ! plant_menu "$REVIEW_WF" menu '## 4. Present And Fix'; then
  fail "menu control planted nothing — its § 4 heading was not found"
elif has_menu "$CTRL"; then
  pass "lint flags a reintroduced Apply fixes? multi-select"
else
  fail "lint MISSED a reintroduced Apply fixes? multi-select"
fi

if ! plant_line "$REVIEW_WF" gated '`mode-independent`' "$GATED_LINE"; then
  fail "gated control planted nothing — the claim token was not found"
elif retains_mode_tokens "$CTRL" gated; then
  if s4_has "$CTRL" '`mode-independent`'; then
    fail "lint MISSED a disposition handed back to the decision mode"
  else
    pass "lint flags a disposition handed back to the decision mode"
  fi
fi

if ! plant_sub "$REVIEW_WF" binding 'ORCH_DECISION_MODE' 'the decision-mode setting'; then
  fail "binding control planted nothing — the setting key was not found"
elif s4_has "$CTRL" 'ORCH_DECISION_MODE'; then
  fail "lint MISSED a binding that stops naming the setting"
else
  pass "lint flags a binding that stops naming the setting"
fi

if ! plant_sub "$REVIEW_WF" every '`ask`' '`auto-recommended`'; then
  fail "every control planted nothing — the ask mode value was not found"
elif s4_has "$CTRL" '`ask`'; then
  fail "lint MISSED a narrowed decision-mode binding"
else
  pass "lint flags a narrowed decision-mode binding"
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

if ! plant_line "$REVIEW_PR_WF" pr-gated '`mode-independent`' "$GATED_LINE"; then
  fail "review-pr gated control planted nothing — the claim token was not found"
elif retains_mode_tokens "$CTRL" pr-gated; then
  if s4_has "$CTRL" '`mode-independent`'; then
    fail "lint MISSED a review-pr disposition handed back to the decision mode"
  else
    pass "lint flags a review-pr disposition handed back to the decision mode"
  fi
fi

if ! plant_sub "$REVIEW_PR_WF" pr-binding 'ORCH_DECISION_MODE' 'the decision-mode setting'; then
  fail "review-pr binding control planted nothing — the setting key was not found"
elif s4_has "$CTRL" 'ORCH_DECISION_MODE'; then
  fail "lint MISSED a review-pr binding that stops naming the setting"
else
  pass "lint flags a review-pr binding that stops naming the setting"
fi

if ! plant_sub "$REVIEW_PR_WF" pr-every '`ask`' '`auto-recommended`'; then
  fail "review-pr every control planted nothing — the ask mode value was not found"
elif s4_has "$CTRL" '`ask`'; then
  fail "lint MISSED a narrowed review-pr decision-mode binding"
else
  pass "lint flags a narrowed review-pr decision-mode binding"
fi

if ! plant_drop "$REVIEW_PR_WF" pr-declined '### 🚫 DECLINED'; then
  fail "review-pr declined control planted nothing — the heading was not found"
elif grep -q '^### 🚫 DECLINED$' "$CTRL"; then
  fail "lint MISSED a dropped review-pr DECLINED section"
else
  pass "lint flags a dropped review-pr DECLINED section"
fi

if ! plant_line "$REVIEW_PR_WF" pr-recalled '`artifact-derived`' "$RECALLED_LINE"; then
  fail "review-pr recalled control planted nothing — the claim token was not found"
elif ! grep -qF -e 'reason: not recorded' "$CTRL"; then
  fail "recalled control dropped the fallback token — it proves nothing about the claim token"
elif grep -qF -e '`artifact-derived`' "$CTRL"; then
  fail "lint MISSED declines taken from memory instead of from the artifacts"
else
  pass "lint flags declines taken from memory instead of from the artifacts"
fi

if ! plant_sub "$REVIEW_PR_WF" pr-fallback 'reason: not recorded' 'whatever you recall'; then
  fail "review-pr fallback control planted nothing — the fallback literal was not found"
elif grep -qF -e 'reason: not recorded' "$CTRL"; then
  fail "lint MISSED a dropped unrecorded-reason fallback"
else
  pass "lint flags a dropped unrecorded-reason fallback"
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
