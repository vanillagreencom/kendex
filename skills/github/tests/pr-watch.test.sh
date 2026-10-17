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

mutant_watch thread-page-bound 's#\$pages >= 20#false#' '$pages >= 20'
table "must-fail: without the page budget 25 resolved pages lose overflow attention||STUB_OPEN_PRS=$P7;STUB_THREADS_PAGES=25|rc=0 kinds=none"
WATCH_BIN="$LIVE_WATCH"

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

echo "=== PR_REVIEW_WAIT_SECS from the project settings ==="
# The project's settings at the working directory's git root set the quiet
# period. The default 900 keeps a ten-minute-old head silent; 60 reports it.
PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/sub"
git -C "$PROJECT" init -q
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
printf '[env]\nPR_REVIEW_WAIT_SECS = "60"\n' >"$PROJECT/kendex.settings.toml"
RECENT="$(date -u -d "@$((WATCH_NOW - 600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$((WATCH_NOW - 600))" +%Y-%m-%dT%H:%M:%SZ)"
RECENT_ENV="STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$RECENT"
table "outside a project the default quiet period holds a recent head silent||$RECENT_ENV|rc=0 kinds=none"
WATCH_CWD="$PROJECT/sub"
table "the project setting drives the clock from a subdirectory||$RECENT_ENV|rc=1 kinds=awaiting-stale"
mutant_watch settings-load 's#kendex_load_project_env "\$project_root" &&#: \&\&#' 'kendex_load_project_env "$project_root" &&'
table "must-fail: without the project load the default holds the head silent||$RECENT_ENV|rc=0 kinds=none"
WATCH_BIN="$LIVE_WATCH"
printf '[env]\nPR_REVIEW_WAIT_SECS = 60\n' >"$PROJECT/kendex.settings.toml"
table "an unreadable project setting refuses the pass||$RECENT_ENV|rc=2 kinds=none diagnostic=review-gate-error=watch-settings-unreadable+value=$PROJECT"
WATCH_CWD="$TMP_ROOT/cwd"

echo "=== a head commit that is not the PR's head ==="
# One read describes one moment; a push landing during it leaves the head
# commit read beside the PR on another sha. That is head-moved, never the
# disarmed or stale line the old head's state would give.
HEAD_AFTER="STUB_HEAD_AFTER=$HEAD_B"
table \
  "a head that moved during the reduction is head-moved||$HEAD_AFTER;STUB_OPEN_PRS=$P7|rc=1 kinds=head-moved protocol=7~aaaaaaaa~head-moved~the+head+changed+during+this+reduction+(now+bbbbbbbb)+—+findings+describe+the+old+head;+re-run" \
  "a moved head is no re-arm nudge||$HEAD_AFTER;STUB_OPEN_PRS=$P7U|rc=1 kinds=head-moved" \
  "a moved head is no stale-review nudge|--awaiting-after 60|$HEAD_AFTER;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=1 kinds=head-moved" \
  "an open thread on a moved head still reports the thread||$HEAD_AFTER;STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1|rc=1 kinds=threads-open"

echo '=== shared thread pages use the latest head and reviewability state ==='
PAGED="STUB_THREADS_PAGES=2"
table \
  "a push during pagination cannot return silence||$PAGED;STUB_OPEN_PRS=$P7;STUB_ROUND_HEAD=$HEAD_B|rc=1 kinds=head-moved" \
  "a push during pagination cannot re-arm the old head||$PAGED;STUB_OPEN_PRS=$P7U;STUB_ROUND_HEAD=$HEAD_B|rc=1 kinds=head-moved" \
  "a push during pagination cannot report the old head stale|--awaiting-after 60|$PAGED;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD;STUB_ROUND_HEAD=$HEAD_B|rc=1 kinds=head-moved" \
  "a current arm suppresses the earlier disarmed state||$PAGED;STUB_OPEN_PRS=$P7U;STUB_ROUND_ARMED=true|rc=0 kinds=none" \
  "a current disarm reports the latest merge ownership||$PAGED;STUB_OPEN_PRS=$P7;STUB_ROUND_ARMED=false|rc=1 kinds=disarmed" \
  "a PR closed during pagination needs no attention||$PAGED;STUB_OPEN_PRS=$P7U;STUB_ROUND_STATE=CLOSED|rc=0 kinds=none" \
  "a PR made draft during pagination gets no re-arm nudge||$PAGED;STUB_OPEN_PRS=$P7U;STUB_ROUND_DRAFT=true|rc=0 kinds=none" \
  "a PR made draft during pagination gets no stale nudge|--awaiting-after 60|$PAGED;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_ROUND_DRAFT=true|rc=0 kinds=none" \
  "a current queue entry suppresses the earlier disarmed state||$PAGED;STUB_OPEN_PRS=$P7U;STUB_ROUND_QUEUED=true|rc=0 kinds=none" \
  "the latest review decision reports a standing objection||$PAGED;STUB_OPEN_PRS=$P7;STUB_ROUND_DECISION=CHANGES_REQUESTED|rc=1 kinds=changes-requested" \
  "the latest queue state annotates the standing objection||$PAGED;STUB_OPEN_PRS=$P7;STUB_ROUND_DECISION=CHANGES_REQUESTED;STUB_ROUND_QUEUED=true|rc=1 kinds=changes-requested queued_notes=1" \
  "a missing current draft state fails loudly||$PAGED;STUB_OPEN_PRS=$P7;STUB_ROUND_DROP=isDraft|rc=2 kinds=error" \
  "a missing current review decision fails loudly||$PAGED;STUB_OPEN_PRS=$P7;STUB_ROUND_DROP=reviewDecision|rc=2 kinds=error" \
  "a malformed current head fails loudly||$PAGED;STUB_OPEN_PRS=$P7;STUB_ROUND_HEAD=not-a-sha|rc=2 kinds=error"

echo "=== lanes-app refresh approval attention ==="
# The watcher wakes the existing overseer approval route; it never approves.
# Actual REST identity and commit-bound check runs drive the real reducer.
REFRESH_ROW="$(pr_row 7 open armed false "$NOW" | jq -c '.head.ref="kendex/refresh" | .user={login:"vanillagreen-fleet-lanes[bot]",type:"Bot"}')"
REFRESH_PRS="[$REFRESH_ROW]"
CI_GREEN="$(jq -cn --arg head "$HEAD_A" '{check_runs:[{name:"CI",head_sha:$head,status:"completed",conclusion:"success"}]}')"
REFRESH_ENV="STUB_OPEN_PRS=$REFRESH_PRS;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$NOW;STUB_CI_RAW=$CI_GREEN"
# Fleet#1298: an armed force-pushed head, empty app suites and successful CI.
# Its suite-name-filtered GraphQL read returned no suites; the same head read
# without that filter returned CI. These responses came from the live API.
FLEET_HEAD=ed24149ea5bf4f1cc29eedd37c3dcf474be219c8
FLEET_ROW="$(jq -c --arg head "$FLEET_HEAD" '.number=1298 | .head.sha=$head' <<<"$REFRESH_ROW")"
FLEET_GREEN="$(jq -c --arg head "$FLEET_HEAD" '.check_runs[0].head_sha=$head' <<<"$CI_GREEN")"
FLEET_ENV="STUB_OPEN_PRS=[$FLEET_ROW];STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=2026-10-13T20:31:24Z;STUB_CI_SUITE_FILTER_EMPTY=yes"
for version in live base-query; do
  expected="rc=1 kinds=refresh-ready subjects=1298~ed24149e"
  if [[ "$version" == base-query ]]; then
    mutant_watch refresh-suite-filter 's#checkSuites(first:10)#checkSuites(first:10,filterBy:{checkName:"CI"})#' 'checkSuites(first:10)'
    expected="rc=0 kinds=none subjects=none"
  fi
  for mode in listing named paginated; do
    args=""
    pages=""
    case "$mode" in
      named) args=1298 ;;
      paginated) pages="STUB_THREADS_PAGES=2;" ;;
    esac
    table "fleet final head $version $mode|$args|$FLEET_ENV;${pages}STUB_CI_RAW={\"check_runs\":[]} {\"check_runs\":[]} {\"check_runs\":[]} {\"check_runs\":[]} $FLEET_GREEN|$expected"
  done
done
WATCH_BIN="$LIVE_WATCH"
table "a push during pagination cannot approve the old refresh head||$REFRESH_ENV;$PAGED;STUB_ROUND_HEAD=$HEAD_B|rc=1 kinds=head-moved"
table \
  "a fresh green refresh reports immediately|--awaiting-after 3600|$REFRESH_ENV|rc=1 kinds=refresh-ready" \
  "a pending refresh aggregate is silent|--awaiting-after 60|$REFRESH_ENV;STUB_HEAD_DATE=$OLD;STUB_CI_RAW=$(jq -c '.check_runs[0].status="in_progress" | .check_runs[0].conclusion=null' <<<"$CI_GREEN")|rc=0 kinds=none" \
  "a missing aggregate is silent|--awaiting-after 60|$REFRESH_ENV;STUB_HEAD_DATE=$OLD;STUB_CI_RAW={\"check_runs\":[]}|rc=0 kinds=none" \
  "a different check cannot act as the aggregate||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].name="build"' <<<"$CI_GREEN")|rc=0 kinds=none" \
  "a page after a passing aggregate can hold a failed aggregate||$REFRESH_ENV;STUB_CI_RAW=$CI_GREEN $(jq -c '.check_runs[0].conclusion="failure"' <<<"$CI_GREEN")|rc=0 kinds=none" \
  "an aggregate past one page fails loud||$REFRESH_ENV;STUB_CI_MORE=yes|rc=2 kinds=error" \
  "a malformed aggregate response fails loud||$REFRESH_ENV;STUB_CI_RAW={}|rc=2 kinds=error" \
  "an object instead of check-run array fails loud||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs={aggregate:.check_runs[0]}' <<<"$CI_GREEN")|rc=2 kinds=error" \
  "a non-string check status fails loud||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].status=false' <<<"$CI_GREEN")|rc=2 kinds=error" \
  "a check missing its conclusion fails loud||$REFRESH_ENV;STUB_CI_RAW=$(jq -c 'del(.check_runs[0].conclusion)' <<<"$CI_GREEN")|rc=2 kinds=error" \
  "a moved refresh head needs a new reduction||$REFRESH_ENV;$HEAD_AFTER|rc=1 kinds=head-moved" \
  "an approved refresh gets no approval attention||$REFRESH_ENV;STUB_DECISION=APPROVED|rc=0 kinds=none" \
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
# disarmed never on a null decision, and awaiting-stale in both directions;
# head-moved compares the head commit with the PR's head.
mutant_watch round-retained-head 's#else $initial.headRefOid as $head#else $p.headRefOid as $head#' 'else $initial.headRefOid as $head'
table "must-fail: forgetting the initial head hides a paginated push||$PAGED;STUB_OPEN_PRS=$P7;STUB_ROUND_HEAD=$HEAD_B|rc=0 kinds=none"
mutant_watch round-retained-state 's#else $last.p + {reviewThreads: $initial.reviewThreads} end)#else $initial end)#' 'else $last.p + {reviewThreads: $initial.reviewThreads} end)'
table "must-fail: retaining the initial reviewability state re-arms an already armed PR||$PAGED;STUB_OPEN_PRS=$P7U;STUB_ROUND_ARMED=true|rc=1 kinds=disarmed"
mutant_watch threads-count 's#select(.isResolved == false)#select(.isResolved == null)#' 'select(.isResolved == false)'
table "must-fail: with unresolved nodes uncounted two open threads read as silence||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=2|rc=0 kinds=none"

mutant_watch changes-decision 's#if $decision == "CHANGES_REQUESTED" then#if $decision == "CHANGES_UNREAD" then#' 'if $decision == "CHANGES_REQUESTED" then'
table "must-fail: with CHANGES_REQUESTED unread a standing objection reads as silence||STUB_OPEN_PRS=$P7;STUB_DECISION=CHANGES_REQUESTED|rc=0 kinds=none"

mutant_watch disarmed-approval 's#elif $decision == "APPROVED" and#elif true and#' 'elif $decision == "APPROVED" and'
table "must-fail: without the approval an unapproved unarmed PR nudges|--awaiting-after 3600|STUB_OPEN_PRS=$P7U;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$NOW|rc=1 kinds=disarmed"

mutant_watch disarmed-null 's#($p.reviewDecision // "NONE")#($p.reviewDecision // "APPROVED")#' '($p.reviewDecision // "NONE")'
table "must-fail: with a null decision read as approval an unreviewed PR nudges||STUB_OPEN_PRS=$P7U;STUB_DECISION=null|rc=1 kinds=disarmed"

STALE_RULE='elif $decision == "REVIEW_REQUIRED" and ($p.isDraft | not) and ($refresh | not)'
mutant_watch awaiting-unread 's#elif $decision == "REVIEW_REQUIRED" and (\$p.isDraft | not) and (\$refresh | not)#elif $decision == "REVIEW_UNREAD"#' "$STALE_RULE"
table "must-fail: with REVIEW_REQUIRED unread an old unapproved head reads as silence|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=0 kinds=none"

mutant_watch awaiting-any 's#elif $decision == "REVIEW_REQUIRED" and (\$p.isDraft | not) and (\$refresh | not)#elif $decision != "CHANGES_REQUESTED"#' "$STALE_RULE"
table \
  "must-fail: with any decision starting the clock an approved old head reads stale|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale" \
  "must-fail: with any decision starting the clock a null decision on an old head reads stale|--awaiting-after 60|STUB_OPEN_PRS=$P7U;STUB_DECISION=null;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale"

mutant_watch head-compare 's#elif $commit.oid != $head#elif false#' 'elif $commit.oid != $head'
table \
  "must-fail: without the head comparison a moved head reads as silence||$HEAD_AFTER;STUB_OPEN_PRS=$P7|rc=0 kinds=none" \
  "must-fail: without the head comparison a moved refresh head reports stale green CI||$REFRESH_ENV;$HEAD_AFTER|rc=1 kinds=refresh-ready"

mutant_watch refresh-branch 's#\.head.ref == "kendex/refresh"#true#' '.head.ref == "kendex/refresh"' lib/refresh-identity.sh
table "must-fail: removing the exact branch check reports a product branch||$REFRESH_ENV;STUB_OPEN_PRS=[$(jq -c '.head.ref="product"' <<<"$REFRESH_ROW")]|rc=1 kinds=refresh-ready"
mutant_watch refresh-author 's#\.user.login == "vanillagreen-fleet-lanes\[bot\]"#true#' '.user.login == "vanillagreen-fleet-lanes[bot]"' lib/refresh-identity.sh
table "must-fail: removing the app login check reports another author||$REFRESH_ENV;STUB_OPEN_PRS=[$(jq -c '.user.login="another[bot]"' <<<"$REFRESH_ROW")]|rc=1 kinds=refresh-ready"
mutant_watch refresh-type 's#\.user.type == "Bot"#true#' '.user.type == "Bot"' lib/refresh-identity.sh
table "must-fail: removing the Bot type check reports a user identity||$REFRESH_ENV;STUB_OPEN_PRS=[$(jq -c '.user.type="User"' <<<"$REFRESH_ROW")]|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-status 's#\.status == "COMPLETED"#true#' '.status == "COMPLETED"'
table "must-fail: removing completion reports running CI||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].status="in_progress"' <<<"$CI_GREEN")|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-conclusion 's#\.conclusion == "SUCCESS"#true#' '.conclusion == "SUCCESS"'
table "must-fail: removing success reports failed CI||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].conclusion="failure"' <<<"$CI_GREEN")|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-present 's#(\$ci | length) > 0#true#' '($ci | length) > 0'
table "must-fail: removing aggregate presence reports absent CI||$REFRESH_ENV;STUB_CI_RAW={\"check_runs\":[]}|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-name 's#select(.name == "CI")#select(.name != "CI")#' 'select(.name == "CI")'
table "must-fail: accepting another name reports a build check||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].name="build"' <<<"$CI_GREEN")|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-envelope 's#(.checkRuns.nodes | type) != "array"#false#' '(.checkRuns.nodes | type) != "array"'
table "must-fail: ignoring the container schema accepts an object||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs={aggregate:.check_runs[0]}' <<<"$CI_GREEN")|rc=1 kinds=refresh-ready"
mutant_watch refresh-ci-node 's#(.status | type) != "string"#false#' '(.status | type) != "string"'
table "must-fail: ignoring the node schema loses malformed-status attention||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].status=false' <<<"$CI_GREEN")|rc=0 kinds=none"
mutant_watch refresh-ci-page 's#elif $s.pageInfo.hasNextPage or#elif false and#' 'elif $s.pageInfo.hasNextPage or'
table "must-fail: ignoring a further page reads the first page's green as the aggregate||$REFRESH_ENV;STUB_CI_MORE=yes|rc=1 kinds=refresh-ready"
REFRESH_RULE='if $refresh and ($p.isDraft | not) and $decision == "REVIEW_REQUIRED"'
mutant_watch refresh-draft 's#if $refresh and (\$p.isDraft | not) and#if $refresh and#' "$REFRESH_RULE"
table "must-fail: ignoring the draft state reports a draft||$REFRESH_ENV;STUB_OPEN_PRS=[$(jq -c '.draft=true' <<<"$REFRESH_ROW")]|rc=1 kinds=refresh-ready"
mutant_watch refresh-review 's#if $refresh and (\$p.isDraft | not) and $decision == "REVIEW_REQUIRED"#if $refresh and ($p.isDraft | not)#' "$REFRESH_RULE"
table "must-fail: ignoring the decision reports an already approved PR||$REFRESH_ENV;STUB_DECISION=APPROVED|rc=1 kinds=refresh-ready"
WATCH_BIN="$LIVE_WATCH"


echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
