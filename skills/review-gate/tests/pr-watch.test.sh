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
P78="$(jq -cn --argjson a "$(pr_row 7)" --argjson b "$(pr_row 8)" '[$a,$b]')"
P7NEW="$(jq -cn --argjson r "$(pr_row 7 open armed false "$NOW")" '[$r]')"
V_THREADS1='verdict=threads-open detail=1 unresolved review threads'
V_THREADS2='verdict=threads-open detail=2 unresolved review threads'
V_CHANGES='verdict=changes-requested detail=reviewer objects'
V_OFF='verdict=approved detail=review gate disabled by settings (REVIEW_GATE_MODE=off)'
V_UNTRACKED='verdict=untracked-claim detail=1 tracking claim naming no issue'
V_UNREASONED='verdict=unreasoned-decline detail=1 decline naming no mechanism'
V_SUPPRESSED='verdict=suppressed-findings detail=2 suppressed findings in a review body: src/a.ts:106'
T_STUCK='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"isResolved":false}]}}}}}'
T_PAGE1='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"isResolved":true},{"isResolved":true}]}}}}}'
T_PAGE2_OPEN='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false}]}}}}}'
T_PAGE2_RESOLVED='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":true}]}}}}}'

echo "=== the reduction over verdict, gate state, arming and queue membership ==="
# A healthy PR is silence. Threads are read directly in both modes, so a
# repo whose predicate ignores them still reports them; a verdict and a gate
# state that disagree are gate-stale in either direction and --heal
# dispatches the writer once per invocation, a failed dispatch included.
# Every finding is its own line, none eats another, and duplicates dedupe.
table \
  "approved, gate success, armed: silence||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=0 kinds=none" \
  "threads-open carries the count||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_THREADS2|rc=1 kinds=threads-open threads=2 protocol=7~aaaaaaaa~threads-open~2+unresolved+review+threads" \
  "threads-open on a queued PR carries the dequeue note||STUB_QUEUED=yes;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_THREADS1|rc=1 kinds=threads-open queued_notes=1" \
  "changes-requested||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_CHANGES|rc=1 kinds=changes-requested protocol=7~aaaaaaaa~changes-requested~reviewer+objects" \
  "approved over a pending gate is gate-stale||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_PENDING|rc=1 kinds=gate-stale" \
  "--heal dispatches the writer once across two stale PRs|--heal|STUB_OPEN_PRS=$P78;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_PENDING|rc=1 kinds=gate-stale,heal-dispatched,gate-stale dispatches=1" \
  "a failed dispatch still consumes the one attempt|--heal|STUB_DISPATCH_FAIL=yes;STUB_OPEN_PRS=$P78;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_PENDING|rc=2 kinds=gate-stale,error,gate-stale dispatches=1" \
  "awaiting over a green gate is gate-stale and heals|--heal --awaiting-after 3600|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_GATE_HISTORY=$G_OK;STUB_HEAD_DATE=$NOW|rc=1 kinds=gate-stale,heal-dispatched dispatches=1" \
  "an objection over a green gate reports both||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_CHANGES;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=changes-requested,gate-stale" \
  "queued lines all carry the dequeue note||STUB_QUEUED=yes;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_CHANGES;STUB_GATE_HISTORY=$G_OK|rc=1 queued_notes=2" \
  "approved, gate success, not armed, not queued: disarmed||STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed" \
  "the same shape queued: the queue owns the merge||STUB_QUEUED=yes;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=0 kinds=none" \
  "a draft never gets the disarmed nag||STUB_OPEN_PRS=$P7UD;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=0 kinds=none" \
  "threads are read directly even under an approved verdict||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=2;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=threads-open,gate-stale threads=2" \
  "open threads do not suppress a standing objection||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1;STUB_VERDICT_LINE=$V_CHANGES|rc=1 kinds=threads-open,changes-requested" \
  "the predicate's duplicate threads-open verdict dedupes||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1;STUB_VERDICT_LINE=$V_THREADS1|rc=1 kinds=threads-open" \
  "the predicate's paging-race threads verdict heals a green gate|--heal|STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=0;STUB_VERDICT_LINE=$V_THREADS1;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=threads-open,gate-stale,heal-dispatched dispatches=1" \
  "cheap mode reports threads by direct read and never consults the predicate|--no-evaluate|STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=3;STUB_VERDICT_LINE=unused|rc=1 kinds=threads-open threads=3 predicate_calls=0" \
  "cheap mode still emits disarmed|--no-evaluate|STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=unused;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed" \
  "cheap mode fires the threads-driven gate-stale and heals|--no-evaluate --heal|STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=1;STUB_VERDICT_LINE=unused;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=threads-open,gate-stale,heal-dispatched dispatches=1" \
  "REVIEW_GATE_THREADS=off: threads report, a green gate over them is designed|--heal|REVIEW_GATE_THREADS=off;STUB_QUEUED=no;STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=2;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=threads-open dispatches=0" \
  "REVIEW_GATE_MODE=off: the same|--heal|REVIEW_GATE_MODE=off;STUB_QUEUED=no;STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=2;STUB_VERDICT_LINE=$V_OFF;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=threads-open dispatches=0" \
  "REVIEW_GATE_THREADS=off: open threads do not eat the disarmed finding||REVIEW_GATE_THREADS=off;STUB_OPEN_PRS=$P7U;STUB_UNRESOLVED=2;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=threads-open,disarmed"

echo "=== the disarmed line carries the submit-size record ==="
# branch-size-check records the branch's measured size at submit, keyed by the
# lane's branch and bound to the head it compared; the reducer reads that
# record and never re-measures. Both disarmed paths carry it, a record of any
# other head reads stale rather than as this head's size, and a state
# directory holding only another lane's record leaves this one unavailable.
table \
  "the evaluated disarmed line carries the counts and their ratio||ORCH_STATE_DIR=$SD_CURRENT;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa" \
  "cheap mode's disarmed line carries the same annotation|--no-evaluate|ORCH_STATE_DIR=$SD_CURRENT;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=unused;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa" \
  "a record of another head reads stale, never as this head's size||ORCH_STATE_DIR=$SD_STALE;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=stale@bbbbbbbb" \
  "another lane's record leaves this branch unavailable||ORCH_STATE_DIR=$SD_OTHER;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=unavailable" \
  "no state directory at all is unavailable||ORCH_STATE_DIR=$TMP_ROOT/state/absent;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=unavailable" \
  "a record stating no allowance reports the count and no ratio||ORCH_STATE_DIR=$SD_NOALLOW;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/none@aaaaaaaa" \
  "a stated allowance of zero is reported as the number it is||ORCH_STATE_DIR=$SD_ZERO;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=5/0@aaaaaaaa!production_over" \
  "a test-allowance breach is named, not hidden by a clean ratio||ORCH_STATE_DIR=$SD_TESTSOVER;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa!tests_over" \
  "a PR row with no head ref keys nothing and reads unavailable||ORCH_STATE_DIR=$SD_NOBRANCH;STUB_OPEN_PRS=$P7UNOREF;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=unavailable"

echo "=== must-fail controls for the surfaces above ==="
# Each control fails against a copy of the reducer with the one expression it
# depends on removed: the call at each disarmed site, the head binding that
# makes a record current, the branch binding that makes it this lane's, and
# the guard that stops an empty branch from keying the lookup at all.
mutant_watch() { # label, sed-expr, anchor — points WATCH_BIN at the mutated copy
  local dir="$TMP_ROOT/mutants/$1"
  mkdir -p "$dir/lib"
  cp "$TMP_ROOT/scripts/pr-watch.sh" "$TMP_ROOT/scripts/review-predicate.sh" "$dir/"
  cp "$TMP_ROOT/scripts/lib/settings.sh" "$TMP_ROOT/scripts/lib/diagnostics.sh" "$dir/lib/"
  chmod +x "$dir/pr-watch.sh" "$dir/review-predicate.sh"
  assert_eq "$(grep -Fc -- "$3" "$dir/pr-watch.sh")" "1" "mutant $1: its anchor stands once in the live script"
  sed -i.bak "$2" "$dir/pr-watch.sh"
  assert_eq "$(grep -Fc -- "$3" "$dir/pr-watch.sh")" "0" "mutant $1: the anchor is gone from the copy"
  WATCH_BIN="$dir/pr-watch.sh"
}
LIVE_WATCH="$WATCH_BIN"

mutant_watch evaluated-call 's|(re-arm)$(size_note "$head_ref" "$head")|(re-arm)|' '(re-arm)$(size_note'
table "must-fail: without the evaluated site's call that line carries no size||ORCH_STATE_DIR=$SD_CURRENT;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=none"

mutant_watch cheap-call 's|before re-arming$(size_note "$head_ref" "$head")|before re-arming|' 'before re-arming$(size_note'
table "must-fail: without the cheap site's call that line carries no size|--no-evaluate|ORCH_STATE_DIR=$SD_CURRENT;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=unused;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=none"

mutant_watch head-binding 's#map(select(.head_sha == $head)) | first#first#' 'map(select(.head_sha == $head)) | first'
table "must-fail: without the head binding the old record reads as current||ORCH_STATE_DIR=$SD_STALE;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/250/85%@bbbbbbbb"

mutant_watch branch-binding 's#(.branch? // "") == $branch#true#' '(.branch? // "") == $branch'
table "must-fail: without the branch binding another lane's record is reported||ORCH_STATE_DIR=$SD_OTHER;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa"

mutant_watch empty-branch-guard 's#if \[ -n "$branch" \]; then#if true; then#' 'if [ -n "$branch" ]; then'
table "must-fail: without the empty-branch guard a branchless lane's record is reported||ORCH_STATE_DIR=$SD_NOBRANCH;STUB_OPEN_PRS=$P7UNOREF;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed size=214/250/85%@aaaaaaaa"

WATCH_BIN="$LIVE_WATCH"

echo "=== the predicate's disposition verdicts reach the reducer ==="
# The disposition and review-body verdicts the predicate can return, driven
# through the reducer arm that consumes each. unreasoned-decline.test.sh decides both
# terms and stops at the count; these rows are the other half — the verdict
# named in the kind column, the attention exit, the stale-green companion a
# green gate over either verdict earns, and the writer dispatch --heal makes
# of it. A presence grep on the arm stood in for these rows until the suite
# they belong beside stopped being size-capped; a grep passes on a branch
# nothing runs.
table \
  "unreasoned-decline is its own kind and its own attention||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_UNREASONED;STUB_GATE_HISTORY=$G_PENDING|rc=1 kinds=unreasoned-decline protocol=7~aaaaaaaa~unreasoned-decline~1+decline+naming+no+mechanism" \
  "a green gate over it is gate-stale and --heal dispatches the writer at it|--heal|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_UNREASONED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=unreasoned-decline,gate-stale,heal-dispatched dispatches=1" \
  "untracked-claim is its own kind and its own attention||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_UNTRACKED;STUB_GATE_HISTORY=$G_PENDING|rc=1 kinds=untracked-claim protocol=7~aaaaaaaa~untracked-claim~1+tracking+claim+naming+no+issue" \
  "a green gate over it is gate-stale and heals the same way|--heal|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_UNTRACKED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=untracked-claim,gate-stale,heal-dispatched dispatches=1" \
  "suppressed-findings is its own kind, carrying the count and the file:line||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_SUPPRESSED;STUB_GATE_HISTORY=$G_PENDING|rc=1 kinds=suppressed-findings protocol=7~aaaaaaaa~suppressed-findings~2+suppressed+findings+in+a+review+body:+src/a.ts:106" \
  "a green gate over a suppressed block is gate-stale and heals the same way|--heal|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_SUPPRESSED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=suppressed-findings,gate-stale,heal-dispatched dispatches=1"

# The rows above read a kind column, and a column can be right for the wrong
# reason: the predicate's verdict word is in the stubbed input, so a reducer
# that echoed its input would satisfy them. With the kind the unreasoned arm
# emits misspelled, the first row must read the misspelling and nothing else
# about the run may move.
mutant_watch emitted-kind 's| unreasoned-decline "$detail$queued"| unreasoned-declined "$detail$queued"|' ' unreasoned-decline "$detail$queued"'
table "must-fail: with the emitted kind misspelled the row reads the misspelling||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_UNREASONED;STUB_GATE_HISTORY=$G_PENDING|rc=1 kinds=unreasoned-declined"
WATCH_BIN="$LIVE_WATCH"

echo "=== the thread walk is paged, summed and bounded ==="
# Over 100 threads, a cursor that never advances, or more than 20 advancing
# pages fail closed as overflow attention; a thread on page two is counted;
# resolved history across pages, 20 pages included, is healthy. Open threads
# under an approved verdict also make the (absent or green) gate stale.
table \
  "over 100 threads is overflow||STUB_OPEN_PRS=$P7;STUB_UNRESOLVED=100;STUB_THREADS_NEXTPAGE=true;STUB_VERDICT_LINE=$V_APPROVED|rc=1 kinds=threads-open,gate-stale threads=overflow" \
  "a cursor that never advances is overflow at the bound||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_STUCK;STUB_VERDICT_LINE=$V_APPROVED|rc=1 kinds=threads-open,gate-stale threads=overflow" \
  "an unresolved thread on page two is counted||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_PAGE1;STUB_THREADS_PAGE2=$T_PAGE2_OPEN;STUB_VERDICT_LINE=$V_APPROVED|rc=1 kinds=threads-open,gate-stale threads=1" \
  "resolved history across pages is healthy||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_PAGE1;STUB_THREADS_PAGE2=$T_PAGE2_RESOLVED;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=0 kinds=none" \
  "25 advancing resolved pages breach the budget: overflow||STUB_OPEN_PRS=$P7;STUB_THREADS_PAGES=25;STUB_VERDICT_LINE=$V_APPROVED|rc=1 kinds=threads-open,gate-stale threads=overflow" \
  "exactly 20 advancing resolved pages are healthy||STUB_OPEN_PRS=$P7;STUB_THREADS_PAGES=20;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=0 kinds=none"

echo "=== the reviewer-silence clock ==="
# Awaiting is stale only past the quiet period, measured from the newest of
# the head commit, the PR's creation, and a readiness, reopen or re-review
# event; drafts are never nagged. PR_REVIEW_WAIT_SECS drives the same clock
# as --awaiting-after, and a zero-padded value is judged by magnitude.
table \
  "a head younger than the threshold is silent|--awaiting-after 3600|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$NOW|rc=0 kinds=none" \
  "a head older than the threshold is awaiting-stale|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale" \
  "PR_REVIEW_WAIT_SECS drives the same clock||PR_REVIEW_WAIT_SECS=60;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale" \
  "a zero-padded --awaiting-after is judged by magnitude|--awaiting-after 0000000000060|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=1 kinds=awaiting-stale" \
  "an old commit in a fresh PR is not stale: creation floors the clock|--awaiting-after 3600|STUB_OPEN_PRS=$P7NEW;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "an old draft is not awaiting-stale|--awaiting-after 60|STUB_OPEN_PRS=$P7AD;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "a fresh ready_for_review restarts the quiet period|--awaiting-after 3600|STUB_READY_AT=$NOW;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "a fresh reopen restarts the quiet period|--awaiting-after 3600|STUB_REOPENED_AT=$NOW;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=0 kinds=none" \
  "a fresh re-review request restarts the quiet period|--awaiting-after 3600|STUB_REREQUEST_AT=$NOW;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=0 kinds=none"

echo "=== a head that moves or a PR that changes mid-reduction ==="
# The just-in-time recheck: a moved head is attention, a disarm is caught, a
# close silences the re-arm nudge, a draft conversion skips only the nudge.
table \
  "a head that moved during the reduction is head-moved||STUB_HEAD_AFTER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=head-moved" \
  "a mid-reduction disarm is caught||STUB_ARMED_AFTER=false;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=1 kinds=disarmed" \
  "a mid-reduction close gets no re-arm nudge||STUB_CLOSED_AFTER=yes;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=0 kinds=none" \
  "a mid-reduction draft conversion skips only the nudge|--heal --awaiting-after 3600|STUB_DRAFT_AFTER=yes;STUB_OPEN_PRS=$P7U;STUB_VERDICT_LINE=$V_AWAITING;STUB_GATE_HISTORY=$G_OK;STUB_HEAD_DATE=$NOW|rc=1 kinds=gate-stale,heal-dispatched"


echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
