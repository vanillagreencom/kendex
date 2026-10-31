#!/usr/bin/env bash
# Tests for the watch-restart helper a succession's watch handover starts,
# `oversee-succeed --watch-restart`: it waits for the caller's window to
# close and restarts the fleet watch from the successor pane, and it prints
# each outcome in one write beside the watch's own lines. The handover itself
# is the orch runtime's (decision 109 (6)): its job runs
# `lib/watch-handover.sh` after a confirmed publication, held by the runtime's
# controller rows, and the legacy script hands its succession to the runtime
# and starts no watch, so no row here runs a succession. Run over a real tmux
# server on a private socket. The watch is a stand-in that records itself
# through lib/watch-pid.sh, as the real one does, and notes what it was
# started with; what the real watch does with that record is
# oversee_watch_lifecycle.sh's.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# mutant_scripts, for the one must-fail control below.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUCCEED="$TEST_DIR/../scripts/oversee-succeed"
SRC_DIR="$(cd "$(dirname "$SUCCEED")" && pwd)"
# shellcheck source=../scripts/lib/watch-pid.sh
source "$SRC_DIR/lib/watch-pid.sh"

TMP_ROOT="$(mktemp -d)"
SOCK="oversee-succeed-watch-$$"
cleanup() {
  local pid
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  for pid in $(sed -n 's/^started \([0-9]*\) .*/\1/p' "$TMP_ROOT/watch.log" 2>/dev/null); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { tmux -L "$SOCK" "$@"; }

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

H="$TMP_ROOT/home"
mkdir -p "$H" "$TMP_ROOT/work/tmp" "$TMP_ROOT/fixture"

tmux -L "$SOCK" -f /dev/null new-session -d -s fleet -x 220 -y 50 'exec sleep 100000'
KEEP_WINDOW="$(tm display-message -p -t fleet:0 '#{window_id}')"
tm set-option -g default-shell /bin/sh
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"

# A caller pane the helper waits on, holding a process until the row closes
# its window.
new_caller() {
  local spec
  tm kill-window -a -t "$KEEP_WINDOW"
  tm move-window -r -t fleet
  spec="$(tm new-window -d -t fleet:1 -c "$TMP_ROOT/work" -P -F '#{pane_id} #{window_id}' "exec sleep 100000")"
  read -r CALLER_PANE CALLER_WINDOW <<<"$spec"
}

# The fleet state beside which the watch keeps its record and a restarted
# watch its output.
FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
printf '{"issue_id": "oversee"}\n' > "$FLEET_STATE"
WATCH_ERR="$TMP_ROOT/work/tmp/oversee-watch.err"
fresh_output() { rm -f -- "${TMP_ROOT:?}/work/tmp/oversee-watch.log" "${TMP_ROOT:?}/work/tmp/oversee-watch.err"; }

# The orch job runner starts the restarted watch where no user manager
# answers: behind a systemd-run whose probe fails, so under setsid, and a
# loginctl that says the manager lingers.
NO_MANAGER="$TMP_ROOT/no-manager"
mkdir -p "$NO_MANAGER"
printf '#!/bin/sh\necho "Failed to connect to bus: No medium found" >&2\nexit 1\n' > "$NO_MANAGER/systemd-run"
printf '#!/bin/sh\necho yes\n' > "$NO_MANAGER/loginctl"
chmod +x "$NO_MANAGER/systemd-run" "$NO_MANAGER/loginctl"

# The stand-in watch: it records itself as the real loop does, with its words
# before `--`, and appends one `started` line, with its pane, origin, account,
# directory and arguments, to watch.log, and one `stopped` line when it is
# stopped. Started by a succession, it first stops the live watch it replaces,
# as the real start does for a watch whose pane is gone (that rule is
# oversee_watch_lifecycle.sh's); where norecord exists, such a start exits
# before it claims, a restart that never comes up.
FIXTURE_WATCH="$TMP_ROOT/fixture/oversee-watch"
cat > "$FIXTURE_WATCH" <<EOF
#!/usr/bin/env bash
source "$SRC_DIR/lib/watch-pid.sh"
# The pid line the real watch adds to its job's record before anything else.
if [[ -n "\${OVERSEE_WATCH_JOB_RECORD:-}" ]]; then
  watch_job_pid_write "\$OVERSEE_WATCH_JOB_RECORD"
  unset OVERSEE_WATCH_JOB_RECORD
fi
trap 'echo "stopped \$\$" >> "$TMP_ROOT/watch.log"; exit 143' TERM
state=""
prev=""
base=()
for arg in "\$@"; do
  [[ "\$arg" != -- ]] || break
  base+=("\$arg")
  [[ "\$prev" != --state ]] || state="\$arg"
  prev="\$arg"
done
if [[ "\${OVERSEE_WATCH_ORIGIN:-hand}" == succession ]]; then
  [[ ! -f "$TMP_ROOT/norecord" ]] || exit 0
  ! watch_pid_live "\$state" || watch_stop "\$WATCH_PID" "\$state"
fi
printf 'started %s pane=%s origin=%s lane=%s cwd=%s argv=%s\n' "\$\$" "\${TMUX_PANE:-none}" \\
  "\${OVERSEE_WATCH_ORIGIN:-hand}" "\${CLAUDE_CONFIG_DIR:-none}" "\$PWD" "\$*" >> "$TMP_ROOT/watch.log"
watch_pid_write "\$state" "\${TMUX_PANE:-none}" "\${OVERSEE_WATCH_ORIGIN:-hand}" "\$0" "\${base[@]}"
while :; do sleep 1; done
EOF
chmod +x "$FIXTURE_WATCH"
WATCH_ARGS="--repeat 60 --state $FLEET_STATE --since 2026-09-24T00:00:00Z"

# start_watch — the stand-in started by hand from the caller's pane, as an
# overseer starts its watch, two forks deep so a stopped one is reaped rather
# than left a zombie that still answers kill -0. Sets OLD.
start_watch() {
  # shellcheck disable=SC2086
  ( cd "$TMP_ROOT/work" && TMUX_PANE="$CALLER_PANE" CLAUDE_CONFIG_DIR="$H/.claude-old" \
      "$FIXTURE_WATCH" $WATCH_ARGS -- --model old --verbose </dev/null >/dev/null 2>&1 & )
  OLD=""
  for _ in $(seq 1 50); do
    if watch_pid_live "$FLEET_STATE"; then OLD="$WATCH_PID"; return 0; fi
    sleep 0.1
  done
  echo "fixture: the stand-in watch never recorded itself" >&2
  exit 1
}
started_line() { grep "^started $1 " "$TMP_ROOT/watch.log" | sed "s/^started $1 //"; }
# wait_restart — the pid of the watch recorded from the successor pane as a
# succession's restart, once its outcome line is written, or empty after the
# bound. The helper does its work after this run has returned.
wait_restart() {
  local i
  NEW=""
  for (( i = 0; i < 150; i++ )); do
    if watch_pid_live "$FLEET_STATE" && [[ "$WATCH_ORIGIN" == succession && "$WATCH_PANE" == "$SUCC_PANE" ]] \
       && grep -q '^oversee-succeed: watch-restarted ' "$WATCH_ERR" 2>/dev/null; then
      NEW="$WATCH_PID"
      return 0
    fi
    sleep 0.1
  done
}

echo "=== oversee-succeed: the watch-restart helper ==="

# The restart waits for the caller's window to close: the helper, run as the
# handover runs it against a caller that stays open, restarts nothing until
# that window closes.
# restart_helper [SUCCEED_BIN] — the helper started against a caller that
# stays open, from a fresh caller and watch.
restart_helper() {
  new_caller
  fresh_output
  start_watch
  watch_argv_read "$FLEET_STATE"
  SUCC_PANE="$(tm new-window -d -t fleet:2 -P -F '#{pane_id}' 'exec sleep 100000')"
  ( cd "$TMP_ROOT/work" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$H" PATH="$NO_MANAGER:$PATH" TMUX="$TMUX_ADDR" \
      "${1:-$SUCCEED}" --watch-restart "$FLEET_STATE" "$CALLER_PANE" "$SUCC_PANE" CLAUDE_CONFIG_DIR "$H/.claude" claude \
      "$WATCH_CWD" "$WATCH_SCRIPT" "${#WATCH_ARGV[@]}" "${WATCH_ARGV[@]}" \
      >>"$WATCH_ERR" 2>&1 </dev/null & )
}
restart_helper
# A real wait: the helper reads the caller every tenth of a second, so two
# seconds of a caller that stands is twenty readings of it.
sleep 2
EARLY="$(grep -c '^oversee-succeed: watch-restarted ' "$WATCH_ERR" 2>/dev/null || true)"
tm kill-window -t "$CALLER_WINDOW"
wait_restart
assert_eq "${EARLY:-0}|${NEW:+restarted}" "0|restarted" \
  "the restart waits for the caller's window to close, and follows it"
watch_stop "$NEW" "$FLEET_STATE" || true
# Its control: a helper that stops waiting at once restarts the watch while
# the caller still stands, read through the suite's bounded wait.
EAGER="$(mutant_scripts eager oversee-succeed)" || exit 1
mutate_file "$EAGER/oversee-succeed" '    [[ "$OL_INSPECT_STATE" != gone ]] || break' '    break'
restart_helper "$EAGER/oversee-succeed"
wait_restart
assert_eq "${NEW:+restarted}|$(tm list-windows -a -F '#{window_id}' | grep -cxF -- "$CALLER_WINDOW" || true)" "restarted|1" \
  "control: a helper that does not wait restarts the watch beside a caller still open"
watch_stop "$NEW" "$FLEET_STATE" || true

# The helper and the restarted watch both append keyed lines to
# oversee-watch.err, so each writer prints its line in one write. A printf
# function plays the other writer: it appends that writer's line to the file
# right after the first call, where a split write would be torn by it.
# interleaved FILE OTHER_LINE WRITER... — WRITER run once, its output on FILE.
interleaved() {
  local file="$1" other="$2"
  shift 2
  (
    first=1
    printf() {
      builtin printf "$@"
      (( first )) || return 0
      first=0
      builtin printf '%s\n' "$other"
    }
    "$@"
  ) >> "$file"
}
# succeed_message SCRIPTS — the oversee-succeed message function of that copy
# writing the helper's outcome line.
succeed_message() {
  eval "$(sed -n '/^message() {/,/^}/p' "$1/oversee-succeed")"
  message watch-restarted pid=7 pane=%1 runner=setsid
}
# watch_message SCRIPTS — the oversee-watch ow_message of that copy writing
# the line a restarted watch prints while the old one finishes.
watch_message() {
  source "$1/lib/oversee-watch-text.sh"
  ow_message watch-finishing pid=8
}
SUCCEED_LINE='oversee-succeed: watch-restarted pid=7 pane=%1 runner=setsid'
WATCH_LINE='oversee-watch: watch-finishing pid=8'
SUCCEED_TORN="$(mutant_scripts succeed-torn oversee-succeed)" || exit 1
mutate_file "$SUCCEED_TORN/oversee-succeed" \
  "  printf -v fields ' %s' \"\$@\"
  printf 'oversee-succeed: %s%s\n%s\n' \"\$key\" \"\$fields\" \"\$text\"" \
  "  printf 'oversee-succeed: %s' \"\$key\"; printf ' %s' \"\$@\"; printf '\n%s\n' \"\$text\""
WATCH_TORN="$(mutant_scripts watch-torn lib/oversee-watch-text.sh)" || exit 1
mutate_file "$WATCH_TORN/lib/oversee-watch-text.sh" \
  "  printf 'oversee-watch: %s%s\n%s\n' \"\$reason\" \"\$fields\" \"\$text\"" \
  "  printf 'oversee-watch: %s' \"\$reason\"; printf '%s' \"\$fields\"; printf '\n%s\n' \"\$text\""
# torn_row SCRIPTS WRITER LINE OTHER — whether LINE and OTHER each stand whole
# in the file WRITER wrote with OTHER cut in after its first call.
torn_row() {
  local file="$TMP_ROOT/interleaved.err"
  : > "$file"
  interleaved "$file" "$4" "$2" "$1"
  printf '%s|%s' "$(grep -cxF -- "$3" "$file")" "$(grep -cxF -- "$4" "$file")"
}
assert_eq "$(torn_row "$SRC_DIR" succeed_message "$SUCCEED_LINE" "$WATCH_LINE")" "1|1" \
  "the helper's watch-restarted line stays whole when the watch writes between its calls"
assert_eq "$(torn_row "$SUCCEED_TORN" succeed_message "$SUCCEED_LINE" "$WATCH_LINE")" "0|0" \
  "control: a message printed in three calls is torn by the watch's line"
assert_eq "$(torn_row "$SRC_DIR" watch_message "$WATCH_LINE" "$SUCCEED_LINE")" "1|1" \
  "the watch's watch-finishing line stays whole when the helper writes between its calls"
assert_eq "$(torn_row "$WATCH_TORN" watch_message "$WATCH_LINE" "$SUCCEED_LINE")" "0|0" \
  "control: an ow_message printed in three calls is torn by the helper's line"

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
