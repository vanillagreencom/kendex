#!/usr/bin/env bash
set -euo pipefail

export SECOND_OPINION_CURRENT_MODEL=none

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
ABANDON_SESSION=""
ABANDON_TOKEN=""
STARTUP_SESSION=""
STARTUP_TOKEN=""
owned_group_member() {
  local token="$1" group="$2" environ pid stat rest
  for environ in /proc/[1-9]*/environ; do
    [[ -r "$environ" ]] || continue
    { tr '\0' '\n' < "$environ"; } 2>/dev/null \
      | grep -Fqx "TEST_SESSION_TOKEN=$token" || continue
    pid="${environ#/proc/}"
    pid="${pid%/environ}"
    [[ -r "/proc/$pid/stat" ]] || continue
    stat="$(cat < "/proc/$pid/stat")"
    rest="${stat##*) }"
    set -- $rest
    [[ $# -ge 3 && "$3" == "$group" ]] || continue
    printf '%s\n' "$pid"
    return 0
  done
  return 1
}
cleanup() {
  if [[ -n "$ABANDON_SESSION" ]]; then
    if owned_group_member "$ABANDON_TOKEN" "$ABANDON_SESSION" >/dev/null; then
      kill -TERM -- "-$ABANDON_SESSION" 2>/dev/null || true
    fi
    wait "$ABANDON_SESSION" 2>/dev/null || true
  fi
  if [[ -n "$STARTUP_SESSION" ]] \
      && owned_group_member "$STARTUP_TOKEN" "$STARTUP_SESSION" >/dev/null; then
    kill -KILL -- "-$STARTUP_SESSION" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/proj/skills" "$TMP_ROOT/bin" "$TMP_ROOT/work"
cat > "$TMP_ROOT/bin/ps" <<'SH'
#!/usr/bin/env bash
mode=""; while [[ $# -gt 0 ]]; do case "$1" in -o) mode="$2"; shift 2 ;; *) shift ;; esac; done
case "$mode" in ppid=) printf '1\n' ;; comm=) printf 'bash\n' ;; esac
SH
chmod +x "$TMP_ROOT/bin/ps"
PATH="$TMP_ROOT/bin:$PATH"
export PATH
unset CLAUDECODE CLAUDE_CODE CLAUDE_PROJECT_DIR CODEX_SANDBOX \
  CODEX_SANDBOX_NETWORK_DISABLED PI_CODING_AGENT_DIR OPENCODE \
  CURSOR_AGENT CURSOR_TRACE_ID
git init -q "$TMP_ROOT/proj"
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SECOND_OPINION="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"
RUNTIME="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion-runtime"

git -C "$TMP_ROOT/work" init -q
git -C "$TMP_ROOT/work" config user.email test@example.com
git -C "$TMP_ROOT/work" config user.name test
printf 'scope\n' > "$TMP_ROOT/work/file.txt"
git -C "$TMP_ROOT/work" add file.txt
git -C "$TMP_ROOT/work" -c commit.gpgsign=false commit -q -m init

cat > "$TMP_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
if [[ -n "${CAPTURE_PROMPT_FILE:-}" ]]; then cat > "$CAPTURE_PROMPT_FILE"; else cat >/dev/null; fi
if [[ "${FAKE_REVIEW:-}" == "1" ]]; then
  target="${0##*/}"
  printf '{"agent":"external-%s","verdict":"pass","summary":"%s","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}\n' "$target" "$target"
  exit 0
fi
if [[ "${FAKE_MODE:-success}" == "nested" ]]; then
  trap '' TERM
  (
    trap '' TERM
    while :; do printf 'tick\n' >> "$HEARTBEAT_FILE"; sleep 0.05; done
  ) &
  wait
fi
if [[ "${FAKE_MODE:-success}" == "abandon" ]]; then
  on_term() {
    printf 'terminated\n' > "$FAKE_CLI_TERM_FILE"
    exit 0
  }
  trap on_term TERM HUP
  printf '%s\n' "$$" > "$FAKE_CLI_PID_FILE"
  printf 'ready\n' > "$FAKE_CLI_READY_FILE"
  while :; do sleep 1; done
fi
if [[ "${FAKE_MODE:-success}" == "early" ]]; then
  (
    trap '' TERM
    while :; do printf 'tick\n' >> "$HEARTBEAT_FILE"; sleep 0.05; done
  ) &
  printf 'ready\n' > "$FAKE_CLI_READY_FILE"
  exit 0
fi
if [[ "${FAKE_MODE:-success}" == "startup" ]]; then
  trap '' TERM HUP
  printf '%s\n' "$$" > "$FAKE_CLI_PID_FILE"
  printf 'ready\n' > "$FAKE_CLI_READY_FILE"
  while :; do printf 'tick\n' >> "$HEARTBEAT_FILE"; sleep 0.05; done
fi
if [[ "${FAKE_MODE:-success}" == "lane-heartbeat" ]]; then
  trap '' TERM HUP
  lane_heartbeat="$HEARTBEAT_DIR/${0##*/}"
  while :; do printf 'tick\n' >> "$lane_heartbeat"; sleep 0.05; done
fi
sleep 1
printf 'answer\n'
SH
chmod +x "$TMP_ROOT/bin/codex"
ln -s codex "$TMP_ROOT/bin/claude"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() {
  grep -Fq "$2" "$1" || {
    sed -n '1,100p' "$1" >&2 || true
    fail "$3"
  }
  printf 'PASS: %s\n' "$3"
}

mkdir -p "$TMP_ROOT/broken-bin"
cat > "$TMP_ROOT/broken-bin/grep" <<'SH'
#!/usr/bin/env bash
exit 2
SH
chmod +x "$TMP_ROOT/broken-bin/grep"
mkdir "$TMP_ROOT/broken-runtime"
printf 'token\n' > "$TMP_ROOT/broken-runtime/token"
printf 'worker log\n' > "$TMP_ROOT/broken-runtime/worker.log"
broken_wait_rc=0
PATH="$TMP_ROOT/broken-bin:$PATH" \
  "$RUNTIME" wait "$TMP_ROOT/broken-artifact" "$TMP_ROOT/broken-runtime" \
    "$(date +%s)" token 1 fake 1 >"$TMP_ROOT/broken.stdout" \
    2>"$TMP_ROOT/broken.stderr" || broken_wait_rc=$?
[[ $broken_wait_rc -eq 1 ]] || fail "broken worker-log read did not fail closed"
assert_contains "$TMP_ROOT/broken.stderr" "cannot read worker log" \
  "broken worker-log read fails with its cause"

printf 'untouched\n' > "$TMP_ROOT/victim"
mkdir "$TMP_ROOT/symlink-runtime"
ln -s "$TMP_ROOT/victim" "$TMP_ROOT/symlink-runtime/worker.log"
symlink_rc=0
"$RUNTIME" launch "$TMP_ROOT/bin/codex" "$TMP_ROOT/symlink-answer" \
  "$TMP_ROOT/symlink-runtime" 1 false x >"$TMP_ROOT/symlink.stdout" \
  2>"$TMP_ROOT/symlink.stderr" || symlink_rc=$?
[[ $symlink_rc -ne 0 ]] || fail "symlinked worker log was opened"
[[ "$(cat < "$TMP_ROOT/victim")" == "untouched" ]] \
  || fail "symlinked worker log truncated its target"
printf 'PASS: worker log creation refuses a symlink replacement\n'

cat > "$TMP_ROOT/bin/dead-worker" <<'SH'
#!/usr/bin/env bash
kill -KILL "$PPID"
kill -KILL $$
SH
chmod +x "$TMP_ROOT/bin/dead-worker"
mkdir "$TMP_ROOT/dead-runtime"
"$RUNTIME" launch "$TMP_ROOT/bin/dead-worker" "$TMP_ROOT/dead-answer" \
  "$TMP_ROOT/dead-runtime" 30 false x >"$TMP_ROOT/dead-launch.stdout"
dead_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/dead-launch.stdout")"
dead_wait_rc=0
bash -c "$dead_wait_cmd" >"$TMP_ROOT/dead-wait.stdout" \
  2>"$TMP_ROOT/dead-wait.stderr" || dead_wait_rc=$?
[[ $dead_wait_rc -eq 1 ]] || fail "dead detached worker was not detected"
assert_contains "$TMP_ROOT/dead-wait.stderr" "exited without a completion marker" \
  "wait fails fast when its worker vanishes"

cat > "$TMP_ROOT/bin/no-timeout-worker" <<'SH'
#!/usr/bin/env bash
exec "$RUNTIME_FOR_WORKER" tree 1 "$WORKER_STDERR" codex
SH
chmod +x "$TMP_ROOT/bin/no-timeout-worker"
mkdir "$TMP_ROOT/deadline-runtime"
deadline_heartbeat="$TMP_ROOT/deadline-heartbeat"
PATH="$PATH" RUNTIME_FOR_WORKER="$RUNTIME" WORKER_STDERR="$TMP_ROOT/deadline-tree.stderr" \
  FAKE_MODE=nested HEARTBEAT_FILE="$deadline_heartbeat" \
  "$RUNTIME" launch "$TMP_ROOT/bin/no-timeout-worker" "$TMP_ROOT/deadline-answer" \
    "$TMP_ROOT/deadline-runtime" 1 false x >"$TMP_ROOT/deadline-launch.stdout"
deadline_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/deadline-launch.stdout")"
deadline_wait_cmd="${deadline_wait_cmd% 30} 1"
deadline_wait_rc=0
bash -c "$deadline_wait_cmd" >"$TMP_ROOT/deadline-wait.stdout" \
  2>"$TMP_ROOT/deadline-wait.stderr" || deadline_wait_rc=$?
[[ $deadline_wait_rc -eq 124 ]] || fail "wait deadline did not return 124"
[[ -s "$deadline_heartbeat" ]] || fail "no-timeout CLI tree never started"
deadline_before="$(wc -c < "$deadline_heartbeat" | tr -d ' ')"
sleep 0.3
deadline_after="$(wc -c < "$deadline_heartbeat" | tr -d ' ')"
[[ "$deadline_before" == "$deadline_after" ]] \
  || fail "wait deadline left the no-timeout CLI tree running"
printf 'PASS: wait deadline stops the no-timeout CLI tree\n'

cat > "$TMP_ROOT/bin/two-tree-worker" <<'SH'
#!/usr/bin/env bash
"$RUNTIME_FOR_WORKER" tree 1 "$WORKER_STDERR.codex" codex &
codex_tree=$!
"$RUNTIME_FOR_WORKER" tree 1 "$WORKER_STDERR.claude" claude &
claude_tree=$!
wait "$codex_tree" "$claude_tree"
SH
chmod +x "$TMP_ROOT/bin/two-tree-worker"
mkdir "$TMP_ROOT/multi-tree-runtime" "$TMP_ROOT/multi-tree-heartbeats"
PATH="$PATH" RUNTIME_FOR_WORKER="$RUNTIME" \
  WORKER_STDERR="$TMP_ROOT/multi-tree.stderr" FAKE_MODE=lane-heartbeat \
  HEARTBEAT_DIR="$TMP_ROOT/multi-tree-heartbeats" \
  "$RUNTIME" launch "$TMP_ROOT/bin/two-tree-worker" "$TMP_ROOT/multi-tree-answer" \
    "$TMP_ROOT/multi-tree-runtime" 1 false x >"$TMP_ROOT/multi-tree-launch.stdout"
for _attempt in {1..100}; do
  active_count="$(find "$TMP_ROOT/multi-tree-runtime" -maxdepth 1 -type f -name 'active.*' | wc -l | tr -d ' ')"
  [[ "$active_count" -eq 2 ]] && break
  sleep 0.05
done
[[ "${active_count:-0}" -eq 2 ]] || fail "concurrent CLI trees did not publish distinct handles"
multi_tree_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/multi-tree-launch.stdout")"
multi_tree_wait_cmd="${multi_tree_wait_cmd% 30} 1"
multi_tree_rc=0
bash -c "$multi_tree_wait_cmd" >"$TMP_ROOT/multi-tree-wait.stdout" \
  2>"$TMP_ROOT/multi-tree-wait.stderr" || multi_tree_rc=$?
[[ $multi_tree_rc -eq 124 ]] || fail "multi-tree wait deadline did not return 124"
for lane in codex claude; do
  lane_heartbeat="$TMP_ROOT/multi-tree-heartbeats/$lane"
  [[ -s "$lane_heartbeat" ]] || fail "$lane CLI tree never started"
  lane_before="$(wc -c < "$lane_heartbeat" | tr -d ' ')"
  sleep 0.3
  lane_after="$(wc -c < "$lane_heartbeat" | tr -d ' ')"
  [[ "$lane_before" == "$lane_after" ]] || fail "wait deadline left the $lane CLI tree running"
done
printf 'PASS: wait deadline stops every concurrent CLI tree\n'

mkdir "$TMP_ROOT/reused-runtime"
printf 'reused\n' > "$TMP_ROOT/reused-runtime/token"
: > "$TMP_ROOT/reused-runtime/worker.log"
sleep 10 &
unrelated_pid=$!
reused_rc=0
"$RUNTIME" wait "$TMP_ROOT/reused-answer" "$TMP_ROOT/reused-runtime" \
  "$(($(date +%s) + 10))" reused "$unrelated_pid" wrong 1 \
  >"$TMP_ROOT/reused.stdout" 2>"$TMP_ROOT/reused.stderr" || reused_rc=$?
[[ $reused_rc -eq 1 ]] || fail "stale worker identity was accepted"
kill -0 "$unrelated_pid" 2>/dev/null || fail "stale worker handle signaled an unrelated process"
kill "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true
printf 'PASS: stale worker identity cannot signal a reused pid\n'

artifact="$TMP_ROOT/answer.txt"
launch_stdout="$TMP_ROOT/launch.stdout"
launch_stderr="$TMP_ROOT/launch.stderr"
launch_rc=0
PATH="$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" quick question --cwd "$TMP_ROOT/work" --output "$artifact" \
    --timeout 2 --foreground >"$launch_stdout" 2>"$launch_stderr" || launch_rc=$?
if [[ $launch_rc -ne 0 ]]; then
  sed -n '1,100p' "$launch_stderr" >&2 || true
  fail "foreground-capped launch returned $launch_rc"
fi

assert_contains "$launch_stdout" "artifact: $artifact" "detached launch names its artifact"
assert_contains "$launch_stdout" "deadline: " "detached launch computes its deadline"
assert_contains "$launch_stdout" "wait: " "detached launch prints one wait command"
[[ "$(grep -c '^wait:' "$launch_stdout")" -eq 1 ]] \
  || fail "detached launch printed more than one wait command"

deadline="$(sed -n 's/^deadline: //p' "$launch_stdout")"
now="$(date +%s)"
[[ "$deadline" =~ ^[0-9]+$ ]] || fail "deadline is not an epoch"
remaining=$((deadline - now))
[[ $remaining -ge 80 && $remaining -le 100 ]] \
  || fail "quick deadline does not include timeout, kill grace, and script margin"

wait_cmd="$(sed -n 's/^wait: //p' "$launch_stdout")"
[[ -n "$wait_cmd" ]] || fail "wait command is empty"
wait_rc=0
bash -c "$wait_cmd" > "$TMP_ROOT/wait.stdout" 2> "$TMP_ROOT/wait.stderr" || wait_rc=$?
if [[ $wait_rc -ne 0 ]]; then
  sed -n '1,100p' "$TMP_ROOT/wait.stderr" >&2 || true
  fail "wait command returned $wait_rc"
fi
assert_contains "$TMP_ROOT/wait.stdout" "$artifact" "wait command returns the artifact path"
assert_contains "$artifact" "answer" "detached worker writes the result"

piped_artifact="$TMP_ROOT/piped-answer.txt"
printf 'piped question\n' | PATH="$PATH" CAPTURE_PROMPT_FILE="$TMP_ROOT/piped.prompt" \
  SECOND_OPINION_TARGET=codex SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" quick --cwd "$TMP_ROOT/work" --output "$piped_artifact" \
    --timeout 2 --foreground >"$TMP_ROOT/piped-launch.stdout"
piped_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/piped-launch.stdout")"
bash -c "$piped_wait_cmd" >"$TMP_ROOT/piped-wait.stdout" 2>"$TMP_ROOT/piped-wait.stderr"
assert_contains "$TMP_ROOT/piped.prompt" "piped question" \
  "detached worker preserves a piped prompt"

review_artifact="$TMP_ROOT/review.json"
review_stdout="$TMP_ROOT/review-launch.stdout"
PATH="$PATH" \
  SECOND_OPINION_FOREGROUND_CAP=1 \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" review --range HEAD --cwd "$TMP_ROOT/work" \
    --output "$review_artifact" --timeout 2 >"$review_stdout" 2>"$TMP_ROOT/review-launch.stderr"
review_deadline="$(sed -n 's/^deadline: //p' "$review_stdout")"
now="$(date +%s)"
review_remaining=$((review_deadline - now))
[[ $review_remaining -ge 114 && $review_remaining -le 134 ]] \
  || fail "review deadline does not include its retry budget"
review_wait_cmd="$(sed -n 's/^wait: //p' "$review_stdout")"
review_wait_rc=0
bash -c "$review_wait_cmd" >"$TMP_ROOT/review-wait.stdout" \
  2>"$TMP_ROOT/review-wait.stderr" || review_wait_rc=$?
[[ $review_wait_rc -eq 3 ]] \
  || fail "environment-capped review did not return its worker status"
printf 'PASS: environment cap detaches with the review retry deadline\n'

printf 'changed\n' >> "$TMP_ROOT/work/file.txt"
multi_artifact="$TMP_ROOT/multi.json"
PATH="$PATH" FAKE_REVIEW=1 SECOND_OPINION_FOREGROUND_CAP=1 \
  SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=2 \
  SECOND_OPINION_CLAUDE_CMD=claude SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" review --range HEAD --cwd "$TMP_ROOT/work" \
    --output "$multi_artifact" --timeout 2 >"$TMP_ROOT/multi-launch.stdout"
multi_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/multi-launch.stdout")"
bash -c "$multi_wait_cmd" >"$TMP_ROOT/multi-wait.stdout" 2>"$TMP_ROOT/multi-wait.stderr"
[[ "$(jq -r '.qa_metadata.lanes | length' "$multi_artifact")" -eq 2 ]] \
  || fail "foreground-capped multi-lane review lost a lane"
assert_contains "$multi_artifact" "external-union" \
  "foreground-capped multi-lane review writes its union"

if [[ "$(uname -s)" == "Linux" ]] && command -v setsid >/dev/null 2>&1; then
  abandon_ready="$TMP_ROOT/abandon.ready"
  abandon_term="$TMP_ROOT/abandon.terminated"
  abandon_pid_file="$TMP_ROOT/abandon.pid"
  abandon_token="session-$RANDOM-$$"
  abandon_artifact="$TMP_ROOT/abandon.txt"
  PATH="$PATH" FAKE_MODE=abandon \
    TEST_SESSION_TOKEN="$abandon_token" \
    FAKE_CLI_READY_FILE="$abandon_ready" \
    FAKE_CLI_TERM_FILE="$abandon_term" \
    FAKE_CLI_PID_FILE="$abandon_pid_file" \
    SECOND_OPINION_TARGET=codex \
    SECOND_OPINION_CODEX_CMD=codex \
    setsid "$SECOND_OPINION" quick question --cwd "$TMP_ROOT/work" \
      --output "$abandon_artifact" --timeout 20 --foreground \
      >"$TMP_ROOT/abandon.stdout" 2>"$TMP_ROOT/abandon.stderr" &
  abandon_session=$!
  ABANDON_SESSION="$abandon_session"
  ABANDON_TOKEN="$abandon_token"
  for _attempt in {1..100}; do
    [[ -s "$abandon_ready" ]] && break
    sleep 0.05
  done
  if [[ ! -s "$abandon_ready" ]]; then
    sed -n '1,100p' "$TMP_ROOT/abandon.stderr" >&2 || true
    fail "detached CLI did not start for caller-cancellation control"
  fi
  owned_group_member "$abandon_token" "$abandon_session" >/dev/null \
    || fail "caller-cancellation control lost ownership of its session"
  kill -TERM -- "-$abandon_session" 2>/dev/null || true
  wait "$abandon_session" 2>/dev/null || true
  for _attempt in {1..100}; do
    [[ -s "$abandon_term" ]] && break
    sleep 0.05
  done
  if [[ ! -s "$abandon_term" ]]; then
    fail "canceling the capped caller left its detached CLI running"
  fi
  ABANDON_SESSION=""
  printf 'PASS: canceling the capped caller stops its detached CLI\n'
else
  printf 'SKIP: caller-cancellation control requires Linux and setsid\n'
fi

if [[ "$(uname -s)" == "Linux" ]]; then
  startup_ready="$TMP_ROOT/startup.ready"
  startup_pid_file="$TMP_ROOT/startup.pid"
  startup_heartbeat="$TMP_ROOT/startup-heartbeat"
  startup_token="startup-$RANDOM-$$"
  cat > "$TMP_ROOT/startup-env" <<'SH'
set -T
startup_cancel_in_launch_window() {
  if [[ "$BASH_COMMAND" == "set +m" && "${STARTUP_CANCEL_SENT:-0}" == 0 ]]; then
    STARTUP_CANCEL_SENT=1
    sleep 0.2
    kill -TERM "$$"
  fi
}
trap startup_cancel_in_launch_window DEBUG
SH
  startup_rc=0
  BASH_ENV="$TMP_ROOT/startup-env" PATH="$PATH" FAKE_MODE=startup \
    TEST_SESSION_TOKEN="$startup_token" \
    FAKE_CLI_READY_FILE="$startup_ready" FAKE_CLI_PID_FILE="$startup_pid_file" \
    HEARTBEAT_FILE="$startup_heartbeat" \
    "$RUNTIME" tree 1 "$TMP_ROOT/startup.stderr" codex \
    >/dev/null 2>"$TMP_ROOT/startup.log" || startup_rc=$?
  if [[ -s "$startup_pid_file" ]]; then
    STARTUP_SESSION="$(cat < "$startup_pid_file")"
    STARTUP_TOKEN="$startup_token"
  fi
  [[ $startup_rc -eq 143 ]] || fail "startup-window cancellation returned $startup_rc"
  [[ ! -e "$startup_ready" && ! -e "$startup_heartbeat" ]] \
    || fail "startup-window cancellation released the CLI"
  STARTUP_SESSION=""
  printf 'PASS: startup-window cancellation cannot release the CLI\n'
else
  printf 'SKIP: startup-window cancellation control requires Linux\n'
fi

resolved_timeout="$(command -v timeout || command -v gtimeout || true)"
if [[ -z "$resolved_timeout" ]]; then
  printf 'SKIP: nested-child expiry control requires timeout or gtimeout\n'
  exit 0
fi

heartbeat="$TMP_ROOT/heartbeat"
tree_rc=0
PATH="$PATH" FAKE_MODE=nested HEARTBEAT_FILE="$heartbeat" \
  "$resolved_timeout" --foreground -k 30 1 "$RUNTIME" tree 1 "$TMP_ROOT/tree.stderr" codex \
  >/dev/null 2> "$TMP_ROOT/tree.log" || tree_rc=$?
[[ $tree_rc -eq 124 ]] || fail "nested tree deadline did not return timeout status"
[[ -s "$heartbeat" ]] || fail "nested child never started"
before="$(wc -c < "$heartbeat" | tr -d ' ')"
sleep 0.3
after="$(wc -c < "$heartbeat" | tr -d ' ')"
[[ "$before" == "$after" ]] || fail "nested child survived deadline teardown"
printf 'PASS: deadline expiry tears down nested CLI children\n'

early_heartbeat="$TMP_ROOT/early-heartbeat"
early_ready="$TMP_ROOT/early-ready"
PATH="$PATH" FAKE_MODE=early HEARTBEAT_FILE="$early_heartbeat" \
  FAKE_CLI_READY_FILE="$early_ready" \
  "$RUNTIME" tree 1 "$TMP_ROOT/early.stderr" codex
[[ -s "$early_ready" && -s "$early_heartbeat" ]] \
  || fail "early-exit child control never started"
early_before="$(wc -c < "$early_heartbeat" | tr -d ' ')"
sleep 0.3
early_after="$(wc -c < "$early_heartbeat" | tr -d ' ')"
[[ "$early_before" == "$early_after" ]] \
  || fail "CLI leader exit left a descendant running"
printf 'PASS: CLI leader exit tears down remaining descendants\n'
