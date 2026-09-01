#!/usr/bin/env bash
# Regression tests for queue-wait's `conflicting` verdict (KEN-837), split
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

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# The pass/fail counters and the assertion vocabulary every waiter suite shares.
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"

# Whole-line match, for the --help rows below. Both `conflicting` and
# `base_conflict` occur in --help prose and in the cause list, so a substring
# assertion on either word passes with the verdict's own row deleted.
assert_matches() {
  local haystack="$1" pattern="$2" name="$3"
  if grep -qE -- "$pattern" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted line matching: %s\n        in: %s\n' "$name" "$pattern" "$haystack"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/seq"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"

# Sequenced `gh` stub, one poll per numbered fixture:
#   $STUB_SEQ_DIR/state-<n>.json   `pr view --json state,mergedAt,mergeable`
#                                  (matched EXACTLY: see _args_have below)
#   $STUB_SEQ_DIR/queue-<n>.json   queue-membership GraphQL body
# `<prefix>-last.json` serves every poll past the last numbered fixture.
# Review-thread reads answer with an empty set so the late-findings guard
# stays quiet; no case here exercises it. `gh pr checks` and the Actions-run
# read belong to the real ci-wait the failed-check probe delegates to:
# STUB_PR_CHECKS_MODE=failure is what lets that probe reach a verdict at all.
# STUB_QUEUE_DELAY makes the queue read itself cost that many seconds, the
# production condition under which a confirmation count outlasts the budget.
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

# Exact, for the field list itself. Every verdict here is routed off a field
# the query names, so a substring match would serve the fixture whatever was
# asked for and a dropped field would read as empty with the suite green.
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
    if [[ "${2:-}" == "checks" ]]; then
      if [[ "${STUB_PR_CHECKS_MODE:-}" == "failure" ]]; then
        echo '[{"name":"build","state":"FAILURE"}]'
        exit 1
      fi
      echo '[{"name":"build","state":"SUCCESS"}]'
      exit 0
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

SEQ_DIR=""
new_case() {
  SEQ_DIR="$TMP_ROOT/seq/$1"
  rm -rf -- "${SEQ_DIR:?}"
  mkdir -p "$SEQ_DIR"
}

write_fixture() { # <prefix> <n|last> <json>
  printf '%s' "$3" > "$SEQ_DIR/$1-$2.json"
}

pr_state() { # <state> <mergeable>
  printf '{"state":"%s","mergedAt":%s,"mergeable":"%s"}' \
    "$1" "$([[ "$1" == "MERGED" ]] && echo '"2026-07-24T10:00:00Z"' || echo null)" "$2"
}

q_in_queue='{"data":{"repository":{"pullRequest":{"id":"PR_node1","isInMergeQueue":true,"mergeQueueEntry":{"state":"QUEUED"},"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'
q_out='{"data":{"repository":{"pullRequest":{"id":"PR_node1","isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":null}}}}'
q_armed_only='{"data":{"repository":{"pullRequest":{"id":"PR_node1","isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'

# Virtual clock, on the same PATH as the gh stub: `date +%s` reads a file the
# `sleep` stub advances, so a budget here is spent in arithmetic rather than in
# real seconds — including STUB_QUEUE_DELAY, which charges a poll its cost on
# the same clock. Rationale and the per-case escape hatch: lib/virtual-clock.sh.
# shellcheck source=lib/virtual-clock.sh
source "$TEST_DIR/lib/virtual-clock.sh"
virtual_clock_install "$TMP_ROOT/bin" "$TMP_ROOT/clock"

run_queue_wait() {
  local env_args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_args+=("$1")
    shift
  done
  shift || true
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env STUB_SEQ_DIR="$SEQ_DIR" \
           QUEUE_WAIT_CONFIRM_POLLS=2 \
           QUEUE_WAIT_ARM_GRACE=120 \
           QUEUE_WAIT_PROBE_INTERVAL=0 \
           ${env_args[@]+"${env_args[@]}"} \
           .agents/skills/orch/scripts/queue-wait "$@")
}

echo "=== queue-wait conflicting verdict (KEN-837) ==="

# --- 1. an armed, queued PR whose head conflicts with the base -------------
# The shape that used to run out the clock as "still queued, still
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
assert_contains "$out" "conflicting" "the plain line names the verdict" "$err"
assert_contains "$out" "restacked" "the plain line names the remedy" "$err"

# The remedy is a ROUTE, not a short restatement of one. merge-pr.md § 5
# step 1 fixes the restack order — disarm, dequeue, and only then push,
# because an armed PR re-enqueues itself the moment its requirements go
# green — and guard_fire enforces that same order here. A line restating a
# shorter version drifts away from it the next time the order is corrected,
# which is exactly what this line did.
assert_contains "$out" "merge-pr.md § 5 step 1" \
  "the plain line routes to the workflow that owns the restack order" "$err"
assert_contains "$out" "a push is not the first step" \
  "the line refuses the bare push a reader would otherwise infer from it" "$err"

# The --help heredoc is the semantics reference other documents point at
# instead of restating a verdict list, so deleting a row here strands them.
# The row assertion is anchored on the row, so deleting it cannot pass on the
# word appearing in the prose above. The ranking is a sentence, matched
# against a whitespace-flattened copy: it wraps mid-clause in the heredoc,
# and anchoring on a wrap point would break on any reflow of a rule that
# survived it.
help_out="$(run_queue_wait -- --help 2>/dev/null)"
help_flat="$(tr '\n' ' ' <<<"$help_out" | tr -s ' ')"
assert_matches "$help_out" '^  conflicting mergeable == "CONFLICTING": the head conflicts with the base\.$' \
  "--help carries the conflicting verdict as a row of its § Verdicts block"
assert_matches "$help_flat" 'this outranks ejected and disarmed — the fix is a restack, not a CI cycle\.' \
  "the row states the ranking that keeps a conflict out of the recovery cycle"
assert_matches "$help_out" '# only when known: base_conflict \|$' \
  "--help carries its cause in the cause list, not only in prose"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
