#!/usr/bin/env bash
# Tests for queue-wait's `conflicting` verdict, split
# from queue_wait.sh at the seam its fixture stub draws (the poll/verdict
# suites and their sequenced stub live there).
#
# The failure this closes: a PR whose head conflicts with its base is armed
# and stays armed. Nothing ejects it, nothing disarms it, and the watch
# reported it "still queued, still progressing" until the deadline — the arm
# flag read as the merge verdict. GitHub's own `mergeable` says CONFLICTING
# from the first poll, and the fix is a restack, not another CI cycle.
#
# Covered:
#   1. CONFLICTING routes the conflicting verdict, cause base_conflict
#   2. it is confirmed across polls like every other terminal verdict
#   3. it outranks ejected, whose recovery would be a CI cycle, and the
#      failed-check probe, which routes to the same CI cycle on one look
#   4. MERGEABLE and UNKNOWN route nothing
#   5. state is read first: a merged PR never reports conflicting
#   6. the human-readable line names the verdict and the remedy
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

pr_state() { # <state> <mergeable>
  printf '{"state":"%s","mergedAt":%s,"mergeable":"%s"}' \
    "$1" "$([[ "$1" == "MERGED" ]] && echo '"2026-07-24T10:00:00Z"' || echo null)" "$2"
}

echo "=== queue-wait conflicting verdict (KEN-837) ==="

# --- 1. an armed, queued PR whose head conflicts with the base -------------
# The shape that would run out the clock as "still queued, still
# progressing": nothing ejects it and nothing disarms it.
new_case conflicting
write_fixture state last "$(pr_state OPEN CONFLICTING)"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e1"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "conflicting exits 1" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "conflicting" "CONFLICTING routes the conflicting verdict" "$err"
assert_eq "$(jq -r .status <<<"$out")" "complete" "conflicting is a complete status, not a timeout" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "base_conflict" "conflicting names its cause" "$err"

# --- 2. confirmed across polls, like every other terminal verdict ----------
# A single CONFLICTING read between two clean ones is GitHub recomputing, not
# a conflict: at a two-poll confirmation it never reaches a verdict, and the
# wait keeps running rather than sending a lane into a restack it does not
# need. QUEUE_WAIT_CONFIRM_POLLS is passed here rather than inherited, so a
# change to run_queue_wait's shared default cannot quietly void the case.
new_case conflicting_blip
write_fixture state 1 "$(pr_state OPEN MERGEABLE)"
write_fixture state 2 "$(pr_state OPEN CONFLICTING)"
write_fixture state last "$(pr_state OPEN MERGEABLE)"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e2"
out="$(run_queue_wait QUEUE_WAIT_CONFIRM_POLLS=2 -- 1 1 4 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "queued" "a one-poll CONFLICTING blip is not a conflict" "$err"

# --- 2b. the deadline applies the same count -------------------------------
# With the confirmation raised past the poll budget the candidate can never
# reach it, so the wait runs to its deadline with a conflict reading
# standing. Handing that back as `conflicting` gives a single unconfirmed
# observation the name a confirmed one carries, and a caller routing on
# verdict cannot tell them apart. The reading is not lost either: it is
# reported beside the still-queued verdict rather than as one. A gap
# shortened to fit the budget can be zero, so it is the poll's own cost that
# puts the count out of reach: STUB_QUEUE_DELAY buys each read a second, as a
# real merge-queue read does, and nine polls do not fit in four.
new_case conflicting_unconfirmed_at_deadline
write_fixture state last "$(pr_state OPEN CONFLICTING)"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e2b"
out="$(run_queue_wait QUEUE_WAIT_CONFIRM_POLLS=9 STUB_QUEUE_DELAY=1 -- 1 1 4 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "queued" \
  "an unconfirmed candidate does not carry a confirmed verdict's name at the deadline" "$err"
assert_eq "$(jq -r .status <<<"$out")" "timeout" \
  "that exit is a timeout, not a complete verdict" "$err"
assert_eq "$(jq -r .unconfirmed_verdict <<<"$out")" "conflicting" \
  "the standing reading is reported beside the verdict, never dropped" "$err"

# --- 3. it outranks ejected ------------------------------------------------
# A conflicting PR that also left the queue is not a CI problem: routing it
# to `ejected` sends the caller into ci-fix for a failure CI never had.
new_case conflicting_outranks_ejected
write_fixture state last "$(pr_state OPEN CONFLICTING)"
write_fixture queue 1 "$q_in_queue"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e3"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "conflicting" "a conflicting PR out of the queue is conflicting, not ejected" "$err"
assert_eq "$(jq -r .was_in_merge_queue <<<"$out")" "true" "the queue memory it outranks is still recorded" "$err"

# --- 3b. it outranks the failed-check probe too ----------------------------
# The ranking above is an if/elif chain, so it settles conflicting against
# ejected and disarm — and settles nothing against the probe, which sits
# outside it and emits `disarmed` on ONE observation. A conflicting PR that
# is armed and not enqueued satisfies the probe's shape, so on the first
# poll, before the conflict is ever confirmed, the probe hands back the
# disarm merge-pr.md routes to a CI cycle: a recovery cycle for a failure CI
# never had. The probe must be able to fire here or the case proves nothing,
# which is why the checks stub is put in failure mode.
new_case conflicting_outranks_check_probe
write_fixture state last "$(pr_state OPEN CONFLICTING)"
write_fixture queue last "$q_armed_only"
err="$TMP_ROOT/e3b"
out="$(run_queue_wait STUB_PR_CHECKS_MODE=failure -- 1 1 20 --json 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "conflicting" \
  "a standing conflict is not overtaken by a single failed-check probe" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "base_conflict" \
  "the verdict keeps the conflict's cause, not the probe's check_failed" "$err"

# --- 4. every other mergeable value routes nothing -------------------------
# UNKNOWN is what GitHub reports while it recomputes; routing on it would
# restack a branch that merges fine.
new_case mergeable_unknown
write_fixture state last "$(pr_state OPEN UNKNOWN)"
write_fixture queue last "$q_armed_only"
err="$TMP_ROOT/e4"
out="$(run_queue_wait -- 1 1 3 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "queued" "UNKNOWN mergeable routes nothing" "$err"

new_case mergeable_clean
write_fixture state last "$(pr_state OPEN MERGEABLE)"
write_fixture queue 1 "$q_armed_only"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e4b"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "disarmed" "a MERGEABLE PR still routes disarm on its own signal" "$err"

# --- 5. state is read first ------------------------------------------------
# `mergeable` settles at a stale value once a PR merges; the merged exit must
# never lose to it.
new_case merged_beats_mergeable
write_fixture state last "$(pr_state MERGED CONFLICTING)"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e5"
out="$(run_queue_wait -- 1 1 10 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "a merged PR still exits 0" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "merged" "a merged PR is merged whatever mergeable says" "$err"

# --- 6. the human-readable line ------------------------------------------
new_case conflicting_text
write_fixture state last "$(pr_state OPEN CONFLICTING)"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e6"
out="$(run_queue_wait -- 1 1 20 --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "plain conflicting result exits 1" "$err"
assert_eq "$(sed -n '1p' <<<"$out")" \
  "queue-wait: result status=complete verdict=conflicting pr=1 repo=owner/repo cause=base_conflict polls=2 progressing=null" \
  "the plain result carries the confirmed verdict and cause" "$err"

# queue-verdict-routing-lint.test.sh checks the help enum against emitted verdicts.

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
