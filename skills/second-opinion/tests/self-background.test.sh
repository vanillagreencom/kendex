#!/usr/bin/env bash
set -euo pipefail

export SECOND_OPINION_CURRENT_MODEL=none

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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
cat >/dev/null
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
sleep 1
printf 'answer\n'
SH
chmod +x "$TMP_ROOT/bin/codex"

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
printf 'worker log\n' > "$TMP_ROOT/broken.log"
broken_wait_rc=0
PATH="$TMP_ROOT/broken-bin:$PATH" \
  "$RUNTIME" wait "$TMP_ROOT/broken-artifact" "$TMP_ROOT/broken.log" \
    "$(date +%s)" token >"$TMP_ROOT/broken.stdout" \
    2>"$TMP_ROOT/broken.stderr" || broken_wait_rc=$?
[[ $broken_wait_rc -eq 1 ]] || fail "broken worker-log read did not fail closed"
assert_contains "$TMP_ROOT/broken.stderr" "cannot read worker log" \
  "broken worker-log read fails with its cause"

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
bash -c "$wait_cmd" > "$TMP_ROOT/wait.stdout" 2> "$TMP_ROOT/wait.stderr"
assert_contains "$TMP_ROOT/wait.stdout" "$artifact" "wait command returns the artifact path"
assert_contains "$artifact" "answer" "detached worker writes the result"

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

if [[ "$(uname -s)" == "Linux" ]] && command -v setsid >/dev/null 2>&1; then
  abandon_ready="$TMP_ROOT/abandon.ready"
  abandon_term="$TMP_ROOT/abandon.terminated"
  abandon_pid_file="$TMP_ROOT/abandon.pid"
  abandon_artifact="$TMP_ROOT/abandon.txt"
  PATH="$PATH" FAKE_MODE=abandon \
    FAKE_CLI_READY_FILE="$abandon_ready" \
    FAKE_CLI_TERM_FILE="$abandon_term" \
    FAKE_CLI_PID_FILE="$abandon_pid_file" \
    SECOND_OPINION_TARGET=codex \
    SECOND_OPINION_CODEX_CMD=codex \
    setsid "$SECOND_OPINION" quick question --cwd "$TMP_ROOT/work" \
      --output "$abandon_artifact" --timeout 20 --foreground \
      >"$TMP_ROOT/abandon.stdout" 2>"$TMP_ROOT/abandon.stderr" &
  abandon_session=$!
  for _attempt in {1..100}; do
    [[ -s "$abandon_ready" ]] && break
    sleep 0.05
  done
  if [[ ! -s "$abandon_ready" ]]; then
    sed -n '1,100p' "$TMP_ROOT/abandon.stderr" >&2 || true
    fail "detached CLI did not start for caller-cancellation control"
  fi
  kill -TERM -- "-$abandon_session" 2>/dev/null || true
  wait "$abandon_session" 2>/dev/null || true
  for _attempt in {1..100}; do
    [[ -s "$abandon_term" ]] && break
    sleep 0.05
  done
  if [[ ! -s "$abandon_term" ]]; then
    abandon_cli_pid="$(cat < "$abandon_pid_file")"
    kill -TERM -- "-$abandon_cli_pid" 2>/dev/null || true
    sleep 0.1
    kill -KILL -- "-$abandon_cli_pid" 2>/dev/null || true
    fail "canceling the capped caller left its detached CLI running"
  fi
  printf 'PASS: canceling the capped caller stops its detached CLI\n'
else
  printf 'SKIP: caller-cancellation control requires Linux and setsid\n'
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
