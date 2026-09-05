#!/usr/bin/env bash
# Tests for orch/scripts/queue-wait, the merge-queue membership waiter
# merge-pr § 3.2 routes on. Its reason to exist is the cross-poll memory a
# re-entering orchestrator cannot keep, WAS_QUEUED: whether any prior poll saw
# the PR queued or armed, without which an ejection and a PR that never
# entered the queue look the same. Beside it, the late-findings guard that
# dequeues on an unresolved thread, and the progress signal on a still-queued
# deadline.
#
# One case per behaviour surface; shaped input is one table per case, one
# asserted row per shape. A row stages its own fixture sequence; its `expect`
# names the fields it pins and `observe` reads exactly those, so a row fails
# on the field it names.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# The pass/fail counters and the assertion vocabulary every waiter suite shares.
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/seq"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

# Sequenced `gh` stub. Each poll makes one `gh pr view --json
# state,mergedAt,mergeable` call, that field list matched EXACTLY by the
# router below, and one queue-membership `gh api graphql` call; independent
# counters replay a per-poll script of fixtures, routed by query content so
# guard traffic never shifts the queue sequence:
#   $STUB_SEQ_DIR/state-<n>.json   PR state for poll n
#   $STUB_SEQ_DIR/queue-<n>.json   queue-membership GraphQL body for poll n
#   $STUB_SEQ_DIR/threads-<n>.json reviewThreads body for guard probe n
#                                  (default: zero threads, so legacy cases
#                                  run with the guard on and quiet)
#   $STUB_SEQ_DIR/dequeue-<n>.json dequeue/disable-auto-merge mutation reply
#   $STUB_SEQ_DIR/checkruns-<n>.json REST check-runs body for the n-th
#                                  progress read of the merge-queue head
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
    # queue-wait's progress read of the merge-queue head commit.
    if [[ "${2:-}" == repos/*/commits/*/check-runs* ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      _emit_fixture checkruns "$(_next checkruns)"
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
      if _args_have "state,mergedAt,mergeable" "$@"; then  # EXACT: a substring match serves this fixture whatever fields were asked for, so a dropped field would read as empty with the suite green
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

# Late-findings guard fixtures: unresolved review-thread sets,
# anomalous read shapes (each planting an unresolved node so a fail-open read
# would fire), and the mutation replies.
t_none='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
t_pre_one_resolved='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false},{"isResolved":true}]}}}}}'
t_all_resolved='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":true},{"isResolved":true}]}}}}}'
t_late='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false}]}}}}}'
t_rt_null='{"data":{"repository":{"pullRequest":{"reviewThreads":null}}}}'
t_bad_bool='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":"false"}]}}}}}'
t_cursor_null='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":null},"nodes":[{"isResolved":false}]}}}}}'
t_cursor_stuck='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"isResolved":false}]}}}}}'
# GitHub answers 200 with BOTH data and a top-level errors array when part of
# the query failed. The thread set beside it is a partial view, so counting it
# would undercount the blockers the guard exists to see.
t_partial_errors='{"errors":[{"message":"Something went wrong"}],"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false}]}}}}}'
# An `errors` field that is present but not an ARRAY is a malformed body. Both
# of these measure zero length, so a length-only check reads them as "no
# errors" and counts the data beside them — the empty object is the shape that
# slips through, and the empty string is the same hole in another type.
t_object_errors='{"errors":{},"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false}]}}}}}'
t_string_errors='{"errors":"","data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false}]}}}}}'
dq_ok='{"data":{"dequeuePullRequest":{"mergeQueueEntry":{"id":"MQE_1"}}}}'
dq_err='{"errors":[{"message":"Pull request is not in the merge queue"}]}'
am_ok='{"data":{"disablePullRequestAutoMerge":{"clientMutationId":null}}}'
am_errs_on_200='{"data":{"disablePullRequestAutoMerge":null},"errors":[{"message":"auto merge is not enabled"}]}'

# Progress-signal fixtures: a queue entry that exposes its
# merge-group head commit, and REST check-runs bodies for that commit.
q_in_queue_head='{"data":{"repository":{"pullRequest":{"id":"PR_node123","isInMergeQueue":true,"mergeQueueEntry":{"state":"AWAITING_CHECKS","position":1,"headCommit":{"oid":"aaa111"}},"autoMergeRequest":{"enabledAt":"2026-07-24T09:00:00Z"}}}}}'
# checkruns_body <completed> <in_progress>
checkruns_body() {
  local done="$1" pending="$2" runs="" i
  for i in $(seq 1 "$done"); do runs+='{"name":"c'"$i"'","status":"completed","conclusion":"success"},'; done
  for i in $(seq 1 "$pending"); do runs+='{"name":"p'"$i"'","status":"in_progress","conclusion":null},'; done
  printf '{"total_count":%d,"check_runs":[%s]}' "$((done + pending))" "${runs%,}"
}

# Virtual clock, on the same PATH as the gh stub: `date +%s` reads a file the
# `sleep` stub advances, so every budget here is spent in arithmetic instead of
# in real seconds, and the deadline cases stop racing the runner. Rationale and
# the per-case escape hatch back to real time: lib/virtual-clock.sh.
# shellcheck source=lib/virtual-clock.sh
source "$TEST_DIR/lib/virtual-clock.sh"
virtual_clock_install "$TMP_ROOT/bin" "$TMP_ROOT/clock"

# --- harness ---------------------------------------------------------------

# stage SPEC — writes one case's fixtures into a fresh sequence directory.
# SPEC is comma-separated `prefix:n=name` items (n a poll number or `last`),
# each name a fixture body above; two shorthands open the common worlds:
#   open_queued       state:last=open,queue:last=in
#   open_queued_head  the same with the entry exposing its head commit
#   open_armed        state:last=open,queue:last=armed
# A name ending in a failure reads as the sidecar it needs: `fail502` is an
# empty body, exit 1 and an HTTP 502 on stderr; `gql_errors` and `dq_err`
# exit 1 with their body. `threads:pages=N` writes N pages that keep promising
# more and an unresolved terminal page after them; `checkruns:advancing=N`
# writes N reads whose completed count grows by one each poll with one run
# still in progress; `checkruns:<n>=cD.P` is D completed and P in progress.
stage() {
  local spec="$1" items item prefix n name i
  new_case "$((++STAGE_SEQ))"
  IFS=',' read -ra items <<<"$spec"
  for item in "${items[@]}"; do
    case "$item" in
      open_queued) write_fixture state last "$pr_open"; write_fixture queue last "$q_in_queue"; continue ;;
      open_queued_head) write_fixture state last "$pr_open"; write_fixture queue last "$q_in_queue_head"; continue ;;
      open_armed) write_fixture state last "$pr_open"; write_fixture queue last "$q_armed_only"; continue ;;
    esac
    prefix="${item%%:*}"
    n="${item#*:}"; n="${n%%=*}"
    name="${item#*=}"
    case "$prefix:$name" in
      *:fail502) write_fixture "$prefix" "$n" '' 1 "HTTP 502: Bad Gateway" ;;
      state:open) write_fixture state "$n" "$pr_open" ;;
      state:merged) write_fixture state "$n" "$pr_merged" ;;
      state:closed) write_fixture state "$n" "$pr_closed" ;;
      queue:in) write_fixture queue "$n" "$q_in_queue" ;;
      queue:in_head) write_fixture queue "$n" "$q_in_queue_head" ;;
      queue:out) write_fixture queue "$n" "$q_out" ;;
      queue:armed) write_fixture queue "$n" "$q_armed_only" ;;
      queue:braces) write_fixture queue "$n" '{}' ;;
      queue:empty) write_fixture queue "$n" '' ;;
      queue:gql_errors) write_fixture queue "$n" '{"errors":[{"message":"Field '"'"'isInMergeQueue'"'"' doesn'"'"'t exist on type '"'"'PullRequest'"'"'"}]}' 1 ;;
      threads:none) write_fixture threads "$n" "$t_none" ;;
      threads:late) write_fixture threads "$n" "$t_late" ;;
      threads:pre_one_resolved) write_fixture threads "$n" "$t_pre_one_resolved" ;;
      threads:all_resolved) write_fixture threads "$n" "$t_all_resolved" ;;
      threads:rt_null) write_fixture threads "$n" "$t_rt_null" ;;
      threads:bad_bool) write_fixture threads "$n" "$t_bad_bool" ;;
      threads:cursor_null) write_fixture threads "$n" "$t_cursor_null" ;;
      threads:cursor_stuck) write_fixture threads "$n" "$t_cursor_stuck" ;;
      threads:partial_errors) write_fixture threads "$n" "$t_partial_errors" ;;
      threads:object_errors) write_fixture threads "$n" "$t_object_errors" ;;
      threads:string_errors) write_fixture threads "$n" "$t_string_errors" ;;
      threads:*)
        [[ "$n" == pages ]] || { echo "stage: unknown fixture $item" >&2; exit 1; }
        for i in $(seq 1 "$name"); do
          write_fixture threads "$i" '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"c'"$i"'"},"nodes":[{"isResolved":false}]}}}}}'
        done
        write_fixture threads "$((name + 1))" "$t_late"
        ;;
      dequeue:am_ok) write_fixture dequeue "$n" "$am_ok" ;;
      dequeue:dq_ok) write_fixture dequeue "$n" "$dq_ok" ;;
      dequeue:dq_err) write_fixture dequeue "$n" "$dq_err" 1 ;;
      dequeue:am_errs_on_200) write_fixture dequeue "$n" "$am_errs_on_200" ;;
      checkruns:queued_run) write_fixture checkruns "$n" '{"total_count":2,"check_runs":[{"name":"c1","status":"completed","conclusion":"success"},{"name":"q1","status":"queued","conclusion":null}]}' ;;
      checkruns:c*.*)
        [[ "$name" =~ ^c([0-9]+)\.([0-9]+)$ ]] || { echo "stage: unknown fixture $item" >&2; exit 1; }
        write_fixture checkruns "$n" "$(checkruns_body "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")"
        ;;
      checkruns:*)
        [[ "$n" == advancing ]] || { echo "stage: unknown fixture $item" >&2; exit 1; }
        for i in $(seq 1 "$name"); do
          write_fixture checkruns "$i" "$(checkruns_body "$i" 1)"
        done
        ;;
      *) echo "stage: unknown fixture $item" >&2; exit 1 ;;
    esac
  done
}
STAGE_SEQ=0

# run_wait ENV ARGS... — runs queue-wait through the .agents symlink, exactly
# how production invokes it, with the staged sequence directory and the
# suite's default knobs; ENV is a comma-separated list of `env` arguments
# that may override those knobs. Sets OUT, RC and ERR (the stderr file).
run_wait() {
  local env_list="$1" env_args=()
  shift
  [[ -z "$env_list" ]] || IFS=',' read -ra env_args <<<"$env_list"
  ERR="$SEQ_DIR/stderr"
  set +e
  OUT=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" \
    env STUB_SEQ_DIR="$SEQ_DIR" \
        QUEUE_WAIT_CONFIRM_POLLS=2 \
        QUEUE_WAIT_ARM_GRACE=120 \
        QUEUE_WAIT_PROBE_INTERVAL=0 \
        ${env_args[@]+"${env_args[@]}"} \
        .agents/skills/orch/scripts/queue-wait "$@" 2>"$ERR")
  RC=$?
  set -e
}

json() { jq -r "$1" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE; }

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order, so a row compares as one string. Plain names are JSON
# result fields; the derived names read the sequence directory or stderr:
#   has_<field>       whether the JSON carries that field at all
#   error~<text>      whether the JSON error names <text>, where the message
#                     is the fact's only carrier: which read failed, which
#                     mutation half failed, that the PR may still be queued
#   stdout            `line` when anything was printed, `empty` otherwise
#   stdout~<word>     whether the text result names that verdict word
#   help_sections     the --help sections merge-pr.md and pr-merge route an
#                     agent to, of exit_codes, environment and arm_grace
#   mutations         the GraphQL mutations issued, in order: `disable`,
#                     `dequeue`, or `none`
#   mutation_ids      the ids those mutations named, or `none`
#   thread_reads      reviewThreads reads the stub served
#   checkruns_read    whether any check-runs read reached the stub
#   guard_warned      the guard's consecutive-failure warning on stderr
#   checkrun_warned   the progress read's consecutive-failure warning
observe() {
  local got="" token name value
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      has_*) value="$(json "has(\"${name#has_}\")")" ;;
      error~*) value="$(json '.error // ""' | grep -qF -- "${name#error~}" && echo true || echo false)" ;;
      stdout) value="$([[ -n "$OUT" ]] && echo line || echo empty)" ;;
      stdout~*) value="$(grep -qF -- "${name#stdout~}" <<<"$OUT" && echo true || echo false)" ;;
      help_sections)
        value=""
        grep -q '^Exit codes:' <<<"$OUT" && value="$value,exit_codes"
        grep -q '^Environment' <<<"$OUT" && value="$value,environment"
        grep -q 'QUEUE_WAIT_ARM_GRACE' <<<"$OUT" && value="$value,arm_grace"
        value="${value#,}"; [[ -n "$value" ]] || value=none
        ;;
      mutations)
        value="$(sed -e 's/^disablePullRequestAutoMerge .*/disable/' -e 's/^dequeuePullRequest .*/dequeue/' "$SEQ_DIR/mutations.log" 2>/dev/null | paste -sd, - || true)"
        [[ -n "$value" ]] || value=none
        ;;
      mutation_ids)
        value="$(grep -o 'PR_[A-Za-z0-9]*\|MQE_[A-Za-z0-9]*' "$SEQ_DIR/mutations.log" 2>/dev/null | sort -u | paste -sd, - || true)"
        [[ -n "$value" ]] || value=none
        ;;
      thread_reads) value="$(cat "$SEQ_DIR/threads.count" 2>/dev/null || echo 0)" ;;
      checkruns_read) value="$([[ -f "$SEQ_DIR/checkruns.count" ]] && echo true || echo false)" ;;
      guard_warned) value="$(grep -q 'thread fetch failed 3 consecutive' "$ERR" && echo true || echo false)" ;;
      checkrun_warned) value="$(grep -q 'check-run read failed 3 consecutive' "$ERR" && echo true || echo false)" ;;
      *) value="$(json ".$name")" ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# table DEFAULT_ARGS ROW... — one staged world, one run and one assertion per
# row. A row is `label|stage|args|env|expect`; empty args mean DEFAULT_ARGS.
# Positional args are `<pr> <poll-interval> <budget-seconds>` plus flags, on
# the virtual clock.
table() {
  local default_args="$1" row label spec args env expect
  shift
  for row in "$@"; do
    IFS='|' read -r label spec args env expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    [[ -n "$args" ]] || args="$default_args"
    stage "$spec"
    # shellcheck disable=SC2086
    run_wait "$env" $args
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

QW='1 1 20 --json --no-check-probe'

echo "=== the verdict over the PR state and queue membership sequence ==="
# WAS_QUEUED is the cross-poll memory: an entry seen queued or armed and then
# gone is ejected or disarmed; one never seen is not_queued. Membership lost
# for a single poll is not an ejection until QUEUE_WAIT_CONFIRM_POLLS agree.
# A transient API failure is absorbed and counted; the check probe delegates
# a failed required check to ci-wait unless --no-check-probe; the last sleep
# is clamped so elapsed lands on the budget; a one-poll observation exposes
# its age.
table "$QW" \
  'merged on the first poll|state:last=merged,queue:last=in|1 1 10 --json --no-check-probe||rc=0 verdict=merged status=complete merged_at=2026-07-24T10:00:00Z' \
  'queued then merged keeps WAS_QUEUED|state:1=open,state:last=merged,queue:last=in|1 1 10 --json --no-check-probe||rc=0 verdict=merged was_queued=true' \
  'membership lost after being queued is an ejection|state:last=open,queue:1=in,queue:last=out|||rc=1 verdict=ejected status=complete was_queued=true was_in_merge_queue=true cause=merge_group_failed' \
  'a one-poll blip out and back is not an ejection|state:last=open,queue:1=in,queue:2=out,queue:last=in|1 1 4 --json --no-check-probe||rc=1 verdict=queued' \
  'never queued is not_queued, not ejected|state:last=open,queue:last=out||QUEUE_WAIT_ARM_GRACE=2|rc=1 verdict=not_queued status=timeout was_queued=false cause=never_armed' \
  'armed then cleared is disarmed|state:last=open,queue:1=armed,queue:last=out|||rc=1 verdict=disarmed was_queued=true was_in_merge_queue=false cause=auto_merge_cleared' \
  'still queued at the deadline is a timeout, never a silent success|open_queued|1 1 3 --json --no-check-probe||rc=1 status=timeout verdict=queued in_merge_queue=true merge_queue_state=QUEUED' \
  'closed without merging|state:last=closed,queue:last=in|1 1 10 --json --no-check-probe||rc=1 verdict=closed' \
  'a transient error is absorbed and counted|state:1=open,state:last=merged,queue:1=fail502,queue:last=in|||rc=0 verdict=merged transient_api_errors=1' \
  'a failed required check on an armed PR disarms through the probe|open_armed|1 1 20 --json|STUB_PR_CHECKS_MODE=failure|rc=1 verdict=disarmed cause=check_failed' \
  '--no-check-probe leaves the same PR queued|open_armed|1 1 3 --json --no-check-probe|STUB_PR_CHECKS_MODE=failure|verdict=queued' \
  'a one-poll queued verdict exposes the age of its sample|open_queued|1 1 1 --json --no-check-probe||verdict=queued polls=1 has_last_poll_age_seconds=true' \
  'the last sleep is clamped to the remaining budget|open_queued|1 3 4 --json --no-check-probe||elapsed_seconds=4'

echo "=== an unreadable queue answer is an error, never not_queued ==="
# merge-pr.md § 5 hands the error to an operator, so each shape names itself:
# an unreadable body, the GraphQL message GitHub sent, the auth ladder.
table "$QW" \
  'an empty object body|state:last=open,queue:last=braces|||rc=1 status=error verdict=unknown error~readable=true' \
  'an empty body|state:last=open,queue:last=empty|||rc=1 status=error verdict=unknown error~readable=true' \
  'a GraphQL errors array surfaces its message|state:last=open,queue:last=gql_errors|||rc=1 status=error verdict=unknown error~isInMergeQueue=true' \
  'no GitHub auth path exits 3 like the other waiters|open_queued||STUB_GH_DENY_KEYRING=1|rc=3 status=error error~auth=true'

echo "=== the late-findings guard: any unresolved thread while queued or armed ==="
# Disarm first (a bare dequeue can be raced back in by the arming), then
# dequeue with the PR node id. A pre-existing unresolved thread is the same
# unsafe state; a resolved set never triggers. A failed or anomalous thread
# read is no evidence: no mutation, keep polling, warn after three (each
# anomalous body plants an unresolved node, so a fail-open reader would
# dequeue and a read-as-empty reader would stay silent without the warning).
# A failed mutation half is loud with its own cause and names the half. The
# deadline runs one last probe. The pagination walk is bounded.
DQ='dequeue:1=am_ok,dequeue:2=dq_ok'
table "$QW" \
  "an unresolved thread while queued disarms, then dequeues by node id|open_queued,threads:last=late,$DQ|||rc=1 verdict=dequeued status=complete cause=late_findings unresolved_count=1 mutations=disable,dequeue mutation_ids=PR_node123" \
  "a thread unresolved since before enqueue dequeues; the resolved sibling is not counted|open_queued,threads:last=pre_one_resolved,$DQ|||rc=1 verdict=dequeued unresolved_count=1 mutations=disable,dequeue" \
  'a fully resolved thread set never triggers|open_queued,threads:last=all_resolved|1 1 3 --json --no-check-probe||verdict=queued unresolved_count=0 mutations=none thread_reads=4' \
  'every thread fetch failing is no evidence and warns|open_queued,threads:last=fail502|1 1 5 --json --no-check-probe||rc=1 verdict=queued mutations=none guard_warned=true' \
  "a null reviewThreads is a failed read|open_queued,threads:last=rt_null,$DQ|1 1 4 --json --no-check-probe||verdict=queued mutations=none guard_warned=true" \
  "a non-boolean isResolved is a failed read|open_queued,threads:last=bad_bool,$DQ|1 1 4 --json --no-check-probe||verdict=queued mutations=none guard_warned=true" \
  "hasNextPage with a null cursor is a failed read|open_queued,threads:last=cursor_null,$DQ|1 1 4 --json --no-check-probe||verdict=queued mutations=none guard_warned=true" \
  "a cursor that never advances is a failed read|open_queued,threads:last=cursor_stuck,$DQ|1 1 4 --json --no-check-probe||verdict=queued mutations=none guard_warned=true" \
  "data beside a top-level errors array is a failed read|open_queued,threads:last=partial_errors,$DQ|1 1 4 --json --no-check-probe||verdict=queued mutations=none guard_warned=true" \
  "an errors object is a failed read|open_queued,threads:last=object_errors,$DQ|1 1 4 --json --no-check-probe||verdict=queued mutations=none guard_warned=true" \
  "an errors string is a failed read|open_queued,threads:last=string_errors,$DQ|1 1 4 --json --no-check-probe||verdict=queued mutations=none guard_warned=true" \
  "--no-guard reads no threads and mutates nothing|open_queued,threads:last=late,$DQ|1 1 3 --json --no-check-probe --no-guard||verdict=queued thread_reads=0 mutations=none" \
  'a failed dequeue half is loud and names the half|open_queued,threads:last=late,dequeue:1=am_ok,dequeue:2=dq_err|||rc=1 verdict=dequeued status=error cause=late_findings_dequeue_failed error~dequeuePullRequest=true error~QUEUED=true mutations=disable,dequeue' \
  'an errors array on an HTTP 200 disarm is a failed half; the dequeue is still attempted|open_queued,threads:last=late,dequeue:1=am_errs_on_200,dequeue:2=dq_ok|||rc=1 cause=late_findings_dequeue_failed error~disablePullRequestAutoMerge=true mutations=disable,dequeue' \
  'armed but never enqueued disables auto-merge only|open_armed,threads:last=late,dequeue:1=am_ok|||rc=1 verdict=dequeued cause=late_findings mutations=disable' \
  "the final probe at the deadline catches a late thread|open_queued,threads:1=none,threads:last=late,$DQ|1 1 1 --json --no-check-probe||verdict=dequeued polls=1 mutations=disable,dequeue" \
  "an overlong pagination walk stops at the bound, a failed read and not a count|open_queued,threads:pages=40,$DQ|1 1 1 --json --no-check-probe||verdict=queued mutations=none thread_reads=40"

echo "=== the progress signal on a budget-exhausted queued verdict ==="
# When the entry exposes its head commit, movement in the entry tuple or the
# completed check-run count within the last three polls, or a check-run still
# running, is still_progressing; measurable and unmoving is stalled. No head
# commit means progress is unobservable: null, never a check-run read. A
# failed read is unknown, never zero, warns after three, and neither erases
# the comparison baseline nor counts as movement.
table '1 1 8 --json --no-check-probe' \
  'a completed count advancing every poll is still progressing|open_queued_head,checkruns:advancing=12|1 1 4 --json --no-check-probe||rc=1 verdict=queued status=timeout progressing=true cause=still_progressing checkruns_read=true' \
  'a flat count with nothing running is stalled|open_queued_head,checkruns:last=c1.0|||verdict=queued progressing=false cause=stalled checkruns_read=true' \
  'one change older than the window, then flat, is stalled|open_queued_head,checkruns:1=c1.0,checkruns:last=c2.0|||verdict=queued progressing=false cause=stalled' \
  'a flat count with a run in progress is still progressing|open_queued_head,checkruns:last=c1.1|||verdict=queued polls=8 progressing=true cause=still_progressing' \
  'a flat count with a run queued is still progressing|open_queued_head,checkruns:last=queued_run|||progressing=true cause=still_progressing' \
  'no head commit on the entry: progress unobservable, no check-run read|open_queued,checkruns:last=c3.0|1 1 4 --json --no-check-probe||verdict=queued has_progressing=true progressing=null cause=stalled checkruns_read=false' \
  'every check-run read failing is unknown, never zero, and warns|open_queued_head,checkruns:last=fail502|1 1 5 --json --no-check-probe||verdict=queued has_progressing=true progressing=null cause=stalled checkrun_warned=true' \
  'a failed read between two reads does not erase the movement|open_queued_head,checkruns:1=c1.0,checkruns:2=fail502,checkruns:last=c2.0|1 1 4 --json --no-check-probe||verdict=queued progressing=true cause=still_progressing' \
  'a merged verdict carries progressing and no cause|state:last=merged,queue:last=in_head|1 1 10 --json --no-check-probe||verdict=merged has_progressing=true has_cause=false'

echo "=== text mode names the verdict on stdout ==="
# The line's wording beyond the verdict word is not a contract anything
# parses; what holds is that every verdict prints its own line, with the same
# exit code as --json.
table '1 1 20 --no-check-probe' \
  'ejected|state:last=open,queue:1=in,queue:last=out|||rc=1 stdout~ejected=true' \
  "dequeued|open_queued,threads:last=late,$DQ|||rc=1 stdout~dequeued=true" \
  'queued after one poll|open_queued|1 1 1 --no-check-probe||rc=1 stdout~queued=true' \
  'queued and stalled|open_queued_head,checkruns:last=c1.0|1 1 8 --no-check-probe||rc=1 stdout~queued=true'

echo "=== argument validation ends in the parser, before any gh call ==="
# The recording gh stub fails every call, so a case that reached auth or a
# poll reads as calls > 0.
mkdir -p "$TMP_ROOT/argbin"
cat > "$TMP_ROOT/argbin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/argval-gh.calls"
exit 1
EOF
chmod +x "$TMP_ROOT/argbin/gh"
# --help is routed: merge-pr.md and the github skill's pr-merge send an agent
# to its Verdicts, Exit codes and Environment sections, so those sections are
# pinned; the verdict vocabulary is the routing lint's.
arg_rows=(
  'poll_interval past max_wait is a usage error|1 1800 600 --json --no-check-probe|rc=2 stdout=empty gh_calls=0'
  'a non-numeric poll_interval is a usage error|1 abc 600 --json --no-check-probe|rc=2 stdout=empty gh_calls=0'
  'an unknown flag is refused in the parser|1 30 600 --bogus-flag|rc=2 stdout=empty gh_calls=0'
  'a missing PR number is a usage error, not exit 1||rc=2 stdout=empty gh_calls=0'
  '--help prints the routed sections and exits 0|--help|rc=0 help_sections=exit_codes,environment,arm_grace gh_calls=0'
)
for row in "${arg_rows[@]}"; do
  IFS='|' read -r label args expect <<<"$row"
  [[ -n "$expect" ]] || { printf 'args: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
  new_case "arg-$((++STAGE_SEQ))"
  : > "$TMP_ROOT/argval-gh.calls"
  ERR="$TMP_ROOT/argval.err"
  set +e
  # shellcheck disable=SC2086
  OUT=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/argbin:$PATH" .agents/skills/orch/scripts/queue-wait $args 2>"$ERR")
  RC=$?
  set -e
  got="$(observe "${expect% gh_calls=*}") gh_calls=$(wc -l <"$TMP_ROOT/argval-gh.calls" | tr -d ' ')"
  assert_eq "$got" "$expect" "$label" "$ERR"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
