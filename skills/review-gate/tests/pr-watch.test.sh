#!/usr/bin/env bash
# Behavioral tests for the watcher reduction surface.
# Stdout attention records are the whole-text protocol read by orch.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/lib/pr-watch-fixture.sh"

P7U="$(jq -cn --argjson r "$(pr_row 7 open unarmed)" '[$r]')"
P7UD="$(jq -cn --argjson r "$(pr_row 7 open unarmed true)" '[$r]')"
P7AD="$(jq -cn --argjson r "$(pr_row 7 open armed true)" '[$r]')"
P7NEW="$(jq -cn --argjson r "$(pr_row 7 open armed false "$NOW")" '[$r]')"
T_STUCK='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"isResolved":false}]}}}}}'
T_PAGE1='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"isResolved":true},{"isResolved":true}]}}}}}'
T_PAGE2_OPEN='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false}]}}}}}'
T_PAGE2_RESOLVED='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":true}]}}}}}'
DISARMED_DETAIL='approved+(reviewDecision+APPROVED)+but+auto-merge+is+not+armed+and+the+PR+is+not+queued+—+nothing+will+merge+this+(re-arm)'

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

echo "=== lanes-app refresh approval attention ==="
# The watcher wakes the existing overseer approval route; it never approves.
# Actual REST identity and commit-bound check runs drive the real reducer.
REFRESH_ROW="$(pr_row 7 open armed false "$NOW" | jq -c '.head.ref="kendex/refresh" | .user={login:"vanillagreen-fleet-lanes[bot]",type:"Bot"}')"
REFRESH_PRS="[$REFRESH_ROW]"
CI_GREEN="$(jq -cn --arg head "$HEAD_A" '{check_runs:[{name:"CI",head_sha:$head,status:"completed",conclusion:"success"}]}')"
REFRESH_ENV="STUB_OPEN_PRS=$REFRESH_PRS;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$NOW;STUB_EXPECT_CI_HEAD=$HEAD_A;STUB_CI_RAW=$CI_GREEN"
table \
  "a fresh green refresh reports immediately|--awaiting-after 3600|$REFRESH_ENV|rc=1 kinds=refresh-ready" \
  "a pending refresh aggregate is silent|--awaiting-after 60|$REFRESH_ENV;STUB_HEAD_DATE=$OLD;STUB_CI_RAW=$(jq -c '.check_runs[0].status="in_progress" | .check_runs[0].conclusion=null' <<<"$CI_GREEN")|rc=0 kinds=none" \
  "a missing aggregate is silent|--awaiting-after 60|$REFRESH_ENV;STUB_HEAD_DATE=$OLD;STUB_CI_RAW={\"check_runs\":[]}|rc=0 kinds=none" \
  "a different check cannot act as the aggregate||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].name="build"' <<<"$CI_GREEN")|rc=0 kinds=none" \
  "a passing aggregate on another head grants no attention||$REFRESH_ENV;STUB_CI_RAW=$(jq -c --arg head "$HEAD_B" '.check_runs[0].head_sha=$head' <<<"$CI_GREEN")|rc=0 kinds=none" \
  "a page after a passing aggregate can hold a failed aggregate||$REFRESH_ENV;STUB_CI_RAW=$CI_GREEN $(jq -c '.check_runs[0].conclusion="failure"' <<<"$CI_GREEN")|rc=0 kinds=none" \
  "an unread aggregate fails loud||$REFRESH_ENV;STUB_CI_RAW=fail|rc=2 kinds=error" \
  "a zero-byte aggregate response fails loud||$REFRESH_ENV;STUB_CI_RAW=emptybytes|rc=2 kinds=error" \
  "a malformed aggregate response fails loud||$REFRESH_ENV;STUB_CI_RAW={}|rc=2 kinds=error" \
  "an object instead of check-run array fails loud||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs={aggregate:.check_runs[0]}' <<<"$CI_GREEN")|rc=2 kinds=error" \
  "a non-string check status fails loud||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].status=false' <<<"$CI_GREEN")|rc=2 kinds=error" \
  "a check missing its conclusion fails loud||$REFRESH_ENV;STUB_CI_RAW=$(jq -c 'del(.check_runs[0].conclusion)' <<<"$CI_GREEN")|rc=2 kinds=error" \
  "a moved refresh head needs a new reduction||$REFRESH_ENV;STUB_REFRESH_HEAD_AFTER=$HEAD_B|rc=1 kinds=head-moved" \
  "a refresh closed during CI reduction gets no approval attention||$REFRESH_ENV;STUB_CLOSED_AFTER=yes|rc=0 kinds=none" \
  "a refresh drafted during CI reduction gets no approval attention||$REFRESH_ENV;STUB_DRAFT_AFTER=yes|rc=0 kinds=none" \
  "a refresh approved during CI reduction gets no approval attention||$REFRESH_ENV;STUB_DECISION_AFTER=APPROVED|rc=0 kinds=none" \
  "an unresolved thread holds refresh approval||$REFRESH_ENV;STUB_UNRESOLVED=1|rc=1 kinds=threads-open" \
  "a standing objection holds refresh approval||$REFRESH_ENV;STUB_DECISION=CHANGES_REQUESTED|rc=1 kinds=changes-requested" \
  "a refresh draft never requests approval attention||$REFRESH_ENV;STUB_OPEN_PRS=[$(jq -c '.draft=true' <<<"$REFRESH_ROW")]|rc=0 kinds=none"
for conclusion in failure cancelled skipped neutral timed_out action_required stale; do
  table "aggregate $conclusion grants no refresh attention||$REFRESH_ENV;STUB_CI_RAW=$(jq -c --arg c "$conclusion" '.check_runs[0].conclusion=$c' <<<"$CI_GREEN")|rc=0 kinds=none"
done
for identity in branch author type; do
  case "$identity" in
    branch) other="$(jq -c '.head.ref="kendex/refresh-extra"' <<<"$REFRESH_ROW")" ;;
    author) other="$(jq -c '.user.login="another[bot]"' <<<"$REFRESH_ROW")" ;;
    type) other="$(jq -c '.user.type="User"' <<<"$REFRESH_ROW")" ;;
  esac
  table \
    "wrong refresh $identity keeps the ordinary quiet period|--awaiting-after 3600|$REFRESH_ENV;STUB_OPEN_PRS=[$other]|rc=0 kinds=none" \
    "wrong refresh $identity keeps ordinary stale attention|--awaiting-after 60|$REFRESH_ENV;STUB_OPEN_PRS=[$(jq -c --arg at "$OLD" '.created_at=$at' <<<"$other")];STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale"
done

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

mutant_watch refresh-branch 's#\.head.ref == "kendex/refresh"#true#' '.head.ref == "kendex/refresh"' lib/refresh-identity.sh
table "must-fail: removing the exact branch check reports a product branch||$REFRESH_ENV;STUB_OPEN_PRS=[$(jq -c '.head.ref="product"' <<<"$REFRESH_ROW")]|rc=1 kinds=refresh-ready"
mutant_watch refresh-author 's#\.user.login == "vanillagreen-fleet-lanes\[bot\]"#true#' '.user.login == "vanillagreen-fleet-lanes[bot]"' lib/refresh-identity.sh
table "must-fail: removing the app login check reports another author||$REFRESH_ENV;STUB_OPEN_PRS=[$(jq -c '.user.login="another[bot]"' <<<"$REFRESH_ROW")]|rc=1 kinds=refresh-ready"
mutant_watch refresh-type 's#\.user.type == "Bot"#true#' '.user.type == "Bot"' lib/refresh-identity.sh
table "must-fail: removing the Bot type check reports a user identity||$REFRESH_ENV;STUB_OPEN_PRS=[$(jq -c '.user.type="User"' <<<"$REFRESH_ROW")]|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-head 's#\.head_sha == \$head#true#' '.head_sha == $head'
table "must-fail: removing CI head binding reports another head||$REFRESH_ENV;STUB_CI_RAW=$(jq -c --arg h "$HEAD_B" '.check_runs[0].head_sha=$h' <<<"$CI_GREEN")|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-status 's#\.status == "completed"#true#' '.status == "completed"'
table "must-fail: removing completion reports running CI||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].status="in_progress"' <<<"$CI_GREEN")|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-conclusion 's#\.conclusion == "success"#true#' '.conclusion == "success"'
table "must-fail: removing success reports failed CI||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].conclusion="failure"' <<<"$CI_GREEN")|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-present 's#(\$ci | length) > 0#true#' '($ci | length) > 0'
table "must-fail: removing aggregate presence reports absent CI||$REFRESH_ENV;STUB_CI_RAW={\"check_runs\":[]}|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-name 's#select(.name == "CI")#select(.name != "CI")#' 'select(.name == "CI")'
table "must-fail: accepting another name reports a build check||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].name="build"' <<<"$CI_GREEN")|rc=1 kinds=refresh-ready"
mutant_watch refresh-head-recheck 's#if \[ "$refresh_now" != "$head" \]; then#if [ "$refresh_now" = "" ]; then#' 'if [ "$refresh_now" != "$head" ]; then'
table "must-fail: removing the fresh head check reports stale green CI||$REFRESH_ENV;STUB_REFRESH_HEAD_AFTER=$HEAD_B|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-envelope 's#(.check_runs | type) != "array"#false#' '(.check_runs | type) != "array"'
table "must-fail: ignoring the container schema accepts an object||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs={aggregate:.check_runs[0]}' <<<"$CI_GREEN")|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-node 's#(.status | type) != "string"#false#' '(.status | type) != "string"'
table "must-fail: ignoring the node schema loses malformed-status attention||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].status=false' <<<"$CI_GREEN")|rc=0 kinds=none"
mutant_watch refresh-open 's#and .state == \\"open\\"#and true#' 'and .state == \"open\"'
table "must-fail: ignoring the fresh open state reports a closed PR||$REFRESH_ENV;STUB_CLOSED_AFTER=yes|rc=1 kinds=refresh-ready"
mutant_watch refresh-draft 's#and .draft == false#and true#' 'and .draft == false'
table "must-fail: ignoring the fresh draft state reports a draft||$REFRESH_ENV;STUB_DRAFT_AFTER=yes|rc=1 kinds=refresh-ready"
mutant_watch refresh-review 's#if \[ "$decision" = REVIEW_REQUIRED \] \&\& jq#if true \&\& jq#' 'if [ "$decision" = REVIEW_REQUIRED ] && jq'
table "must-fail: ignoring the fresh decision reports an already approved PR||$REFRESH_ENV;STUB_DECISION_AFTER=APPROVED|rc=1 kinds=refresh-ready"
WATCH_BIN="$LIVE_WATCH"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
