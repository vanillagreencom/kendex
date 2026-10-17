#!/usr/bin/env bash
# Behavioral tests for the watcher input validation surface.
# Stdout attention records are the whole-text protocol read by orch.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/lib/pr-watch-fixture.sh"

for lib in refresh-identity kendex-env; do
  mv "$TMP_ROOT/scripts/lib/$lib.sh" "$TMP_ROOT/$lib.sh"
  run_watch '' --help
  assert_eq "$RC" 2 "a missing lib/$lib.sh refuses watcher startup"
  assert_eq "$(sed -n 's/^review-gate-error=\([^ ]*\) value=.*/\1/p' <<<"$OUT")" \
    "$lib-load" "the missing lib/$lib.sh has a structured load error"
  mv "$TMP_ROOT/$lib.sh" "$TMP_ROOT/scripts/lib/$lib.sh"
done

P7GHOST="$(jq -cn --arg head "$HEAD_A" '[{number:7, state:"open", draft:false, head:{sha:$head}, user:null, created_at:"2026-01-01T00:00:00Z", auto_merge:{merge_method:"merge"}}]')"
P7BADTIMES="$(jq -cn --arg head "$HEAD_A" '[{number:7, state:"open", draft:false, head:{sha:$head}, user:{login:"author"}, created_at:"garbage", auto_merge:{merge_method:"merge"}}]')"
P7BADCREATED="$(jq -cn --argjson r "$(pr_row 7 open armed false garbage)" '[$r]')"
PR9CLOSED="$(pr_row 9 closed | jq -c .)"
PR9BOGUS="$(pr_row 9 bogus | jq -c .)"
PR9PARTIAL="$(jq -cn --arg head "$HEAD_A" '{number:9, state:"open", head:{sha:$head}, user:{login:"author"}}')"
PR9NONSHA="$(jq -cn '{number:9, state:"open", draft:false, head:{sha:"main"}, user:{login:"author"}, created_at:"2026-01-01T00:00:00Z", auto_merge:null}')"
PR9EMPTYARM="$(jq -cn --arg head "$HEAD_A" '{number:9, state:"open", draft:false, head:{sha:$head}, user:{login:"author"}, created_at:"2026-01-01T00:00:00Z", auto_merge:{}}')"
R_ERRORS='{"errors":[{"message":"rate limited"}],"data":{"repository":{"pullRequest":{"isInMergeQueue":false,"mergeQueueEntry":null,"reviewDecision":"APPROVED"}}}}'
R_NODECISION='{"data":{"repository":{"pullRequest":{"isInMergeQueue":false,"mergeQueueEntry":null}}}}'
R_QUEUEWORD='{"data":{"repository":{"pullRequest":{"isInMergeQueue":"no","mergeQueueEntry":null,"reviewDecision":"APPROVED"}}}}'
# The same instant written with the author's +02:00 offset.
OFFSET_NOW="$(date -u -d "@$((WATCH_NOW + 7200))" +%Y-%m-%dT%H:%M:%S+02:00 2>/dev/null || date -u -r "$((WATCH_NOW + 7200))" +%Y-%m-%dT%H:%M:%S+02:00)"
R_MALFORMED='review-state+read+is+malformed+(GraphQL+errors,+a+missing+field,+or+a+value+outside+the+queue+or+reviewDecision+enums)'
T_PAGE1='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"isResolved":true}]}}}}}'
T_NULLNODE='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":null}]}}}}}'
T_BADPAGEINFO='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":null},"nodes":[]}}}}}'
T_NONARRAY='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":{"item":{"isResolved":true}}}}}}}'

echo "=== explicit PR arguments ==="
# Each row compares the complete error record emitted by the boundary under
# test.
table \
  "a failed PR listing names the repository||STUB_OPEN_PRS=fail|rc=2 kinds=none diagnostic=review-gate-error=watch-list-failed+value=acme/widgets" \
  "a closed PR is skipped silently|9|STUB_PR_9=$PR9CLOSED|rc=0 kinds=none" \
  "a zero-padded argument normalizes|09|STUB_PR_9=$PR9CLOSED|rc=0 kinds=none" \
  "a junk response is that PR's error line and the rest still process|5 6|STUB_PR_5=not json at all;STUB_PR_6=$(pr_row 6 closed | jq -c .)|rc=2 kinds=error protocol=5~--------~error~PR+#5+response+is+not+a+well-formed+PR+object+(broken+read)" \
  "a response describing a different PR fails the binding check|9|STUB_PR_9=$(pr_row 7 | jq -c .)|rc=2 kinds=error protocol=9~--------~error~PR+#9+response+is+not+a+well-formed+PR+object+(broken+read)" \
  "a state outside the open or closed enum is malformed, never a skip|9|STUB_PR_9=$PR9BOGUS|rc=2 kinds=error protocol=9~aaaaaaaa~error~PR+state+'bogus'+is+outside+the+open|closed+enum+(malformed+response)" \
  "a PR object missing reducer fields is malformed|9|STUB_PR_9=$PR9PARTIAL|rc=2 kinds=error protocol=9~--------~error~PR+#9+response+is+not+a+well-formed+PR+object+(broken+read)" \
  "a non-sha initial head is malformed|9|STUB_PR_9=$PR9NONSHA|rc=2 kinds=error protocol=9~--------~error~PR+#9+response+is+not+a+well-formed+PR+object+(broken+read)" \
  "an empty auto_merge object is malformed, never silently armed|9|STUB_PR_9=$PR9EMPTYARM|rc=2 kinds=error protocol=9~--------~error~PR+#9+response+is+not+a+well-formed+PR+object+(broken+read)"

echo "=== a broken read is an error, never health ==="
# Exit 2 with an error line. The complete record distinguishes inputs that
# share an error kind and exit status.
table \
  "a zero-byte PR listing||STUB_OPEN_PRS=emptybytes|rc=2 kinds=none diagnostic=review-gate-error=watch-list-empty+value=acme/widgets" \
  "a non-object listing element||STUB_OPEN_PRS=[42]|rc=2 kinds=none diagnostic=review-gate-error=watch-list-malformed+value=acme/widgets" \
  "an empty-object listing element||STUB_OPEN_PRS=[{}]|rc=2 kinds=none diagnostic=review-gate-error=watch-list-malformed+value=acme/widgets" \
  "a ghost author reduces like any other PR||STUB_OPEN_PRS=$P7GHOST|rc=0 kinds=none" \
  "a failed named read is each named PR's error line|7 9|STUB_OPEN_PRS=$P7;STUB_PR_9=$PR9CLOSED;STUB_REVIEW_FAIL=yes|rc=2 kinds=error,error protocol=7~--------~error~could+not+read+PR+#7;9~--------~error~could+not+read+PR+#9" \
  "a zero-byte named read is the named PR's error line|7|STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=emptybytes|rc=2 kinds=error protocol=7~--------~error~could+not+read+PR+#7" \
  "an unknown named PR fails the read with its neighbours|7 8|STUB_OPEN_PRS=$P7|rc=2 kinds=error,error" \
  "a listing answer carrying GraphQL errors is no listing||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=$R_ERRORS|rc=2 kinds=none diagnostic=review-gate-error=watch-list-failed+value=acme/widgets" \
  "a review-state answer without reviewDecision||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=$R_NODECISION|rc=2 kinds=error protocol=7~aaaaaaaa~error~$R_MALFORMED" \
  "a reviewDecision outside the enum||STUB_OPEN_PRS=$P7;STUB_DECISION=DISMISSED|rc=2 kinds=error protocol=7~aaaaaaaa~error~$R_MALFORMED" \
  "a queue membership that is not a boolean||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=$R_QUEUEWORD|rc=2 kinds=error protocol=7~aaaaaaaa~error~$R_MALFORMED" \
  "a null isResolved node||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_NULLNODE|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+response+malformed+(non-boolean+isResolved)+or+unparsable" \
  "malformed pagination metadata is an error, never overflow||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_BADPAGEINFO|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+pagination+metadata+malformed+(non-boolean+hasNextPage)" \
  "a non-array nodes container||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_NONARRAY|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+response+malformed+(non-boolean+isResolved)+or+unparsable" \
  "a failed thread page read||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_PAGE1;STUB_ROUND=fail|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+read+failed" \
  "a zero-byte thread page read||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_PAGE1;STUB_ROUND=emptybytes|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+read+produced+zero+bytes+(broken+read)" \
  "a future-dated committer timestamp is unprovable silence|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=2030-01-01T00:00:00Z|rc=2 kinds=error protocol=7~aaaaaaaa~error~silence+clock+is+in+the+future+by+${FUTURE_SKEW}s+(author-controlled+committer+timestamp)+—+silence+age+unprovable" \
  "unparsable timestamps|--awaiting-after 60|STUB_OPEN_PRS=$P7BADTIMES;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=also-garbage|rc=2 kinds=error protocol=7~aaaaaaaa~error~head+committer+date+unparsable+(broken+read)+—+the+silence+clock+never+substitutes+the+creation+time+for+broken+head+metadata" \
  "an unparsable creation timestamp|--awaiting-after 60|STUB_OPEN_PRS=$P7BADCREATED;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=2 kinds=error protocol=7~aaaaaaaa~error~PR+creation+timestamp+unparsable+(broken+read)+—+the+silence+floor+cannot+be+computed" \
  "a head commit without a committer date|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=null|rc=2 kinds=error protocol=7~aaaaaaaa~error~head+commit+has+no+usable+committer+date+(broken+read)" \
  "a timeline event without a time while confirming staleness|--awaiting-after 60|STUB_TIMELINE_RAW=[{}];STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=2 kinds=error protocol=7~aaaaaaaa~error~timeline+pages+malformed+while+confirming+staleness+(fail+loud,+not+a+stale+alert)" \
  "a commit time with an offset is read in UTC|--awaiting-after 3600|STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OFFSET_NOW|rc=0 kinds=none" \
  "an unparsable readiness timestamp|--awaiting-after 60|STUB_READY_AT=garbage-timestamp;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=2 kinds=error" \
  "a future-dated timeline event|--awaiting-after 60|STUB_READY_AT=2030-01-01T00:00:00Z;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=2 kinds=error protocol=7~aaaaaaaa~error~silence+clock+is+in+the+future+by+${FUTURE_SKEW}s+(timeline+event+timestamp)+—+silence+age+unprovable" \
  "a head commit without a sha||STUB_HEAD_AFTER=null;STUB_OPEN_PRS=$P7|rc=2 kinds=error protocol=7~aaaaaaaa~error~head+commit+read+returned+no+usable+sha+(broken+read)" \
  "a non-sha head commit is a broken read, never head-moved||STUB_HEAD_AFTER=42;STUB_OPEN_PRS=$P7|rc=2 kinds=error" \
  "a head past the listed 250 commits is a broken read, never head-moved||STUB_HEAD_AFTER=$HEAD_B;STUB_COMMITS=250;STUB_OPEN_PRS=$P7|rc=2 kinds=error protocol=7~aaaaaaaa~error~head+commit+is+past+the+250+commits+GitHub+lists+for+a+PR+(broken+read)" \
  "a moved head under the listed 250 commits is head-moved||STUB_HEAD_AFTER=$HEAD_B;STUB_COMMITS=249;STUB_OPEN_PRS=$P7|rc=1 kinds=head-moved"

echo '=== every open-PR listing page reaches the reduction ==='
P7P9="$(jq -cn --argjson row "$(pr_row 7)" '[$row, ($row | .number = 9)]')"
PAGED_LIST="STUB_OPEN_PRS=$P7P9;STUB_LIST_PAGE_SIZE=1;STUB_UNRESOLVED=1"
table "a finding on each listing page reports both PRs||$PAGED_LIST|rc=1 kinds=threads-open,threads-open protocol=7~aaaaaaaa~threads-open~1+unresolved+review+thread(s);9~aaaaaaaa~threads-open~1+unresolved+review+thread(s)"
mutant_watch list-first-page 's#\[try inputs catch null\] as $documents#([try inputs catch null] | .[0:1]) as $documents#' '[try inputs catch null] as $documents'
table "must-fail: dropping later listing pages loses the second PR||$PAGED_LIST|rc=1 kinds=threads-open protocol=7~aaaaaaaa~threads-open~1+unresolved+review+thread(s)"
WATCH_BIN="$LIVE_WATCH"

echo "=== must-fail controls for the review-state read ==="
# One control per rule the read refuses on, each against a copy of the
# reducer with that rule planted wrong: the row it holds above must move from
# its error record to what the unguarded read makes of the same answer.
mutant_watch named-zero-bytes 's#\[ "$main_read" = failed \] || \[ -n "$main" \] || main_read=empty#:#' '[ "$main_read" = failed ] || [ -n "$main" ] || main_read=empty'
table "must-fail: without the zero-byte check the empty answer reads as a malformed PR|7|STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=emptybytes|rc=2 kinds=error protocol=7~--------~error~PR+#7+response+is+not+a+well-formed+PR+object+(broken+read)"
mutant_watch review-has-decision 's#($p | has("reviewDecision") | not)#false#' '($p | has("reviewDecision") | not)'
table "must-fail: without the field check a missing decision reads as no review required||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=$R_NODECISION|rc=0 kinds=none"
mutant_watch review-decision-enum 's#IN("APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED") | not#IN("APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", "DISMISSED") | not#' 'IN("APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED") | not'
table "must-fail: without the enum check an unknown decision reaches the reduction||STUB_OPEN_PRS=$P7;STUB_DECISION=DISMISSED|rc=2 kinds=error protocol=7~aaaaaaaa~error~reviewDecision+'DISMISSED'+reached+the+reduction+unhandled+—+the+review-state+read+admits+only+APPROVED,+CHANGES_REQUESTED,+REVIEW_REQUIRED+and+NONE"
mutant_watch review-queue-boolean 's#($p.isInMergeQueue | type) != "boolean"#false#' '($p.isInMergeQueue | type) != "boolean"'
table "must-fail: without the boolean check a string membership reads as queued and healthy||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=$R_QUEUEWORD|rc=0 kinds=none"
mutant_watch commit-cap 's#elif $p.commits.totalCount >= 250 and#elif false and#' 'elif $p.commits.totalCount >= 250 and'
table "must-fail: without the commit cap a long PR reads as a push forever||STUB_HEAD_AFTER=$HEAD_B;STUB_COMMITS=250;STUB_OPEN_PRS=$P7|rc=1 kinds=head-moved"
mutant_watch offset-sign 's#if $c.s == "-" then -1 else 1 end#if $c.s == "-" then 1 else -1 end#' 'if $c.s == "-" then -1 else 1 end'
table "must-fail: with the offset applied the wrong way the commit reads four hours ahead|--awaiting-after 3600|STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OFFSET_NOW|rc=2 kinds=error"
WATCH_BIN="$LIVE_WATCH"

echo '=== full shared thread pages are streamed, without an argv size bound ==='
LARGE_PRS="$(jq -cn --argjson row "$(pr_row 1)" '[range(1;81) as $n | $row | .number = $n]')"
LARGE_ENV="STUB_OPEN_PRS=$LARGE_PRS;STUB_LIST_PAGE_SIZE=50;STUB_THREADS_PAGES=2;STUB_THREADS_PAGE_NODES=100;STUB_ROUND_BYTES_FILE=$TMP_ROOT/shared-page-bytes"
table "80 PRs with 200 resolved threads each remain healthy||$LARGE_ENV|rc=0 kinds=none"
read -r SHARED_PAGE_BYTES <"$TMP_ROOT/shared-page-bytes"
large=0
[[ "$SHARED_PAGE_BYTES" -le 131072 ]] || large=1
assert_eq "$large" 1 'the actual shared response exceeds the Linux single-argument limit'
printf 'shared page evidence: prs=80 threads-per-pr=200 response-bytes=%s\n' "$SHARED_PAGE_BYTES"
case "$OSTYPE" in
  linux*)
    mutant_watch thread-response-argv 's#--arg state_fields "$PR_STATE_FIELDS"#--arg bulk "${rounds[2]:-}" --arg state_fields "${PR_STATE_FIELDS}"#' '--arg state_fields "$PR_STATE_FIELDS"'
    table "must-fail: putting the shared response in argv loses every PR result||$LARGE_ENV|rc=2 kinds=none diagnostic=review-gate-error=watch-reduce-failed+value=acme/widgets"
    WATCH_BIN="$LIVE_WATCH" ;;
esac

echo "=== configuration errors refuse to reduce ==="
table \
  "a missing --awaiting-after value is refused|--awaiting-after||rc=2 kinds=none diagnostic=review-gate-error=watch-wait-invalid+value=''" \
  "an unknown flag is refused by exact diagnostic|--unknown||rc=2 kinds=none diagnostic=review-gate-error=watch-flag-unknown+value=--unknown" \
  "a non-numeric PR argument is refused by exact diagnostic|abc||rc=2 kinds=none diagnostic=review-gate-error=watch-pr-invalid+value=abc" \
  "a non-numeric PR_REVIEW_WAIT_SECS||PR_REVIEW_WAIT_SECS=90s;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=2 kinds=none diagnostic=review-gate-error=watch-wait-setting-invalid+value=90s" \
  "a PR_REVIEW_WAIT_SECS past the integer range||PR_REVIEW_WAIT_SECS=99999999999999999999;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=2 kinds=none diagnostic=review-gate-error=watch-wait-setting-range+value=99999999999999999999" \
  "an --awaiting-after past the integer range|--awaiting-after 99999999999999999999|STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=2 kinds=none diagnostic=review-gate-error=watch-wait-range+value=99999999999999999999"

echo "=== --help answers before the GH_REPO requirement ==="
# The contract callers route to: readable with no environment at all, against
# the shipped script, with no gh behind it.
for flag in --help -h; do
  set +e
  OUT=$(cd "$TMP_ROOT" && env -u GH_REPO "$SKILL_ROOT/scripts/pr-watch.sh" "$flag" 2>&1); RC=$?
  set -e
  assert_eq "$RC" "0" "$flag answers before the repository requirement"
done

set +e
OUT=$(cd "$TMP_ROOT" && env -u GH_REPO "$SKILL_ROOT/scripts/pr-watch.sh" 2>&1); RC=$?
set -e
assert_eq "$(observe "rc diagnostic")" "rc=2 diagnostic=review-gate-error=watch-repo-missing+value=''" "a missing repository is refused by exact diagnostic"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
