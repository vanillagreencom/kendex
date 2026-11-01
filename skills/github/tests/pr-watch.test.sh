#!/usr/bin/env bash
# Behavioral tests for the watcher reduction surface.
# Stdout attention records are the whole-text protocol read by orch.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/lib/pr-watch-fixture.sh"

# Keep the repository queue independent of the PR fields in this fixture.
mv "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/gh-response"
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$args" == *'--input -'* ]]; then
  request="$(cat)"
  args="$request"
  answer="$("${BASH_SOURCE[0]%/*}/gh-response" "$@" <<<"$request")" || exit "$?"
else
  answer="$("${BASH_SOURCE[0]%/*}/gh-response" "$@")" || exit "$?"
fi
if [[ "$args" == *'mergeQueue{'* ]]; then
  printf '%s\n' "$answer" | jq -c '
    .data.repository.mergeQueue =
      (if $ENV.STUB_REPO_QUEUE then $ENV.STUB_REPO_QUEUE | fromjson else null end)'
else
  printf '%s\n' "$answer"
fi
EOF
chmod +x "$TMP_ROOT/bin/gh"

P7U="$(jq -cn --argjson r "$(pr_row 7 open unarmed)" '[$r]')"
P7UD="$(jq -cn --argjson r "$(pr_row 7 open unarmed true)" '[$r]')"
P7AD="$(jq -cn --argjson r "$(pr_row 7 open armed true)" '[$r]')"
P7NEW="$(jq -cn --argjson r "$(pr_row 7 open armed false "$NOW")" '[$r]')"
T_STUCK='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"isResolved":false}]}}}}}'
T_PAGE1='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"isResolved":true},{"isResolved":true}]}}}}}'
T_PAGE2_OPEN='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false}]}}}}}'
T_PAGE2_RESOLVED='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":true}]}}}}}'

echo "=== the reduction over threads, reviewDecision, arming and queue membership ==="
# A healthy PR is silence. Every finding is its own line read from GitHub:
# an open thread and a standing objection both report, while an open thread
# holds the re-arm and stale-review nudges until it is answered.
table \
  "approved and armed: silence||STUB_OPEN_PRS=$P7|rc=0 kinds=none" \
  "threads-open carries the count||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=2|rc=1 kinds=threads-open threads=2 subjects=7~aaaaaaaa" \
  "threads-open on a queued PR carries the dequeue note||STUB_QUEUED=yes;STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1|rc=1 kinds=threads-open queued_notes=1" \
  "changes-requested is read from reviewDecision||STUB_OPEN_PRS=$P7;STUB_DECISION=CHANGES_REQUESTED|rc=1 kinds=changes-requested subjects=7~aaaaaaaa" \
  "open threads do not suppress a standing objection||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1;STUB_DECISION=CHANGES_REQUESTED|rc=1 kinds=threads-open,changes-requested" \
  "queued lines all carry the dequeue note||STUB_QUEUED=yes;STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1;STUB_DECISION=CHANGES_REQUESTED|rc=1 queued_notes=2" \
  "approved, not armed, not queued: disarmed||STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed subjects=7~aaaaaaaa" \
  "a null decision is no approval: an unarmed PR is never disarmed||STUB_OPEN_PRS=$P7U;STUB_DECISION=null|rc=0 kinds=none" \
  "a null decision is never awaiting-stale|--awaiting-after 60|STUB_OPEN_PRS=$P7U;STUB_DECISION=null;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "the same shape queued: the queue owns the merge||STUB_QUEUED=yes;STUB_OPEN_PRS=$P7U|rc=0 kinds=none" \
  "a draft never gets the disarmed nag||STUB_OPEN_PRS=$P7UD|rc=0 kinds=none" \
  "an open thread holds the re-arm nudge||STUB_OPEN_PRS=$P7U;STUB_UNRESOLVED=2|rc=1 kinds=threads-open" \
  "an unapproved PR is never disarmed|--awaiting-after 3600|STUB_OPEN_PRS=$P7U;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$NOW|rc=0 kinds=none" \
  "an open thread holds the stale-review nudge|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=1 kinds=threads-open" \
  "an approved PR is never awaiting-stale|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_HEAD_DATE=$OLD|rc=0 kinds=none"

echo '=== repository queue confirms a disarmed candidate ==='
REPO_QUEUED='{"entries":{"pageInfo":{"hasNextPage":false},"nodes":[{"pullRequest":{"number":7}}]}}'
REPO_EMPTY='{"entries":{"pageInfo":{"hasNextPage":false},"nodes":[]}}'
QUEUE_RACE="STUB_OPEN_PRS=$P7U;STUB_REPO_QUEUE=$REPO_QUEUED"
QUEUE_CI_RED='{"check_runs":[{"name":"CI","status":"completed","conclusion":"failure"}]}'
for mode in listing named paginated; do
  flags="" pages=""
  case "$mode" in
    named) flags=7 ;;
    paginated) pages=';STUB_THREADS_PAGES=2' ;;
  esac
  table \
    "repository queue suppresses false disarmed: $mode|$flags|$QUEUE_RACE$pages|rc=0 kinds=none" \
    "repository queue reports failed current-head CI: $mode|$flags|$QUEUE_RACE;STUB_CI_RAW=$QUEUE_CI_RED$pages|rc=1 kinds=ci-failed subjects=7~aaaaaaaa queued_notes=1" \
    "repository queue annotates CI and objections: $mode|$flags|$QUEUE_RACE;STUB_CI_RAW=$QUEUE_CI_RED;STUB_DECISION=CHANGES_REQUESTED$pages|rc=1 kinds=ci-failed,changes-requested queued_notes=2" \
    "absent from both views stays disarmed: $mode|$flags|STUB_OPEN_PRS=$P7U;STUB_REPO_QUEUE=$REPO_EMPTY$pages|rc=1 kinds=disarmed"
done
table \
  "unreadable queue is no confirmed disarm||STUB_OPEN_PRS=$P7U;STUB_REPO_QUEUE={};STUB_CI_RAW=$QUEUE_CI_RED|rc=2 kinds=error" \
  "an incomplete queue cannot confirm absence||STUB_OPEN_PRS=$P7U;STUB_REPO_QUEUE=$(jq -c '.entries.pageInfo.hasNextPage=true' <<<"$REPO_EMPTY");STUB_CI_RAW=$QUEUE_CI_RED|rc=2 kinds=error" \
  "membership is known even on an incomplete queue||$QUEUE_RACE;STUB_REPO_QUEUE=$(jq -c '.entries.pageInfo.hasNextPage=true' <<<"$REPO_QUEUED");STUB_CI_RAW=$QUEUE_CI_RED|rc=1 kinds=ci-failed queued_notes=1"
mutant_watch repository-queue-member 's#elif any($entries.nodes\[\]?; .pullRequest.number == $n) then {member: true}#elif false then {member: true}#' 'elif any($entries.nodes[]?; .pullRequest.number == $n) then {member: true}'
table "must-fail: ignoring the repository queue loses CI and repeats the false disarm||$QUEUE_RACE;STUB_CI_RAW=$QUEUE_CI_RED|rc=1 kinds=disarmed"
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
printf '[env]\nPR_REVIEW_WAIT_SECS = 60\n' >"$PROJECT/kendex.settings.toml"
table "an unreadable project setting refuses the pass||$RECENT_ENV|rc=2 kinds=none diagnostic=review-gate-error=watch-settings-unreadable+value=$PROJECT"
WATCH_CWD="$TMP_ROOT/cwd"

echo "=== a head commit that is not the PR's head ==="
# One read describes one moment; a push landing during it leaves the head
# commit read beside the PR on another sha. That is head-moved, never the
# disarmed or stale line the old head's state would give.
HEAD_AFTER="STUB_HEAD_AFTER=$HEAD_B"
table \
  "a head that moved during the reduction is head-moved||$HEAD_AFTER;STUB_OPEN_PRS=$P7|rc=1 kinds=head-moved subjects=7~aaaaaaaa" \
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
for mode in listing named paginated; do
  args=""
  pages=""
  case "$mode" in
    named) args=1298 ;;
    paginated) pages="STUB_THREADS_PAGES=2;" ;;
  esac
  table "fleet final head $mode|$args|$FLEET_ENV;${pages}STUB_CI_RAW={\"check_runs\":[]} {\"check_runs\":[]} {\"check_runs\":[]} {\"check_runs\":[]} $FLEET_GREEN|rc=1 kinds=refresh-ready subjects=1298~ed24149e"
done
table "a push during pagination cannot approve the old refresh head||$REFRESH_ENV;$PAGED;STUB_ROUND_HEAD=$HEAD_B|rc=1 kinds=head-moved"
table \
  "a fresh green refresh reports immediately|--awaiting-after 3600|$REFRESH_ENV|rc=1 kinds=refresh-ready" \
  "a pending refresh aggregate is silent|--awaiting-after 60|$REFRESH_ENV;STUB_HEAD_DATE=$OLD;STUB_CI_RAW=$(jq -c '.check_runs[0].status="in_progress" | .check_runs[0].conclusion=null' <<<"$CI_GREEN")|rc=0 kinds=none" \
  "a missing aggregate is silent|--awaiting-after 60|$REFRESH_ENV;STUB_HEAD_DATE=$OLD;STUB_CI_RAW={\"check_runs\":[]}|rc=0 kinds=none" \
  "a different check cannot act as the aggregate||$REFRESH_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].name="build"' <<<"$CI_GREEN")|rc=0 kinds=none" \
  "a page after a passing aggregate can hold a failed aggregate||$REFRESH_ENV;STUB_CI_RAW=$CI_GREEN $(jq -c '.check_runs[0].conclusion="failure"' <<<"$CI_GREEN")|rc=1 kinds=ci-failed" \
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
for conclusion in cancelled skipped neutral action_required stale; do
  table "aggregate $conclusion grants no refresh attention||$REFRESH_ENV;STUB_CI_RAW=$(jq -c --arg c "$conclusion" '.check_runs[0].conclusion=$c' <<<"$CI_GREEN")|rc=0 kinds=none"
done
CI_RED="$(jq -c '.check_runs[0].conclusion="failure"' <<<"$CI_GREEN")"
ARMED_ENV="STUB_OPEN_PRS=$P7;STUB_CI_RAW=$CI_RED"
for conclusion in failure timed_out startup_failure; do
  failed="$(jq -c --arg c "$conclusion" '.check_runs[0].conclusion=$c' <<<"$CI_GREEN")"
  table \
    "refresh aggregate $conclusion reports its current head||$REFRESH_ENV;STUB_CI_RAW=$failed|rc=1 kinds=ci-failed subjects=7~aaaaaaaa" \
    "armed aggregate $conclusion reports its current head||$ARMED_ENV;STUB_CI_RAW=$failed|rc=1 kinds=ci-failed subjects=7~aaaaaaaa" \
    "queued aggregate $conclusion reports its current head||$ARMED_ENV;STUB_OPEN_PRS=$P7U;STUB_QUEUED=yes;STUB_CI_RAW=$failed|rc=1 kinds=ci-failed queued_notes=1"
done
table \
  "a failed approved refresh reports CI without approval attention||$REFRESH_ENV;STUB_CI_RAW=$CI_RED;STUB_DECISION=APPROVED|rc=1 kinds=ci-failed" \
  "failed CI reports beside open threads and objections||$REFRESH_ENV;STUB_CI_RAW=$CI_RED;STUB_UNRESOLVED=1;STUB_DECISION=CHANGES_REQUESTED|rc=1 kinds=threads-open,ci-failed,changes-requested" \
  "a moved failing refresh head reports no old CI||$REFRESH_ENV;STUB_CI_RAW=$CI_RED;$HEAD_AFTER|rc=1 kinds=head-moved" \
  "a moved armed head during pagination reports no old CI||$ARMED_ENV;$PAGED;STUB_ROUND_HEAD=$HEAD_B|rc=1 kinds=head-moved" \
  "a failed draft refresh is silent||$REFRESH_ENV;STUB_CI_RAW=$CI_RED;STUB_OPEN_PRS=[$(jq -c '.draft=true' <<<"$REFRESH_ROW")]|rc=0 kinds=none" \
  "a failed armed draft is silent||$ARMED_ENV;STUB_OPEN_PRS=$P7AD|rc=0 kinds=none" \
  "an unarmed failed approved PR keeps its disarmed line||$ARMED_ENV;STUB_OPEN_PRS=$P7U|rc=1 kinds=disarmed" \
  "armed green CI is silent||$ARMED_ENV;STUB_CI_RAW=$CI_GREEN|rc=0 kinds=none" \
  "armed pending CI is silent||$ARMED_ENV;STUB_CI_RAW=$(jq -c '.check_runs[0].status="in_progress"' <<<"$CI_RED")|rc=0 kinds=none" \
  "armed malformed CI keeps its silence||$ARMED_ENV;STUB_CI_RAW={}|rc=0 kinds=none" \
  "armed CI past one page keeps its silence||$ARMED_ENV;STUB_CI_MORE=yes|rc=0 kinds=none"
for conclusion in cancelled skipped neutral action_required stale; do
  table "armed aggregate $conclusion is silent||$ARMED_ENV;STUB_CI_RAW=$(jq -c --arg c "$conclusion" '.check_runs[0].conclusion=$c' <<<"$CI_GREEN")|rc=0 kinds=none"
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



echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
