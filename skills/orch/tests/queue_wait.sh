#!/usr/bin/env bash
# Regression tests for orch/scripts/queue-wait (vstack#819).
#
# queue-wait is the merge-queue membership waiter merge-pr § 3.2 routes on.
# Its reason to exist is the CROSS-POLL memory a re-entering orchestrator
# cannot keep: WAS_QUEUED — whether any earlier poll observed the PR queued
# or armed. Without it, "ejected from the queue" and "never entered it" look
# identical, and a PR ejected by a failed merge-group run goes unnoticed.
#
# Covered:
#   1.  merged on the first poll
#   2.  queued, then merged (WAS_QUEUED recorded, exit 0)
#   3.  ejected after being queued — THE WAS_QUEUED path
#   4.  never queued is NOT reported as ejected (the disambiguation)
#   5.  auto-merge disarmed (armed, never enqueued, arming gone)
#   6.  timeout while still queued (armed, never a success, never a failure)
#   7.  malformed / empty GraphQL response is an error, never "not queued"
#   8.  GraphQL errors[] (e.g. an unsupported field on older GHES)
#   9.  auth failure exits 3, matching ci-wait / approval-wait
#   10. failed-required-check probe delegates to ci-wait (verdict fail)
#   11. --no-check-probe suppresses that probe (the flag has teeth)
#   12. PR closed without merging
#   13. human-readable (non --json) output names the verdict
#   14. a transient GitHub error is absorbed inside the wait budget
#   15-19. argument validation, --help, low-confidence one-poll flag, budget bound
#   20. late-findings guard (vstack#1289): a NEW unresolved thread while
#       queued dequeues via dequeuePullRequest with the PR node id
#   21. pre-existing (and since-resolved) threads never trigger the guard
#   22. a failed thread fetch is no evidence — no dequeue, keep polling, warn
#   23. --no-guard restores unguarded queueing (no thread reads at all)
#   24. a failed dequeue mutation is loud (late_findings_dequeue_failed)
#   25. armed-but-never-enqueued guard path disables auto-merge
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

assert_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/seq"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

# Sequenced `gh` stub. Each poll of queue-wait makes exactly one
# `gh pr view --json state,mergedAt` call and one queue-membership
# `gh api graphql` call, so independent counters replay a per-poll script of
# fixtures, routed by query content so guard traffic never shifts the queue
# sequence:
#   $STUB_SEQ_DIR/state-<n>.json   PR state for poll n
#   $STUB_SEQ_DIR/queue-<n>.json   queue-membership GraphQL body for poll n
#   $STUB_SEQ_DIR/threads-<n>.json reviewThreads body for guard probe n
#                                  (default: zero threads, so legacy cases
#                                  run with the guard on and quiet)
#   $STUB_SEQ_DIR/dequeue-<n>.json dequeue/disable-auto-merge mutation reply
# Mutations are also appended to $STUB_SEQ_DIR/mutations.log (name + args)
# so tests can assert a dequeue was or was not issued.
# `<prefix>-last.json` serves every poll past the last numbered fixture.
# Optional sidecars: `<prefix>-<n>.exit` (exit code) and `<prefix>-<n>.err`
# (stderr text, for transient-failure classification).
# Other `gh pr view --json ...` shapes (mergeStateStatus, headRefOid) and
# `gh pr checks` belong to the real ci-wait the probe delegates to, and are
# served independently of the poll counters.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

_stub_auth_ok() {
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$tok" ]]; then
    [[ -n "${STUB_GH_VALID_TOKEN:-}" && "$tok" == "$STUB_GH_VALID_TOKEN" ]] && return 0
    return 1
  fi
  [[ "${STUB_GH_DENY_KEYRING:-0}" == "1" ]] && return 1
  return 0
}

_next() {
  local f="$STUB_SEQ_DIR/$1.count" n=0
  [[ -f "$f" ]] && n="$(cat "$f")"
  n=$((n + 1))
  printf '%s' "$n" > "$f"
  printf '%s' "$n"
}

_emit_fixture() {
  local prefix="$1" n="$2" default_body="${3:-}" f
  f="$STUB_SEQ_DIR/$prefix-$n.json"
  [[ -f "$f" ]] || f="$STUB_SEQ_DIR/$prefix-last.json"
  if [[ ! -f "$f" ]]; then
    if [[ -n "$default_body" ]]; then
      printf '%s\n' "$default_body"
      exit 0
    fi
    printf 'stub: no fixture for %s-%s\n' "$prefix" "$n" >&2
    exit 1
  fi
  [[ -f "${f%.json}.err" ]] && cat "${f%.json}.err" >&2
  cat "$f"
  if [[ -f "${f%.json}.exit" ]]; then
    exit "$(cat "${f%.json}.exit")"
  fi
  exit 0
}

_args_have() {
  local needle="$1"
  shift
  local a
  for a in "$@"; do
    [[ "$a" == "$needle" ]] && return 0
  done
  return 1
}

_args_have_sub() {
  local needle="$1"
  shift
  local a
  for a in "$@"; do
    [[ "$a" == *"$needle"* ]] && return 0
  done
  return 1
}

case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      if _stub_auth_ok; then
        echo "Logged in"
        exit 0
      fi
      echo "auth failed" >&2
      exit 1
    fi
    ;;
  api)
    if [[ "${2:-}" == "graphql" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      if _args_have_sub "reviewThreads" "$@"; then
        _emit_fixture threads "$(_next threads)" \
          '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
      fi
      if _args_have_sub "dequeuePullRequest" "$@"; then
        printf 'dequeuePullRequest %s\n' "$*" >> "$STUB_SEQ_DIR/mutations.log"
        _emit_fixture dequeue "$(_next dequeue)"
      fi
      if _args_have_sub "disablePullRequestAutoMerge" "$@"; then
        printf 'disablePullRequestAutoMerge %s\n' "$*" >> "$STUB_SEQ_DIR/mutations.log"
        _emit_fixture dequeue "$(_next dequeue)"
      fi
      _emit_fixture queue "$(_next graphql)"
    fi
    if [[ "${2:-}" == "user" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "test-user"
      exit 0
    fi
    # ci-wait's superseded-run correlation (never reached by these fixtures,
    # whose failing checks carry no Actions link).
    if [[ "${2:-}" == repos/*/actions/runs* ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo '{"workflow_runs":[]}'
      exit 0
    fi
    ;;
  repo)
    if [[ "${2:-}" == "view" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "owner/repo"
      exit 0
    fi
    ;;
  pr)
    if [[ "${2:-}" == "view" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      if _args_have "state,mergedAt" "$@"; then
        _emit_fixture state "$(_next prview)"
      fi
      if _args_have "headRefOid" "$@"; then
        echo "${STUB_HEAD_SHA:-737bce791577e140436490e0fed5751bb5144a61}"
        exit 0
      fi
      # ci-wait's conflict preflight.
      echo "CLEAN"
      exit 0
    fi
    if [[ "${2:-}" == "checks" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
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

cat > "$TMP_ROOT/bin/op" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'op called: %s\n' "\$*" >>"$TMP_ROOT/op.calls"
exit 1
EOF
chmod +x "$TMP_ROOT/bin/op"

# --- fixture authoring -----------------------------------------------------

SEQ_DIR=""

new_case() {
  SEQ_DIR="$TMP_ROOT/seq/$1"
  rm -rf "$SEQ_DIR"
  mkdir -p "$SEQ_DIR"
}

# write_fixture <prefix> <n|last> <json> [exit_code] [stderr_text]
write_fixture() {
  local prefix="$1" n="$2" body="$3" code="${4:-}" err="${5:-}"
  printf '%s' "$body" > "$SEQ_DIR/$prefix-$n.json"
  [[ -n "$code" ]] && printf '%s' "$code" > "$SEQ_DIR/$prefix-$n.exit"
  [[ -n "$err" ]] && printf '%s\n' "$err" > "$SEQ_DIR/$prefix-$n.err"
  return 0
}

pr_open='{"state":"OPEN","mergedAt":null}'
pr_merged='{"state":"MERGED","mergedAt":"2026-07-24T10:00:00Z"}'
pr_closed='{"state":"CLOSED","mergedAt":null}'

# In the merge queue (and armed), out of it entirely, and armed-only (plain
# auto-merge repo shape: enabled but never enqueued).
q_in_queue='{"data":{"repository":{"pullRequest":{"id":"PR_node123","isInMergeQueue":true,"mergeQueueEntry":{"state":"QUEUED"},"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'
q_out='{"data":{"repository":{"pullRequest":{"id":"PR_node123","isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":null}}}}'
q_armed_only='{"data":{"repository":{"pullRequest":{"id":"PR_node123","isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'

# Late-findings guard (vstack#1289) fixtures: unresolved review-thread sets
# and the dequeue-mutation replies.
t_none='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
t_pre='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PRRT_pre1","isResolved":false},{"id":"PRRT_pre2","isResolved":false}]}}}}}'
t_pre_one_resolved='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PRRT_pre1","isResolved":false},{"id":"PRRT_pre2","isResolved":true}]}}}}}'
t_late='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PRRT_late1","isResolved":false}]}}}}}'
dq_ok='{"data":{"dequeuePullRequest":{"mergeQueueEntry":{"id":"MQE_1"}}}}'
dq_err='{"errors":[{"message":"Pull request is not in the merge queue"}]}'
am_ok='{"data":{"disablePullRequestAutoMerge":{"clientMutationId":null}}}'

# Run queue-wait through the .agents symlink, exactly how it is invoked in
# production. `env "$@"` injects the stub's fixture directory and knobs; the
# trailing args are the caller-visible ones.
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
           "${env_args[@]}" \
           .agents/skills/orch/scripts/queue-wait "$@")
}

echo "=== queue-wait (vstack#819) ==="

# --- 1. merged on the first poll -------------------------------------------
new_case merged_now
write_fixture state last "$pr_merged"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e1"
out="$(run_queue_wait -- 1 1 10 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "merged exits 0" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "merged" "merged verdict" "$err"
assert_eq "$(jq -r .status <<<"$out")" "complete" "merged status complete" "$err"
assert_eq "$(jq -r .merged_at <<<"$out")" "2026-07-24T10:00:00Z" "merged_at reported" "$err"

# --- 2. queued, then merged ------------------------------------------------
new_case queued_then_merged
write_fixture state 1 "$pr_open"
write_fixture state last "$pr_merged"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e2"
out="$(run_queue_wait -- 1 1 10 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "queued-then-merged exits 0" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "merged" "queued-then-merged verdict" "$err"
assert_eq "$(jq -r .was_queued <<<"$out")" "true" "WAS_QUEUED survives the poll that merged" "$err"

# --- 3. ejected after being queued (THE WAS_QUEUED path) -------------------
new_case ejected
write_fixture state last "$pr_open"
write_fixture queue 1 "$q_in_queue"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e3"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "ejection exits 1" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "ejected" "ejected verdict after queue membership is lost" "$err"
assert_eq "$(jq -r .status <<<"$out")" "complete" "ejected status complete" "$err"
assert_eq "$(jq -r .was_queued <<<"$out")" "true" "ejected records WAS_QUEUED" "$err"
assert_eq "$(jq -r .was_in_merge_queue <<<"$out")" "true" "ejected records queue membership" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "merge_group_failed" "ejected cause" "$err"

# 3b. a single out-of-queue blip does not eject on its own: with the
# confirmation raised past the poll budget the wait keeps running and the
# deadline still reports the candidate, never a silent "queued".
new_case ejected_single_blip
write_fixture state last "$pr_open"
write_fixture queue 1 "$q_in_queue"
write_fixture queue 2 "$q_out"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e3b"
out="$(run_queue_wait QUEUE_WAIT_CONFIRM_POLLS=2 -- 1 1 4 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "queued" "a one-poll blip back into the queue is not an ejection" "$err"
assert_eq "$rc" "1" "unconfirmed blip still exits 1 (never silent success)" "$err"

# --- 4. never queued is NOT an ejection ------------------------------------
new_case never_queued
write_fixture state last "$pr_open"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e4"
out="$(run_queue_wait QUEUE_WAIT_ARM_GRACE=2 -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "never-queued exits 1" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "not_queued" "never-queued verdict is not_queued, not ejected" "$err"
assert_eq "$(jq -r .status <<<"$out")" "timeout" "never-queued status timeout" "$err"
assert_eq "$(jq -r .was_queued <<<"$out")" "false" "never-queued records WAS_QUEUED false" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "never_armed" "never-queued cause" "$err"

# --- 5. auto-merge disarmed ------------------------------------------------
new_case disarmed
write_fixture state last "$pr_open"
write_fixture queue 1 "$q_armed_only"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e5"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "disarm exits 1" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "disarmed" "armed-then-cleared verdict is disarmed" "$err"
assert_eq "$(jq -r .was_queued <<<"$out")" "true" "disarm records WAS_QUEUED" "$err"
assert_eq "$(jq -r .was_in_merge_queue <<<"$out")" "false" "disarm never saw queue membership" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "auto_merge_cleared" "disarm cause" "$err"

# --- 6. timeout while still queued -----------------------------------------
new_case still_queued
write_fixture state last "$pr_open"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e6"
out="$(run_queue_wait -- 1 1 3 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "still-queued deadline exits 1 (never a silent success)" "$err"
assert_eq "$(jq -r .status <<<"$out")" "timeout" "still-queued status timeout" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "queued" "still-queued verdict" "$err"
assert_eq "$(jq -r .in_merge_queue <<<"$out")" "true" "still-queued reports live membership" "$err"
assert_eq "$(jq -r .merge_queue_state <<<"$out")" "QUEUED" "still-queued reports entry state" "$err"

# --- 7. malformed / empty GraphQL response ---------------------------------
new_case malformed
write_fixture state last "$pr_open"
write_fixture queue last '{}'
err="$TMP_ROOT/e7"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "malformed queue response exits 1" "$err"
assert_eq "$(jq -r .status <<<"$out")" "error" "malformed queue response is an error" "$err"
assert_contains "$(jq -r .error <<<"$out")" "no readable pull request" "malformed error names the cause" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "unknown" "malformed never routes as not_queued/ejected" "$err"

new_case empty_body
write_fixture state last "$pr_open"
write_fixture queue last ''
err="$TMP_ROOT/e7b"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .status <<<"$out")" "error" "empty queue response is an error" "$err"

# --- 8. GraphQL errors[] ---------------------------------------------------
new_case gql_errors
write_fixture state last "$pr_open"
write_fixture queue last '{"errors":[{"message":"Field '"'"'isInMergeQueue'"'"' doesn'"'"'t exist on type '"'"'PullRequest'"'"'"}]}' 1
err="$TMP_ROOT/e8"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "GraphQL errors[] exits 1" "$err"
assert_eq "$(jq -r .status <<<"$out")" "error" "GraphQL errors[] is an error" "$err"
assert_contains "$(jq -r .error <<<"$out")" "isInMergeQueue" "GraphQL error message is surfaced" "$err"

# --- 9. auth failure -------------------------------------------------------
new_case auth_fail
write_fixture state last "$pr_open"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e9"
out="$(run_queue_wait STUB_GH_DENY_KEYRING=1 -- 1 1 10 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "3" "auth failure exits 3 (matches ci-wait/approval-wait)" "$err"
assert_eq "$(jq -r .status <<<"$out")" "error" "auth failure emits an error result" "$err"
assert_contains "$(jq -r .error <<<"$out")" "no working GitHub auth path" "auth failure names the ladder" "$err"

# --- 10. failed-required-check probe delegates to ci-wait ------------------
new_case probe_fail
write_fixture state last "$pr_open"
write_fixture queue last "$q_armed_only"
err="$TMP_ROOT/e10"
out="$(run_queue_wait STUB_PR_CHECKS_MODE=failure -- 1 1 20 --json 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "failed required check exits 1" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "disarmed" "armed PR with a failed required check is disarmed" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "check_failed" "probe cause is check_failed" "$err"

# --- 11. --no-check-probe suppresses the probe -----------------------------
new_case probe_off
write_fixture state last "$pr_open"
write_fixture queue last "$q_armed_only"
err="$TMP_ROOT/e11"
out="$(run_queue_wait STUB_PR_CHECKS_MODE=failure -- 1 1 3 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "queued" "--no-check-probe leaves an armed PR queued (flag has teeth)" "$err"

# --- 12. closed without merging --------------------------------------------
new_case closed
write_fixture state last "$pr_closed"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e12"
out="$(run_queue_wait -- 1 1 10 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "closed PR exits 1" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "closed" "closed PR verdict" "$err"

# --- 13. human-readable output ---------------------------------------------
new_case human
write_fixture state last "$pr_open"
write_fixture queue 1 "$q_in_queue"
write_fixture queue last "$q_out"
err="$TMP_ROOT/e13"
out="$(run_queue_wait -- 1 1 20 --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_contains "$out" "Merge queue: ejected" "non-JSON output names the ejection" "$err"

# --- 14. transient GitHub error absorbed -----------------------------------
new_case transient
write_fixture state 1 "$pr_open"
write_fixture state last "$pr_merged"
write_fixture queue 1 '' 1 "HTTP 502: Bad Gateway"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e14"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "transient error absorbed, wait completes" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "merged" "transient error does not change the verdict" "$err"
assert_eq "$(jq -r '.transient_api_errors // 0' <<<"$out")" "1" "transient error counted in JSON" "$err"


# --- 15. argument validation: poll_interval > max_wait (vstack#972) ---------
# The reported invocation shape: `queue-wait 481 1800` reads as poll=1800,
# max=600 and can only ever poll once while overshooting the budget.
new_case argval_swapped
err="$TMP_ROOT/e15"
run_queue_wait -- 1 1800 600 --json --no-check-probe >/dev/null 2>"$err" && rc=0 || rc=$?
assert_eq "$rc" "2" "poll_interval > max_wait exits 2" "$err"
assert_contains "$(cat "$err")" "exceeds max_wait" "swapped-arg error names the cause" "$err"

# --- 16. argument validation: non-numeric interval --------------------------
new_case argval_nonnumeric
err="$TMP_ROOT/e16"
run_queue_wait -- 1 abc 600 --json --no-check-probe >/dev/null 2>"$err" && rc=0 || rc=$?
assert_eq "$rc" "2" "non-numeric poll_interval exits 2" "$err"
assert_contains "$(cat "$err")" "positive integer" "non-numeric error is explicit" "$err"

# --- 17. --help prints usage and exits 0 ------------------------------------
new_case help
err="$TMP_ROOT/e17"
out="$(run_queue_wait -- --help 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "--help exits 0" "$err"
assert_contains "$out" "Usage: queue-wait" "--help prints usage" "$err"

# --- 18. a one-poll queued verdict is flagged low-confidence -----------------
# With poll_interval == max_wait the loop polls exactly once. The "still queued"
# observation is then a single sample; the verdict must say so, in both the
# human line and the JSON (last_poll_age_seconds), so a routing caller does not
# read a stale one-poll observation as live.
new_case one_poll_queued
write_fixture state last "$pr_open"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e18"
out="$(run_queue_wait -- 1 1 1 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "queued" "one-poll still-queued verdict" "$err"
assert_eq "$(jq -r .polls <<<"$out")" "1" "exactly one poll happened" "$err"
assert_eq "$(jq -r 'has("last_poll_age_seconds")' <<<"$out")" "true" "JSON exposes last_poll_age_seconds" "$err"
herr="$TMP_ROOT/e18h"
hout="$(run_queue_wait -- 1 1 1 --no-check-probe 2>"$herr")" && rc=0 || rc=$?
assert_contains "$hout" "LOW CONFIDENCE" "one-poll human verdict is flagged low-confidence" "$herr"

# --- 19. max_wait is a real upper bound (sleep clamped to remaining) ---------
# poll_interval 3 with max_wait 4: the second poll's full interval would push
# elapsed to ~6 unless the final sleep is clamped to the ~1s of remaining budget.
new_case budget_upper_bound
write_fixture state last "$pr_open"
write_fixture queue last "$q_in_queue"
err="$TMP_ROOT/e19"
out="$(run_queue_wait -- 1 3 4 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
elapsed_seconds="$(jq -r .elapsed_seconds <<<"$out")"
if [[ "$elapsed_seconds" =~ ^[0-9]+$ ]] && [ "$elapsed_seconds" -le 5 ]; then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "elapsed ($elapsed_seconds s) stays within max_wait+1 (clamped sleep)"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        elapsed_seconds=%s (want <= 5)\n' "budget upper bound" "$elapsed_seconds"; dump_stderr "$err"
fi

# --- 20. late-findings guard: NEW unresolved thread while queued dequeues ----
# Poll 1 baselines an empty thread set; poll 2 sees PRRT_late1 → the guard
# must issue dequeuePullRequest with the PR NODE id (not the queue-entry id)
# and exit 1 with verdict dequeued / cause late_findings (vstack#1289).
new_case guard_dequeue
write_fixture state last "$pr_open"
write_fixture queue last "$q_in_queue"
write_fixture threads 1 "$t_none"
write_fixture threads last "$t_late"
write_fixture dequeue last "$dq_ok"
err="$TMP_ROOT/e20"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "late-findings dequeue exits 1" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "dequeued" "late-findings verdict is dequeued" "$err"
assert_eq "$(jq -r .status <<<"$out")" "complete" "late-findings status complete" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "late_findings" "late-findings cause" "$err"
assert_eq "$(jq -r .unresolved_count <<<"$out")" "1" "unresolved count reported" "$err"
assert_contains "$(cat "$SEQ_DIR/mutations.log" 2>/dev/null)" "dequeuePullRequest" "dequeue mutation issued" "$err"
assert_contains "$(cat "$SEQ_DIR/mutations.log" 2>/dev/null)" "PR_node123" "dequeue passes the PR node id" "$err"

# 20h. same shape, human-readable output names the dequeue.
new_case guard_dequeue_human
write_fixture state last "$pr_open"
write_fixture queue last "$q_in_queue"
write_fixture threads 1 "$t_none"
write_fixture threads last "$t_late"
write_fixture dequeue last "$dq_ok"
err="$TMP_ROOT/e20h"
out="$(run_queue_wait -- 1 1 20 --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_contains "$out" "Merge queue: dequeued" "non-JSON output names the dequeue" "$err"

# --- 21. pre-existing threads never trigger the guard ------------------------
# Two threads unresolved at entry (the caller's problem — approval-wait gates
# those before enqueue); one resolves while queued. Neither the standing
# baseline nor the resolution may dequeue.
new_case guard_preexisting
write_fixture state last "$pr_open"
write_fixture queue last "$q_in_queue"
write_fixture threads 1 "$t_pre"
write_fixture threads last "$t_pre_one_resolved"
err="$TMP_ROOT/e21"
out="$(run_queue_wait -- 1 1 3 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "queued" "pre-existing threads leave the PR queued" "$err"
assert_eq "$([ -f "$SEQ_DIR/mutations.log" ] && echo present || echo absent)" "absent" "no mutation for pre-existing threads" "$err"
assert_eq "$(jq -r .unresolved_count <<<"$out")" "1" "count tracks the live unresolved set" "$err"

# --- 22. a failed thread fetch is no evidence --------------------------------
# Every guard fetch fails: no dequeue may be fabricated, the wait keeps
# polling to its deadline, and 3 consecutive failures warn on stderr.
new_case guard_fetch_fail
write_fixture state last "$pr_open"
write_fixture queue last "$q_in_queue"
write_fixture threads last '' 1 "HTTP 502: Bad Gateway"
err="$TMP_ROOT/e22"
out="$(run_queue_wait -- 1 1 5 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "blind guard still exits 1 at the deadline" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "queued" "fetch failure never fabricates a dequeue" "$err"
assert_eq "$([ -f "$SEQ_DIR/mutations.log" ] && echo present || echo absent)" "absent" "no mutation on fetch failure" "$err"
assert_contains "$(cat "$err")" "thread fetch failed 3 consecutive" "consecutive fetch failures warn" "$err"

# --- 23. --no-guard restores unguarded queueing ------------------------------
# Same trigger fixtures as case 20: with the guard off there must be no
# thread read at all (the flag has teeth), no mutation, and the old
# still-queued timeout verdict.
new_case guard_off
write_fixture state last "$pr_open"
write_fixture queue last "$q_in_queue"
write_fixture threads 1 "$t_none"
write_fixture threads last "$t_late"
write_fixture dequeue last "$dq_ok"
err="$TMP_ROOT/e23"
out="$(run_queue_wait -- 1 1 3 --json --no-check-probe --no-guard 2>"$err")" && rc=0 || rc=$?
assert_eq "$(jq -r .verdict <<<"$out")" "queued" "--no-guard leaves the PR queued" "$err"
assert_eq "$([ -f "$SEQ_DIR/threads.count" ] && echo present || echo absent)" "absent" "--no-guard never reads threads" "$err"
assert_eq "$([ -f "$SEQ_DIR/mutations.log" ] && echo present || echo absent)" "absent" "--no-guard never mutates" "$err"

# --- 24. a failed dequeue mutation is loud -----------------------------------
new_case guard_dequeue_fail
write_fixture state last "$pr_open"
write_fixture queue last "$q_in_queue"
write_fixture threads 1 "$t_none"
write_fixture threads last "$t_late"
write_fixture dequeue last "$dq_err" 1
err="$TMP_ROOT/e24"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "failed dequeue exits 1" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "dequeued" "failed dequeue keeps the dequeued verdict" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "late_findings_dequeue_failed" "failed dequeue has its own cause" "$err"
assert_eq "$(jq -r .status <<<"$out")" "error" "failed dequeue is an error result" "$err"
assert_contains "$(jq -r .error <<<"$out")" "STILL QUEUED" "failed dequeue states the PR is still queued" "$err"
assert_contains "$(cat "$SEQ_DIR/mutations.log" 2>/dev/null)" "dequeuePullRequest" "failed dequeue was attempted" "$err"

# --- 25. armed-but-never-enqueued guard path disables auto-merge -------------
new_case guard_armed_only
write_fixture state last "$pr_open"
write_fixture queue last "$q_armed_only"
write_fixture threads 1 "$t_none"
write_fixture threads last "$t_late"
write_fixture dequeue last "$am_ok"
err="$TMP_ROOT/e25"
out="$(run_queue_wait -- 1 1 20 --json --no-check-probe 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "1" "armed-only late finding exits 1" "$err"
assert_eq "$(jq -r .verdict <<<"$out")" "dequeued" "armed-only verdict is dequeued" "$err"
assert_eq "$(jq -r .cause <<<"$out")" "late_findings" "armed-only cause" "$err"
assert_contains "$(cat "$SEQ_DIR/mutations.log" 2>/dev/null)" "disablePullRequestAutoMerge" "armed-only path disables auto-merge" "$err"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
