#!/usr/bin/env bash
# Regression lint for KEN-518. When review-pr § 4 hit the cycle cap, the
# verification pass's outstanding blockers routed to § 5 without ever landing
# in `fixed_items` or `escalated_items`. § 8's decline derivation ("in a
# json_paths artifact but in neither bucket → declined") then reported live
# blockers as declined with `reason: not recorded` and dropped them from the
# filing candidates — nothing filed them.
#
# What this pins are IDENTIFIERS and their relationships, never sentences:
# review-bots.md bans sentence-pinning lints on markdown, and an editorial
# rephrase must not fail a suite while the contract holds. The contract is
# carried by tokens that cannot be reworded without changing behaviour —
# `escalated_items`, `fixed_items`, `outcome`/`blocked`, `--slurpfile`,
# `qa-review`, the `At The Cap` heading — plus the relationships between them:
# one command carries the drop and the record, the cap section precedes Fix
# Delegation, and every token sits inside the section that owns it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
REVIEW_PR_WF="$SKILL_DIR/workflows/review-pr.md"
WS_SCRIPT="$SKILL_DIR/scripts/workflow-state"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== review-pr capped items escalated lint (KEN-518) ==="

# HTML comment regions are stripped from EVERY line before any section gate, so
# a comment opened above a heading blanks the heading too and the section never
# opens: a commented-out instruction is not an instruction, wherever the
# comment starts.
strip_comments() {
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
      print out
    }
  ' "$1"
}

# $1 = file, $2 = opening heading, $3 = ERE ending the slice.
slice() {
  strip_comments "$1" | awk -v head="$2" -v tail="$3" '
    $0 == head      { on = 1; next }
    on && $0 ~ tail { on = 0 }
    !on { next }
    { print }
  '
}

cap_section() { strip_comments "$1" | awk '/orch-env REVIEW_MAX_CYCLES/ { on = 1 } on && /^###? / { on = 0 } !on { next } { print }'; }
section_4()   { slice "$1" '## 4. Handle Review Items' '^## 5[.]'; }
section_7()   { slice "$1" '## 7. Handle QA Items' '^## 8[.]'; }

# The one command the cap rule runs per item. Every grep reads a herestring,
# never a pipe: `grep -q` exits at the first match, SIGPIPE would kill the
# extractor, and `pipefail` would promote its 141 into a false failure.
CAP_WRITE_RE='workflow-state update \[ISSUE_ID\].*escalated_items'
CAP_WRITE_TXT='workflow-state update [ISSUE_ID]'
cap_write() { grep -E "$CAP_WRITE_RE" <<<"$(cap_section "$1")"; }
write_has() { grep -q -e "$2" <<<"$(cap_write "$1")"; }
sec_has()   { grep -q -e "$2" <<<"$(cap_section "$1")"; }
s7_has()    { grep -q -e "$2" <<<"$(section_7 "$1")"; }

# Line number of the first line holding a fixed substring, or 0. index(), so
# bracketed placeholders need no escaping.
first_line() { awk -v s="$1" 'index($0, s) && !n { n = NR } END { print n + 0 }'; }

# The refusal line, selected by the setting it names rather than by its wording.
cap_refusal() { grep -F 'REVIEW_MAX_CYCLES=' "$1"; }

# --- 1: the cap decides before any fix round is delegated -------------------
# With Fix Delegation first, reaching the cap still runs one more fix round and
# the items escalated afterwards predate that round's diff.
S4="$(section_4 "$REVIEW_PR_WF")"
cap_at="$(first_line '### At The Cap' <<<"$S4")"
fix_at="$(first_line '### Fix Delegation' <<<"$S4")"
if [[ "$cap_at" -gt 0 ]] && [[ "$fix_at" -gt 0 ]] && [[ "$cap_at" -lt "$fix_at" ]]; then
  pass "§ 4 runs the cap check before Fix Delegation"
else
  fail "§ 4 delegates a fix round before the cap check (cap=$cap_at fix=$fix_at)"
fi

# --- 2: the section carries a state write naming escalated_items ------------
if [[ -n "$(cap_write "$REVIEW_PR_WF")" ]]; then
  pass "At The Cap writes escalated_items"
else
  fail "At The Cap lost its escalated_items write"
fi

# --- 3: the entry is typed so the audit builder maps it to escalated --------
if write_has "$REVIEW_PR_WF" 'outcome' && write_has "$REVIEW_PR_WF" 'blocked'; then
  pass "the entry carries outcome and blocked"
else
  fail "the entry lost outcome or blocked"
fi

# --- 4: one command drops the superseded entry and records the new one ------
# Two commands leave a window where the item is in neither bucket, which § 8
# reads as declined; no drop at all leaves it in both, printed as ✅ FIXED
# against a stale SHA and as ⚠️ ESCALATED at once. The drop is keyed on both
# fields, the same key § 8 dedupes on.
if write_has "$REVIEW_PR_WF" 'fixed_items' \
   && write_has "$REVIEW_PR_WF" '\.location' \
   && write_has "$REVIEW_PR_WF" '\.description'; then
  pass "the same command drops fixed_items, keyed on location and description"
else
  fail "the fixed_items drop is missing from the escalated_items command or unkeyed"
fi

# --- 5: the finding's text is bound from its artifact, never pasted ---------
# A location like fs.rs::write_all's guard ends a quoted shell word early, so
# the command breaks before any binding can help.
if write_has "$REVIEW_PR_WF" '--slurpfile' && write_has "$REVIEW_PR_WF" '--arg src'; then
  if grep -q -e "--arg [a-z]* '\[" <<<"$(cap_write "$REVIEW_PR_WF")"; then
    fail "the cap write pastes a placeholder into a quoted shell word"
  else
    pass "the cap write binds from the artifact file and pastes no finding text"
  fi
else
  fail "the cap write lost its --slurpfile or --arg src binding"
fi

# --- 6: both provenances are named where the rule is stated -----------------
if sec_has "$REVIEW_PR_WF" 'pr-review' && sec_has "$REVIEW_PR_WF" 'qa-review'; then
  pass "At The Cap names both the pr-review and qa-review sources"
else
  fail "At The Cap lost one of its source values"
fi

# --- 7: § 4 declines are excluded by name -----------------------------------
# A decline sits in neither bucket, exactly like an unrecorded capped item, so
# the rule must name them or it sweeps declines into escalated.
if sec_has "$REVIEW_PR_WF" 'declined'; then
  pass "At The Cap names declined items as excluded"
else
  fail "At The Cap lost the declined exclusion"
fi

# No check here for the schema's cycle-cap provenance. The `escalated_items`
# row says entries also arrive from review-pr's cycle cap in words alone; the
# row carries no token that is present only when that clause is, so the rule
# has no lint and is not asked for one.

# --- 9: the cap refusal carries both halves of the contract -----------------
# The doc-side mirror. workflow-state-cycle-cap.sh asserts the same tokens on
# the message the refusal actually prints, which is what proves it reachable.
REFUSAL="$(cap_refusal "$WS_SCRIPT")"
if grep -q 'escalated_items' <<<"$REFUSAL" && grep -q 'fixed_items' <<<"$REFUSAL"; then
  pass "the cap refusal names escalated_items and fixed_items"
else
  fail "the cap refusal lost one half of the recording contract"
fi

# --- 10: a re-found QA item reaches the cap disposition ---------------------
# § 7 used to drop anything already fixed, so a QA blocker whose fix did not
# hold never reached the cap rule and § 8 kept reporting it as fixed. Naming
# both buckets is what distinguishes the retaining rule from the blanket one.
if s7_has "$REVIEW_PR_WF" 'fixed_items' \
   && s7_has "$REVIEW_PR_WF" 'escalated_items' \
   && s7_has "$REVIEW_PR_WF" 'qa-review'; then
  pass "§ 7 states its exclusions against fixed_items and escalated_items by name"
else
  fail "§ 7 lost the named-bucket exclusion that retains a re-found QA item"
fi

# --- 11: § 7's own exit records a re-found item ------------------------------
# § 7 runs no cap check, so its convergence exit is the only place a QA
# blocker the fix did not hold gets recorded. A re-check surfacing no NEW
# blocker routes to § 8, and a blocker re-reported every round is not new:
# without the write it leaves the loop live with its stale `fixed_items`
# entry standing, and § 8 reports it as fixed.
s7_exit() { section_7 "$1" | awk '/^### Converged/ { on = 1; next } on && /^## / { on = 0 } on'; }
EXIT7="$(s7_exit "$REVIEW_PR_WF")"
if [[ -n "$EXIT7" ]] \
   && grep -q -F 'escalated_items' <<<"$EXIT7" \
   && grep -q -F 'fixed_items' <<<"$EXIT7" \
   && grep -q -F 'qa-review' <<<"$EXIT7"; then
  pass "§ 7's Converged exit records outstanding items before § 8"
else
  fail "§ 7's Converged exit lost its escalate-and-supersede write"
fi

# The exit's write, selected by the command token that only it carries. The
# convergence predicate and the disposition set are prose on their own lines
# with no such token, so nothing here reads them.
s7_write() { s7_exit "$1" | grep -F -- '--slurpfile art'; }

# No check here for what the convergence predicate says. Two rules live only
# in that sentence — it counts one re-check rather than two consecutive ones,
# and it covers blockers and `category == "fix"` suggestions while routing a
# `category == "issue"` suggestion to § 8. Its `category == "fix"` and
# `category == "issue"` literals sit in the disposition sentence below it too,
# so no token separates the two, and a pin on either could stand while the
# sentence around it said the opposite. Both rules are uncovered.

# --- 12: every path out of QA reaches the predicate --------------------------
# The defect this closes is not a count, it is a path deciding its own exit.
# § 6's all-pass branch returned to § 8 around whatever § 7 required, and § 7
# carried a **Skip if** doing the same. One predicate, no early returns.
section_6() { strip_comments "$1" | awk '$0 == "## 6. QA Checks" { on = 1; next } on && /^## 7[.]/ { on = 0 } on'; }
section_5() { strip_comments "$1" | awk '$0 == "## 5. Verdict Pass" { on = 1; next } on && /^## 6[.]/ { on = 0 } on'; }
# A route reads `→ § 8`; a bare mention is a cross-reference. § 5 names dev's
# own § 8 legitimately, so the arrow is what the check reads. Every bypass
# found so far lived in § 5 or § 6: skip_qa, empty signals, and all-pass.
BYPASS=0
for sect in 5 6; do
  body="$(section_$sect "$REVIEW_PR_WF")"
  if grep -q -F -- '→ § 8' <<<"$body"; then
    fail "§ $sect routes to § 8 around the predicate" "$(grep -F -- '→ § 8' <<<"$body")"
    BYPASS=1
  fi
done
[[ "$BYPASS" -eq 0 ]] && pass "§ 5 and § 6 reach the predicate instead of returning to § 8"
if grep -q -F '**Skip if**' <<<"$(section_7 "$REVIEW_PR_WF")"; then
  fail "§ 7 carries an early return around its own predicate"
else
  pass "§ 7 has no early return around its predicate"
fi

# --- 13: a verification pass is not a fix cycle ------------------------------
# The § 7 → § 2 pass verifies a fix that already landed. Written to the gated
# key it is refused once the internal budget is spent, and the round reaches
# § 5 with an unseen fix diff — which is what § 4's rule forbids in words.
S7ALL="$(section_7 "$REVIEW_PR_WF")"
if grep -q -F 'verification_panel' <<<"$S7ALL"; then
  pass "the § 2 verification pass takes an ungated key"
else
  fail "the § 2 verification pass is gated by the fix-cycle cap"
fi

# No check here for the exit's disposition set — that it covers every blocker
# and every `category == "fix"` suggestion whether or not `fixed_items` lists
# it, and escalates no `category == "issue"` suggestion. That is a prose
# sentence sharing its tokens with the predicate above it, so it is uncovered.

# --- 14: the recorded reason is § 7's own, never § 4's cap -------------------
# § 7 runs no cap, so the cap's reason string in its write is a false reason in
# the summary § 8 posts. Read the write itself: the prose around it explains
# the reason and would satisfy a slice-wide grep on its own.
WRITE7="$(s7_write "$REVIEW_PR_WF")"
if grep -q -F 'outstanding at the review cycle cap' <<<"$WRITE7"; then
  fail "§ 7's write records the cap's reason in a section that runs no cap"
elif grep -q -F 'QA loop converged with the item unresolved' <<<"$WRITE7"; then
  pass "§ 7's write records its own reason, not the cap's"
else
  fail "§ 7's write records no reason of its own"
fi

# --- planted controls: prove each check can fail ----------------------------
echo
echo "--- planted controls ---"

# $1 = control name, $2 = sed program. Sets CTRL and reports whether the
# program changed anything: one matching nothing leaves the source untouched
# and the control proves nothing. Runs in the parent shell, never a command
# substitution, so its verdict reaches the counters.
plant_pr() {
  CTRL="$TMP_ROOT/pr-$1.md"
  sed "$2" "$REVIEW_PR_WF" > "$CTRL"
  ! cmp -s "$CTRL" "$REVIEW_PR_WF"
}

if ! plant_pr write "/$CAP_WRITE_RE/d"; then
  fail "write control planted nothing — its sed program matched no text"
elif [[ -n "$(cap_write "$CTRL")" ]]; then
  fail "lint MISSED a dropped escalated_items write"
else
  pass "lint flags a dropped escalated_items write"
fi

if ! plant_pr outcome 's/outcome: "blocked", //'; then
  fail "outcome control planted nothing — its sed program matched no text"
elif write_has "$CTRL" 'outcome'; then
  fail "lint MISSED a dropped outcome field"
else
  pass "lint flags a dropped outcome field"
fi

# Records the item, leaves its stale fixed_items entry: the both-buckets shape.
if ! plant_pr supersede 's/\$art\[0\]\.\[ARRAY\].*\.escalated_items = /$art[0].[ARRAY][[INDEX]] as $item | .escalated_items = /'; then
  fail "supersede control planted nothing — its sed program matched no text"
elif write_has "$CTRL" 'fixed_items'; then
  fail "lint MISSED a write that records without dropping the fixed_items entry"
else
  pass "lint flags a write that records without dropping the fixed_items entry"
fi

# The drop and the record split into two commands: the neither-bucket shape.
TWOWRITE="$TMP_ROOT/pr-twowrite.md"
awk -v q="'" '
  {
    i = index($0, ")))) | .escalated_items")
    if (i == 0) i = index($0, "))) | .escalated_items")
    if (i > 0 && !done) {
      print substr($0, 1, i + 2) q
      print ".agents/skills/orch/scripts/workflow-state update [ISSUE_ID] --slurpfile art [ARTIFACT_PATH] --arg src [SOURCE] " \
            q "$art[0].[ARRAY][[INDEX]] as $item | .escalated_items = ((.escalated_items // []) + [{description: $item.description, outcome: \"blocked\", source: $src}])" q
      done = 1
      next
    }
    print
  }
' "$REVIEW_PR_WF" > "$TWOWRITE"
if [[ "$(grep -cF -- '--slurpfile art' "$TWOWRITE")" -lt 2 ]]; then
  fail "two-write control planted nothing — the command was not split"
elif write_has "$TWOWRITE" 'fixed_items'; then
  fail "lint credits a drop and a record split across two commands"
else
  pass "lint flags a drop and a record split across two commands"
fi

# The pasted-text shape this PR exists to remove.
if ! plant_pr pasted "s/--slurpfile art '\[ARTIFACT_PATH\]'/--arg loc '[LOC]' --arg desc '[DESC]'/"; then
  fail "pasted-text control planted nothing — its sed program matched no text"
elif grep -q -e "--arg [a-z]* '\[" <<<"$(cap_write "$CTRL")"; then
  pass "lint flags a placeholder pasted into a quoted shell word"
else
  fail "lint MISSED a placeholder pasted into a quoted shell word"
fi

if ! plant_pr source 's/`qa-review` for a QA-sourced item/the § 7 value for such an item/'; then
  fail "source control planted nothing — its sed program matched no text"
elif sec_has "$CTRL" 'qa-review'; then
  fail "lint MISSED a cap rule that stops naming qa-review"
else
  pass "lint flags a cap rule that stops naming qa-review"
fi

if ! plant_pr declined 's/declined/set aside/g'; then
  fail "declined control planted nothing — its sed program matched no text"
elif sec_has "$CTRL" 'declined'; then
  fail "lint MISSED a cap rule that drops the declined exclusion"
else
  pass "lint flags a cap rule that drops the declined exclusion"
fi

# Inert-text control: the rule preserved verbatim but commented out, anchored
# on the headings rather than on any sentence.
INERT="$TMP_ROOT/pr-inert.md"
awk '
  /^### At The Cap/      { print; print "<!--"; next }
  /^### Fix Delegation/ && !closed { print "-->"; closed = 1 }
  { print }
' "$REVIEW_PR_WF" > "$INERT"
if ! grep -qF '<!--' "$INERT" || ! grep -qF -- '-->' "$INERT"; then
  fail "inert-rule control planted nothing — no comment region was opened"
elif [[ -n "$(cap_write "$INERT")" ]]; then
  fail "lint credits a write that sits inside an HTML comment"
else
  pass "lint flags a cap rule commented out inside its own section"
fi

# The same evasion from OUTSIDE the section: the comment opens above the
# heading. Stripping before the section gate is what catches this.
ABOVE="$TMP_ROOT/pr-above.md"
awk '
  /^### At The Cap/ && !opened { print "<!--"; opened = 1 }
  /^### Fix Delegation/ && opened && !closed { print "-->"; closed = 1 }
  { print }
' "$REVIEW_PR_WF" > "$ABOVE"
if ! grep -qF '<!--' "$ABOVE"; then
  fail "above-heading control planted nothing — no comment was opened"
elif [[ -n "$(cap_write "$ABOVE")" ]]; then
  fail "lint credits a write under a comment opened above the section heading"
else
  pass "lint flags a cap rule commented out from above the section heading"
fi

# Ordering control: the whole At The Cap block moved back behind delegation.
REORDERED="$TMP_ROOT/pr-reordered.md"
awk '
  /^### At The Cap/ { cap = 1; buf = $0 ORS; next }
  cap && /^###? /   { cap = 0 }
  cap               { buf = buf $0 ORS; next }
  /^### Bounded Re-Review/ && buf != "" { printf "%s", buf; buf = "" }
  { print }
' "$REVIEW_PR_WF" > "$REORDERED"
R4="$(section_4 "$REORDERED")"
r_cap="$(first_line '### At The Cap' <<<"$R4")"
r_fix="$(first_line '### Fix Delegation' <<<"$R4")"
if [[ "$r_cap" -eq 0 ]] || [[ "$r_fix" -eq 0 ]]; then
  fail "ordering control planted nothing — a heading went missing (cap=$r_cap fix=$r_fix)"
elif [[ "$r_cap" -lt "$r_fix" ]]; then
  fail "ordering control planted nothing — the sections did not swap"
elif [[ -z "$(cap_write "$REORDERED")" ]]; then
  fail "ordering control lost the cap write instead of moving it"
else
  pass "lint flags § 4 delegating a fix round ahead of the cap check"
fi

# Scoping control: a write elsewhere must not satisfy check 2. Built with awk,
# not a sed \n replacement: BSD sed emits a literal 'n' there, which would weld
# the plant to the heading and prove nothing.
CTRL="$TMP_ROOT/pr-scope.md"
awk -v cap="$CAP_WRITE_TXT" '
  /^### At The Cap/       { on = 1 }
  /^### Fix Delegation/   { on = 0 }
  on && index($0, cap)    { next }
  { print }
  /^## 5\. Verdict Pass$/ && !planted {
    print ""
    print ".agents/skills/orch/scripts/workflow-state update [ISSUE_ID] escalated_items placeholder"
    planted = 1
  }
' "$REVIEW_PR_WF" > "$CTRL"
if ! grep -qx '.agents/skills/orch/scripts/workflow-state update \[ISSUE_ID\] escalated_items placeholder' "$CTRL"; then
  fail "scoping fixture planted no write outside At The Cap — control is vacuous"
elif [[ -n "$(cap_write "$CTRL")" ]]; then
  fail "lint credits an escalated_items write outside At The Cap"
else
  pass "lint scopes the write check to At The Cap"
fi

# § 7's retaining rule reverted to the blanket exclusion.
QA_REVERT='s/, and excluding a .fixed_items. entry only when this round.s QA artifact does not report it again//; s/A re-found item is retained on purpose[^.]*[.] //; s/, whether or not .fixed_items. already lists it//; s/which drops any superseded .fixed_items. entry and records/which records/; /--slurpfile art/d'
if ! plant_pr qa "$QA_REVERT"; then
  fail "qa control planted nothing — its sed program matched no text"
elif s7_has "$CTRL" 'fixed_items'; then
  fail "lint MISSED § 7 reverting to the blanket fixed-or-escalated exclusion"
else
  pass "lint flags § 7 reverting to the blanket fixed-or-escalated exclusion"
fi

# § 7's exit reverted to routing straight to § 8, which is the shape that let
# a re-reported blocker leave the loop reported as fixed.
if ! plant_pr s7exit '/^### Converged/,/^## 8[.]/d'; then
  fail "§ 7 exit control planted nothing — its sed program matched no text"
elif [[ -n "$(s7_exit "$CTRL")" ]]; then
  fail "lint MISSED a § 7 exit that records nothing before § 8"
else
  pass "lint flags a § 7 exit that records nothing before § 8"
fi

# § 6 deciding its own exit again.
if ! plant_pr s6exit 's/→ § 7 — every verdict, every time/→ § 8 when every verdict is pass, else § 7/'; then
  fail "§ 6 early-return control planted nothing — its sed program matched no text"
elif grep -q -F -- '→ § 8' <<<"$(section_6 "$CTRL")"; then
  pass "lint flags § 6 returning to § 8 around the predicate"
else
  fail "lint MISSED § 6 returning to § 8 around the predicate"
fi

# § 5's skip_qa branch going straight to § 8, the bypass the § 6-only check
# could not see.
if ! plant_pr s5skip 's/`\"rationale\":\"user skip\"`, → § 7/`\"rationale\":\"user skip\"`, → § 8/'; then
  fail "§ 5 skip control planted nothing — its sed program matched no text"
elif grep -q -F -- '→ § 8' <<<"$(section_5 "$CTRL")"; then
  pass "lint flags § 5's skip_qa branch returning to § 8"
else
  fail "lint MISSED § 5's skip_qa branch returning to § 8"
fi

# § 5's empty-signals branch doing the same.
if ! plant_pr s5empty 's/Signals empty → § 7/Signals empty → § 8/'; then
  fail "§ 5 signals control planted nothing — its sed program matched no text"
elif grep -q -F -- '→ § 8' <<<"$(section_5 "$CTRL")"; then
  pass "lint flags § 5's empty-signals branch returning to § 8"
else
  fail "lint MISSED § 5's empty-signals branch returning to § 8"
fi

# § 7 growing its own early return back.
CTRL="$TMP_ROOT/pr-skipif.md"
awk '
  /^## 7\. Handle QA Items/ && !planted {
    print; print ""
    print "**Skip if** every QA verdict is `pass` and no fix suggestions remain → § 8."
    planted = 1; next
  }
  { print }
' "$REVIEW_PR_WF" > "$CTRL"
if cmp -s "$CTRL" "$REVIEW_PR_WF"; then
  fail "§ 7 skip-if control planted nothing — no early return was inserted"
elif grep -q -F '**Skip if**' <<<"$(section_7 "$CTRL")"; then
  pass "lint flags § 7 growing an early return back"
else
  fail "lint MISSED § 7 growing an early return back"
fi

# The verification pass routed back onto the gated key.
if ! plant_pr s7verif 's/verification_panel/rereview_panel/'; then
  fail "§ 7 verification control planted nothing — its sed program matched no text"
elif grep -q -F 'verification_panel' <<<"$(section_7 "$CTRL")"; then
  fail "lint MISSED a verification pass gated by the fix-cycle cap"
else
  pass "lint flags a verification pass gated by the fix-cycle cap"
fi

# The borrowed reason: § 4's cap string recorded by a section that runs no cap.
if ! plant_pr s7reason 's/QA loop converged with the item unresolved/outstanding at the review cycle cap/'; then
  fail "§ 7 reason control planted nothing — its sed program matched no text"
elif grep -q -F 'QA loop converged with the item unresolved' <<<"$(s7_write "$CTRL")"; then
  fail "lint MISSED a § 7 write recording the cap's reason"
else
  pass "lint flags a § 7 write recording the cap's reason"
fi

# Anchored on the token the check reads, not on the wording around it: the
# refusal message is free to be reworded without stopping the control planting.
SCRATCH_WS="$TMP_ROOT/workflow-state"
awk 'index($0, "REVIEW_MAX_CYCLES=") { gsub(/fixed_items/, "∅") } { print }' \
  "$WS_SCRIPT" > "$SCRATCH_WS"
if cmp -s "$SCRATCH_WS" "$WS_SCRIPT"; then
  fail "refusal control planted nothing — its sed program matched no text"
elif grep -q 'fixed_items' <<<"$(cap_refusal "$SCRATCH_WS")"; then
  fail "lint MISSED a cap refusal that names only the escalated half"
else
  pass "lint flags a cap refusal that names only the escalated half"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
