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
# What this pins are IDENTIFIERS and their relationships, never sentences:
# review-bots.md bans sentence-pinning lints on markdown, and an editorial
# rephrase must not fail a suite while the contract holds. The tokens here are
# the ones that cannot be reworded without changing behaviour — the `unless`/
# `except` conditional that makes the suppression narrow, the `[COMMIT_SHA]`
# placeholder that makes a re-report checkable, `Escalated`/`suppressed`, and
# the `fixed_items`/`escalated_items` bucket names in the writes.
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

# --- 2: the exception names the SHA the item is recorded against ------------
# One occurrence is the Fixed list's own line; the exception adds a second, so
# the reviewer's re-report cites a SHA the orchestrator can check.
if [[ "$(count "$RR" '[COMMIT_SHA]')" -ge 2 ]]; then
  pass "the re-review exception names the recorded [COMMIT_SHA]"
else
  fail "the re-review exception does not name the recorded [COMMIT_SHA]"
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
# Same [COMMIT_SHA] count rule as check 2: the list line owns the first.
QA="$(qa_block "$REVIEW_PR_WF")"
if has "$QA" 'Do NOT re-report' && has "$QA" "$COND" && [[ "$(count "$QA" '[COMMIT_SHA]')" -ge 2 ]]; then
  pass "the QA delegation states the exception and names the recorded SHA"
else
  fail "the QA delegation suppresses fixed items unconditionally"
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
if has "$RRR" 'not re-reported' && has "$RRR" "$COND" && has "$RRR" 'sha'; then
  pass "reviewer § Re-Review Rounds states the exception and names the sha"
else
  fail "reviewer § Re-Review Rounds suppresses resolved items unconditionally"
fi

if keeps_escalated_suppressed "$RRR"; then
  pass "reviewer § Re-Review Rounds keeps Escalated items suppressed"
else
  fail "reviewer § Re-Review Rounds lost the Escalated suppression"
fi

# --- 6: dev-fix records each item into exactly one bucket, once -------------
# The re-report path this change opens brings an item back for a second
# disposition, so both writes may land on one `fixed_items` already lists
# against a SHA that no longer fixes it. An append leaves that stale entry
# standing beside the new record: § 8 then prints the item twice, or under
# FIXED and ESCALATED at once, against a dead SHA.
devfix_writes() { strip_comments "$1" | grep -E 'workflow-state (append|update) \[ISSUE_ID\]'; }
fixed_write()   { grep -F '"commit"'  <<<"$(devfix_writes "$1")"; }
escal_write()   { grep -F '"outcome"' <<<"$(devfix_writes "$1")"; }

# The drop is keyed on both fields, the same key § 8 dedupes on.
drops_stale() {
  has "$1" 'fixed_items' && has "$1" '\.location' && has "$1" '\.description' && has "$1" 'map\(select\('
}

FW="$(fixed_write "$DEV_FIX_WF")"
if [[ -n "$FW" ]] && has "$FW" 'workflow-state update' && drops_stale "$FW"; then
  pass "the fixed_items write supersedes a stale entry in the same command"
else
  fail "the fixed_items write appends beside a stale entry"
fi

EW="$(escal_write "$DEV_FIX_WF")"
if [[ -n "$EW" ]] && has "$EW" 'workflow-state update' && has "$EW" 'escalated_items' && drops_stale "$EW"; then
  pass "the escalated_items write drops the superseded fixed_items entry"
else
  fail "the escalated_items write leaves the item in both buckets"
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
RR_BLANKET='s/re-report, unless you check a Fixed entry against the current diff and the defect is still there: report that one again, naming the \[COMMIT_SHA\] it is listed against, so the stale entry can be superseded[.] A Fixed entry you did not check, and every Escalated entry, stays suppressed[.]/re-report:/'
if ! plant "$REVIEW_PR_WF" rr-blanket.md "$RR_BLANKET"; then
  fail "re-review control planted nothing — its sed program matched no text"
else
  C="$(rereview_block "$CTRL")"
  if has "$C" "$COND"; then
    fail "lint MISSED a re-review delegation reverted to blanket suppression"
  elif [[ "$(count "$C" '[COMMIT_SHA]')" -ge 2 ]]; then
    fail "lint MISSED the loss of the recorded-SHA citation"
  else
    pass "lint flags a re-review delegation reverted to blanket suppression"
  fi
fi

# The exception kept, but with nothing to check the re-report against.
if ! plant "$REVIEW_PR_WF" rr-nosha.md 's/, naming the \[COMMIT_SHA\] it is listed against, so the stale entry can be superseded//'; then
  fail "sha control planted nothing — its sed program matched no text"
elif [[ "$(count "$(rereview_block "$CTRL")" '[COMMIT_SHA]')" -ge 2 ]]; then
  fail "lint MISSED an exception that cites no recorded SHA"
else
  pass "lint flags an exception that cites no recorded SHA"
fi

# The exception widened over Escalated entries too.
if ! plant "$REVIEW_PR_WF" rr-wide.md 's/A Fixed entry you did not check, and every Escalated entry, stays suppressed[.]/Report anything you doubt./'; then
  fail "widening control planted nothing — its sed program matched no text"
elif keeps_escalated_suppressed "$(rereview_block "$CTRL")"; then
  fail "lint MISSED an exception widened past the Fixed list"
else
  pass "lint flags an exception widened past the Fixed list"
fi

if ! plant "$REVIEW_PR_WF" qa-blanket.md 's/items, unless you check a fixed item against the current diff and the defect is still there — then report it again, naming the \[COMMIT_SHA\] it is listed against[.] A fixed item you did not check, and every escalated item, stays suppressed[.] Otherwise report/items. Report/'; then
  fail "QA control planted nothing — its sed program matched no text"
else
  C="$(qa_block "$CTRL")"
  if has "$C" "$COND" || [[ "$(count "$C" '[COMMIT_SHA]')" -ge 2 ]]; then
    fail "lint MISSED a QA delegation reverted to blanket suppression"
  else
    pass "lint flags a QA delegation reverted to blanket suppression"
  fi
fi

if ! plant "$REVIEWER_SKILL" reviewer-blanket.md 's/re-reported, unless you check a Fixed item against the current diff and the defect is still there — report that one again, naming the commit sha it is listed against so the claim is checkable[.] A Fixed item you did not check, and every Escalated item, stays suppressed[.]/re-reported./'; then
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

# The pre-KEN-632 escalate: recorded beside its stale fixed_items entry.
if ! plant "$DEV_FIX_WF" df-append.md "s|workflow-state update \[ISSUE_ID\] --argjson item '\(.*\"outcome\".*\)' '.*'|workflow-state append [ISSUE_ID] escalated_items '\1'|"; then
  fail "escalate control planted nothing — its sed program matched no text"
else
  C="$(escal_write "$CTRL")"
  if [[ -n "$C" ]] && drops_stale "$C"; then
    fail "lint MISSED an escalate that records without dropping the stale entry"
  elif ! devfix_writes "$CTRL" | grep -qE 'append \[ISSUE_ID\] escalated_items'; then
    fail "escalate control planted no append — control is vacuous"
  else
    pass "lint flags an escalate that records without dropping the stale entry"
  fi
fi

# The same for the fixed_items record: a second entry against a live SHA while
# the dead-SHA entry § 8 reads first still stands.
if ! plant "$DEV_FIX_WF" df-fixed-append.md "s|workflow-state update \[ISSUE_ID\] --argjson item '\(.*\"commit\".*\)' '.*'|workflow-state append [ISSUE_ID] fixed_items '\1'|"; then
  fail "fixed control planted nothing — its sed program matched no text"
else
  C="$(fixed_write "$CTRL")"
  if [[ -n "$C" ]] && drops_stale "$C"; then
    fail "lint MISSED a fixed_items append beside a stale entry"
  else
    pass "lint flags a fixed_items append beside a stale entry"
  fi
fi

# The drop present but keyed on one field: two findings at the same location
# collide, or the same finding re-worded survives as a duplicate.
if ! plant "$DEV_FIX_WF" df-halfkey.md 's/select(\.location != $item\.location or \.description != $item\.description)/select(.location != $item.location)/g'; then
  fail "half-key control planted nothing — its sed program matched no text"
elif drops_stale "$(escal_write "$CTRL")"; then
  fail "lint MISSED a drop keyed on one field"
else
  pass "lint flags a drop keyed on one field"
fi

SCRATCH_SCHEMA="$TMP_ROOT/schema.md"
sed 's/ An item is never in both buckets: a write that escalates one `fixed_items` already lists supersedes that entry and drops it in the same command//' "$STATE_SCHEMA" > "$SCRATCH_SCHEMA"
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
