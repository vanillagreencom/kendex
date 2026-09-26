#!/usr/bin/env bash
# Tests for queue-wait's confirmation count against its deadline
# split from the verdict suites at the seam the mechanism draws:
# these cases are about WHEN a candidate is confirmed, not which verdict it
# carries.
#
# The failure this closes: `ejected` and `disarmed` are TRANSITIONS. Each is
# observed once — was_in_queue true then in_queue_now false, was_queued true
# then armed_now false — and a re-run of queue-wait starts with those priors
# false, so a candidate the deadline cut off mid-confirmation is re-observed
# by nobody: the caller re-runs, reads `not_queued`, and merge-pr's table
# re-arms a PR the queue already threw out. `conflicting` is read from
# `mergeable` on every poll and a re-run sees it again, which is why the loss
# is these two and not that one.
#
# Covered:
#   1. an ejection standing at the deadline is polled to its confirmation
#      inside the budget, and routes `ejected`
#   2. the same for the auto-merge-cleared disarm
#   3. the budget is still the upper bound: max_wait is not overrun
#   4. a blip is still not routed, shortened gap or not
#   5. the count is still the whole rule: a candidate that cannot reach it
#      even shortened is reported beside the timeout, never as a verdict
#   6. the squeeze allowance is per candidate verdict, so a transition
#      arriving after a prior candidate spent it is still confirmed
#
#   7. a transition whose owed polls fit the budget exactly is squeezed
#      anyway, because a gap landing ON the deadline is a poll never made
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

# The sequenced gh stub, the virtual clock, new_case, write_fixture, the q_*
# queue bodies and run_queue_wait.
# shellcheck source=lib/queue-wait-seq.sh
source "$TEST_DIR/lib/queue-wait-seq.sh"

pr_open_mergeable='{"state":"OPEN","mergedAt":null,"mergeable":"MERGEABLE"}'
pr_open_conflicting='{"state":"OPEN","mergedAt":null,"mergeable":"CONFLICTING"}'

echo "=== queue-wait confirmation against the deadline (KEN-837) ==="

# --- 1. an ejection standing when the budget runs out ----------------------
# Poll 1 sees the PR in the queue, poll 2 sees it gone. At a poll interval of
# 2 against a 3-second budget the second confirmation poll does not fit at
# that interval, so the gap before it shrinks to fit inside the budget. Cut
# off instead, the run ends "still queued" and the transition dies with the
# process: the caller's next run starts with was_in_queue false and never
# sees the ejection at all.
new_case ejected_at_deadline
write_fixture state last "$pr_open_mergeable"
write_fixture queue 1 "$q_in_queue"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e1"
out="$(run_queue_wait -- 1 2 3 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "the ejected verdict exits 1" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "ejected" \
  "an ejection standing at the deadline is confirmed inside the budget" "$err"
assert_eq "$(jq -r .status <<<"$out")" "complete" \
  "that exit is a complete verdict, not a timeout" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "merge_group_failed" \
  "the confirmed ejection names its cause" "$err"

# 3. The budget is still the upper bound. The confirmation polls are moved
# INSIDE max_wait, never included after it, so a caller's own deadline still
# holds.
assert_le "$(jq -r .elapsed_seconds <<<"$out")" "3" \
  "confirming inside the budget does not overrun max_wait" "$err"

# --- 2. the auto-merge-cleared disarm, the other transition ----------------
# Armed and never enqueued, then the arming is gone. Same shape, same loss:
# a re-run starts with was_queued false and reads not_queued for a PR whose
# merge will never fire.
new_case disarmed_at_deadline
write_fixture state last "$pr_open_mergeable"
write_fixture queue 1 "$q_armed_only"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e2"
out="$(run_queue_wait -- 1 2 3 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "disarmed" \
  "a disarm standing at the deadline is confirmed inside the budget" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "auto_merge_cleared" \
  "the confirmed disarm names its cause" "$err"
assert_le "$(jq -r .elapsed_seconds <<<"$out")" "3" \
  "the disarm confirmation does not overrun max_wait either" "$err"

# --- 4. a blip is still not a verdict -------------------------------------
# The shortened gap buys the candidate its second look, not its verdict. A
# PR that left the queue for one poll and came back is GitHub's view catching
# up, and routing it to `ejected` sends the lane into a CI cycle for a
# failure CI never had.
new_case ejection_blip_at_deadline
write_fixture state last "$pr_open_mergeable"
write_fixture queue 1 "$q_in_queue"
write_fixture queue 2 "$q_out"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e3"
out="$(run_queue_wait -- 1 2 3 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "queued" \
  "a one-poll ejection blip is not an ejection, shortened gap or not" "$err"
assert_eq "$(jq -r .unconfirmed_verdict <<<"$out")" "null" \
  "a reading the next poll contradicted is not reported at all" "$err"

# --- 5. the count is still the whole rule ---------------------------------
# With the confirmation raised past what the budget can hold even shortened,
# the candidate cannot reach its count. It is not handed back wearing a
# confirmed verdict's name — that is the routing the count exists to prevent
# — and it is not lost either: unconfirmed_verdict carries it beside the
# timeout. A shortened gap can be zero, so it is the poll's own cost that
# makes the count unreachable: STUB_QUEUE_DELAY buys each read a second, as
# a real merge-queue read does, and nine polls do not fit in four.
new_case ejected_unreachable_count
write_fixture state last "$pr_open_mergeable"
write_fixture queue 1 "$q_in_queue"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e4"
out="$(run_queue_wait QUEUE_WAIT_CONFIRM_POLLS=9 STUB_QUEUE_DELAY=1 -- 1 1 4 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "queued" \
  "a candidate that cannot reach its count carries no confirmed verdict" "$err"
assert_eq "$(jq -r .status <<<"$out")" "timeout" \
  "that exit is a timeout" "$err"
assert_eq "$(jq -r .unconfirmed_verdict <<<"$out")" "ejected" \
  "the standing reading is reported beside the verdict, never dropped" "$err"
assert_le "$(jq -r .elapsed_seconds <<<"$out")" "4" \
  "an unreachable count does not spin the poll loop past the budget" "$err"

# --- 6. the squeeze allowance is per candidate verdict -----------
# A conflicting reading stands first and spends the run's one squeeze, then
# the poll after it reads the PR out of the queue. That second candidate is a
# TRANSITION: cut off here it is re-observed by nobody, and merge-pr re-arms
# a PR the queue threw out. Budgeted per run, the ejection gets no shortened
# gap and the deadline takes it; budgeted per candidate verdict, it gets the
# allowance its own confirmation owes.
new_case later_candidate_after_spent_budget
write_fixture state 1 "$pr_open_mergeable"
write_fixture state 2 "$pr_open_conflicting"
write_fixture state last "$pr_open_mergeable"
write_fixture queue 1 "$q_in_queue"
write_fixture queue 2 "$q_in_queue"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e5"
out="$(run_queue_wait -- 1 3 5 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "ejected" \
  "an ejection after a spent candidate is still confirmed" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "merge_group_failed" \
  "it carries its own cause, not the earlier candidate's" "$err"
assert_le "$(jq -r .elapsed_seconds <<<"$out")" "5" \
  "the second confirmation still finishes inside the budget" "$err"

# --- 7. owed polls that fit the budget exactly -------------------
# The loop runs while elapsed < max_wait, so polls owed at exactly the
# remaining budget land the last one ON the deadline, where it is never made.
# Three confirmations at a one-second interval, first seen within two seconds
# of it, meet that equality on a step and the count is never reached.
new_case owed_polls_fit_exactly
write_fixture state last "$pr_open_mergeable"
write_fixture queue 1 "$q_in_queue"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e6"
out="$(run_queue_wait QUEUE_WAIT_CONFIRM_POLLS=3 -- 1 1 3 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "ejected" \
  "a transition owed exactly the remaining budget is squeezed, not cut" "$err"
assert_eq "$(jq -r .status <<<"$out")" "complete" \
  "that exit is a complete verdict, not a timeout" "$err"
assert_le "$(jq -r .elapsed_seconds <<<"$out")" "3" \
  "squeezing at the boundary does not overrun max_wait" "$err"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
