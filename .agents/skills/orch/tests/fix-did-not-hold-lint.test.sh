#!/usr/bin/env bash
# Regression lint for KEN-632. Every re-review prompt told the reviewer not to
# re-report anything the delegation listed as Fixed, with no exception. A
# reviewer that obeyed stayed silent about a finding whose recorded fix did not
# hold, so the machinery that supersedes the stale `fixed_items` entry never got
# the input it needs and § 8 kept publishing a live blocker as fixed against a
# dead SHA. The rule lives at three sites — review-pr's re-review delegation,
# its QA delegation, and the reviewer package's own § Re-Review Rounds — and a
# compliant reviewer obeys its own skill whatever a delegation invites, so all
# three carry the exception or the change does not take effect.
#
# The exception's other half matters as much: suppression that becomes optional
# is the failure it exists to prevent. It is narrowed to a Fixed item the
# reviewer actually checked against the current diff; an Escalated item is
# accepted as blocked and stays suppressed.
#
# The re-report has to land on the supersede's key, which is exact equality of
# the RECORDED entry's location and description. So each prompt tells the
# reviewer to copy those two fields verbatim and to put the sha in the
# recommendation, where no key reads it. The sha is named in prose: a
# `[COMMIT_SHA]` token outside a per-item loop binds to nothing, and the
# fill-or-omit rule for delegation blocks would drop the sentence holding it.
#
# What this pins are IDENTIFIERS and their relationships, never sentences:
# review-bots.md bans sentence-pinning lints on markdown, and an editorial
# rephrase must not fail a suite while the contract holds. The tokens here are
# the ones that cannot be reworded without changing behaviour — the `unless`/
# `except` conditional that makes the suppression narrow, `commit sha` and
# `verbatim` for the re-report's two obligations, `Escalated`/`suppressed`,
# and the bucket names and bindings in the writes.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
REVIEW_PR_WF="$SKILL_DIR/workflows/review-pr.md"
DEV_FIX_WF="$SKILL_DIR/workflows/dev-fix.md"
REVIEWER_SKILL="$SKILL_DIR/../reviewer/SKILL.md"
STATE_SCHEMA="$SKILL_DIR/schemas/workflow-state.md"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== re-report a fix that did not hold lint (KEN-632) ==="

# HTML comment regions are stripped from EVERY line before any section gate, so
# a comment opened above a marker blanks the marker too and the region never
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

# $1 = file, $2 = ERE opening the region (its line is included), $3 = ERE
# closing it (its line is excluded).
slice() {
  strip_comments "$1" | awk -v head="$2" -v tail="$3" '
    !on && $0 ~ head { on = 1 }
    on && printed && $0 ~ tail { on = 0 }
    !on { next }
    { print; printed = 1 }
  '
}

rereview_block() { slice "$1" '^<if re-review cycle>$' '^</if>$'; }
qa_block()       { slice "$1" 'Previous review cycle context' '^</delegation_format>$'; }
rr_rounds()      { slice "$1" '^## Re-Review Rounds$' '^## [^R]'; }

# Every grep reads a herestring, never a pipe: `grep -q` exits at the first
# match, SIGPIPE would kill the extractor, and `pipefail` would promote its 141
# into a false failure.
has()   { grep -qE -e "$2" <<<"$1"; }
count() { grep -oF -e "$2" <<<"$1" | wc -l | tr -d ' '; }

# The conditional connective family. A suppression rule that loses it is
# blanket again, whatever words surround it.
COND='unless|except'

# --- 1: the re-review delegation's suppression is conditional ---------------
RR="$(rereview_block "$REVIEW_PR_WF")"
if has "$RR" 'do NOT re-report' && has "$RR" "$COND"; then
  pass "the re-review delegation states a conditional suppression"
else
  fail "the re-review delegation suppresses fixed items unconditionally"
fi

# --- 2: the re-report is checkable and lands on the supersede's key ---------
# The sha makes the claim checkable. Copying location and description verbatim
# is what makes the drop match: it keys on exact equality with the recorded
# entry, and a reviewer that re-authors either field strands it.
names_recorded_sha()  { has "$1" 'commit sha'; }
copies_key_verbatim() { has "$1" 'verbatim' && has "$1" 'location' && has "$1" 'description'; }

if names_recorded_sha "$RR"; then
  pass "the re-review exception names the recorded commit sha"
else
  fail "the re-review exception does not name the recorded commit sha"
fi

if copies_key_verbatim "$RR"; then
  pass "the re-review exception copies location and description verbatim"
else
  fail "the re-review exception lets the reviewer re-author the key fields"
fi

# A per-item token outside the loop that binds it is unfillable. The Fixed
# line owns the block's one legitimate occurrence.
if [[ "$(count "$RR" '[COMMIT_SHA]')" -eq 1 ]]; then
  pass "the re-review exception carries no unbound [COMMIT_SHA]"
else
  fail "the re-review exception carries a [COMMIT_SHA] nothing binds"
fi

# --- 3: the escalated half stays suppressed ---------------------------------
# Escalated items are accepted as blocked. Extending the exception to them
# reopens decisions already made and is the re-report-everything failure. The
# two tokens must meet on ONE line: the exception paragraph is where the
# narrowing is stated, and `suppressed` elsewhere in the block does not carry
# it.
keeps_escalated_suppressed() { grep -E 'Escalated|escalated' <<<"$1" | grep -q 'suppressed'; }

if keeps_escalated_suppressed "$RR"; then
  pass "the re-review delegation keeps Escalated entries suppressed"
else
  fail "the re-review delegation lost the Escalated suppression"
fi

# --- 4: the QA delegation carries the same exception ------------------------
QA="$(qa_block "$REVIEW_PR_WF")"
if has "$QA" 'Do NOT re-report' && has "$QA" "$COND" && names_recorded_sha "$QA" && copies_key_verbatim "$QA"; then
  pass "the QA delegation states the exception, the sha, and the verbatim copy"
else
  fail "the QA delegation suppresses fixed items unconditionally"
fi

if [[ "$(count "$QA" '[COMMIT_SHA]')" -eq 1 ]]; then
  pass "the QA exception carries no unbound [COMMIT_SHA]"
else
  fail "the QA exception carries a [COMMIT_SHA] nothing binds"
fi

if keeps_escalated_suppressed "$QA"; then
  pass "the QA delegation keeps escalated items suppressed"
else
  fail "the QA delegation lost the escalated suppression"
fi

# --- 5: the reviewer package's own rule carries it too ----------------------
# A compliant reviewer obeys its skill whatever a delegation invites, so the
# skill's rule is the one that decides.
RRR="$(rr_rounds "$REVIEWER_SKILL")"
if has "$RRR" 'not re-reported' && has "$RRR" "$COND" && names_recorded_sha "$RRR" && copies_key_verbatim "$RRR"; then
  pass "reviewer § Re-Review Rounds states the exception, the sha, and the verbatim copy"
else
  fail "reviewer § Re-Review Rounds suppresses resolved items unconditionally"
fi

if keeps_escalated_suppressed "$RRR"; then
  pass "reviewer § Re-Review Rounds keeps Escalated items suppressed"
else
  fail "reviewer § Re-Review Rounds lost the Escalated suppression"
fi

# --- 6: dev-fix records each item into exactly one bucket, once -------------
# An item comes back for a second disposition two ways: a re-reported fix that
# did not hold, and an escalated item a later round fixes. Either way a bucket
# still lists it against a dead sha, so each write clears the item from BOTH
# buckets before appending its own. Clearing only the opposite bucket leaves
# the item printed under FIXED and ESCALATED at once.
# `|| true`, every one of them: a control that removes the write leaves grep
# with no match, and an unguarded failure inside a command substitution ends
# the run under `set -e` before the control can be judged.
devfix_writes() { strip_comments "$1" | grep -E 'workflow-state (append|update) \[ISSUE_ID\]' || true; }
fixed_write()   { grep -F '.fixed_items += '     <<<"$(devfix_writes "$1")" || true; }
escal_write()   { grep -F '.escalated_items += ' <<<"$(devfix_writes "$1")" || true; }

# Both buckets cleared, keyed on both fields — the same key § 8 dedupes on.
drops_stale() {
  has "$1" 'fixed_items = ' && has "$1" 'escalated_items = ' \
    && has "$1" '\.location' && has "$1" '\.description' && has "$1" 'map\(select\('
}

# The entry crosses into jq through a file. Pasted into argv it breaks on the
# text findings actually carry: a double quote makes the JSON argument
# invalid, an apostrophe ends the shell word, and the failed write leaves the
# stale entry standing with nothing recorded.
binds_from_file() { has "$1" '--slurpfile item' && ! has "$1" '--arg'; }

FW="$(fixed_write "$DEV_FIX_WF")"
if [[ -n "$FW" ]] && has "$FW" 'workflow-state update' && drops_stale "$FW"; then
  pass "the fixed_items write clears the item from both buckets"
else
  fail "the fixed_items write leaves a stale entry in one of the buckets"
fi

EW="$(escal_write "$DEV_FIX_WF")"
if [[ -n "$EW" ]] && has "$EW" 'workflow-state update' && drops_stale "$EW"; then
  pass "the escalated_items write clears the item from both buckets"
else
  fail "the escalated_items write leaves a stale entry in one of the buckets"
fi

if [[ -n "$FW" ]] && [[ -n "$EW" ]] && binds_from_file "$FW" && binds_from_file "$EW"; then
  pass "both writes bind the entry from a file and paste no finding text"
else
  fail "a write pastes the finding's own text into a shell word"
fi

if devfix_writes "$DEV_FIX_WF" | grep -qE 'append \[ISSUE_ID\] (fixed|escalated)_items'; then
  fail "dev-fix still appends into a bucket instead of superseding"
else
  pass "dev-fix uses no bare append into either bucket"
fi

# --- 7: the schema documents the one-bucket invariant -----------------------
if grep -qE 'never in both buckets' "$STATE_SCHEMA"; then
  pass "workflow-state schema states the one-bucket invariant"
else
  fail "workflow-state schema lost the one-bucket invariant"
fi

# --- planted controls: prove each check can fail ----------------------------
echo
echo "--- planted controls ---"

# $1 = source file, $2 = control name, $3 = sed program. Sets CTRL and reports
# whether the program changed anything: one matching nothing leaves the source
# untouched and the control proves nothing. Runs in the parent shell, never a
# command substitution, so its verdict reaches the counters.
plant() {
  CTRL="$TMP_ROOT/$2"
  sed "$3" "$1" > "$CTRL"
  ! cmp -s "$CTRL" "$1"
}

# The pre-KEN-632 shape: the exception cut back to a blanket rule.
RR_BLANKET='s/re-report, unless you check a Fixed entry against the current diff and the defect is still there: report that one again, copying that entry.s location and description verbatim and naming its recorded commit sha in your recommendation, so the stale entry can be superseded[.] A Fixed entry you did not check, and every Escalated entry, stays suppressed[.]/re-report:/'
if ! plant "$REVIEW_PR_WF" rr-blanket.md "$RR_BLANKET"; then
  fail "re-review control planted nothing — its sed program matched no text"
else
  C="$(rereview_block "$CTRL")"
  if has "$C" "$COND"; then
    fail "lint MISSED a re-review delegation reverted to blanket suppression"
  elif names_recorded_sha "$C" || copies_key_verbatim "$C"; then
    fail "lint MISSED the loss of the sha citation or the verbatim copy"
  else
    pass "lint flags a re-review delegation reverted to blanket suppression"
  fi
fi

# The exception kept, but with nothing to check the re-report against.
if ! plant "$REVIEW_PR_WF" rr-nosha.md 's/ and naming its recorded commit sha in your recommendation//'; then
  fail "sha control planted nothing — its sed program matched no text"
elif names_recorded_sha "$(rereview_block "$CTRL")"; then
  fail "lint MISSED an exception that cites no recorded sha"
else
  pass "lint flags an exception that cites no recorded sha"
fi

# The exception kept, but the reviewer left free to re-author the two fields
# the drop keys on. The write then records beside the stale entry.
if ! plant "$REVIEW_PR_WF" rr-reauthored.md "s/copying that entry's location and description verbatim and naming/describing what you found and naming/"; then
  fail "verbatim control planted nothing — its sed program matched no text"
elif copies_key_verbatim "$(rereview_block "$CTRL")"; then
  fail "lint MISSED an exception that lets the key fields be re-authored"
else
  pass "lint flags an exception that lets the key fields be re-authored"
fi

# The sha carried as a per-item token in a sentence no loop fills.
if ! plant "$REVIEW_PR_WF" rr-placeholder.md 's/naming its recorded commit sha in your recommendation/naming the [COMMIT_SHA] it is listed against/'; then
  fail "placeholder control planted nothing — its sed program matched no text"
elif [[ "$(count "$(rereview_block "$CTRL")" '[COMMIT_SHA]')" -eq 1 ]]; then
  fail "lint MISSED an unbound [COMMIT_SHA] in the exception"
else
  pass "lint flags an unbound [COMMIT_SHA] in the exception"
fi

# The exception widened over Escalated entries too.
if ! plant "$REVIEW_PR_WF" rr-wide.md 's/A Fixed entry you did not check, and every Escalated entry, stays suppressed[.]/Report anything you doubt./'; then
  fail "widening control planted nothing — its sed program matched no text"
elif keeps_escalated_suppressed "$(rereview_block "$CTRL")"; then
  fail "lint MISSED an exception widened past the Fixed list"
else
  pass "lint flags an exception widened past the Fixed list"
fi

if ! plant "$REVIEW_PR_WF" qa-blanket.md 's/items, unless you check a fixed item against the current diff and the defect is still there — then report it again, copying that entry.s location and description verbatim and naming its recorded commit sha in your recommendation[.] A fixed item you did not check, and every escalated item, stays suppressed[.] Otherwise report/items. Report/'; then
  fail "QA control planted nothing — its sed program matched no text"
else
  C="$(qa_block "$CTRL")"
  if has "$C" "$COND" || names_recorded_sha "$C" || copies_key_verbatim "$C"; then
    fail "lint MISSED a QA delegation reverted to blanket suppression"
  else
    pass "lint flags a QA delegation reverted to blanket suppression"
  fi
fi

if ! plant "$REVIEWER_SKILL" reviewer-blanket.md 's/re-reported, unless you check a Fixed item against the current diff and the defect is still there — report that one again, copying the listed entry.s location and description verbatim and naming its recorded commit sha in your recommendation, which is what makes the claim checkable and lets the orchestrator supersede the stale entry[.] A Fixed item you did not check, and every Escalated item, stays suppressed[.]/re-reported./'; then
  fail "reviewer control planted nothing — its sed program matched no text"
else
  C="$(rr_rounds "$CTRL")"
  if has "$C" "$COND"; then
    fail "lint MISSED a reviewer rule reverted to blanket suppression"
  else
    pass "lint flags a reviewer rule reverted to blanket suppression"
  fi
fi

# Inert-text control: the reviewer rule preserved verbatim but commented out.
INERT="$TMP_ROOT/reviewer-inert.md"
awk '
  /^## Re-Review Rounds/ && !opened { print "<!--"; opened = 1 }
  /^## Mutation-Stability/ && opened && !closed { print "-->"; closed = 1 }
  { print }
' "$REVIEWER_SKILL" > "$INERT"
if ! grep -qF '<!--' "$INERT"; then
  fail "inert-rule control planted nothing — no comment region was opened"
elif has "$(rr_rounds "$INERT")" "$COND"; then
  fail "lint credits a rule that sits inside an HTML comment"
else
  pass "lint flags a re-review rule commented out from above its heading"
fi

# The append shape: the entry recorded beside whatever already stands.
if ! plant "$DEV_FIX_WF" df-append.md "s|workflow-state update \[ISSUE_ID\] --slurpfile item \(.*\) '.*escalated_items += .*'|workflow-state append [ISSUE_ID] escalated_items \\1|"; then
  fail "escalate control planted nothing — its sed program matched no text"
else
  C="$(escal_write "$CTRL")"
  if [[ -n "$C" ]] && drops_stale "$C"; then
    fail "lint MISSED an escalate that records without clearing the buckets"
  elif ! devfix_writes "$CTRL" | grep -qE 'append \[ISSUE_ID\] escalated_items'; then
    fail "escalate control planted no append — control is vacuous"
  else
    pass "lint flags an escalate that records without clearing the buckets"
  fi
fi

if ! plant "$DEV_FIX_WF" df-fixed-append.md "s|workflow-state update \[ISSUE_ID\] --slurpfile item \(.*\) '.*fixed_items += .*'|workflow-state append [ISSUE_ID] fixed_items \\1|"; then
  fail "fixed control planted nothing — its sed program matched no text"
else
  C="$(fixed_write "$CTRL")"
  if [[ -n "$C" ]] && drops_stale "$C"; then
    fail "lint MISSED a fixed_items append beside a stale entry"
  else
    pass "lint flags a fixed_items append beside a stale entry"
  fi
fi

# The one-directional shape: the fixed write clears its own bucket and leaves
# a matching escalated entry standing. § 8 then prints the item under both.
if ! plant "$DEV_FIX_WF" df-oneway.md 's/ | .escalated_items = ((.escalated_items \/\/ \[\]) | map(select(.location != $e.location or .description != $e.description))) | .fixed_items += \[$e\]/ | .fixed_items += [$e]/'; then
  fail "one-way control planted nothing — its sed program matched no text"
elif drops_stale "$(fixed_write "$CTRL")"; then
  fail "lint MISSED a fixed write that never clears escalated_items"
else
  pass "lint flags a fixed write that never clears escalated_items"
fi

# The drop present but keyed on one field: two findings at the same location
# collide, or the same finding re-worded survives as a duplicate.
if ! plant "$DEV_FIX_WF" df-halfkey.md 's/select(\.location != $e\.location or \.description != $e\.description)/select(.location != $e.location)/g'; then
  fail "half-key control planted nothing — its sed program matched no text"
elif drops_stale "$(escal_write "$CTRL")"; then
  fail "lint MISSED a drop keyed on one field"
else
  pass "lint flags a drop keyed on one field"
fi

# The entry pasted into argv instead of bound from its file.
if ! plant "$DEV_FIX_WF" df-pasted.md "s|--slurpfile item tmp/state-item-\[ISSUE_ID\].json|--arg desc '[DESC]' --arg loc '[LOC]'|g"; then
  fail "pasted-entry control planted nothing — its sed program matched no text"
elif binds_from_file "$(escal_write "$CTRL")"; then
  fail "lint MISSED an entry pasted into a shell word"
else
  pass "lint flags an entry pasted into a shell word"
fi

SCRATCH_SCHEMA="$TMP_ROOT/schema.md"
sed 's/ An item is never in both buckets: every dev-fix outcome write clears the item from both, matched on (location, description), before appending its own entry//' "$STATE_SCHEMA" > "$SCRATCH_SCHEMA"
if cmp -s "$SCRATCH_SCHEMA" "$STATE_SCHEMA"; then
  fail "schema control planted nothing — its sed program matched no text"
elif grep -qE 'never in both buckets' "$SCRATCH_SCHEMA"; then
  fail "lint MISSED a schema that lost the one-bucket invariant"
else
  pass "lint flags a schema that lost the one-bucket invariant"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
