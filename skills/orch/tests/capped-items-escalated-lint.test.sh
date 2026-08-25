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
# route to § 5, dropping its superseded `fixed_items` entry in the SAME
# workflow-state update: one finding then sits in neither both buckets nor
# none, whichever moment a dying session stops at. This lint pins that single
# write inside the Bounded Re-Review section, its outcome field, the selection
# clause deciding which items it covers, the schema's coverage of the cap path,
# and the same contract in workflow-state's cap-refusal message — the
# instruction an orchestrator receives at the instant the cap fires.
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

# The cap rule lives in § 4's Bounded Re-Review subsection, before § 5. HTML
# comment regions are stripped from EVERY line before the section gate runs, so
# a comment opened above the heading blanks the heading too and the section
# never opens: a commented-out instruction is not an instruction, wherever the
# comment starts.
bounded_rereview() {
  awk '
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
      $0 = out
    }
    /^### Bounded Re-Review/ { on = 1; next }
    /^## 5\./               { on = 0 }
    !on { next }
    { print }
  ' "$1"
}

# The refusal `workflow-state set … rereview_panel` prints once cycles is
# past the cap.
cap_refusal() { grep -F 'cycles is past the cap' "$1"; }

# Every grep below reads its input through a herestring, never a pipe: `grep -q`
# exits at the first match, a pipe would deliver SIGPIPE to the extractor, and
# `pipefail` would promote that 141 into a failed check for text that is
# present. The race grows with the section's length, so it is latent until an
# edit lengthens § 4.
# -e/-F -e so a pattern that begins with a dash is a pattern, not a flag.
sec_has()  { grep -q  -e "$2" <<<"$(bounded_rereview "$1")"; }
sec_hasF() { grep -qF -e "$2" <<<"$(bounded_rereview "$1")"; }

# The one command the cap rule runs per item. It is a single `update` filter,
# not a drop followed by an append: between two writes the item is in neither
# bucket, which is exactly the state § 8 reads as declined, so a session that
# dies in that window re-declines a live blocker.
CAP_WRITE_RE='workflow-state update \[ISSUE_ID\].*escalated_items'
CAP_WRITE_TXT='workflow-state update [ISSUE_ID]'
cap_write() { grep -E "$CAP_WRITE_RE" <<<"$(bounded_rereview "$1")"; }
write_has() { grep -q -e "$2" <<<"$(cap_write "$1")"; }

# The schema row for the cap path. POSIX classes only, never \s: BSD grep -E
# does not know it, and the assertion would go vacuous on macOS rather than
# loud.
SCHEMA_CAP_RE='\|[[:space:]]*`escalated_items`.*cycle cap'

# The pre-fix instruction: route and report, record nothing.
REPORT_ONLY='At the cap, report the outstanding items'

# --- a: the cap paragraph records outstanding items as escalated ------------
if [[ -n "$(cap_write "$REVIEW_PR_WF")" ]]; then
  pass "Bounded Re-Review records capped items in escalated_items before § 5"
else
  fail "Bounded Re-Review lost the escalated_items write for capped items"
fi

# --- b: the entry carries the typed outcome so audit maps it to escalated ---
if write_has "$REVIEW_PR_WF" 'outcome: "blocked"'; then
  pass "the capped-item entry writes outcome \"blocked\""
else
  fail "the capped-item entry lost outcome \"blocked\""
fi

# --- b2: the finding's own text is bound, never interpolated ----------------
# A location or description carrying an apostrophe or a quote breaks the
# filter when it is spliced in, and the item goes unrecorded — the failure this
# rule exists to prevent. --arg hands jq a literal string instead.
if write_has "$REVIEW_PR_WF" '--arg desc' && write_has "$REVIEW_PR_WF" 'description: \$desc'; then
  pass "the cap write binds the finding text with --arg and names \$desc"
else
  fail "the cap write interpolates the finding text instead of binding it"
fi

# --- c: the rule states the disposition, not just the mechanics -------------
# Without the stated contract, a future edit can keep an append somewhere while
# reverting to report-only routing at the cap.
if sec_has "$REVIEW_PR_WF" 'Capped items are escalated, never dropped'; then
  pass "Bounded Re-Review states the capped-items-are-escalated contract"
else
  fail "Bounded Re-Review lost the capped-items-are-escalated contract"
fi

# --- d: a re-found item an earlier round called fixed is still recorded -----
# The cap is reached when fixes are not converging, so the ordinary content of
# the final pass is a blocker whose recorded fix did not hold. Excluding it
# leaves § 8 printing a live blocker as ✅ FIXED against a stale SHA.
if sec_has "$REVIEW_PR_WF" 'whose fix did not hold'; then
  pass "the selection clause keeps an item whose recorded fix did not hold"
else
  fail "the selection clause lost the re-found fixed_items case"
fi

# --- e: § 4 declines stay declined -----------------------------------------
# A decline sits in neither bucket, exactly like an unrecorded capped item, so
# the clause must separate them by name or it sweeps declines into escalated.
if sec_hasF "$REVIEW_PR_WF" 'a decline is terminal'; then
  pass "the selection clause excludes § 4 declines"
else
  fail "the selection clause lost the decline exclusion"
fi

# --- f: the dedup key is named, not left to the reader ----------------------
if sec_hasF "$REVIEW_PR_WF" '(location, description)'; then
  pass "the selection clause names the (location, description) match key"
else
  fail "the selection clause lost the match key"
fi

# --- g: the pre-fix report-only instruction is gone -------------------------
if sec_hasF "$REVIEW_PR_WF" "$REPORT_ONLY"; then
  fail "Bounded Re-Review carries the pre-fix report-only instruction again"
else
  pass "Bounded Re-Review carries no report-only cap instruction"
fi

# --- h: one write does both, so no window exists ----------------------------
# Recording without dropping the superseded fixed_items entry puts one finding
# in both buckets: § 8 renders it under ✅ FIXED with the stale SHA AND under
# ⚠️ ESCALATED, and post-summary counts it twice. Dropping and recording as two
# commands is worse — between them the item is in neither bucket, which § 8
# reads as declined. The drop must therefore ride the same command.
if write_has "$REVIEW_PR_WF" '\.fixed_items'; then
  pass "the same command drops the superseded fixed_items entry"
else
  fail "the cap rule records the item without dropping its fixed_items entry in the same command"
fi

# --- i: the rule states the outcome that single write exists to produce -----
if sec_hasF "$REVIEW_PR_WF" 'never in both buckets and never in neither'; then
  pass "the cap rule states the never-both, never-neither contract"
else
  fail "the cap rule lost the never-both, never-neither contract"
fi

# --- j: the schema documents the cap path into escalated_items --------------
if grep -qE "$SCHEMA_CAP_RE" "$STATE_SCHEMA"; then
  pass "workflow-state schema covers the cycle-cap path into escalated_items"
else
  fail "workflow-state schema lost the cycle-cap path for escalated_items"
fi

# --- k: the cap refusal says record-then-route, matching § 4 ----------------
# The doc-side mirror. workflow-state-cycle-cap.sh asserts the same text on the
# refusal this branch actually prints, which is what proves it reachable.
if grep -q 'escalated_items' <<<"$(cap_refusal "$WS_SCRIPT")"; then
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
if ! plant_pr write "/$CAP_WRITE_RE/d"; then
  fail "write control planted nothing — its sed program matched no text"
elif [[ -n "$(cap_write "$CTRL")" ]]; then
  fail "lint MISSED a dropped capped-item escalated_items write"
else
  pass "lint flags a dropped capped-item escalated_items write"
fi

if ! plant_pr outcome 's/outcome: "blocked", //'; then
  fail "outcome control planted nothing — its sed program matched no text"
elif write_has "$CTRL" 'outcome: "blocked"'; then
  fail "lint MISSED a dropped outcome field on the capped-item entry"
else
  pass "lint flags a dropped outcome field on the capped-item entry"
fi

# The pre-fix shape of this command: the finding's text spliced into the filter.
if ! plant_pr interpolated 's/--arg loc '"'"'\[LOC\]'"'"' --arg desc '"'"'\[DESC\]'"'"' --arg src '"'"'\[SOURCE\]'"'"' //; s/\$loc/"[LOC]"/g; s/\$desc/"[DESC]"/g; s/\$src/"[SOURCE]"/g'; then
  fail "interpolation control planted nothing — its sed program matched no text"
elif write_has "$CTRL" '--arg desc' || write_has "$CTRL" 'description: \$desc'; then
  fail "lint MISSED a cap write that interpolates the finding text"
else
  pass "lint flags a cap write that interpolates the finding text"
fi

if ! plant_pr contract "s/\*\*Capped items are escalated, never dropped\.\*\* Record every blocker.*$/$REPORT_ONLY after that pass and proceed to § 5./"; then
  fail "contract control planted nothing — its sed program matched no text"
elif sec_has "$CTRL" 'Capped items are escalated, never dropped'; then
  fail "lint MISSED a reverted report-only cap rule"
else
  pass "lint flags a reverted report-only cap rule"
fi

if ! plant_pr refound 's/ whose fix did not hold//'; then
  fail "re-found control planted nothing — its sed program matched no text"
elif sec_has "$CTRL" 'whose fix did not hold'; then
  fail "lint MISSED a selection clause that drops the re-found fixed_items case"
else
  pass "lint flags a selection clause that drops the re-found fixed_items case"
fi

if ! plant_pr decline 's/; a decline is terminal//'; then
  fail "decline control planted nothing — its sed program matched no text"
elif sec_hasF "$CTRL" 'a decline is terminal'; then
  fail "lint MISSED a selection clause that drops the decline exclusion"
else
  pass "lint flags a selection clause that drops the decline exclusion"
fi

if ! plant_pr key 's/ Match on (location, description), the § 8 key\.//'; then
  fail "match-key control planted nothing — its sed program matched no text"
elif sec_hasF "$CTRL" '(location, description)'; then
  fail "lint MISSED a selection clause that drops the match key"
else
  pass "lint flags a selection clause that drops the match key"
fi

# The both-buckets regression: record the item, leave its fixed_items entry.
if ! plant_pr supersede "s/'\.fixed_items = .*))) | \.escalated_items/'.escalated_items/"; then
  fail "supersede control planted nothing — its sed program matched no text"
elif write_has "$CTRL" '\.fixed_items'; then
  fail "lint MISSED a cap rule that records without dropping the fixed_items entry"
else
  pass "lint flags a cap rule that records without dropping the fixed_items entry"
fi

# The neither-bucket regression: the drop and the record split into two
# commands, leaving a window in which the item is in no bucket at all.
TWOWRITE="$TMP_ROOT/pr-twowrite.md"
awk -v q="'" '
  {
    i = index($0, "))) | .escalated_items")
    if (i > 0 && !done) {
      print substr($0, 1, i + 2) q
      print ".agents/skills/orch/scripts/workflow-state append [ISSUE_ID] escalated_items " \
            q "{\"description\":\"[DESC]\",\"location\":\"[LOC]\",\"outcome\":\"blocked\",\"source\":\"[SOURCE]\"}" q
      done = 1
      next
    }
    print
  }
' "$REVIEW_PR_WF" > "$TWOWRITE"
if ! grep -qF 'workflow-state append [ISSUE_ID] escalated_items' "$TWOWRITE"; then
  fail "two-write control planted nothing — the command was not split"
elif write_has "$TWOWRITE" '\.fixed_items'; then
  fail "lint credits a drop and a record split across two commands"
else
  pass "lint flags a drop and a record split across two commands"
fi

if ! plant_pr neither 's/, so the item is never in both buckets and never in neither//'; then
  fail "never-both control planted nothing — its sed program matched no text"
elif sec_hasF "$CTRL" 'never in both buckets and never in neither'; then
  fail "lint MISSED a cap rule that drops the never-both, never-neither contract"
else
  pass "lint flags a cap rule that drops the never-both, never-neither contract"
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
  st == 1 && /^```$/ && seen_append { print $0 " -->"; print ""; print report_only; st = 2; next }
  st == 1 && /escalated_items/ { seen_append = 1 }
  { print }
' "$REVIEW_PR_WF" > "$INERT"
if ! grep -qF '<!-- **Capped items are escalated' "$INERT"; then
  fail "inert-rule control planted nothing — the cap rule was not commented out"
elif [[ -n "$(cap_write "$INERT")" ]]; then
  fail "lint credits an escalated_items write that sits inside an HTML comment"
elif sec_has "$INERT" 'Capped items are escalated, never dropped'; then
  fail "lint credits a contract sentence that sits inside an HTML comment"
elif ! sec_hasF "$INERT" "$REPORT_ONLY"; then
  fail "lint does not see the restored report-only instruction"
else
  pass "lint flags a cap rule commented out and replaced by report-only routing"
fi

# The same evasion from OUTSIDE the section: opening the comment on the line
# above the heading, closing it after the append. Stripping before the section
# gate is what catches this — gating first would leave `incomment` unset.
ABOVE="$TMP_ROOT/pr-above.md"
awk '
  /^### Bounded Re-Review/ && !opened { print "<!--"; opened = 1 }
  /^`\[SOURCE\]` is/ && opened && !closed { print "-->"; closed = 1 }
  { print }
' "$REVIEW_PR_WF" > "$ABOVE"
if ! grep -qF '<!--' "$ABOVE"; then
  fail "above-heading control planted nothing — no comment was opened"
elif [[ -n "$(cap_write "$ABOVE")" ]]; then
  fail "lint credits a write under a comment opened above the section heading"
elif sec_has "$ABOVE" 'Capped items are escalated, never dropped'; then
  fail "lint credits a contract sentence under a comment opened above the heading"
else
  pass "lint flags a cap rule commented out from above the section heading"
fi

# Scoping control: an escalated_items write elsewhere (dev-fix's § 6 pattern
# quoted in another section) must not satisfy check a. Built with awk, not a
# sed \n replacement: BSD sed emits a literal 'n' there, which would leave the
# plant welded to the § 5 heading and the control proving nothing.
CTRL="$TMP_ROOT/pr-scope.md"
awk -v cap="$CAP_WRITE_TXT" '
  /^### Bounded Re-Review/ { on = 1 }
  /^## 5\. Verdict Pass$/  { on = 0 }
  on && index($0, cap)     { next }
  { print }
  /^## 5\. Verdict Pass$/ && !planted {
    print ""
    print ".agents/skills/orch/scripts/workflow-state update [ISSUE_ID] escalated_items placeholder"
    planted = 1
  }
' "$REVIEW_PR_WF" > "$CTRL"
if ! grep -qx '.agents/skills/orch/scripts/workflow-state update \[ISSUE_ID\] escalated_items placeholder' "$CTRL"; then
  fail "scoping fixture planted no append outside Bounded Re-Review — control is vacuous"
elif [[ -n "$(cap_write "$CTRL")" ]]; then
  fail "lint credits an escalated_items write outside Bounded Re-Review"
else
  pass "lint scopes the append check to Bounded Re-Review"
fi

SCRATCH_SCHEMA="$TMP_ROOT/schema.md"
sed 's/, plus items still outstanding when review-pr'\''s cycle cap ends the fix loop//; s/; the cap path always writes this//' "$STATE_SCHEMA" > "$SCRATCH_SCHEMA"
if cmp -s "$SCRATCH_SCHEMA" "$STATE_SCHEMA"; then
  fail "schema control planted nothing — its sed program matched no text"
elif grep -qE "$SCHEMA_CAP_RE" "$SCRATCH_SCHEMA"; then
  fail "lint MISSED a schema that lost the cycle-cap path"
else
  pass "lint flags a schema that lost the cycle-cap path"
fi

SCRATCH_WS="$TMP_ROOT/workflow-state"
sed 's/in escalated_items (outcome/in the state (outcome/' "$WS_SCRIPT" > "$SCRATCH_WS"
if cmp -s "$SCRATCH_WS" "$WS_SCRIPT"; then
  fail "refusal control planted nothing — its sed program matched no text"
elif grep -q 'escalated_items' <<<"$(cap_refusal "$SCRATCH_WS")"; then
  fail "lint MISSED a cap refusal that routes without recording"
else
  pass "lint flags a cap refusal that routes without recording"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
