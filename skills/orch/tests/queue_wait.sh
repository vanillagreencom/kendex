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
# `gh pr view --json state,mergedAt` call and one `gh api graphql` call, so
# two independent counters replay a per-poll script of fixtures:
#   $STUB_SEQ_DIR/state-<n>.json   PR state for poll n
#   $STUB_SEQ_DIR/queue-<n>.json   GraphQL body for poll n
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
  local prefix="$1" n="$2" f
  f="$STUB_SEQ_DIR/$prefix-$n.json"
  [[ -f "$f" ]] || f="$STUB_SEQ_DIR/$prefix-last.json"
  if [[ ! -f "$f" ]]; then
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
q_in_queue='{"data":{"repository":{"pullRequest":{"isInMergeQueue":true,"mergeQueueEntry":{"state":"QUEUED"},"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'
q_out='{"data":{"repository":{"pullRequest":{"isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":null}}}}'
q_armed_only='{"data":{"repository":{"pullRequest":{"isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'

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

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
