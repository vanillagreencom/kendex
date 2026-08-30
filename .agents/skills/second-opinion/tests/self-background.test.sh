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
FAILURE_SESSION=""
FAILURE_TOKEN=""
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
owned_session_groups() {
  local token="$1" session="$2" environ pid stat rest group seen=" "
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
    [[ $# -ge 4 && "$4" == "$session" ]] || continue
    group="$3"
    case "$seen" in *" $group "*) continue ;; esac
    seen="$seen$group "
    printf '%s\n' "$group"
  done
}
stop_owned_session() {
  local token="$1" session="$2" grace="$3" groups group end
  end=$(($(date +%s) + grace))
  while :; do
    groups="$(owned_session_groups "$token" "$session")"
    [[ -n "$groups" ]] || return 0
    for group in $groups; do kill -TERM -- "-$group" 2>/dev/null || true; done
    [[ $(date +%s) -lt $end ]] || break
    sleep 0.1
  done
  groups="$(owned_session_groups "$token" "$session")"
  for group in $groups; do kill -KILL -- "-$group" 2>/dev/null || true; done
}
cleanup() {
  if [[ -n "$ABANDON_SESSION" ]]; then
    stop_owned_session "$ABANDON_TOKEN" "$ABANDON_SESSION" 1
    wait "$ABANDON_SESSION" 2>/dev/null || true
  fi
  if [[ -n "$STARTUP_SESSION" ]] \
      && owned_group_member "$STARTUP_TOKEN" "$STARTUP_SESSION" >/dev/null; then
    kill -KILL -- "-$STARTUP_SESSION" 2>/dev/null || true
  fi
  if [[ -n "$FAILURE_SESSION" ]] \
      && owned_group_member "$FAILURE_TOKEN" "$FAILURE_SESSION" >/dev/null; then
    kill -KILL -- "-$FAILURE_SESSION" 2>/dev/null || true
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
if [[ "${FAKE_MODE:-success}" == "runtime-failure" ]]; then
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
if [[ "${FAKE_MODE:-success}" == "gate-gone" ]]; then
  if find "$GATE_TMPDIR" -mindepth 1 -print -quit | grep -q .; then exit 9; fi
  printf 'answer\n'
  exit 0
fi
if [[ -n "${CONTROL_ENV_CAPTURE:-}" ]]; then
  if [[ -n "${SECOND_OPINION_RUNTIME_DIR:-}${SECOND_OPINION_RUN_TOKEN:-}" ]]; then
    printf 'leaked\n' > "$CONTROL_ENV_CAPTURE"
  else
    printf 'clean\n' > "$CONTROL_ENV_CAPTURE"
  fi
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
assert_not_contains() {
  if grep -Fq "$2" "$1"; then
    fail "$3"
  fi
  printf 'PASS: %s\n' "$3"
}
workflow_commands_detach() {
  awk '
    BEGIN { matches = 0 }
    /scripts\/second-opinion (review|quick|challenge|audit)/ {
      matches++
      command = $0
      collecting = ($0 ~ /\\$/)
      if (!collecting && command !~ /--foreground/) exit 1
      next
    }
    collecting {
      command = command "\n" $0
      if ($0 !~ /\\$/) {
        if (command !~ /--foreground/) exit 1
        collecting = 0
      }
    }
    END {
      if (matches == 0) exit 3
      if (collecting) exit 2
    }
  ' "$1"
}
assert_workflow_commands_detach() {
  workflow_commands_detach "$1" \
    || fail "$1 has no capped second-opinion command or one lacks --foreground"
}
supervise_blocks_without_polling() {
  awk '
    /^supervise\(\)/ { inside = 1 }
    inside && /cannot release detached worker/ { released = 1 }
    inside && released && /^[[:space:]]*(while|until)[[:space:]]/ { exit 1 }
    inside && released && /IFS= read -r event/ { saw_event = 1 }
    inside && released && /wait "\$worker_pid"/ { saw_wait = 1 }
    inside && /^}/ {
      if (!released || !saw_event || !saw_wait) exit 2
      exit 0
    }
    END { if (!inside) exit 3 }
  ' "$1"
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
    "$(date +%s)" token 1 >"$TMP_ROOT/broken.stdout" \
    2>"$TMP_ROOT/broken.stderr" || broken_wait_rc=$?
[[ $broken_wait_rc -eq 1 ]] || fail "broken worker-log read did not fail closed"
assert_contains "$TMP_ROOT/broken.stderr" "cannot read worker log" \
  "broken worker-log read fails with its cause"

printf 'untouched\n' > "$TMP_ROOT/victim"
mkdir "$TMP_ROOT/symlink-runtime"
ln -s "$TMP_ROOT/victim" "$TMP_ROOT/symlink-runtime/worker.log"
symlink_rc=0
"$RUNTIME" launch "$TMP_ROOT/bin/codex" "$TMP_ROOT/symlink-answer" \
  "$TMP_ROOT/symlink-runtime" 2 false 1 1 x >"$TMP_ROOT/symlink.stdout" \
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
  "$TMP_ROOT/dead-runtime" 30 false 1 3 x >"$TMP_ROOT/dead-launch.stdout"
dead_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/dead-launch.stdout")"
dead_wait_rc=0
bash -c "$dead_wait_cmd" >"$TMP_ROOT/dead-wait.stdout" \
  2>"$TMP_ROOT/dead-wait.stderr" || dead_wait_rc=$?
[[ $dead_wait_rc -eq 1 ]] || fail "dead detached worker was not detected"
assert_contains "$TMP_ROOT/dead-wait.stderr" "exited without a completion status" \
  "wait fails fast when its worker vanishes"

cat > "$TMP_ROOT/bin/no-timeout-worker" <<'SH'
#!/usr/bin/env bash
exec "$RUNTIME_FOR_WORKER" tree 1 "$WORKER_STDERR" codex
SH
chmod +x "$TMP_ROOT/bin/no-timeout-worker"
cat > "$TMP_ROOT/bash3-read-env" <<'SH'
read() {
  local previous="" arg
  for arg in "$@"; do
    if [[ "$previous" == "-t" ]]; then sleep "$arg"; return 1; fi
    previous="$arg"
  done
  command read "$@"
}
SH
mkdir "$TMP_ROOT/deadline-runtime"
deadline_heartbeat="$TMP_ROOT/deadline-heartbeat"
BASH_ENV="$TMP_ROOT/bash3-read-env" PATH="$PATH" RUNTIME_FOR_WORKER="$RUNTIME" \
  WORKER_STDERR="$TMP_ROOT/deadline-tree.stderr" \
  FAKE_MODE=nested HEARTBEAT_FILE="$deadline_heartbeat" \
  "$RUNTIME" launch "$TMP_ROOT/bin/no-timeout-worker" "$TMP_ROOT/deadline-answer" \
    "$TMP_ROOT/deadline-runtime" 4 false 3 5 x >"$TMP_ROOT/deadline-launch.stdout"
deadline_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/deadline-launch.stdout")"
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
    "$TMP_ROOT/multi-tree-runtime" 5 false 3 6 x >"$TMP_ROOT/multi-tree-launch.stdout"
for _attempt in {1..100}; do
  [[ -s "$TMP_ROOT/multi-tree-heartbeats/codex" \
      && -s "$TMP_ROOT/multi-tree-heartbeats/claude" ]] && break
  sleep 0.05
done
[[ -s "$TMP_ROOT/multi-tree-heartbeats/codex" \
    && -s "$TMP_ROOT/multi-tree-heartbeats/claude" ]] \
  || fail "concurrent CLI trees did not both start"
multi_tree_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/multi-tree-launch.stdout")"
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
assert_not_contains "$RUNTIME" "signal_active" \
  "runtime has no waiter process-signaling path"
assert_not_contains "$RUNTIME" "kill -ALRM" \
  "deadline ownership uses no delayed PID signal"
assert_contains "$RUNTIME" 'mkfifo "$owner_fifo" "$event_fifo"' \
  "supervisor deadline uses owned channels"
supervise_blocks_without_polling "$RUNTIME" \
  || fail "supervisor executable path polls or lacks blocking event and worker waits"
assert_not_contains "$RUNTIME" "process_identity" \
  "wait protocol has no supervisor identity control flow"
cat > "$TMP_ROOT/polling-supervisor" <<'SH'
supervise() {
  : > "$gate/release"
  wait "$worker_pid" >/dev/null 2>&1 &
  while kill -0 "$worker_pid" 2>/dev/null; do sleep 0.07; done
}
SH
if supervise_blocks_without_polling "$TMP_ROOT/polling-supervisor"; then
  fail "no-polling control accepted alternate polling with a decoy wait"
fi
printf 'PASS: supervisor blocks without polling and the control rejects a live mutant\n'
mkdir "$TMP_ROOT/race-runtime" "$TMP_ROOT/race-bin"
printf 'race\n' > "$TMP_ROOT/race-runtime/token"
: > "$TMP_ROOT/race-runtime/worker.log"
printf 'answer\n' > "$TMP_ROOT/race-answer"
cat > "$TMP_ROOT/race-bin/grep" <<'SH'
#!/usr/bin/env bash
count=0
[[ ! -e "$RACE_COUNT" ]] || count="$(cat < "$RACE_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" > "$RACE_COUNT"
grep_rc=0
"$REAL_GREP" "$@" || grep_rc=$?
if [[ $count -eq 2 ]]; then
  printf '%s\n' "$RACE_COMPLETION" >> "$RACE_LOG"
fi
exit "$grep_rc"
SH
chmod +x "$TMP_ROOT/race-bin/grep"
race_rc=0
PATH="$TMP_ROOT/race-bin:$PATH" REAL_GREP="$(command -v grep)" \
  RACE_COUNT="$TMP_ROOT/race.count" RACE_LOG="$TMP_ROOT/race-runtime/worker.log" \
  RACE_COMPLETION="__SECOND_OPINION_EXIT_race__=0" \
  "$RUNTIME" wait "$TMP_ROOT/race-answer" "$TMP_ROOT/race-runtime" \
    "$(date +%s)" race 1 >"$TMP_ROOT/race.stdout" 2>"$TMP_ROOT/race.stderr" \
    || race_rc=$?
[[ $race_rc -eq 0 ]] || fail "waiter missed completion published at its deadline check"
assert_contains "$TMP_ROOT/race.stdout" "$TMP_ROOT/race-answer" \
  "waiter rechecks completion at its deadline"
workflow_files=(
  "$REPO_ROOT/skills/second-opinion/workflows/quick.md"
  "$REPO_ROOT/skills/second-opinion/workflows/challenge.md"
  "$REPO_ROOT/skills/second-opinion/workflows/audit.md"
  "$REPO_ROOT/skills/second-opinion/workflows/review.md"
  "$REPO_ROOT/skills/orch/workflows/review-pr.md"
  "$REPO_ROOT/skills/orch/workflows/submit-pr.md"
)
for workflow_file in "${workflow_files[@]}"; do
  assert_workflow_commands_detach "$workflow_file"
  assert_contains "$workflow_file" 'exact command printed after `wait:`' \
    "${workflow_file##*/} executes the emitted wait command"
  assert_contains "$workflow_file" 'Exit 75 means completion is still recoverable' \
    "${workflow_file##*/} resumes bounded waits"
done
assert_contains "${workflow_files[0]}" 'cat < [ARTIFACT_PATH]' \
  "quick workflow reads the detached artifact"
assert_contains "${workflow_files[1]}" 'cat < [ARTIFACT_PATH]' \
  "challenge workflow reads the detached artifact"
assert_contains "${workflow_files[4]}" '2 × `SECOND_OPINION_TIMEOUT` plus 3 minutes' \
  "review-pr keeps a numeric external deadline fallback"
assert_workflow_commands_detach "$REPO_ROOT/skills/second-opinion/SKILL.md"
assert_contains "$REPO_ROOT/skills/second-opinion/SKILL.md" \
  'Pass `--foreground` when the call can outlast the harness foreground cap.' \
  "skill execution rules require foreground-cap opt-in"
assert_contains "$REPO_ROOT/skills/second-opinion/SKILL.md" \
  'Exit 75 means completion is still recoverable' \
  "skill execution rules resume bounded waits"
cat > "$TMP_ROOT/no-command-workflow.md" <<'EOF'
Execute the exact command printed after `wait:` and read the artifact.
EOF
if workflow_commands_detach "$TMP_ROOT/no-command-workflow.md"; then
  fail "workflow wiring check accepted prose with no launch command"
fi
printf 'PASS: workflow wiring check rejects a missing launch command\n'
printf 'PASS: every shipped workflow detaches and consumes the protocol\n'
cat > "$TMP_ROOT/bin/slow-worker" <<'SH'
#!/usr/bin/env bash
output=""
for arg in "$@"; do case "$arg" in --output=*) output="${arg#--output=}" ;; esac; done
sleep 2
printf 'slow answer\n' > "$output"
SH
chmod +x "$TMP_ROOT/bin/slow-worker"
mkdir "$TMP_ROOT/resume-runtime"
"$RUNTIME" launch "$TMP_ROOT/bin/slow-worker" "$TMP_ROOT/resume-answer" \
  "$TMP_ROOT/resume-runtime" 10 false 1 1 x >"$TMP_ROOT/resume-launch.stdout"
resume_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/resume-launch.stdout")"
resume_started="$(date +%s)"
resume_rc=0
bash -c "$resume_wait_cmd" >"$TMP_ROOT/resume-first.stdout" \
  2>"$TMP_ROOT/resume-first.stderr" || resume_rc=$?
resume_elapsed=$(($(date +%s) - resume_started))
[[ $resume_rc -eq 75 && $resume_elapsed -lt 4 ]] \
  || fail "bounded wait did not return still-running promptly"
for _attempt in {1..5}; do
  resume_rc=0
  bash -c "$resume_wait_cmd" >"$TMP_ROOT/resume-final.stdout" \
    2>"$TMP_ROOT/resume-final.stderr" || resume_rc=$?
  [[ $resume_rc -eq 75 ]] || break
done
[[ $resume_rc -eq 0 ]] || fail "resumed wait did not collect the terminal result"
assert_contains "$TMP_ROOT/resume-answer" "slow answer" \
  "bounded wait resumes to the final artifact"
cat > "$TMP_ROOT/bin/empty-worker" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP_ROOT/bin/empty-worker"
mkdir "$TMP_ROOT/empty-runtime"
"$RUNTIME" launch "$TMP_ROOT/bin/empty-worker" "$TMP_ROOT/empty-answer" \
  "$TMP_ROOT/empty-runtime" 10 false 1 2 x >"$TMP_ROOT/empty-launch.stdout"
empty_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/empty-launch.stdout")"
empty_rc=0
bash -c "$empty_wait_cmd" >"$TMP_ROOT/empty-wait.stdout" \
  2>"$TMP_ROOT/empty-wait.stderr" || empty_rc=$?
[[ $empty_rc -eq 1 ]] || fail "zero-exit empty artifact did not fail closed"
assert_contains "$TMP_ROOT/empty-wait.stderr" "exited 0 without writing its artifact" \
  "zero-exit empty artifact names its failure"
"$SECOND_OPINION" --help > "$TMP_ROOT/help.stdout"
assert_contains "$TMP_ROOT/help.stdout" "Exit 75 means completion is still recoverable" \
  "help documents resumable detached waits"
assert_contains "$TMP_ROOT/help.stdout" "124 detached wait: the supervisor published its terminal deadline result" \
  "help documents the detached supervisor deadline"
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
[[ ! -e "$artifact" ]] || fail "documented foreground command waited for the CLI"

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

no_output_stdout="$TMP_ROOT/no-output-launch.stdout"
PATH="$PATH" SECOND_OPINION_TARGET=codex SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" quick question --cwd "$TMP_ROOT/work" --timeout 2 \
    --foreground >"$no_output_stdout"
no_output_artifact="$(sed -n 's/^artifact: //p' "$no_output_stdout")"
case "$no_output_artifact" in
  "$TMP_ROOT/work/tmp/second-opinion/"*) ;;
  *) fail "no-output quick artifact is outside the owner-only artifact home" ;;
esac
no_output_wait_cmd="$(sed -n 's/^wait: //p' "$no_output_stdout")"
bash -c "$no_output_wait_cmd" >"$TMP_ROOT/no-output-wait.stdout" \
  2>"$TMP_ROOT/no-output-wait.stderr"
assert_contains "$no_output_artifact" "answer" \
  "detached no-output quick writes the model answer"
if stat -c '%a' "$no_output_artifact" >/dev/null 2>&1; then
  no_output_mode="$(stat -c '%a' "$no_output_artifact")"
else
  no_output_mode="$(stat -f '%Lp' "$no_output_artifact")"
fi
[[ "$no_output_mode" == "600" ]] \
  || fail "detached no-output quick artifact mode is $no_output_mode, expected 600"
printf 'PASS: detached no-output quick artifact is owner-only\n'

piped_artifact="$TMP_ROOT/piped-answer.txt"
printf 'piped question\n' | PATH="$PATH" CAPTURE_PROMPT_FILE="$TMP_ROOT/piped.prompt" \
  SECOND_OPINION_TARGET=codex SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" quick --cwd "$TMP_ROOT/work" --output "$piped_artifact" \
    --timeout 2 --foreground >"$TMP_ROOT/piped-launch.stdout"
piped_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/piped-launch.stdout")"
bash -c "$piped_wait_cmd" >"$TMP_ROOT/piped-wait.stdout" 2>"$TMP_ROOT/piped-wait.stderr"
assert_contains "$TMP_ROOT/piped.prompt" "piped question" \
  "detached worker preserves a piped prompt"

control_artifact="$TMP_ROOT/control-answer.txt"
PATH="$PATH" CONTROL_ENV_CAPTURE="$TMP_ROOT/control.env" \
  SECOND_OPINION_RUNTIME_DIR=hostile SECOND_OPINION_RUN_TOKEN=hostile \
  SECOND_OPINION_TARGET=codex SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" quick question --cwd "$TMP_ROOT/work" \
    --output "$control_artifact" --timeout 2 --foreground \
    >"$TMP_ROOT/control-launch.stdout"
control_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/control-launch.stdout")"
bash -c "$control_wait_cmd" >"$TMP_ROOT/control-wait.stdout" \
  2>"$TMP_ROOT/control-wait.stderr"
assert_contains "$TMP_ROOT/control.env" "clean" \
  "external CLI cannot see detached runtime controls"
mkdir "$TMP_ROOT/failure-runtime"
failure_ready="$TMP_ROOT/failure.ready"
failure_pid_file="$TMP_ROOT/failure.pid"
failure_heartbeat="$TMP_ROOT/failure-heartbeat"
failure_token="failure-$RANDOM-$$"
PATH="$PATH" RUNTIME_FOR_WORKER="$RUNTIME" WORKER_STDERR="$TMP_ROOT/failure-tree.stderr" \
  FAKE_MODE=runtime-failure TEST_SESSION_TOKEN="$failure_token" \
  FAKE_CLI_READY_FILE="$failure_ready" FAKE_CLI_PID_FILE="$failure_pid_file" \
  HEARTBEAT_FILE="$failure_heartbeat" \
  "$RUNTIME" launch "$TMP_ROOT/bin/no-timeout-worker" "$TMP_ROOT/failure-answer" \
    "$TMP_ROOT/failure-runtime" 4 false 3 3 x >"$TMP_ROOT/failure-launch.stdout"
failure_wait_cmd="$(sed -n 's/^wait: //p' "$TMP_ROOT/failure-launch.stdout")"
failure_deadline="$(sed -n 's/^deadline: //p' "$TMP_ROOT/failure-launch.stdout")"
failure_wait_rc=0
bash -c "$failure_wait_cmd" >"$TMP_ROOT/failure-wait.stdout" \
  2>"$TMP_ROOT/failure-wait.stderr" &
failure_wait_pid=$!
for _attempt in {1..100}; do
  [[ -s "$failure_ready" ]] && break
  sleep 0.05
done
[[ -s "$failure_ready" ]] || fail "post-release failure control never started its CLI"
FAILURE_SESSION="$(cat < "$failure_pid_file")"
FAILURE_TOKEN="$failure_token"
sleep 0.1
rm -f -- "$TMP_ROOT/failure-runtime/token"
wait "$failure_wait_pid" || failure_wait_rc=$?
while [[ $failure_wait_rc -eq 75 && $(date +%s) -le $failure_deadline ]]; do
  failure_wait_rc=0
  bash -c "$failure_wait_cmd" >"$TMP_ROOT/failure-wait.stdout" \
    2>"$TMP_ROOT/failure-wait.stderr" || failure_wait_rc=$?
done
if [[ $failure_wait_rc -ne 1 ]]; then
  sed -n '1,100p' "$TMP_ROOT/failure-wait.stderr" >&2 || true
  fail "post-release runtime failure returned $failure_wait_rc"
fi
failure_before="$(wc -c < "$failure_heartbeat" | tr -d ' ')"
sleep 0.3
failure_after="$(wc -c < "$failure_heartbeat" | tr -d ' ')"
[[ "$failure_before" == "$failure_after" ]] \
  || fail "post-release runtime failure left its CLI tree running"
FAILURE_SESSION=""
printf 'PASS: post-release runtime failure stops and reaps its CLI tree\n'

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
  [[ -n "$(owned_session_groups "$abandon_token" "$abandon_session")" ]] \
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
  for _attempt in {1..100}; do
    [[ -z "$(owned_session_groups "$abandon_token" "$abandon_session")" ]] && break
    sleep 0.05
  done
  [[ -z "$(owned_session_groups "$abandon_token" "$abandon_session")" ]] \
    || fail "caller cancellation left a token-owned process in its session"
  ABANDON_SESSION=""
  printf 'PASS: canceling the capped caller stops its detached CLI\n'
else
  printf 'SKIP: caller-cancellation control requires Linux and setsid\n'
fi
if [[ "$(uname -s)" == "Linux" ]] && command -v setsid >/dev/null 2>&1 \
    && command -v timeout >/dev/null 2>&1; then
  startup_ready="$TMP_ROOT/startup.ready"
  startup_pid_file="$TMP_ROOT/startup.pid"
  startup_heartbeat="$TMP_ROOT/startup-heartbeat"
  startup_token="startup-$RANDOM-$$"
  cat > "$TMP_ROOT/startup-env" <<'SH'
set -T
startup_cancel_in_launch_window() {
  case "$BASH_COMMAND" in
    *'exec 6>'*)
      if [[ "${STARTUP_CANCEL_SENT:-0}" == 0 ]]; then
        STARTUP_CANCEL_SENT=1
        kill -TERM "$$"
      fi
      ;;
  esac
}
trap startup_cancel_in_launch_window DEBUG
SH
  startup_rc=0 STARTUP_TOKEN="$startup_token"
  setsid timeout --foreground -k 2 5 env BASH_ENV="$TMP_ROOT/startup-env" PATH="$PATH" \
    FAKE_MODE=startup TEST_SESSION_TOKEN="$startup_token" \
    FAKE_CLI_READY_FILE="$startup_ready" FAKE_CLI_PID_FILE="$startup_pid_file" \
    HEARTBEAT_FILE="$startup_heartbeat" "$RUNTIME" tree 1 \
    "$TMP_ROOT/startup.stderr" codex >/dev/null 2>"$TMP_ROOT/startup.log" &
  STARTUP_SESSION=$!
  wait "$STARTUP_SESSION" || startup_rc=$?
  [[ $startup_rc -eq 143 ]] || fail "startup-window cancellation returned $startup_rc"
  [[ ! -e "$startup_ready" && ! -e "$startup_heartbeat" ]] \
    || fail "startup-window cancellation released the CLI"
  for _attempt in {1..20}; do [[ -z "$(owned_session_groups "$startup_token" "$STARTUP_SESSION")" ]] && break; sleep 0.05; done
  [[ -z "$(owned_session_groups "$startup_token" "$STARTUP_SESSION")" ]] \
    || fail "startup-window cancellation left a process in its session"
  STARTUP_SESSION=""
  printf 'PASS: startup-window cancellation cannot release the CLI\n'
else
  printf 'SKIP: startup-window cancellation control requires Linux, setsid, and timeout\n'
fi

gate_scratch="$TMP_ROOT/gate-scratch"
mkdir "$gate_scratch"
TMPDIR="$gate_scratch" PATH="$PATH" FAKE_MODE=gate-gone GATE_TMPDIR="$gate_scratch" \
  "$RUNTIME" tree 1 "$TMP_ROOT/gate-gone.stderr" codex \
  >"$TMP_ROOT/gate-gone.stdout"
assert_contains "$TMP_ROOT/gate-gone.stdout" "answer" \
  "CLI starts after its startup gate pathname is deleted"
[[ -z "$(find "$gate_scratch" -mindepth 1 -print -quit)" ]] \
  || fail "FD-owned startup gate left scratch state"
printf 'PASS: FD-owned startup gate survives scratch cleanup\n'

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
