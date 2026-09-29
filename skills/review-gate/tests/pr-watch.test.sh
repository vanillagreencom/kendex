#!/usr/bin/env bash
# Behavioral tests for the watcher reduction surface.
# Stdout attention records are the whole-text protocol read by orch.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/lib/pr-watch-fixture.sh"

# One orch workflow-state file per size fixture, the shape branch-size-check
# writes: the record under `pr.size_check`, keyed by the lane's own branch and
# bound to the head it measured. A null allowance is the `allowance_missing`
# verdict, which the check emits for an issue that states no expected delta.
size_state() { # dir, branch, head_sha, production_lines, allowance-or-null, [verdict]
  mkdir -p "$1"
  jq -n --arg branch "$2" --arg head "$3" --argjson prod "$4" --argjson allow "$5" \
    --arg verdict "${6:-}" \
    '{issue_id:"KEN-1", branch:$branch, worktree:"/wt",
      pr:{baseline_lines:100,
          size_check:{base_sha:"0000000000000000000000000000000000000000", head_sha:$head,
                      production_lines:$prod, test_lines:40, mirror_lines:0,
                      production_allowance:$allow, test_allowance:null,
                      verdict:(if $verdict != "" then $verdict
                               elif $allow == null then "allowance_missing"
                               else "pass" end),
                      reason:""}}}' > "$1/workflow-state-KEN-1.json"
}
SD_CURRENT="$TMP_ROOT/state/current"; size_state "$SD_CURRENT" lane "$HEAD_A" 214 250
SD_STALE="$TMP_ROOT/state/stale";     size_state "$SD_STALE"   lane "$HEAD_B" 214 250
SD_NOALLOW="$TMP_ROOT/state/noallow"; size_state "$SD_NOALLOW" lane "$HEAD_A" 214 null
SD_OTHER="$TMP_ROOT/state/other";     size_state "$SD_OTHER"   other-lane "$HEAD_A" 214 250
# A stated allowance of zero is a real number, not an absent line: the check's
# delta grammar accepts `0 lines`, which is how a test-only issue states its
# production budget. Past it, and past a test allowance the production ratio
# says nothing about, the verdict is the only signal. `workflow-state init`
# with no --branch records the empty string, so an empty head ref must never
# be allowed to key the lookup.
SD_ZERO="$TMP_ROOT/state/zero";           size_state "$SD_ZERO"      lane "$HEAD_A"   5   0 production_over
SD_TESTSOVER="$TMP_ROOT/state/testsover"; size_state "$SD_TESTSOVER" lane "$HEAD_A" 214 250 tests_over
SD_NOBRANCH="$TMP_ROOT/state/nobranch";   size_state "$SD_NOBRANCH"  ""   "$HEAD_A" 214 250


P7U="$(jq -cn --argjson r "$(pr_row 7 open unarmed)" '[$r]')"
P7UD="$(jq -cn --argjson r "$(pr_row 7 open unarmed true)" '[$r]')"
P7UNOREF="$(jq -cn --argjson r "$(pr_row 7 open unarmed | jq 'del(.head.ref)')" '[$r]')"
P7AD="$(jq -cn --argjson r "$(pr_row 7 open armed true)" '[$r]')"
P7NEW="$(jq -cn --argjson r "$(pr_row 7 open armed false "$NOW")" '[$r]')"
T_STUCK='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"isResolved":false}]}}}}}'
T_PAGE1='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"isResolved":true},{"isResolved":true}]}}}}}'
T_PAGE2_OPEN='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false}]}}}}}'
T_PAGE2_RESOLVED='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":true}]}}}}}'
DISARMED_DETAIL='approved+(reviewDecision+APPROVED)+but+auto-merge+is+not+armed+and+the+PR+is+not+queued+—+nothing+will+merge+this+(re-arm)+—+size+unavailable:+no+submit+measurement+is+recorded+for+this+branch'

echo "=== the reduction over threads, reviewDecision, arming and queue membership ==="
# A healthy PR is silence. Every finding is its own line read from GitHub:
# an open thread and a standing objection both report, while an open thread
# holds the re-arm and stale-review nudges until it is answered.
table \
  "approved and armed: silence||STUB_OPEN_PRS=$P7|rc=0 kinds=none" \
  "threads-open carries the count||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=2|rc=1 kinds=threads-open threads=2 protocol=7~aaaaaaaa~threads-open~2+unresolved+review+thread(s)" \
  "threads-open on a queued PR carries the dequeue note||STUB_QUEUED=yes;STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1|rc=1 kinds=threads-open queued_notes=1" \
  "changes-requested is read from reviewDecision||STUB_OPEN_PRS=$P7;STUB_DECISION=CHANGES_REQUESTED|rc=1 kinds=changes-requested protocol=7~aaaaaaaa~changes-requested~a+reviewer+requested+changes+(reviewDecision+CHANGES_REQUESTED)" \
  "open threads do not suppress a standing objection||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1;STUB_DECISION=CHANGES_REQUESTED|rc=1 kinds=threads-open,changes-requested" \
  "queued lines all carry the dequeue note||STUB_QUEUED=yes;STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1;STUB_DECISION=CHANGES_REQUESTED|rc=1 queued_notes=2" \
  "approved, not armed, not queued: disarmed||STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed protocol=7~aaaaaaaa~disarmed~$DISARMED_DETAIL" \
  "a null decision is no approval: an unarmed PR is never disarmed||STUB_OPEN_PRS=$P7U;STUB_DECISION=null|rc=0 kinds=none" \
  "a null decision is never awaiting-stale|--awaiting-after 60|STUB_OPEN_PRS=$P7U;STUB_DECISION=null;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "the same shape queued: the queue owns the merge||STUB_QUEUED=yes;STUB_OPEN_PRS=$P7U|rc=0 kinds=none" \
  "a draft never gets the disarmed nag||STUB_OPEN_PRS=$P7UD|rc=0 kinds=none" \
  "an open thread holds the re-arm nudge||STUB_OPEN_PRS=$P7U;STUB_UNRESOLVED=2|rc=1 kinds=threads-open" \
  "an unapproved PR is never disarmed|--awaiting-after 3600|STUB_OPEN_PRS=$P7U;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$NOW|rc=0 kinds=none" \
  "an open thread holds the stale-review nudge|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=1 kinds=threads-open" \
  "an approved PR is never awaiting-stale|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_HEAD_DATE=$OLD|rc=0 kinds=none"

echo "=== the disarmed line carries the submit-size record ==="
# branch-size-check records the branch's measured size at submit, keyed by the
# lane's branch and bound to the head it compared; the reducer reads that
# record and never re-measures. The disarmed line carries it, a record of any
# other head reads stale rather than as this head's size, and a state
# directory holding only another lane's record leaves this one unavailable.
table \
  "the disarmed line carries the counts and their ratio||ORCH_STATE_DIR=$SD_CURRENT;STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa" \
  "a record of another head reads stale, never as this head's size||ORCH_STATE_DIR=$SD_STALE;STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed size=stale@bbbbbbbb" \
  "another lane's record leaves this branch unavailable||ORCH_STATE_DIR=$SD_OTHER;STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed size=unavailable" \
  "no state directory at all is unavailable||ORCH_STATE_DIR=$TMP_ROOT/state/absent;STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed size=unavailable" \
  "a record stating no allowance reports the count and no ratio||ORCH_STATE_DIR=$SD_NOALLOW;STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed size=214/none@aaaaaaaa" \
  "a stated allowance of zero is reported as the number it is||ORCH_STATE_DIR=$SD_ZERO;STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed size=5/0@aaaaaaaa!production_over" \
  "a test-allowance breach is named, not hidden by a clean ratio||ORCH_STATE_DIR=$SD_TESTSOVER;STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa!tests_over" \
  "a PR row with no head ref keys nothing and reads unavailable||ORCH_STATE_DIR=$SD_NOBRANCH;STUB_OPEN_PRS=$P7UNOREF|rc=1 kinds=disarmed size=unavailable"

echo "=== must-fail controls for the surfaces above ==="
# Each control fails against a copy of the reducer with the one expression it
# depends on removed: the call at the disarmed site, the head binding that
# makes a record current, the branch binding that makes it this lane's, and
# the guard that stops an empty branch from keying the lookup at all.

mutant_watch disarmed-call 's|(re-arm)$(size_note "$head_ref" "$head")|(re-arm)|' '(re-arm)$(size_note'
table "must-fail: without the disarmed site's call that line carries no size||ORCH_STATE_DIR=$SD_CURRENT;STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed size=none"

mutant_watch head-binding 's#map(select(.head_sha == $head)) | first#first#' 'map(select(.head_sha == $head)) | first'
table "must-fail: without the head binding the old record reads as current||ORCH_STATE_DIR=$SD_STALE;STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed size=214/250/85%@bbbbbbbb"

mutant_watch branch-binding 's#(.branch? // "") == $branch#true#' '(.branch? // "") == $branch'
table "must-fail: without the branch binding another lane's record is reported||ORCH_STATE_DIR=$SD_OTHER;STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa"

mutant_watch empty-branch-guard 's#if \[ -n "$branch" \]; then#if true; then#' 'if [ -n "$branch" ]; then'
table "must-fail: without the empty-branch guard a branchless lane's record is reported||ORCH_STATE_DIR=$SD_NOBRANCH;STUB_OPEN_PRS=$P7UNOREF|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa"

WATCH_BIN="$LIVE_WATCH"

echo "=== the thread walk is paged, summed and bounded ==="
# Over 100 threads, a cursor that never advances, or more than 20 advancing
# pages fail closed as overflow attention; a thread on page two is counted;
# resolved history across pages, 20 pages included, is healthy.
table \
  "over 100 threads is overflow||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=100;STUB_THREADS_NEXTPAGE=true|rc=1 kinds=threads-open threads=overflow" \
  "a cursor that never advances is overflow at the bound||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_STUCK|rc=1 kinds=threads-open threads=overflow" \
  "an unresolved thread on page two is counted||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_PAGE1;STUB_THREADS_PAGE2=$T_PAGE2_OPEN|rc=1 kinds=threads-open threads=1" \
  "resolved history across pages is healthy||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_PAGE1;STUB_THREADS_PAGE2=$T_PAGE2_RESOLVED|rc=0 kinds=none" \
  "25 advancing resolved pages breach the budget: overflow||STUB_OPEN_PRS=$P7;STUB_THREADS_PAGES=25|rc=1 kinds=threads-open threads=overflow" \
  "exactly 20 advancing resolved pages are healthy||STUB_OPEN_PRS=$P7;STUB_THREADS_PAGES=20|rc=0 kinds=none"

echo "=== the reviewer-silence clock ==="
# Awaiting is stale only past the quiet period, measured from the newest of
# the head commit, the PR's creation, and a readiness, reopen or re-review
# event; drafts are never nagged, and only REVIEW_REQUIRED starts the clock.
# PR_REVIEW_WAIT_SECS drives the same clock as --awaiting-after, and a
# zero-padded value is judged by magnitude.
table \
  "a head younger than the threshold is silent|--awaiting-after 3600|STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$NOW|rc=0 kinds=none" \
  "a head older than the threshold is awaiting-stale|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale" \
  "PR_REVIEW_WAIT_SECS drives the same clock||PR_REVIEW_WAIT_SECS=60;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale" \
  "a zero-padded --awaiting-after is judged by magnitude|--awaiting-after 0000000000060|STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale" \
  "an old commit in a fresh PR is not stale: creation floors the clock|--awaiting-after 3600|STUB_OPEN_PRS=$P7NEW;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "an old draft is not awaiting-stale|--awaiting-after 60|STUB_OPEN_PRS=$P7AD;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "a fresh ready_for_review restarts the quiet period|--awaiting-after 3600|STUB_READY_AT=$NOW;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "a fresh reopen restarts the quiet period|--awaiting-after 3600|STUB_REOPENED_AT=$NOW;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "a fresh re-review request restarts the quiet period|--awaiting-after 3600|STUB_REREQUEST_AT=$NOW;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=0 kinds=none"

echo "=== a head that moves or a PR that changes mid-reduction ==="
# The just-in-time recheck: a moved head is attention, a disarm is caught, and
# a close, a draft conversion or a dismissed approval silences the re-arm
# nudge. The nudge needs the approval in both reads.
table \
  "a head that moved during the reduction is head-moved||STUB_HEAD_AFTER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;STUB_OPEN_PRS=$P7|rc=1 kinds=head-moved" \
  "a mid-reduction disarm is caught||STUB_ARMED_AFTER=false;STUB_OPEN_PRS=$P7|rc=1 kinds=disarmed" \
  "a mid-reduction close gets no re-arm nudge||STUB_CLOSED_AFTER=yes;STUB_OPEN_PRS=$P7U|rc=0 kinds=none" \
  "a mid-reduction draft conversion gets no re-arm nudge||STUB_DRAFT_AFTER=yes;STUB_OPEN_PRS=$P7U|rc=0 kinds=none" \
  "an approval dismissed mid-reduction gets no re-arm nudge|--awaiting-after 3600|STUB_DECISION_AFTER=REVIEW_REQUIRED;STUB_OPEN_PRS=$P7U;STUB_HEAD_DATE=$NOW|rc=0 kinds=none" \
  "an approval that lands mid-reduction waits for the next pass|--awaiting-after 3600|STUB_DECISION=REVIEW_REQUIRED;STUB_DECISION_AFTER=APPROVED;STUB_OPEN_PRS=$P7U;STUB_HEAD_DATE=$NOW|rc=0 kinds=none"

echo "=== must-fail controls for each kept kind ==="
# One control per rule a kind is read by, each against a copy of the reducer
# with that rule's condition planted wrong and the row it holds replayed: the
# row's live answer above must move. threads-open counts unresolved nodes;
# changes-requested, disarmed and awaiting-stale each read reviewDecision,
# disarmed in both the first read and the just-in-time recheck and never on
# a null decision, and awaiting-stale in both directions; head-moved compares
# the recheck's head.
mutant_watch threads-count 's#select(.isResolved==false)#select(.isResolved==null)#' 'select(.isResolved==false)'
table "must-fail: with unresolved nodes uncounted two open threads read as silence||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=2|rc=0 kinds=none"

mutant_watch changes-decision 's#"$decision" = "CHANGES_REQUESTED" \]#"$decision" = "CHANGES_UNREAD" ]#' '"$decision" = "CHANGES_REQUESTED" ]'
table "must-fail: with CHANGES_REQUESTED unread a standing objection reads as silence||STUB_OPEN_PRS=$P7;STUB_DECISION=CHANGES_REQUESTED|rc=0 kinds=none"

mutant_watch disarmed-first-read 's#if \[ "$review_met" = "1" \] && \[ "$draft" != "true" \]; then#if [ "$draft" != "true" ]; then#' 'if [ "$review_met" = "1" ] && [ "$draft" != "true" ]; then'
table "must-fail: without the first read's approval an approval landing mid-reduction nudges||STUB_DECISION=REVIEW_REQUIRED;STUB_DECISION_AFTER=APPROVED;STUB_OPEN_PRS=$P7U;STUB_HEAD_DATE=$NOW|rc=1 kinds=disarmed"

mutant_watch disarmed-null 's#APPROVED) review_met=1#APPROVED|NONE) review_met=1#' 'APPROVED) review_met=1'
table "must-fail: with a null decision read as approval an unreviewed PR nudges||STUB_OPEN_PRS=$P7U;STUB_DECISION=null|rc=1 kinds=disarmed"

mutant_watch disarmed-recheck 's#classify_decision "$number" "$head" recheck || continue#:#' 'classify_decision "$number" "$head" recheck'
table "must-fail: without the recheck's approval a dismissed approval still nudges|--awaiting-after 3600|STUB_DECISION_AFTER=REVIEW_REQUIRED;STUB_OPEN_PRS=$P7U;STUB_HEAD_DATE=$NOW|rc=1 kinds=disarmed"

mutant_watch awaiting-unread 's#"$decision" = "REVIEW_REQUIRED" \]#"$decision" = "REVIEW_UNREAD" ]#' '"$decision" = "REVIEW_REQUIRED" ]'
table "must-fail: with REVIEW_REQUIRED unread an old unapproved head reads as silence|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=0 kinds=none"

mutant_watch awaiting-any 's#"$decision" = "REVIEW_REQUIRED" \]#"$decision" != "CHANGES_REQUESTED" ]#' '"$decision" = "REVIEW_REQUIRED" ]'
table \
  "must-fail: with any decision starting the clock an approved old head reads stale|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale" \
  "must-fail: with any decision starting the clock a null decision on an old head reads stale|--awaiting-after 60|STUB_OPEN_PRS=$P7U;STUB_DECISION=null;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale"

mutant_watch head-compare 's#if \[ "$head_now" != "$head" \]; then#if [ "$head_now" = "" ]; then#' 'if [ "$head_now" != "$head" ]; then'
table "must-fail: without the head comparison a moved head reads as silence||STUB_HEAD_AFTER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;STUB_OPEN_PRS=$P7|rc=0 kinds=none"
WATCH_BIN="$LIVE_WATCH"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
