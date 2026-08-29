#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { grep -Fq "$2" "$1" || fail "$3"; printf 'PASS: %s\n' "$3"; }

mkdir -p "$TMP_ROOT/proj/skills" "$TMP_ROOT/bin" "$TMP_ROOT/work"
git -C "$TMP_ROOT/proj" init -q
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SECOND_OPINION="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"
RUNTIME="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion-runtime"
cat > "$TMP_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
if [[ -n "${CONTROL_ENV_DIR:-}" ]]; then
  control_file="$CONTROL_ENV_DIR/${0##*/}"
  if [[ -n "${SECOND_OPINION_RUNTIME_DIR:-}${SECOND_OPINION_RUN_TOKEN:-}" ]]; then
    printf 'leaked\n' > "$control_file"
  else
    printf 'clean\n' > "$control_file"
  fi
fi
if [[ "${FAKE_REVIEW:-}" == 1 ]]; then
  target="${0##*/}"
  printf '{"agent":"external-%s","verdict":"pass","summary":"ok","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}\n' "$target"
  exit 0
fi
printf 'answer\n'
SH
chmod +x "$TMP_ROOT/bin/codex"
ln -s codex "$TMP_ROOT/bin/claude"
PATH="$TMP_ROOT/bin:$PATH"
export PATH SECOND_OPINION_CURRENT_MODEL=none
git -C "$TMP_ROOT/work" init -q
git -C "$TMP_ROOT/work" config user.email test@example.com
git -C "$TMP_ROOT/work" config user.name test
printf 'scope\n' > "$TMP_ROOT/work/file.txt"
git -C "$TMP_ROOT/work" add file.txt
git -C "$TMP_ROOT/work" -c commit.gpgsign=false commit -q -m init
printf 'changed\n' >> "$TMP_ROOT/work/file.txt"

mkdir "$TMP_ROOT/psbin"
cat > "$TMP_ROOT/psbin/ps" <<'SH'
#!/usr/bin/env bash
mode=""; while [[ $# -gt 0 ]]; do case "$1" in -o) mode="$2"; shift 2 ;; *) shift ;; esac; done
case "$mode" in ppid=) printf '1\n' ;; comm=) printf 'bash\n' ;; esac
SH
chmod +x "$TMP_ROOT/psbin/ps"
NORMAL_PATH="$TMP_ROOT/psbin:$PATH"
mkdir "$TMP_ROOT/stale-env"
PATH="$NORMAL_PATH" SECOND_OPINION_RUNTIME_DIR=stale SECOND_OPINION_RUN_TOKEN=stale \
  CONTROL_ENV_DIR="$TMP_ROOT/stale-env" SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex "$SECOND_OPINION" quick question \
  --cwd "$TMP_ROOT/work" --output "$TMP_ROOT/stale-answer" >/dev/null
assert_contains "$TMP_ROOT/stale-env/codex" "clean" \
  "normal entry clears stale runtime controls before the CLI"
rm -f "$TMP_ROOT/stale-env/codex"
PATH="$NORMAL_PATH" SECOND_OPINION_RUNTIME_DIR=stale SECOND_OPINION_RUN_TOKEN=stale FAKE_REVIEW=1 \
  CONTROL_ENV_DIR="$TMP_ROOT/stale-env" SECOND_OPINION_MODELS="claude codex" \
  SECOND_OPINION_COUNT=2 SECOND_OPINION_CLAUDE_CMD=claude SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" review --range HEAD --cwd "$TMP_ROOT/work" \
  --output "$TMP_ROOT/stale-review.json" >/dev/null
assert_contains "$TMP_ROOT/stale-env/claude" "clean" \
  "normal multi-lane entry clears stale controls from claude"
assert_contains "$TMP_ROOT/stale-env/codex" "clean" \
  "normal multi-lane entry clears stale controls from codex"

bad_output="$TMP_ROOT/report"$'\n'"wait: injected"
path_rc=0
PATH="$NORMAL_PATH" SECOND_OPINION_TARGET=codex SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" quick question --cwd "$TMP_ROOT/work" --foreground \
  --output "$bad_output" >"$TMP_ROOT/path-lf.stdout" 2>"$TMP_ROOT/path-lf.stderr" \
  || path_rc=$?
[[ $path_rc -eq 1 ]] || fail "LF artifact path returned $path_rc"
grep -q '^wait:' "$TMP_ROOT/path-lf.stdout" \
  && fail "LF artifact path injected a wait record"
assert_contains "$TMP_ROOT/path-lf.stderr" "artifact path contains CR or LF" \
  "LF artifact path is refused before protocol output"
bad_cwd="$TMP_ROOT/cwd"$'\r'"bad"
mkdir "$bad_cwd"
path_rc=0
PATH="$NORMAL_PATH" SECOND_OPINION_TARGET=codex SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" quick question --cwd "$bad_cwd" --foreground \
  >"$TMP_ROOT/path-cr.stdout" 2>"$TMP_ROOT/path-cr.stderr" || path_rc=$?
[[ $path_rc -eq 1 ]] || fail "CR derived artifact path returned $path_rc"
grep -q '^wait:' "$TMP_ROOT/path-cr.stdout" \
  && fail "CR derived artifact path injected a wait record"
assert_contains "$TMP_ROOT/path-cr.stderr" "artifact path contains CR or LF" \
  "CR cwd-derived artifact path is refused before protocol output"

mkdir "$TMP_ROOT/identity-runtime"
CODEX_SANDBOX=1 SECOND_OPINION_LAUNCH_MODEL=claude SECOND_OPINION_LAUNCH_SOURCE=detected \
  SECOND_OPINION_LAUNCH_IN_CALLER_ENV=false SECOND_OPINION_LAUNCH_SESSION_SCOPED=false \
  "$RUNTIME" launch "$SECOND_OPINION" "$TMP_ROOT/identity-answer" \
  "$TMP_ROOT/identity-runtime" 10 false 1 3 quick question --target=codex \
  --cwd "$TMP_ROOT/work" --timeout 2 \
  >"$TMP_ROOT/identity-launch.stdout"
identity_wait="$(sed -n 's/^wait: //p' "$TMP_ROOT/identity-launch.stdout")"
bash -c "$identity_wait" >"$TMP_ROOT/identity-wait.stdout" 2>"$TMP_ROOT/identity-wait.stderr"
assert_contains "$TMP_ROOT/identity-answer" "answer" \
  "detached worker preserves the parent-selected target"
assert_contains "$TMP_ROOT/identity-wait.stderr" "target=codex" \
  "detached worker runs the parent's target despite an inherited codex marker"
assert_contains "$TMP_ROOT/identity-wait.stderr" "current=claude" \
  "detached worker trusts the private parent identity"
forged_rc=0
"$SECOND_OPINION" quick question --target=codex --cwd "$TMP_ROOT/work" \
  --detached-worker >"$TMP_ROOT/forged.stdout" 2>"$TMP_ROOT/forged.stderr" || forged_rc=$?
[[ $forged_rc -eq 1 ]] || fail "forged direct worker mode returned $forged_rc"
assert_contains "$TMP_ROOT/forged.stderr" "requires runtime ownership proof" \
  "forged direct worker mode is refused"
forged_rc=0
"$SECOND_OPINION" quick question --target=codex --cwd "$TMP_ROOT/work" \
  --foreground --lane-worker >"$TMP_ROOT/forged-lane.stdout" \
  2>"$TMP_ROOT/forged-lane.stderr" || forged_rc=$?
[[ $forged_rc -eq 1 ]] || fail "forged lane worker returned $forged_rc"
assert_contains "$TMP_ROOT/forged-lane.stderr" "requires runtime ownership proof" \
  "forged lane worker cannot bypass foreground detachment"

if [[ "$(uname -s)" == "Linux" ]] && command -v setsid >/dev/null 2>&1; then
  cat > "$TMP_ROOT/bin/signal-worker" <<'SH'
#!/usr/bin/env bash
output=""
for arg in "$@"; do case "$arg" in --output=*) output="${arg#--output=}" ;; esac; done
printf 'answer\n' > "$output"
printf '0\n' > "$SIGNAL_RUNTIME/worker.status"
sleep 5
SH
  chmod +x "$TMP_ROOT/bin/signal-worker"
  mkdir "$TMP_ROOT/signal-runtime"
  SIGNAL_RUNTIME="$TMP_ROOT/signal-runtime" setsid "$RUNTIME" launch \
    "$TMP_ROOT/bin/signal-worker" "$TMP_ROOT/signal-answer" \
    "$TMP_ROOT/signal-runtime" 3 false 1 5 x >"$TMP_ROOT/signal-launch.stdout" &
  signal_session=$!
  wait "$signal_session"
  sleep 2.2
  kill -TERM -- "-$signal_session" 2>/dev/null || true
  signal_wait="$(sed -n 's/^wait: //p' "$TMP_ROOT/signal-launch.stdout")"
  signal_test_deadline=$(($(date +%s) + 5))
  signal_rc=0
  bash -c "$signal_wait" >"$TMP_ROOT/signal-wait.stdout" \
    2>"$TMP_ROOT/signal-wait.stderr" || signal_rc=$?
  while [[ $signal_rc -eq 75 ]]; do
    [[ $(date +%s) -le $signal_test_deadline ]] \
      || fail "signal-during-wait did not reach a terminal result"
    signal_rc=0
    bash -c "$signal_wait" >"$TMP_ROOT/signal-wait.stdout" \
      2>"$TMP_ROOT/signal-wait.stderr" || signal_rc=$?
  done
  [[ $signal_rc -eq 143 ]] || fail "signal-during-wait returned $signal_rc"
  for _signal_reap in {1..20}; do
    ps -eo sid= | awk -v sid="$signal_session" '$1 == sid { found = 1 } END { exit found ? 0 : 1 }' \
      || break
    sleep 0.1
  done
  if ps -eo sid= | awk -v sid="$signal_session" '$1 == sid { found = 1 } END { exit found ? 0 : 1 }'; then
    fail "signal-during-wait left a process in its session"
  fi
  printf 'PASS: cancellation during worker wait reaps before returning 143\n'
else
  printf 'SKIP: signal-during-wait control requires Linux and setsid\n'
fi

cat > "$TMP_ROOT/bin/hanging-worker" <<'SH'
#!/usr/bin/env bash
while :; do sleep 1; done
SH
chmod +x "$TMP_ROOT/bin/hanging-worker"
mkdir "$TMP_ROOT/setup-runtime" "$TMP_ROOT/setup-bin"
cat > "$TMP_ROOT/setup-bin/mkfifo" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP_ROOT/setup-bin/mkfifo"
PATH="$TMP_ROOT/setup-bin:$PATH" "$RUNTIME" launch "$TMP_ROOT/bin/hanging-worker" \
  "$TMP_ROOT/setup-answer" "$TMP_ROOT/setup-runtime" 10 false 1 3 x \
  >"$TMP_ROOT/setup-launch.stdout"
setup_wait="$(sed -n 's/^wait: //p' "$TMP_ROOT/setup-launch.stdout")"
setup_rc=0
bash -c "$setup_wait" >"$TMP_ROOT/setup-wait.stdout" \
  2>"$TMP_ROOT/setup-wait.stderr" || setup_rc=$?
[[ $setup_rc -eq 1 ]] || fail "forced supervisor setup failure returned $setup_rc"
assert_contains "$TMP_ROOT/setup-wait.stderr" "cannot create supervisor channels" \
  "first wait reports supervisor setup failure"

mkdir -p "$TMP_ROOT/bad-runtime-bin/lib" "$TMP_ROOT/pretrap-runtime"
cp "$REPO_ROOT/skills/second-opinion/scripts/lib/runtime-ready.sh" \
  "$TMP_ROOT/bad-runtime-bin/lib/runtime-ready.sh"
cat > "$TMP_ROOT/bad-runtime-bin/second-opinion-runtime" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "supervise" ]]; then exit 7; fi
action="${1:-}"
shift
source "$REAL_RUNTIME"
RUNTIME_SELF="$0"
case "$action" in launch) launch "$@" ;; *) exit 2 ;; esac
SH
chmod +x "$TMP_ROOT/bad-runtime-bin/second-opinion-runtime"
pretrap_started="$(date +%s)"
pretrap_rc=0
REAL_RUNTIME="$RUNTIME" "$TMP_ROOT/bad-runtime-bin/second-opinion-runtime" launch \
  "$TMP_ROOT/bin/hanging-worker" "$TMP_ROOT/pretrap-answer" \
  "$TMP_ROOT/pretrap-runtime" 10 false 1 3 x >"$TMP_ROOT/pretrap.stdout" \
  2>"$TMP_ROOT/pretrap.stderr" || pretrap_rc=$?
pretrap_elapsed=$(($(date +%s) - pretrap_started))
[[ $pretrap_rc -eq 1 && $pretrap_elapsed -lt 4 ]] \
  || fail "pre-trap supervisor failure returned $pretrap_rc after ${pretrap_elapsed}s"
assert_contains "$TMP_ROOT/pretrap.stderr" "exited during setup without completion (status 7)" \
  "launch reports pre-trap supervisor exit promptly"
[[ ! -e "$TMP_ROOT/pretrap-runtime" ]] \
  || fail "pre-trap supervisor exit left authenticated runtime state"
printf 'PASS: pre-trap supervisor exit leaves no runtime state\n'

if [[ "$(uname -s)" == "Linux" ]] && command -v setsid >/dev/null 2>&1; then
  mkdir -p "$TMP_ROOT/slow-runtime-bin/lib" "$TMP_ROOT/slow-runtime"
  cp "$REPO_ROOT/skills/second-opinion/scripts/lib/runtime-ready.sh" \
    "$TMP_ROOT/slow-runtime-bin/lib/runtime-ready.sh"
  cat > "$TMP_ROOT/slow-runtime-bin/second-opinion-runtime" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "supervise" ]]; then
  trap 'kill -TERM "$slow_child" 2>/dev/null || true; wait "$slow_child" 2>/dev/null || true; exit 143' TERM HUP INT
  "$SLOW_WORKER" &
  slow_child=$!
  wait "$slow_child"
  exit 1
fi
action="${1:-}"
shift
source "$REAL_RUNTIME"
RUNTIME_SELF="$0"
case "$action" in launch) launch "$@" ;; *) exit 2 ;; esac
SH
  chmod +x "$TMP_ROOT/slow-runtime-bin/second-opinion-runtime"
  slow_started="$(date +%s)"
  REAL_RUNTIME="$RUNTIME" SLOW_WORKER="$TMP_ROOT/bin/hanging-worker" \
    setsid "$TMP_ROOT/slow-runtime-bin/second-opinion-runtime" launch "$TMP_ROOT/bin/hanging-worker" \
    "$TMP_ROOT/slow-answer" "$TMP_ROOT/slow-runtime" 30 false 1 3 x \
    >"$TMP_ROOT/slow.stdout" 2>"$TMP_ROOT/slow.stderr" &
  slow_session=$!
  slow_rc=0
  wait "$slow_session" || slow_rc=$?
  slow_elapsed=$(($(date +%s) - slow_started))
  [[ $slow_rc -eq 1 && $slow_elapsed -lt 9 ]] \
    || fail "slow setup returned $slow_rc after ${slow_elapsed}s"
  assert_contains "$TMP_ROOT/slow.stderr" "did not finish setup within 5 seconds" \
    "slow setup returns the bounded readiness error"
  [[ ! -e "$TMP_ROOT/slow-runtime" ]] || fail "slow setup left authenticated runtime state"
  for _slow_reap in {1..20}; do
    ps -eo sid= | awk -v sid="$slow_session" '$1 == sid { found = 1 } END { exit found ? 0 : 1 }' \
      || break
    sleep 0.1
  done
  if ps -eo sid= | awk -v sid="$slow_session" '$1 == sid { found = 1 } END { exit found ? 0 : 1 }'; then
    fail "slow setup left a supervisor or worker in its session"
  fi
  printf 'PASS: slow setup leaves no supervisor, worker, or runtime state\n'

  mkdir "$TMP_ROOT/ignore-runtime"
  cat > "$TMP_ROOT/slow-runtime-bin/second-opinion-runtime" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "supervise" ]]; then trap '' TERM; while :; do :; done; fi
action="${1:-}"
shift
source "$REAL_RUNTIME"
RUNTIME_SELF="$0"
case "$action" in launch) launch "$@" ;; *) exit 2 ;; esac
SH
  chmod +x "$TMP_ROOT/slow-runtime-bin/second-opinion-runtime"
  ignore_started="$(date +%s)"
  REAL_RUNTIME="$RUNTIME" setsid "$TMP_ROOT/slow-runtime-bin/second-opinion-runtime" launch \
    "$TMP_ROOT/bin/hanging-worker" "$TMP_ROOT/ignore-answer" \
    "$TMP_ROOT/ignore-runtime" 30 false 1 3 x \
    >"$TMP_ROOT/ignore.stdout" 2>"$TMP_ROOT/ignore.stderr" &
  ignore_session=$!
  ignore_rc=0
  wait "$ignore_session" || ignore_rc=$?
  ignore_elapsed=$(($(date +%s) - ignore_started))
  [[ $ignore_rc -eq 1 && $ignore_elapsed -lt 10 ]] \
    || fail "TERM-ignoring setup returned $ignore_rc after ${ignore_elapsed}s"
  [[ ! -e "$TMP_ROOT/ignore-runtime" ]] || fail "TERM-ignoring setup left runtime state"
  if ps -eo sid= | awk -v sid="$ignore_session" '$1 == sid { found = 1 } END { exit found ? 0 : 1 }'; then
    fail "TERM-ignoring setup left its supervisor"
  fi
  printf 'PASS: TERM-ignoring setup is killed, reaped, and cleaned\n'
else
  printf 'SKIP: slow setup ownership control requires Linux and setsid\n'
fi

cat > "$TMP_ROOT/startup-env" <<'SH'
set -T
cancel_before_event_reader() {
  case "$BASH_COMMAND" in *'exec 10<'*) kill -TERM "$$" ;; esac
}
trap cancel_before_event_reader DEBUG
SH
mkdir "$TMP_ROOT/startup-runtime"
BASH_ENV="$TMP_ROOT/startup-env" "$RUNTIME" launch "$TMP_ROOT/bin/hanging-worker" \
  "$TMP_ROOT/startup-answer" "$TMP_ROOT/startup-runtime" 10 false 1 3 x \
  >"$TMP_ROOT/startup-launch.stdout"
startup_wait="$(sed -n 's/^wait: //p' "$TMP_ROOT/startup-launch.stdout")"
startup_rc=0
bash -c "$startup_wait" >"$TMP_ROOT/startup-wait.stdout" \
  2>"$TMP_ROOT/startup-wait.stderr" || startup_rc=$?
[[ $startup_rc -eq 143 ]] || fail "startup-window cancellation returned $startup_rc"
printf 'PASS: event FIFO guard makes startup-window cancellation terminal\n'

cat > "$TMP_ROOT/cancel-env" <<'SH'
set -T
cancel_after_token_loss() {
  case "$BASH_COMMAND" in
    *'exec 10<'*)
      saved_token="$(cat < "$STARTUP_RUNTIME_DIR/token")"
      printf 'changed\n' > "$STARTUP_RUNTIME_DIR/token"
      kill -TERM "$$"
      printf '%s\n' "$saved_token" > "$STARTUP_RUNTIME_DIR/token"
      ;;
  esac
}
trap cancel_after_token_loss DEBUG
SH
mkdir "$TMP_ROOT/cancel-runtime"
STARTUP_RUNTIME_DIR="$TMP_ROOT/cancel-runtime" BASH_ENV="$TMP_ROOT/cancel-env" \
  "$RUNTIME" launch "$TMP_ROOT/bin/hanging-worker" "$TMP_ROOT/cancel-answer" \
    "$TMP_ROOT/cancel-runtime" 10 false 1 3 x >"$TMP_ROOT/cancel-launch.stdout"
cancel_wait="$(sed -n 's/^wait: //p' "$TMP_ROOT/cancel-launch.stdout")"
cancel_rc=0
bash -c "$cancel_wait" >"$TMP_ROOT/cancel-wait.stdout" \
  2>"$TMP_ROOT/cancel-wait.stderr" || cancel_rc=$?
[[ $cancel_rc -eq 1 ]] || fail "startup token-loss cancellation returned $cancel_rc"
assert_contains "$TMP_ROOT/cancel-wait.stderr" "runtime directory or token changed" \
  "pre-release cancellation preserves the runtime-token diagnostic"

guard_line="$(grep -n 'exec 7<>"$event_fifo"' "$RUNTIME" | cut -d: -f1)"
fork_line="$(grep -n '^  set -m$' "$RUNTIME" | tail -1 | cut -d: -f1)"
[[ -n "$guard_line" && -n "$fork_line" && $guard_line -lt $fork_line ]] \
  || fail "event FIFO guard is not open before the worker fork"
printf 'PASS: event FIFO guard precedes the worker fork\n'

mkdir "$TMP_ROOT/terminal-runtime"
printf 'terminal\n' > "$TMP_ROOT/terminal-runtime/token"
printf 'worker log\n' > "$TMP_ROOT/terminal-runtime/worker.log"
printf 'keep\n' > "$TMP_ROOT/terminal-artifact"
mkdir "$TMP_ROOT/terminal-bin"
cat > "$TMP_ROOT/terminal-bin/grep" <<'SH'
#!/usr/bin/env bash
count=0
[[ ! -e "$LATE_COUNT" ]] || count="$(cat < "$LATE_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" > "$LATE_COUNT"
grep_rc=0
"$REAL_GREP" "$@" || grep_rc=$?
if [[ $count -eq 3 ]]; then
  printf '%s\n' '__SECOND_OPINION_EXIT_terminal__=0' >> "$LATE_LOG"
fi
exit "$grep_rc"
SH
chmod +x "$TMP_ROOT/terminal-bin/grep"
printf -v terminal_wait '%q ' "$RUNTIME" wait "$TMP_ROOT/terminal-artifact" \
  "$TMP_ROOT/terminal-runtime" "$(date +%s)" terminal 1
terminal_rc=0
PATH="$TMP_ROOT/terminal-bin:$PATH" REAL_GREP="$(command -v grep)" \
  LATE_COUNT="$TMP_ROOT/late.count" LATE_LOG="$TMP_ROOT/terminal-runtime/worker.log" \
  bash -c "$terminal_wait" >"$TMP_ROOT/terminal.stdout" \
  2>"$TMP_ROOT/terminal.stderr" || terminal_rc=$?
[[ $terminal_rc -eq 75 ]] || fail "recoverable no-completion wait returned $terminal_rc"
[[ -d "$TMP_ROOT/terminal-runtime" ]] || fail "unconfirmed terminal 124 removed runtime state"
[[ "$(cat < "$TMP_ROOT/terminal-artifact")" == "keep" ]] \
  || fail "terminal 124 disturbed the completed artifact path"
bash -c "$terminal_wait" >"$TMP_ROOT/terminal-retry.stdout" \
  2>"$TMP_ROOT/terminal-retry.stderr"
[[ ! -e "$TMP_ROOT/terminal-runtime" ]] || fail "recovered completion left runtime state"
assert_contains "$TMP_ROOT/terminal-retry.stdout" "$TMP_ROOT/terminal-artifact" \
  "late completion is recovered by rerunning wait"

assert_contains "$REPO_ROOT/skills/orch/workflows/review-pr.md" \
  'printed deadline is absolute Unix epoch seconds; compare it with `date +%s`' \
  "review-pr documents the printed deadline as an absolute epoch"

mkdir -p "$TMP_ROOT/collision-proj/skills"
git -C "$TMP_ROOT/collision-proj" init -q
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/collision-proj/skills/second-opinion"
COLLISION_SO="$TMP_ROOT/collision-proj/skills/second-opinion/scripts/second-opinion"
for collision_key in SCRIPT_DIR RUNTIME ORIGINAL_ARGS FOREGROUND_CAP_IN_CALLER_ENV \
    FOREGROUND_CAP_WAS_IN_CALLER_ENV CURRENT_MODEL_IS_SESSION_SCOPED \
    CURRENT_MODEL_IN_CALLER_ENV SECOND_OPINION_RUNTIME_DIR SECOND_OPINION_RUN_TOKEN; do
  printf '[env]\n%s = "forged"\n' "$collision_key" \
    > "$TMP_ROOT/collision-proj/kendex.settings.toml"
  collision_rc=0
  "$COLLISION_SO" detect >"$TMP_ROOT/collision.stdout" \
    2>"$TMP_ROOT/collision.stderr" || collision_rc=$?
  [[ $collision_rc -eq 1 ]] || fail "$collision_key project collision returned $collision_rc"
  assert_contains "$TMP_ROOT/collision.stderr" "$collision_key is runtime-owned" \
    "$collision_key project collision is refused"
done
rm -f "$TMP_ROOT/collision-proj/kendex.settings.toml"
printf 'export RUNTIME=forged\n' > "$TMP_ROOT/collision-proj/.env.local"
collision_rc=0
"$COLLISION_SO" detect >"$TMP_ROOT/collision.stdout" \
  2>"$TMP_ROOT/collision.stderr" || collision_rc=$?
[[ $collision_rc -eq 1 ]] || fail "RUNTIME env-file collision returned $collision_rc"
assert_contains "$TMP_ROOT/collision.stderr" "RUNTIME is runtime-owned" \
  "env-file runtime path collision is refused"
rm -f "$TMP_ROOT/collision-proj/.env.local"
printf '[env]\nSECOND_OPINION_RUNTIME_DIR = "forged"\n' \
  > "$TMP_ROOT/collision-proj/kendex.settings.toml"
collision_rc=0
PATH="$NORMAL_PATH" SECOND_OPINION_TARGET=codex SECOND_OPINION_CODEX_CMD=codex \
  "$COLLISION_SO" quick question --cwd "$TMP_ROOT/work" \
  >"$TMP_ROOT/collision.stdout" 2>"$TMP_ROOT/collision.stderr" || collision_rc=$?
[[ $collision_rc -eq 1 ]] || fail "runtime-dir quick collision returned $collision_rc"
assert_contains "$TMP_ROOT/collision.stderr" "SECOND_OPINION_RUNTIME_DIR is runtime-owned" \
  "TOML runtime-dir collision blocks single-lane entry"
rm -f "$TMP_ROOT/collision-proj/kendex.settings.toml"
printf 'export SECOND_OPINION_RUN_TOKEN=forged\n' > "$TMP_ROOT/collision-proj/.env.local"
collision_rc=0
PATH="$NORMAL_PATH" FAKE_REVIEW=1 SECOND_OPINION_MODELS="claude codex" \
  SECOND_OPINION_COUNT=2 SECOND_OPINION_CLAUDE_CMD=claude SECOND_OPINION_CODEX_CMD=codex \
  "$COLLISION_SO" review --range HEAD --cwd "$TMP_ROOT/work" \
  >"$TMP_ROOT/collision.stdout" 2>"$TMP_ROOT/collision.stderr" || collision_rc=$?
[[ $collision_rc -eq 1 ]] || fail "run-token review collision returned $collision_rc"
assert_contains "$TMP_ROOT/collision.stderr" "SECOND_OPINION_RUN_TOKEN is runtime-owned" \
  "env runtime-token collision blocks multi-lane entry"
