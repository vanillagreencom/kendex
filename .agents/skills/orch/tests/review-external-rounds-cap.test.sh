#!/usr/bin/env bash
# KEN-592: the external review-round cap.
#
# `pr_comment_review.iterations` counts the triage passes orch runs against an
# open PR's bot review. Its bound was a literal 5 written into two workflows;
# it is now `REVIEW_MAX_EXTERNAL_ROUNDS` (default 4), read in § 6.1 before
# anything is delegated and resolved through
# `orch-env` beside `REVIEW_MAX_CYCLES`. Past the cap a finding gets a
# disposition and no fix push — except a defect the diff itself introduces,
# which is fixed whatever the round count, because a cap that forces a
# disposition onto a defect the change created ships the defect.
#
# The markdown assertions pin IDENTIFIERS and their placement — the setting
# name, the three reply forms, the absence of a literal bound — never
# sentences: an editorial rephrase must not fail this suite while the contract
# holds. Every check carries a planted control proving it can go red.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

ORCH_ENV="$SKILL_DIR/scripts/orch-env"
COMMENTS_WF="$SKILL_DIR/workflows/review-pr-comments.md"
SUBMIT_WF="$SKILL_DIR/workflows/submit-pr.md"
DISPOSITION="$SKILL_DIR/references/finding-disposition.md"
SETTINGS_EXAMPLE="$SKILL_DIR/kendex.settings.toml.example"
ORCH_README="$SKILL_DIR/README.md"

SETTING=REVIEW_MAX_EXTERNAL_ROUNDS

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3" "expected: $2  got: $1"; }

echo "=== external review-round cap ($SETTING) ==="

# --- resolution -------------------------------------------------------------
# Isolated project roots: orch-env resolves the project from the cwd's git
# toplevel, so each scenario gets its own repo with no settings noise.
proj_bare="$TMP_ROOT/proj-bare"
git init -q "$proj_bare"

proj_set="$TMP_ROOT/proj-set"
git init -q "$proj_set"
cat > "$proj_set/kendex.settings.toml" <<'TOML'
[env]
REVIEW_MAX_EXTERNAL_ROUNDS = "2"
TOML

proj_bad="$TMP_ROOT/proj-bad"
git init -q "$proj_bad"
cat > "$proj_bad/kendex.settings.toml" <<'TOML'
[env]
REVIEW_MAX_EXTERNAL_ROUNDS = "several"
TOML

got="$(cd "$proj_bare" && env -u "$SETTING" "$ORCH_ENV" "$SETTING" 4)"
eq "$got" "4" "unset anywhere resolves to the documented default of 4"

got="$(cd "$proj_set" && env -u "$SETTING" "$ORCH_ENV" "$SETTING" 4)"
eq "$got" "2" "kendex.settings.toml [env] overrides the default"

got="$(cd "$proj_set" && REVIEW_MAX_EXTERNAL_ROUNDS=6 "$ORCH_ENV" "$SETTING" 4)"
eq "$got" "6" "process env outranks the settings file"

# A non-numeric value would make the workflow compare iterations against a
# word; the numeric-default rule falls back instead.
got="$(cd "$proj_bad" && env -u "$SETTING" "$ORCH_ENV" "$SETTING" 4)"
eq "$got" "4" "a non-numeric setting falls back to the numeric default"

# It resolves independently of the internal cap — two knobs, not one.
got="$(cd "$proj_set" && env -u "$SETTING" -u REVIEW_MAX_CYCLES "$ORCH_ENV" REVIEW_MAX_CYCLES 4)"
eq "$got" "4" "setting the external cap does not move REVIEW_MAX_CYCLES"

# --- wiring -----------------------------------------------------------------
# HTML comment regions are stripped before any section gate: a commented-out
# instruction is not an instruction, wherever the comment opens.
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

cap_site() { slice "$1" '### 6.1 Delegate Fixes' '^### 6[.]2'; }
# submit-pr's single restart decision point. Every path that would restart
# § 4 step 1's wait passes through it, so the cap is applied once, in a place
# no route can go around.
restart_check() { awk '/^   \*\*Restart check\.\*\*/ { on = 1; print; next } on && (/^   \*\*/ || /^#/) { on = 0 } on' "$1"; }
loop_site() { slice "$1" '### 6.3 Re-Triage Or Exit' '^## 7[.]'; }
# The cap rule itself: § 6.1 from its budget read down to the delegation setup.
# The rule names every disposition form, so a bound narrower than the section
# is what keeps another mention of `Fixed in` out of the check.
cap_rule() { cap_site "$1" | awk '/REVIEW_MAX_EXTERNAL_ROUNDS/ { on = 1 } /^Ensure the worktree exists/ { on = 0 } on'; }

# The prose bounds in submit-pr: every iteration-cap mention that is not the
# fenced `workflow-state increment` command — § 3.1's triage pass and § 6.1's
# gate-3 pass both bound the same counter.
submit_bound() { strip_comments "$1" | grep -Ei 'iteration' | grep -v -F 'workflow-state'; }

# A literal bound on the counter — `iterations >= 5`, `max 5`, `(max 5;` — is
# the shape this issue removes. Every grep reads a herestring, never a pipe:
# `grep -q` exits at the first match and SIGPIPE under `pipefail` would
# promote a 141 into a false failure.
# Line number of the first line holding a fixed substring, or 0. index(), so
# bracketed placeholders need no escaping.
first_line() { awk -v s="$1" 'index($0, s) && !n { n = NR } END { print n + 0 }'; }
# Character offset of the first occurrence in the WHOLE blob, or 0. A markdown
# paragraph is one line, so a line-number comparison cannot order two phrases
# inside it — this reads the slice as a single record.
first_at() { awk -v s="$1" 'BEGIN { RS = "\0" } { print index($0, s) }'; }

LITERAL_BOUND_RE='(iterations?[^A-Za-z0-9_]*(>=|<=|==|>|<)[[:space:]]*[0-9]|max[-[:space:]]+[0-9])'

site="$(cap_site "$COMMENTS_WF")"
if grep -q -F "$SETTING" <<<"$site"; then
  ok "review-pr-comments § 6.1 names $SETTING"
else
  bad "review-pr-comments § 6.1 does not name $SETTING"
fi
if grep -q -F 'orch-env' <<<"$site"; then
  ok "§ 6.1 resolves the cap through orch-env"
else
  bad "§ 6.1 does not resolve the cap through orch-env"
fi
if grep -qE "$LITERAL_BOUND_RE" <<<"$site"; then
  bad "§ 6.1 still carries a literal bound on iterations" "$(grep -nE "$LITERAL_BOUND_RE" <<<"$site")"
else
  ok "§ 6.1 carries no literal bound on iterations"
fi

# The cap governs what may be PUSHED, so it has to decide before the round is
# delegated. Read after the delegation, re-entering at the cap pushes one more
# fix round and the findings that arrive after it get no disposition at all.
cap_at="$(first_line "$SETTING" <<<"$site")"
del_at="$(first_line '<delegation_format>' <<<"$site")"
if [[ "$cap_at" -gt 0 ]] && [[ "$del_at" -gt 0 ]] && [[ "$cap_at" -lt "$del_at" ]]; then
  ok "§ 6.1 reads the cap before it delegates (cap=$cap_at delegation=$del_at)"
else
  bad "§ 6.1 delegates before reading the cap" "cap=$cap_at delegation=$del_at"
fi

# The exception is what keeps the cap from shipping a defect the diff created.
# Its tokens are the three reply forms: drop the exception and `Fixed in`
# leaves the section, so the cap reads as disposition-only.
EXCEPTION='introduces or arms'
rule="$(cap_rule "$COMMENTS_WF")"
# A Tracked: reply naming an issue that does not exist yet turns the merge
# gate red. The cap rule files through § 6.2 before it replies, so the id is
# real by the time a reply names it.
file_at="$(first_at '§ 6.2' <<<"$rule")"
track_at="$(first_at 'Tracked:' <<<"$rule")"
if [[ "$file_at" -gt 0 ]] && [[ "$track_at" -gt 0 ]] && [[ "$file_at" -lt "$track_at" ]]; then
  ok "the cap rule files through § 6.2 before it replies Tracked (file=$file_at reply=$track_at)"
else
  bad "the cap rule replies Tracked before the issue is filed" "file=$file_at reply=$track_at"
fi

# § 6.2's audit returns where it is told, and its usual target is § 6.3. On
# the cap path that skips the exception's delegation entirely: the pass files
# the issue, lands in § 6.3, increments and exits, and the introduced defect
# the exception requires it to fix is never delegated.
if grep -q -F -- '→ § 6.1' <<<"$rule"; then
  ok "the cap path records the audit's return to § 6.1"
else
  bad "the cap path lets § 6.2 return to § 6.3 and skip the exception"
fi

# File, then delegate the exception, then reply. A Tracked reply needs its
# issue to exist and a Fixed in reply needs the fix to have landed, so the
# replies come last.
file_step="$(first_at 'File first' <<<"$rule")"
exc_step="$(first_at 'Then the exception' <<<"$rule")"
reply_step="$(first_at 'Then reply' <<<"$rule")"
if [[ "$file_step" -gt 0 ]] && [[ "$exc_step" -gt "$file_step" ]] && [[ "$reply_step" -gt "$exc_step" ]]; then
  ok "the at-cap pass files, then delegates the exception, then replies"
else
  bad "the at-cap steps are out of order" "file=$file_step exception=$exc_step reply=$reply_step"
fi

# The cap is a rule about which items may still be fixed, stated once where
# `items` is defined for the rest of the section. Restating it downstream is
# the shape that let an ordinary Fixing item ride along on an exempt round:
# three carriers to keep in step, and the template the last to know.
if grep -q -F '**fix set**' <<<"$rule"; then
  ok "the fix set is defined once, inside the cap rule that narrows it"
else
  bad "the cap rule does not define the set the rest of the section carries"
fi
# Every carrier refers to that set. A carrier that re-derives it — by
# repeating the Fixing predicate or by asking whether this is the cap — is a
# copy of the rule to keep in step, and the template was always the last to
# know. Three carriers today; a fourth inherits the rule for free.
downstream() { cap_site "$1" | awk '/^Ensure the worktree exists/ { on = 1 } on'; }
DOWN="$(downstream "$COMMENTS_WF")"
if grep -q -i -F 'at the cap' <<<"$DOWN" || grep -q -F 'marked "Fixing"' <<<"$DOWN"; then
  bad "a carrier re-derives the fix set instead of referring to it" "$(grep -n -iE 'at the cap|marked "Fixing"' <<<"$DOWN")"
else
  ok "no carrier re-derives the fix set"
fi
carriers="$(grep -c -F 'fix set' <<<"$DOWN")"
if [[ "$carriers" -ge 3 ]]; then
  ok "the grouping, the round record and the template each name the fix set ($carriers)"
else
  bad "only $carriers carrier(s) refer to the fix set by name"
fi

# One exception, one definition. finding-disposition is what a reviewer reads
# first; a broader claim there selects findings review-pr-comments will not
# push a fix for.
if grep -q -F "$EXCEPTION" <<<"$rule" && grep -q -F "$EXCEPTION" "$DISPOSITION"; then
  ok "both sites name the exception by the same test"
else
  bad "the cap rule and finding-disposition name different exception sets"
fi
if grep -q -F "Step 1's \`fix\` verdict outranks the cap" "$DISPOSITION"; then
  bad "finding-disposition still grants every Step 1 fix verdict the exception"
else
  ok "finding-disposition scopes the exception to the introduced-or-armed branch"
fi

if grep -q -F 'Fixed in' <<<"$rule" \
   && grep -q -F 'Declined:' <<<"$rule" \
   && grep -q -F 'Tracked:' <<<"$rule"; then
  ok "the cap rule states all three post-cap dispositions, Fixed in included"
else
  bad "the cap rule lost a post-cap disposition form" "$rule"
fi

# § 6.3 counts the round and decides the loop. Re-applying the cap there is
# what let the at-cap path exit before the late-thread fetch below it.
loop="$(loop_site "$COMMENTS_WF")"
if grep -q -F "$SETTING" <<<"$loop"; then
  bad "§ 6.3 re-applies the cap instead of leaving it to § 6.1"
else
  ok "§ 6.3 leaves the cap to § 6.1"
fi

# Not every caller has a Restart check: this workflow runs standalone, and
# submit-pr § 3 and merge-pr § 5 call it from return sites without one. A late
# thread routed to a caller that has none is never analyzed, replied to or
# resolved, which wedges the gate. The cap governs actions, not routing.
if grep -q -F 'cap decision' <<<"$loop" || grep -q -F 'return to the caller' <<<"$loop"; then
  bad "§ 6.3 routes a late thread to a caller instead of dispositioning it"
else
  ok "§ 6.3 loops on at the cap, so a late thread is never dropped"
fi
# No check that § 6.1 states the cap as which actions are allowed rather than
# where to jump — that the disposition is unconditional at the cap and only
# the fix stops. It is a sentence with no token the reply-form check above
# does not already read, so the rule is uncovered.
if grep -q -F 'pr-threads' <<<"$loop"; then
  ok "§ 6.3 fetches late threads on every path out of the round"
else
  bad "§ 6.3 lost the late-thread fetch"
fi

# One counter, one writer. Two callers incrementing it spends two units per
# round and the documented budget is half what it says.
writers="$(grep -rc -F 'increment [ISSUE_ID] pr_comment_review.iterations' "$SKILL_DIR"/workflows/*.md | grep -v ':0$' || true)"
count="$(grep -r -F -l 'increment [ISSUE_ID] pr_comment_review.iterations' "$SKILL_DIR"/workflows/*.md | wc -l | tr -d ' ')"
total="$(grep -r -F -c 'increment [ISSUE_ID] pr_comment_review.iterations' "$SKILL_DIR"/workflows/*.md | awk -F: '{ n += $2 } END { print n + 0 }')"
if [[ "$total" -eq 1 ]] && [[ "$count" -eq 1 ]] && [[ "$writers" == *review-pr-comments.md* ]]; then
  ok "pr_comment_review.iterations has exactly one writer, in review-pr-comments"
else
  bad "pr_comment_review.iterations has $total writer(s) across $count file(s)" "$writers"
fi

CHECK="$(restart_check "$SUBMIT_WF")"
if [[ -z "$CHECK" ]]; then
  bad "submit-pr has no Restart check — the cap has no single decision point"
elif grep -q -F "$SETTING" <<<"$CHECK" \
     && grep -q -F 'changes_requested' <<<"$CHECK" \
     && grep -q -F 'Triage again' <<<"$CHECK" \
     && grep -q -F 'Force merge' <<<"$CHECK" \
     && grep -q -F 'Stop here' <<<"$CHECK"; then
  ok "the Restart check reads the cap and presents the prompt at it"
else
  bad "the Restart check lost the cap or one of its three options" "$CHECK"
fi

# A standing changes-requested verdict outlives a disposition, so a restart
# arm that bypasses the check returns the same verdict and triages past the
# cap. The phrase belongs to the check alone.
total_restarts="$(grep -c -F 'restart step 1' "$SUBMIT_WF" || true)"
inside_restarts="$(grep -c -F 'restart step 1' <<<"$CHECK" || true)"
if [[ "$inside_restarts" -ge 1 ]] && [[ "$total_restarts" -eq "$inside_restarts" ]]; then
  ok "every restart of the wait is the Restart check's own ($total_restarts total)"
else
  bad "a path restarts the wait outside the Restart check" "total=$total_restarts inside=$inside_restarts"
fi

# The cap denies a fix; the filing bar still files what clears it. If submit-pr
# then implements every issue triage created, the denied fix lands anyway one
# step later, through the issue path. The re-submit set is defined to exclude
# those filings, so § 3 has nothing to filter.
resubmit="$(grep -F 'The **re-submit set**' "$SUBMIT_WF")"
if [[ -z "$resubmit" ]]; then
  bad "submit-pr does not name the re-submit set"
elif grep -q -F "$SETTING" <<<"$resubmit" \
     && grep -q -F 'pr_comment_review.issues_created' <<<"$resubmit"; then
  ok "the re-submit set is defined against the cap and the counter it records into"
else
  bad "the re-submit set names neither the cap nor issues_created" "$resubmit"
fi
if grep -q -F 'Issues created during triage need implementing' "$SUBMIT_WF"; then
  bad "submit-pr still implements every issue created during triage"
else
  ok "no step re-derives the re-submit set from what triage filed"
fi

bound="$(submit_bound "$SUBMIT_WF")"
if [[ -z "$bound" ]]; then
  bad "submit-pr no longer states a bound on pr_comment_review.iterations"
elif grep -q -F "$SETTING" <<<"$bound"; then
  ok "submit-pr bounds the triage pass on $SETTING"
else
  bad "submit-pr bounds the triage pass on something other than $SETTING" "$bound"
fi
if grep -qE "$LITERAL_BOUND_RE" <<<"$bound"; then
  bad "submit-pr still carries a literal bound on iterations" "$bound"
else
  ok "submit-pr carries no literal bound on iterations"
fi

# Two workflows applying one counter must apply one number, or the earlier
# site silently wins.
if [[ "$(grep -c -F "$SETTING" <<<"$site")" -ge 1 ]] && grep -q -F "$SETTING" <<<"$bound"; then
  ok "both cap sites read the same setting"
else
  bad "the two cap sites disagree on which setting bounds the counter"
fi

# --- documentation ----------------------------------------------------------
if grep -q -F "$SETTING" "$DISPOSITION" && grep -q -F 'pr_comment_review.iterations' "$DISPOSITION"; then
  ok "finding-disposition names the cap and the counter it reads"
else
  bad "finding-disposition lost the external cap or its counter"
fi
if grep -q -F "$SETTING" "$ORCH_README"; then
  ok "the README configuration table documents $SETTING"
else
  bad "the README configuration table lost $SETTING"
fi
if grep -q -F "$SETTING" "$SETTINGS_EXAMPLE"; then
  ok "kendex.settings.toml.example seeds $SETTING"
else
  bad "kendex.settings.toml.example does not seed $SETTING"
fi

# --- planted controls: prove each markdown check can fail --------------------
echo
echo "--- planted controls ---"

# $1 = destination, $2 = source, $3 = sed program. Reports whether the program
# changed anything: one matching nothing proves nothing.
plant() {
  sed "$3" "$2" > "$1"
  ! cmp -s "$1" "$2"
}

CTRL="$TMP_ROOT/comments-literal.md"
if ! plant "$CTRL" "$COMMENTS_WF" "s/at or past \`$SETTING\`/>= 5/"; then
  bad "literal-bound control planted nothing — its sed program matched no text"
elif grep -qE "$LITERAL_BOUND_RE" <<<"$(cap_site "$CTRL")"; then
  ok "the check flags § 6.1 comparing iterations against a literal"
else
  bad "the check MISSED § 6.1 comparing iterations against a literal"
fi

CTRL="$TMP_ROOT/comments-exception.md"
if ! plant "$CTRL" "$COMMENTS_WF" 's/ — a defect this diff itself introduces or arms//'; then
  bad "exception control planted nothing — its sed program matched no text"
elif grep -q -F "$EXCEPTION" <<<"$(cap_rule "$CTRL")"; then
  bad "the check MISSED a cap rule that dropped the introduced-defect exception"
else
  ok "the check flags a cap rule that dropped the introduced-defect exception"
fi

# The evasion of leaving the rule in place but commenting it out, anchored on
# the heading rather than on any sentence.
CTRL="$TMP_ROOT/comments-inert.md"
awk '
  /^### 6\.1 Delegate Fixes/ && !opened { print "<!--"; opened = 1 }
  /^### 6\.2 Create Issues/ && opened && !closed { print "-->"; closed = 1 }
  { print }
' "$COMMENTS_WF" > "$CTRL"
if ! grep -qF '<!--' "$CTRL"; then
  bad "inert control planted nothing — no comment region was opened"
elif grep -q -F "$SETTING" <<<"$(cap_site "$CTRL")"; then
  bad "the check credits a cap rule that sits inside an HTML comment"
else
  ok "the check flags a cap rule commented out from above its heading"
fi

CTRL="$TMP_ROOT/submit-literal.md"
if ! plant "$CTRL" "$SUBMIT_WF" "s/below \`$SETTING\` → restart step 1/< 5 → restart step 1/"; then
  bad "submit control planted nothing — its sed program matched no text"
elif grep -qE "$LITERAL_BOUND_RE" <<<"$(submit_bound "$CTRL")"; then
  ok "the check flags submit-pr reverting to a literal bound"
else
  bad "the check MISSED submit-pr reverting to a literal bound" "$(submit_bound "$CTRL")"
fi

# Every submit-pr bound must name THIS setting: a second knob on one counter
# is the two-disagreeing-bounds shape the issue removes.
CTRL="$TMP_ROOT/submit-other-knob.md"
if ! plant "$CTRL" "$SUBMIT_WF" "s/$SETTING/A_DIFFERENT_CAP/g"; then
  bad "submit knob control planted nothing — its sed program matched no text"
elif grep -q -F "$SETTING" <<<"$(submit_bound "$CTRL")"; then
  bad "the check MISSED submit-pr bounding the counter on another setting"
else
  ok "the check flags submit-pr bounding the counter on another setting"
fi

# A second caller incrementing the counter: the round costs two units and the
# documented four-round budget is really two.
CTRL_DIR="$TMP_ROOT/workflows"
mkdir -p "$CTRL_DIR"
cp "$SKILL_DIR"/workflows/*.md "$CTRL_DIR/"
printf '%s\n' '.agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] pr_comment_review.iterations' >> "$CTRL_DIR/submit-pr.md"
ctrl_total="$(grep -r -F -c 'increment [ISSUE_ID] pr_comment_review.iterations' "$CTRL_DIR"/*.md | awk -F: '{ n += $2 } END { print n + 0 }')"
if [[ "$ctrl_total" -eq 1 ]]; then
  bad "second-writer control planted nothing — the count did not move"
elif [[ "$ctrl_total" -eq 2 ]]; then
  ok "the check flags a second writer of the iteration counter"
else
  bad "the check MISSED a second writer of the iteration counter" "total=$ctrl_total"
fi

# The audit left on its default return: filing runs and the exception never does.
CTRL="$TMP_ROOT/comments-return.md"
if ! plant "$CTRL" "$COMMENTS_WF" 's/invoked with its return recorded as `→ § 6.1` rather than § 6.2.s usual `→ § 6.3`/invoked as usual/'; then
  bad "audit-return control planted nothing — its sed program matched no text"
elif grep -q -F -- '→ § 6.1' <<<"$(cap_rule "$CTRL")"; then
  bad "the check MISSED a cap path that lets the audit return to § 6.3"
else
  ok "the check flags a cap path that lets the audit return to § 6.3"
fi

# The exception's delegation moved after the replies, so a Fixed in reply
# would name a sha that does not exist yet.
CTRL="$TMP_ROOT/comments-order3.md"
if ! plant "$CTRL" "$COMMENTS_WF" 's/\*\*Then the exception\*\*, the only delegation and the only push this pass makes\. //'; then
  bad "step-order control planted nothing — its sed program matched no text"
else
  ctrl_rule="$(cap_rule "$CTRL")"
  ce="$(first_at 'Then the exception' <<<"$ctrl_rule")"
  if [[ "$ce" -eq 0 ]]; then
    ok "the check flags an at-cap pass that never delegates the exception"
  else
    bad "the check MISSED an at-cap pass that never delegates the exception" "exception=$ce"
  fi
fi

# The reply-before-filing order this round removed.
CTRL="$TMP_ROOT/comments-order.md"
if ! plant "$CTRL" "$COMMENTS_WF" 's/ends the ordinary fix rounds on this PR\./ends the ordinary fix rounds on this PR, each item taking a `Tracked: [ISSUE_ID]` or a `Declined: [REASON]`./'; then
  bad "ordering control planted nothing — its sed program matched no text"
else
  ctrl_rule="$(cap_rule "$CTRL")"
  cf="$(first_at '§ 6.2' <<<"$ctrl_rule")"
  ct="$(first_at 'Tracked:' <<<"$ctrl_rule")"
  if [[ "$ct" -gt 0 ]] && { [[ "$cf" -eq 0 ]] || [[ "$cf" -gt "$ct" ]]; }; then
    ok "the check flags a cap rule that replies before it files"
  else
    bad "the check MISSED a cap rule that replies before it files" "file=$cf reply=$ct"
  fi
fi

# The exception widened back to every Step 1 fix verdict.
CTRL="$TMP_ROOT/disposition-wide.md"
if ! plant "$CTRL" "$DISPOSITION" "s/Only Step 1's introduced-or-armed branch outranks the cap/Step 1's \`fix\` verdict outranks the cap/"; then
  bad "exception-width control planted nothing — its sed program matched no text"
elif grep -q -F "Step 1's \`fix\` verdict outranks the cap" "$CTRL"; then
  ok "the check flags an exception widened to every Step 1 fix verdict"
else
  bad "the check MISSED an exception widened to every Step 1 fix verdict"
fi

# The check removed: the arms route to a decision point that is not there.
CTRL="$TMP_ROOT/submit-nocheck.md"
if ! plant "$CTRL" "$SUBMIT_WF" '/^   \*\*Restart check\.\*\*/,/^   \*\*On /{/^   \*\*On /!d}'; then
  bad "restart-check control planted nothing — its sed program matched no text"
elif [[ -z "$(restart_check "$CTRL")" ]]; then
  ok "the check flags submit-pr losing its Restart check"
else
  bad "the check MISSED submit-pr losing its Restart check"
fi

# A restart arm going straight back to the wait, around the cap.
CTRL="$TMP_ROOT/submit-bypass.md"
if ! plant "$CTRL" "$SUBMIT_WF" 's/Run the triage pass, then the Restart check/Run the triage pass, then restart step 1/'; then
  bad "restart-bypass control planted nothing — its sed program matched no text"
else
  ctrl_total="$(grep -c -F 'restart step 1' "$CTRL" || true)"
  ctrl_inside="$(grep -c -F 'restart step 1' <<<"$(restart_check "$CTRL")" || true)"
  if [[ "$ctrl_total" -eq "$ctrl_inside" ]]; then
    bad "the check MISSED a restart arm bypassing the Restart check" "total=$ctrl_total inside=$ctrl_inside"
  else
    ok "the check flags a restart arm bypassing the Restart check"
  fi
fi

# § 6.3 sending a capped late thread back to a caller that may have no check.
CTRL="$TMP_ROOT/comments-route.md"
if ! plant "$CTRL" "$COMMENTS_WF" 's/and loop to § 1, at the cap as below it/, then at or past the cap return to the caller rather than re-entering/'; then
  bad "late-thread routing control planted nothing — its sed program matched no text"
elif grep -q -F 'return to the caller' <<<"$(loop_site "$CTRL")"; then
  ok "the check flags § 6.3 routing a capped late thread away"
else
  bad "the check MISSED § 6.3 routing a capped late thread away"
fi

# The template re-deriving the set from the Fixing predicate, which is what
# left it one edit behind the cap rule.
CTRL="$TMP_ROOT/comments-set.md"
if ! plant "$CTRL" "$COMMENTS_WF" 's/\[For each item in the fix set:\]/[For each item marked "Fixing":]/'; then
  bad "carrier control planted nothing — its sed program matched no text"
elif grep -q -F 'marked "Fixing"' <<<"$(downstream "$CTRL")"; then
  ok "the check flags a carrier re-deriving the fix set"
else
  bad "the check MISSED a carrier re-deriving the fix set"
fi

# The re-submit set back to every issue triage created.
CTRL="$TMP_ROOT/submit-resubmit.md"
if ! plant "$CTRL" "$SUBMIT_WF" 's/The \*\*re-submit set\*\* is the issues this session filed for work the cap did not deny\..*bounded at two re-submit cycles:/Issues created during triage need implementing before merge, bounded at two re-submit cycles:/'; then
  bad "re-submit control planted nothing — its sed program matched no text"
elif grep -q -F 'Issues created during triage need implementing' "$CTRL"; then
  ok "the check flags a re-submit set that takes every filed issue"
else
  bad "the check MISSED a re-submit set that takes every filed issue"
fi

CTRL="$TMP_ROOT/disposition.md"
if ! plant "$CTRL" "$DISPOSITION" "s/\`$SETTING\` (default 4)/a round cap/"; then
  bad "disposition control planted nothing — its sed program matched no text"
elif grep -q -F "$SETTING" "$CTRL"; then
  bad "the check MISSED a reference that stopped naming the cap"
else
  ok "the check flags a reference that stopped naming the cap"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
