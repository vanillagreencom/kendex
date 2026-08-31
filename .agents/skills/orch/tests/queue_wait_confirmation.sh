#!/usr/bin/env bash
# Regression tests for queue-wait's confirmation count against its deadline
# (KEN-837), split from the verdict suites at the seam the mechanism draws:
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
#      arriving after an earlier candidate spent it is still confirmed
#      (KEN-886)
#   7. a transition whose owed polls fit the budget exactly is squeezed
#      anyway, because a gap landing ON the deadline is a poll never made
#      (KEN-886)
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

dump_stderr() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  printf '        stderr:\n'
  sed 's/^/          /' "$file"
}

assert_eq() {
  local got="$1" want="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    dump_stderr "$stderr_file"
  fi
}

assert_le() {
  local got="$1" bound="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" =~ ^[0-9]+$ ]] && [ "$got" -le "$bound" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted: <= %s\n        got:    %s\n' "$name" "$bound" "$got"
    dump_stderr "$stderr_file"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/seq"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"

# Sequenced `gh` stub, one poll per numbered fixture — the same contract
# queue_wait_conflicting.sh documents:
#   $STUB_SEQ_DIR/state-<n>.json   `pr view --json state,mergedAt,mergeable`
#   $STUB_SEQ_DIR/queue-<n>.json   queue-membership GraphQL body
# `<prefix>-last.json` serves every poll past the last numbered fixture, and
# review-thread reads answer with an empty set so the late-findings guard
# stays quiet. `STUB_QUEUE_DELAY` makes the queue read itself cost that many
# seconds on the clock below, the production condition under which a
# confirmation count can be larger than the remaining budget can hold however
# short the gaps are made.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

_next() {
  local f="$STUB_SEQ_DIR/$1.count" n=0
  [[ -f "$f" ]] && n="$(cat "$f")"
  n=$((n + 1))
  printf '%s' "$n" > "$f"
  printf '%s' "$n"
}

_emit_fixture() {
  local prefix="$1" n="$2" f
  f="$STUB_SEQ_DIR/$prefix-$n.json"
  [[ -f "$f" ]] || f="$STUB_SEQ_DIR/$prefix-last.json"
  if [[ ! -f "$f" ]]; then
    printf 'stub: no fixture for %s-%s\n' "$prefix" "$n" >&2
    exit 1
  fi
  cat "$f"
  exit 0
}

_args_have_sub() {
  local needle="$1" a
  shift
  for a in "$@"; do
    [[ "$a" == *"$needle"* ]] && return 0
  done
  return 1
}

# Exact, for the field list: a substring match would serve the fixture
# whatever was asked for, so a dropped field would read as empty and leave
# the suite green.
_args_have() {
  local needle="$1" a
  shift
  for a in "$@"; do
    [[ "$a" == "$needle" ]] && return 0
  done
  return 1
}

case "${1:-}" in
  auth) [[ "${2:-}" == "status" ]] && { echo "Logged in"; exit 0; } ;;
  repo) [[ "${2:-}" == "view" ]] && { echo "owner/repo"; exit 0; } ;;
  api)
    if [[ "${2:-}" == "graphql" ]]; then
      if _args_have_sub "reviewThreads" "$@"; then
        echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
        exit 0
      fi
      [[ -n "${STUB_QUEUE_DELAY:-}" ]] && sleep "$STUB_QUEUE_DELAY"
      _emit_fixture queue "$(_next graphql)"
    fi
    if [[ "${2:-}" == "user" ]]; then echo "test-user"; exit 0; fi
    if [[ "${2:-}" == repos/*/actions/runs* ]]; then echo '{"workflow_runs":[]}'; exit 0; fi
    ;;
  pr)
    if [[ "${2:-}" == "view" ]]; then
      if _args_have "state,mergedAt,mergeable" "$@"; then
        _emit_fixture state "$(_next prview)"
      fi
      echo "CLEAN"
      exit 0
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

# Virtual clock, on the same PATH as the gh stub. On wall time these cases have
# no margin worth the name. They run on budgets of a few seconds, and once a
# poll costs a large fraction of a second the deadline arrives before the
# squeezed confirmation poll can land, so every case goes red. That is what a
# contended CI runner and a busy developer box both produce, and it is what
# made this suite eject merge groups (KEN-879).
#
# None of it is about real duration. What the cases assert is arithmetic over
# the clock queue-wait itself keeps, and queue-wait reads wall time only as
# `date +%s` and waits only through `sleep`, so owning those two commands makes
# the budget exact rather than raced. A sleep advances the clock, a poll costs
# nothing unless the stub is told to charge for it, and every assertion below
# lands on the same number no matter how slow the machine is. The suite also
# stops needing `date +%N`, a GNU extension that is absent on macOS.
REAL_DATE="$(command -v date)"
REAL_SLEEP="$(command -v sleep)"
if [[ ! -x "$REAL_DATE" || ! -x "$REAL_SLEEP" ]]; then
  echo "no external date/sleep for the clock stubs to fall back on" >&2
  exit 1
fi

cat > "$TMP_ROOT/bin/date" <<'EOF'
#!/usr/bin/env bash
# `+%s` is the clock queue-wait keeps its budget on. Every other form is the
# real date, so a timestamp the script prints is still a real timestamp.
if [[ "${1:-}" == "+%s" && -f "${STUB_CLOCK:-}" ]]; then
  cat "$STUB_CLOCK"
  exit 0
fi
exec "$STUB_REAL_DATE" "$@"
EOF
chmod +x "$TMP_ROOT/bin/date"

cat > "$TMP_ROOT/bin/sleep" <<'EOF'
#!/usr/bin/env bash
# Whole seconds advance the clock and return; that is every wait queue-wait and
# the gh stub make. Anything else is a real sleep, so an unexpected fractional
# wait still waits rather than silently passing.
if [[ "${1:-}" =~ ^[0-9]+$ && -f "${STUB_CLOCK:-}" ]]; then
  printf '%s' "$(( $(cat "$STUB_CLOCK") + $1 ))" > "$STUB_CLOCK"
  exit 0
fi
exec "$STUB_REAL_SLEEP" "$@"
EOF
chmod +x "$TMP_ROOT/bin/sleep"

SEQ_DIR=""
new_case() {
  SEQ_DIR="$TMP_ROOT/seq/$1"
  rm -rf -- "${SEQ_DIR:?}"
  mkdir -p "$SEQ_DIR"
}

write_fixture() { # <prefix> <n|last> <json>
  printf '%s' "$3" > "$SEQ_DIR/$1-$2.json"
}

pr_open_mergeable='{"state":"OPEN","mergedAt":null,"mergeable":"MERGEABLE"}'
pr_open_conflicting='{"state":"OPEN","mergedAt":null,"mergeable":"CONFLICTING"}'

q_in_queue='{"data":{"repository":{"pullRequest":{"id":"PR_node1","isInMergeQueue":true,"mergeQueueEntry":{"state":"QUEUED"},"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'
q_out='{"data":{"repository":{"pullRequest":{"id":"PR_node1","isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":null}}}}'
q_armed_only='{"data":{"repository":{"pullRequest":{"id":"PR_node1","isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'

run_queue_wait() {
  local env_args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_args+=("$1")
    shift
  done
  shift || true
  # Start each run at the real epoch, so anything reading an absolute time
  # still reads a plausible one, and let the run move the clock from there.
  date +%s > "$TMP_ROOT/clock"
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env STUB_SEQ_DIR="$SEQ_DIR" \
           STUB_CLOCK="$TMP_ROOT/clock" \
           STUB_REAL_DATE="$REAL_DATE" \
           STUB_REAL_SLEEP="$REAL_SLEEP" \
           QUEUE_WAIT_CONFIRM_POLLS=2 \
           QUEUE_WAIT_ARM_GRACE=120 \
           QUEUE_WAIT_PROBE_INTERVAL=0 \
           ${env_args[@]+"${env_args[@]}"} \
           .agents/skills/orch/scripts/queue-wait "$@")
}

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
# INSIDE max_wait, never added after it, so a caller's own deadline still
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

# --- 6. the squeeze allowance is per candidate verdict (KEN-886) ----------
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

# --- 7. owed polls that fit the budget exactly (KEN-886) ------------------
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
