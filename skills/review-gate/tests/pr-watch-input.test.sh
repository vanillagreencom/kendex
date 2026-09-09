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
G_NULL='[{"context":"Review gate","state":null}]'
G_BOGUS='[{"context":"Review gate","state":"bogus"}]'
V_GARBAGE='garbage output with no verdict'
T_NULLNODE='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":null}]}}}}}'
T_BADPAGEINFO='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":null},"nodes":[]}}}}}'
T_NONARRAY='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":{"item":{"isResolved":true}}}}}}}'

echo "=== explicit PR arguments ==="
# A fixture whose predicate line is `unused` ends in an error line of its own
# once the schema boundary is passed. Each row compares the complete error
# record emitted by the boundary under test.
table \
  "a closed PR is skipped silently|9|STUB_PR_9=$PR9CLOSED;STUB_VERDICT_LINE=unused|rc=0 kinds=none" \
  "a zero-padded argument normalizes|09|STUB_PR_9=$PR9CLOSED;STUB_VERDICT_LINE=unused|rc=0 kinds=none" \
  "a junk response is that PR's error line and the rest still process|5 6|STUB_PR_5=not json at all;STUB_PR_6=$(pr_row 6 closed | jq -c .);STUB_VERDICT_LINE=unused|rc=2 kinds=error protocol=5~--------~error~PR+#5+response+is+not+a+well-formed+PR+object+(broken+read)" \
  "a response describing a different PR fails the binding check|9|STUB_PR_9=$(pr_row 7 | jq -c .);STUB_VERDICT_LINE=unused|rc=2 kinds=error protocol=9~--------~error~PR+#9+response+is+not+a+well-formed+PR+object+(broken+read)" \
  "a state outside the open or closed enum is malformed, never a skip|9|STUB_PR_9=$PR9BOGUS;STUB_VERDICT_LINE=unused|rc=2 kinds=error protocol=9~aaaaaaaa~error~PR+state+'bogus'+is+outside+the+open|closed+enum+(malformed+response)" \
  "a PR object missing reducer fields is malformed|9|STUB_PR_9=$PR9PARTIAL;STUB_VERDICT_LINE=unused|rc=2 kinds=error protocol=9~--------~error~PR+#9+response+is+not+a+well-formed+PR+object+(broken+read)" \
  "a non-sha initial head is malformed|9|STUB_PR_9=$PR9NONSHA;STUB_VERDICT_LINE=unused|rc=2 kinds=error protocol=9~--------~error~PR+#9+response+is+not+a+well-formed+PR+object+(broken+read)" \
  "an empty auto_merge object is malformed, never silently armed|9|STUB_PR_9=$PR9EMPTYARM;STUB_VERDICT_LINE=unused|rc=2 kinds=error protocol=9~--------~error~PR+#9+response+is+not+a+well-formed+PR+object+(broken+read)"

echo "=== a broken read is an error, never health ==="
# Exit 2 with an error line. The complete record distinguishes inputs that
# share an error kind and exit status. The queue read's
# envelope and errors[] guards live inside `gh api --jq`, which the stub
# never runs, so one failed-read row is all the stub can drive there.
table \
  "predicate failure||STUB_OPEN_PRS=$P7;STUB_PREDICATE_RC=2;STUB_VERDICT_LINE=unused|rc=2 kinds=error protocol=7~aaaaaaaa~error~predicate+evaluation+failed+(exit+2+—+read+failure+or+invalid+config)" \
  "a zero-exit predicate with no recognizable verdict||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_GARBAGE|rc=2 kinds=error protocol=7~aaaaaaaa~error~predicate+produced+no+recognizable+verdict+(broken+output)" \
  "a zero-byte PR listing||STUB_OPEN_PRS=emptybytes;STUB_VERDICT_LINE=unused|rc=2 kinds=none diagnostic=review-gate-error=watch-list-empty+value=acme/widgets" \
  "a non-object listing element||STUB_OPEN_PRS=[42];STUB_VERDICT_LINE=unused|rc=2 kinds=none diagnostic=review-gate-error=watch-list-malformed+value=acme/widgets" \
  "an empty-object listing element||STUB_OPEN_PRS=[{}];STUB_VERDICT_LINE=unused|rc=2 kinds=none diagnostic=review-gate-error=watch-list-malformed+value=acme/widgets" \
  "a ghost author reduces threads and names the ghost||STUB_OPEN_PRS=$P7GHOST;STUB_UNRESOLVED=1;STUB_VERDICT_LINE=$V_APPROVED|rc=2 kinds=threads-open,error error_payload=7~aaaaaaaa~error~PR+author+is+a+deleted+account+(ghost)+—+the+predicate+cannot+evaluate+author-exclusion+terms;+review+and+merge+this+PR+manually" \
  "a ghost author with nothing else to report names the cause||STUB_OPEN_PRS=$P7GHOST;STUB_VERDICT_LINE=unused|rc=2 kinds=error protocol=7~aaaaaaaa~error~PR+author+is+a+deleted+account+(ghost)+—+the+predicate+cannot+evaluate+author-exclusion+terms;+review+and+merge+this+PR+manually" \
  "a failed queue-membership read||STUB_OPEN_PRS=$P7;STUB_QUEUE_FAIL=yes;STUB_VERDICT_LINE=$V_APPROVED|rc=2 kinds=error protocol=7~aaaaaaaa~error~merge-queue+membership+read+failed+or+malformed" \
  "a zero-byte gate-status read||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=emptybytes|rc=2 kinds=error protocol=7~aaaaaaaa~error~gate-status+read+produced+zero+bytes+(broken+read)" \
  "a matching gate row without a state||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_NULL|rc=2 kinds=error protocol=7~aaaaaaaa~error~gate-status+pages+are+malformed+(broken+read,+or+a+matching+row+without+a+valid+error|failure|pending|success+state)" \
  "a gate row with a state outside the enum||STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_BOGUS|rc=2 kinds=error protocol=7~aaaaaaaa~error~gate-status+pages+are+malformed+(broken+read,+or+a+matching+row+without+a+valid+error|failure|pending|success+state)" \
  "a null isResolved node||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_NULLNODE;STUB_VERDICT_LINE=unused|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+response+malformed+(non-boolean+isResolved)+or+unparsable" \
  "malformed pagination metadata is an error, never overflow||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_BADPAGEINFO;STUB_VERDICT_LINE=unused|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+pagination+metadata+malformed+(non-boolean+hasNextPage)" \
  "a non-array nodes container||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=$T_NONARRAY;STUB_VERDICT_LINE=unused|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+response+malformed+(non-boolean+isResolved)+or+unparsable" \
  "a zero-byte thread read||STUB_OPEN_PRS=$P7;STUB_THREADS_RAW=emptybytes;STUB_VERDICT_LINE=unused|rc=2 kinds=error protocol=7~aaaaaaaa~error~thread+read+produced+zero+bytes+(broken+read)" \
  "a future-dated committer timestamp is unprovable silence|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=2030-01-01T00:00:00Z|rc=2 kinds=error protocol=7~aaaaaaaa~error~silence+clock+is+in+the+future+by+${FUTURE_SKEW}s+(author-controlled+committer+timestamp)+—+silence+age+unprovable" \
  "unparsable timestamps|--awaiting-after 60|STUB_OPEN_PRS=$P7BADTIMES;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=also-garbage|rc=2 kinds=error protocol=7~aaaaaaaa~error~head+committer+date+unparsable+(broken+read)+—+the+silence+clock+never+substitutes+the+creation+time+for+broken+head+metadata" \
  "an unparsable creation timestamp|--awaiting-after 60|STUB_OPEN_PRS=$P7BADCREATED;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=error protocol=7~aaaaaaaa~error~PR+creation+timestamp+unparsable+(broken+read)+—+the+silence+floor+cannot+be+computed" \
  "a head commit without a committer date|--awaiting-after 60|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=null|rc=2 kinds=error protocol=7~aaaaaaaa~error~head+commit+has+no+usable+committer+date+(broken+read)" \
  "a timeline failure while confirming staleness|--awaiting-after 60|STUB_TIMELINE_FAIL=yes;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=error" \
  "a zero-byte timeline response|--awaiting-after 60|STUB_TIMELINE_EMPTYBYTES=yes;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=error protocol=7~aaaaaaaa~error~timeline+read+produced+zero+bytes+while+confirming+staleness+(broken+read)" \
  "an unparsable readiness timestamp|--awaiting-after 60|STUB_READY_AT=garbage-timestamp;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=error" \
  "a future-dated timeline event|--awaiting-after 60|STUB_READY_AT=2030-01-01T00:00:00Z;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=error protocol=7~aaaaaaaa~error~silence+clock+is+in+the+future+by+${FUTURE_SKEW}s+(timeline+event+timestamp)+—+silence+age+unprovable" \
  "a recheck returning no usable sha||STUB_HEAD_AFTER=null;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=2 kinds=error protocol=7~aaaaaaaa~error~head+recheck+returned+no+usable+sha+(broken+read)" \
  "a non-sha recheck value is a broken read, never head-moved||STUB_HEAD_AFTER=42;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_APPROVED;STUB_GATE_HISTORY=$G_OK|rc=2 kinds=error"

echo "=== configuration errors refuse to reduce ==="
table \
  "a non-numeric PR_REVIEW_WAIT_SECS||PR_REVIEW_WAIT_SECS=90s;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=none diagnostic=review-gate-error=watch-wait-setting-invalid+value=90s" \
  "a PR_REVIEW_WAIT_SECS past the integer range||PR_REVIEW_WAIT_SECS=99999999999999999999;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=none diagnostic=review-gate-error=watch-wait-setting-range+value=99999999999999999999" \
  "an --awaiting-after past the integer range|--awaiting-after 99999999999999999999|STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=$V_AWAITING;STUB_HEAD_DATE=$OLD|rc=2 kinds=none diagnostic=review-gate-error=watch-wait-range+value=99999999999999999999" \
  "an invalid REVIEW_GATE_THREADS||REVIEW_GATE_THREADS=of;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=unused|rc=2 kinds=none diagnostic=review-gate-error=watch-threads-invalid+value=of" \
  "an invalid REVIEW_GATE_MODE||REVIEW_GATE_MODE=offf;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=unused|rc=2 kinds=none diagnostic=review-gate-error=watch-mode-invalid+value=offf" \
  "an explicitly empty REVIEW_GATE_CONTEXT, in cheap mode too|--no-evaluate|REVIEW_GATE_CONTEXT=;STUB_OPEN_PRS=$P7;STUB_VERDICT_LINE=unused|rc=2 kinds=none diagnostic=review-gate-error=watch-context-empty+value=''"

echo "=== --help answers before the GH_REPO requirement ==="
# The contract callers route to: readable with no environment at all, against
# the shipped script, with no gh and no predicate behind it.
for flag in --help -h; do
  set +e
  OUT=$(cd "$TMP_ROOT" && env -u GH_REPO "$SKILL_ROOT/scripts/pr-watch.sh" "$flag" 2>&1); RC=$?
  set -e
  assert_eq "$RC" "0" "$flag answers before the repository requirement"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
