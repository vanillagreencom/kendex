#!/usr/bin/env bash
# Behavioral tests for the watcher input validation surface.
# Stdout attention records are the whole-text protocol read by orch.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/lib/pr-watch-fixture.sh"

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
R_MALFORMED='review-state+read+is+malformed+(GraphQL+errors,+a+missing+field,+or+a+value+outside+the+queue+or+reviewDecision+enums)'
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
  "a failed review-state read||STUB_OPEN_PRS=$P7;STUB_REVIEW_FAIL=yes|rc=2 kinds=error protocol=7~aaaaaaaa~error~review-state+read+failed" \
  "a zero-byte review-state read||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=emptybytes|rc=2 kinds=error protocol=7~aaaaaaaa~error~review-state+read+produced+zero+bytes+(broken+read)" \
  "a review-state answer carrying GraphQL errors||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=$R_ERRORS|rc=2 kinds=error protocol=7~aaaaaaaa~error~$R_MALFORMED" \
  "a review-state answer without reviewDecision||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=$R_NODECISION|rc=2 kinds=error protocol=7~aaaaaaaa~error~$R_MALFORMED" \
  "a reviewDecision outside the enum||STUB_OPEN_PRS=$P7;STUB_DECISION=DISMISSED|rc=2 kinds=error protocol=7~aaaaaaaa~error~$R_MALFORMED" \
  "a queue membership that is not a boolean||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=$R_QUEUEWORD|rc=2 kinds=error protocol=7~aaaaaaaa~error~$R_MALFORMED" \
  "a null isResolved node||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_NULLNODE|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+response+malformed+(non-boolean+isResolved)+or+unparsable" \
  "malformed pagination metadata is an error, never overflow||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_BADPAGEINFO|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+pagination+metadata+malformed+(non-boolean+hasNextPage)" \
  "a non-array nodes container||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_NONARRAY|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+response+malformed+(non-boolean+isResolved)+or+unparsable" \
  "a zero-byte thread read||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=emptybytes|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+read+produced+zero+bytes+(broken+read)" \
  "a future-dated committer timestamp is unprovable silence|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=2030-01-01T00:00:00Z|rc=2 kinds=error protocol=7~aaaaaaaa~error~silence+clock+is+in+the+future+by+${FUTURE_SKEW}s+(author-controlled+committer+timestamp)+—+silence+age+unprovable" \
  "unparsable timestamps|--awaiting-after 60|STUB_OPEN_PRS=$P7BADTIMES;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=also-garbage|rc=2 kinds=error protocol=7~aaaaaaaa~error~head+committer+date+unparsable+(broken+read)+—+the+silence+clock+never+substitutes+the+creation+time+for+broken+head+metadata" \
  "an unparsable creation timestamp|--awaiting-after 60|STUB_OPEN_PRS=$P7BADCREATED;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=2 kinds=error protocol=7~aaaaaaaa~error~PR+creation+timestamp+unparsable+(broken+read)+—+the+silence+floor+cannot+be+computed" \
  "a head commit without a committer date|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=null|rc=2 kinds=error protocol=7~aaaaaaaa~error~head+commit+has+no+usable+committer+date+(broken+read)" \
  "a timeline failure while confirming staleness|--awaiting-after 60|STUB_TIMELINE_FAIL=yes;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=2 kinds=error" \
  "a zero-byte timeline response|--awaiting-after 60|STUB_TIMELINE_EMPTYBYTES=yes;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=2 kinds=error protocol=7~aaaaaaaa~error~timeline+read+produced+zero+bytes+while+confirming+staleness+(broken+read)" \
  "an unparsable readiness timestamp|--awaiting-after 60|STUB_READY_AT=garbage-timestamp;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=2 kinds=error" \
  "a future-dated timeline event|--awaiting-after 60|STUB_READY_AT=2030-01-01T00:00:00Z;STUB_OPEN_PRS=$P7;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD|rc=2 kinds=error protocol=7~aaaaaaaa~error~silence+clock+is+in+the+future+by+${FUTURE_SKEW}s+(timeline+event+timestamp)+—+silence+age+unprovable" \
  "a recheck returning no usable sha||STUB_HEAD_AFTER=null;STUB_OPEN_PRS=$P7|rc=2 kinds=error protocol=7~aaaaaaaa~error~head+recheck+returned+no+usable+sha+(broken+read)" \
  "a non-sha recheck value is a broken read, never head-moved||STUB_HEAD_AFTER=42;STUB_OPEN_PRS=$P7|rc=2 kinds=error"

echo "=== must-fail controls for the review-state read ==="
# One control per rule the read refuses on, each against a copy of the
# reducer with that rule planted wrong: the row it holds above must move from
# its error record to what the unguarded read makes of the same answer.
mutant_watch review-zero-bytes 's#if \[ -z "$resp" \]; then#if false; then#' 'if [ -z "$resp" ]; then'
table "must-fail: without the zero-byte check the empty answer reaches the sentinel||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=emptybytes|rc=2 kinds=error protocol=7~aaaaaaaa~error~review-state+read+produced+no+usable+sentinel+(broken+read)"
mutant_watch review-errors $'s#REVIEW_STATE_JQ=\'if ((.errors? // \\[\\]) | length) > 0#REVIEW_STATE_JQ=\'if false#' "REVIEW_STATE_JQ='if ((.errors? // []) | length) > 0"
table "must-fail: without the errors check a partial answer reads as healthy||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=$R_ERRORS|rc=0 kinds=none"
mutant_watch review-has-decision 's#(($p | has("reviewDecision")) | not)#false#' '(($p | has("reviewDecision")) | not)'
table "must-fail: without the field check a missing decision reads as no review required||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=$R_NODECISION|rc=0 kinds=none"
mutant_watch review-decision-enum 's#IN("APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED")#IN("APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", "DISMISSED")#' 'IN("APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"))'
table "must-fail: without the enum check an unknown decision reaches the reduction||STUB_OPEN_PRS=$P7;STUB_DECISION=DISMISSED|rc=2 kinds=error protocol=7~aaaaaaaa~error~reviewDecision+'DISMISSED'+reached+the+reduction+unhandled+—+read_review_state+admits+only+APPROVED,+CHANGES_REQUESTED,+REVIEW_REQUIRED+and+NONE"
mutant_watch review-queue-boolean 's#(($p.isInMergeQueue | type) != "boolean")#false#' '(($p.isInMergeQueue | type) != "boolean")'
table "must-fail: without the boolean check a string membership reads as queued and healthy||STUB_OPEN_PRS=$P7;STUB_REVIEW_RAW=$R_QUEUEWORD|rc=0 kinds=none"
WATCH_BIN="$LIVE_WATCH"

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
