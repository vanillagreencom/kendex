#!/usr/bin/env bash
# Tests for what `oversee launch --predecessor` and `oversee resume` do to
# the fleet watch: the watch served the predecessor's pane, which the
# succession stops or the lost server closed, so the launch hands it to the
# new pane through lib/watch-handover.sh, the handover `oversee-succeed` runs. Run over a real tmux server at the default
# socket under a private TMUX_TMPDIR, from outside tmux as oversee_launch.sh
# runs the verb, whose suite owns everything else a launch does. The watch
# handed over is a stand-in that records itself through lib/watch-pid.sh, as
# the real one does, save in the last rows, where the real watch runs: the
# successor dies under it, and its GitHub credentials decide whether it
# starts. What the helper does once started is oversee_succeed_watch.sh's.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/named-process.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"
# Private script layouts hold the stand-in watch beside the real launcher.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
OVERSEE="$SRC_DIR/oversee"
# shellcheck source=../scripts/lib/watch-pid.sh
source "$SRC_DIR/lib/watch-pid.sh"
# The words a claude launch carries, read from the launch table the launcher
# writes them from, so the restarted watch's flags are asserted without this
# file spelling them.
# shellcheck source=../scripts/lib/lane-launch.sh
source "$SRC_DIR/lib/lane-launch.sh"
BYPASS="$(launch_choice_permission_write claude)" || { echo "fixture: no claude permission word in the launch table" >&2; exit 1; }
QUESTION_OFF="$(launch_choice_question_off claude)"
COMPACT="$(launch_choice_compaction_off claude)"

TMP_ROOT="$(mktemp -d)" || { echo "oversee_launch_watch: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "oversee_launch_watch: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "oversee_launch_watch: scratch=resolve-failed" >&2; exit 1; }
TMUX_DIR="$TMP_ROOT/tmux"
mkdir -p "$TMUX_DIR"
cleanup() {
  local pid
  if [[ -S $TMUX_DIR/tmux-$(id -u)/default ]]; then
    tmux -S "$TMUX_DIR/tmux-$(id -u)/default" kill-server 2>/dev/null || true
  fi
  for pid in $(sed -n 's/^started \([0-9]*\) .*/\1/p' "$TMP_ROOT/watch.log" 2>/dev/null); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  # The real watch of the last rows, where a failed row left it running.
  ! watch_pid_live "$TMP_ROOT/work/tmp/workflow-state-oversee.json" || kill -TERM "$WATCH_PID" 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { tmux -S "$TMUX_DIR/tmux-$(id -u)/default" "$@"; }

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# A removed TMUX_TMPDIR makes label-based tmux fall back to /tmp. The
# decoy uses a unique label there so the old cleanup can never hit a caller.
CLEANUP_RC=0
(
  TMP_ROOT="$(mktemp -d)" || exit 1
  [[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || exit 1
  TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1
  TMUX_DIR="$TMP_ROOT/tmux"
  CLEANUP_LABEL="oversee-cleanup-${TMP_ROOT##*/}"
  DECOY_SOCKET="/tmp/tmux-$(id -u)/$CLEANUP_LABEL"
  # Restoring label-based cleanup must hit this decoy, never the caller.
  tmux() {
    if [[ ${1:-} == -L && ${2:-} == default ]]; then
      shift 2
      command tmux -L "$CLEANUP_LABEL" "$@"
    else
      command tmux "$@"
    fi
  }
  trap 'tmux -S "$DECOY_SOCKET" kill-server 2>/dev/null || true; cleanup' EXIT
  mkdir -p "$TMUX_DIR" || exit 1
  TMUX_TMPDIR=/tmp tmux -L "$CLEANUP_LABEL" -f /dev/null new-session -d -s decoy 'exec sleep 100000' || exit 1
  tmux -S "$DECOY_SOCKET" has-session -t decoy || exit 1
  cleanup
  cleanup
  tmux -S "$DECOY_SOCKET" has-session -t decoy
) || CLEANUP_RC=$?
assert_eq "$CLEANUP_RC" 0 "cleanup twice leaves the fallback-path decoy server alive"

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN" "$TMP_ROOT/work/tmp" "$TMP_ROOT/fixture"
# A checkout, which the real watch's mailbox reads resolve their root in.
git init -q "$TMP_ROOT/work"
git -C "$TMP_ROOT/work" config gc.auto 0
git -C "$TMP_ROOT/work" config maintenance.auto false
# The harness: it shows a running turn and holds its pane until its sleep,
# whose pid it writes under its pane's number, is killed, which returns the
# pane to the shell the launch line was typed into.
HARNESS_PIDS="$TMP_ROOT/harness"
mkdir -p "$HARNESS_PIDS"
cat > "$BIN/claude" <<STUB
#!/bin/sh
echo 'esc to interrupt'
(
  while [ ! -f "$HARNESS_PIDS/wall-\${TMUX_PANE#%}" ]; do sleep 0.1; done
  echo "You've hit your limit"
) &
wall_writer=\$!
trap 'kill "\$wall_writer" 2>/dev/null || true' 0
sleep 100000 &
echo \$! > "$HARNESS_PIDS/\${TMUX_PANE#%}"
wait \$!
STUB
chmod +x "$BIN/claude"
# A real watch authenticates before it claims: this gh answers its auth check
# and nothing else, as an authenticated host with no fleet fixture would.
printf '#!/bin/sh\n[ "$1 $2" = "auth status" ] || { echo "fixture: no GitHub fixture" >&2; exit 1; }\necho "Logged in"\n' > "$BIN/gh"
chmod +x "$BIN/gh"

new_home fleet
make_lane "$H" claude
FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"

env PATH="$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" tmux -L default -f /dev/null new-session -d -s fleet -x 200 -y 40 'exec sleep 100000'
KEEP_WINDOW="$(tm display-message -p -t fleet:0 '#{window_id}')"
tm set-option -g renumber-windows off
tm set-option -g default-shell /bin/sh
tm set-option -g default-command "PATH=$BIN:\$PATH; export PATH; exec /bin/sh"
SERVER_PID="$(tm display-message -p '#{pid}')"
SOCKET="$TMUX_DIR/tmux-$(id -u)/default"

# The orch job runner starts the helper and the restarted watch where no user
# manager answers: behind a systemd-run whose probe fails, so under setsid,
# and behind a loginctl that says the manager lingers, the one manager the
# runner starts a unit under, which this host's may not.
NO_MANAGER="$TMP_ROOT/no-manager"
mkdir -p "$NO_MANAGER"
printf '#!/bin/sh\necho "Failed to connect to bus: No medium found" >&2\nexit 1\n' > "$NO_MANAGER/systemd-run"
printf '#!/bin/sh\necho yes\n' > "$NO_MANAGER/loginctl"
chmod +x "$NO_MANAGER/systemd-run" "$NO_MANAGER/loginctl"
SETSID_LINE='runner=setsid reason=probe-failed detail=Failed to connect to bus: No medium found'

# run_oversee [OVERSEE_BIN] -- ARGS... — the script under an explicit, whole
# environment with no $TMUX, from the work directory, ORCH_TMUX_SESSION naming
# the fleet. ROW_ENV, when set, is added to that environment, and ROW_LAUNCH,
# when set, is the word the run is started under. Sets OUT (both streams) and
# RC.
ROW_ENV=()
ROW_LAUNCH=""
run_oversee() {
  local bin="$OVERSEE"
  [[ "$1" == -- ]] || { bin="$1"; shift; }
  shift
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && ${ROW_LAUNCH:+"$ROW_LAUNCH"} env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$H" PATH="$NO_MANAGER:$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" \
    LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state" \
    ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="$H/.claude" ORCH_LANES_USAGE_TTL=0 \
    ORCH_OVERSEER_PREFERENCE=claude:fable:high ORCH_TMUX_SESSION=fleet \
    ${ROW_ENV[@]+"${ROW_ENV[@]}"} "$bin" "$@" 2>&1 </dev/null)" || RC=$?
}
FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
WATCH_ERR="$TMP_ROOT/work/tmp/oversee-watch.err"
recorded() { jq -r ".overseer.$1 // \"none\"" "$FLEET_STATE" 2>/dev/null || echo unreadable; }
fresh_output() { rm -f -- "${TMP_ROOT:?}/work/tmp/oversee-watch.log" "${TMP_ROOT:?}/work/tmp/oversee-watch.err"; }

# The stand-in watch: it records itself as the real loop does, with its words
# before `--`, and appends one `started` line, with its pane, origin, account,
# tmux server, directory and arguments, to watch.log, and one `stopped` line
# when it is stopped. Started by a succession, it first stops the live watch
# it replaces where the real start does, a succession's watch for its own
# pane, the watch OVERSEE_WATCH_REPLACE names or a watch whose pane its tmux
# server no longer lists, and otherwise refuses as the real one does (that
# rule is oversee_watch_lifecycle.sh's). FIXTURE_RECORD_SCRIPT, when set, is
# the script its record names in place of its own, which a replay runs.
# FIXTURE_FINISH_HOLD, when set, models a pass still part way through a
# lane-close: stopped, it releases its record, then runs on until that file
# exists, when it appends `finished` and its pid to watch.log.
FIXTURE_WATCH="$TMP_ROOT/fixture/oversee-watch"
cat > "$FIXTURE_WATCH" <<EOF
#!/usr/bin/env bash
set -euo pipefail
trap 'rc=\$?; [[ -z "\${FIXTURE_STARTUP_STATUS:-}" ]] || printf "%s\\n" "\$rc" > "\$FIXTURE_STARTUP_STATUS"' EXIT
source "$SRC_DIR/lib/watch-pid.sh"
# The pid line the real watch adds to its job's record before anything else.
if [[ -n "\${OVERSEE_WATCH_JOB_RECORD:-}" ]]; then
  watch_job_pid_write "\$OVERSEE_WATCH_JOB_RECORD"
  unset OVERSEE_WATCH_JOB_RECORD
fi
finish() {
  [[ -n "\${FIXTURE_FINISH_HOLD:-}" ]] || return 0
  for _ in \$(seq 1 1200); do [[ ! -e "\$FIXTURE_FINISH_HOLD" ]] || break; sleep 0.1; done
  echo "finished \$\$" >> "$TMP_ROOT/watch.log"
}
trap 'watch_pid_release "\$state"; echo "stopped \$\$" >> "$TMP_ROOT/watch.log"; finish; exit 143' TERM
state=""
prev=""
base=()
for arg in "\$@"; do
  [[ "\$arg" != -- ]] || break
  base+=("\$arg")
  [[ "\$prev" != --state ]] || state="\$arg"
  prev="\$arg"
done
if [[ "\${OVERSEE_WATCH_ORIGIN:-hand}" == succession ]] && watch_pid_live "\$state"; then
  panes="\$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)" || panes="\$WATCH_PANE"
  if [[ "\$WATCH_PID" != "\${OVERSEE_WATCH_REPLACE:-}" ]] \
     && [[ "\$WATCH_ORIGIN" != succession || "\$WATCH_PANE" != "\${TMUX_PANE:-}" ]] \
     && grep -qxF -- "\$WATCH_PANE" <<<"\$panes"; then
    echo "oversee-watch: watch-running pid=\$WATCH_PID pane=\$WATCH_PANE" >&2
    exit 1
  fi
  watch_stop "\$WATCH_PID" "\$state"
fi
printf 'started %s pane=%s origin=%s lane=%s tmux=%s cwd=%s argv=%s\n' "\$\$" "\${TMUX_PANE:-none}" \\
  "\${OVERSEE_WATCH_ORIGIN:-hand}" "\${CLAUDE_CONFIG_DIR:-none}" "\${TMUX:-none}" "\$PWD" "\$*" >> "$TMP_ROOT/watch.log"
if [[ -n "\${OVERSEE_WATCH_LOG_CASE:-}" ]]; then
  printf 'EVENT fixture current-%s\n' "\$OVERSEE_WATCH_LOG_CASE"
  printf 'fixture current-%s\n' "\$OVERSEE_WATCH_LOG_CASE" >&2
fi
watch_pid_write "\$state" "\${TMUX_PANE:-none}" "\${OVERSEE_WATCH_ORIGIN:-hand}" "\${FIXTURE_RECORD_SCRIPT:-\$0}" "\${base[@]}"
while :; do sleep 1; done
EOF
chmod +x "$FIXTURE_WATCH"
WATCH_ARGS="--repeat 60 --state $FLEET_STATE --since 2026-01-01T00:00:00Z --repo owner/repo"

# new_predecessor — a first launch, whose overseer is the predecessor below,
# and the stand-in started by hand from its pane, as an overseer starts its
# watch, two forks deep so a stopped one is reaped rather than left a zombie
# that still answers kill -0. STAND_IN_PANE, when set, is the pane the
# stand-in claims in place of the predecessor's, and STAND_IN_ENV words are
# added to its environment. Sets PRED and OLD.
STAND_IN_ENV=()
new_predecessor() {
  local claim_rc=1 startup_exit=unread child_process=unread capture
  tm kill-window -a -t "$KEEP_WINDOW"
  tm move-window -r -t fleet
  rm -f -- "$FLEET_STATE"
  run_oversee -- launch --wait-secs 20
  PRED="$(recorded pane)"
  [[ "$RC" -eq 0 && "$PRED" == %* ]] || { printf 'fixture: the first launch failed\n%s\n' "$OUT" >&2; exit 1; }
  watch_pid_paths "$FLEET_STATE"
  watch_job_pid_read "$WATCH_RUNNER_FILE"
  [[ -n "$WATCH_JOB_PID" ]] || { printf 'fixture: the first launch recorded no watch pid\n' >&2; exit 1; }
  watch_stop "$WATCH_JOB_PID" "$FLEET_STATE"
  # A previously stopped child can still finish after this setup starts.
  capture="$(mktemp -d "$TMP_ROOT/stand-in.XXXXXX")" || exit 1
  # shellcheck disable=SC2086
  ( ( cd "${WATCH_START_CWD:-$TMP_ROOT/work}" || exit 1
      exec env TMUX_PANE="${STAND_IN_PANE:-$PRED}" CLAUDE_CONFIG_DIR="$H/.claude-old" FIXTURE_STARTUP_STATUS="$capture/exit" ${STAND_IN_ENV[@]+"${STAND_IN_ENV[@]}"} \
        "$FIXTURE_WATCH" $WATCH_ARGS -- --model old --verbose ) </dev/null >"$capture/output" 2>&1 &
    echo $! > "$TMP_ROOT/stand-in.pid" )
  OLD="$(cat "$TMP_ROOT/stand-in.pid")"
  for _ in $(seq 1 50); do
    claim_rc=0
    watch_pid_live "$FLEET_STATE" || claim_rc=$?
    if [[ "$claim_rc" -eq 0 && "$WATCH_PID" == "$OLD" ]]; then return 0; fi
    sleep 0.1
  done
  # Read evidence before EXIT cleanup removes it; an unread fact is no cause.
  startup_exit="$(cat "$capture/exit" 2>/dev/null)" || startup_exit=unread
  child_process="$(ps -o stat= -o args= -p "$OLD" 2>&1)" || child_process="unread $child_process"
  {
    printf 'fixture: operation=new_predecessor step=claim child-pid=%s expected-pane=%s claim-result=%s claim-pid=%s claim-pane=%s startup-exit=%s\n' \
      "$OLD" "${STAND_IN_PANE:-$PRED}" "$claim_rc" "${WATCH_PID:-unread}" "${WATCH_PANE:-unread}" "$startup_exit"
    printf 'child-process=%s\n' "$child_process"
    printf 'child-output-begin\n'
    cat "$capture/output" || printf 'child-output=unread\n'
    printf 'claim-record-begin\n'
    cat "$WATCH_PID_FILE" 2>/dev/null || printf 'claim-record=unread\n'
    printf 'watch-order-begin\n'
    cat "$TMP_ROOT/watch.log" 2>/dev/null || printf 'watch-order=unread\n'
  } >&2
  exit 1
}
started_line() { grep "^started $1 " "$TMP_ROOT/watch.log" | sed "s/^started $1 //"; }
watch_handoff_read() {
  local word prev=""
  watch_pid_live "$FLEET_STATE" || { printf '%s\n' "$OUT" >&2; cat -- "$WATCH_ERR" >&2; return 1; }
  watch_argv_read "$FLEET_STATE"
  WATCH_HANDOFF="" WATCH_SINCE="" WATCH_HARNESS=""
  for word in "${WATCH_ARGV[@]}"; do
    [[ "$prev" != --handoff ]] || WATCH_HANDOFF="$word"
    [[ "$prev" != --since ]] || WATCH_SINCE="$word"
    [[ "$prev" != --harness ]] || WATCH_HARNESS="$word"
    prev="$word"
  done
}
# wait_restart — the pid of the watch recorded from the successor pane as a
# succession's restart, once its outcome line is written, or empty after the
# bound. The helper does its work after the launch has returned.
wait_restart() {
  local i
  NEW=""
  for (( i = 0; i < 150; i++ )); do
    if watch_pid_live "$FLEET_STATE" && [[ "$WATCH_ORIGIN" == succession && "$WATCH_PANE" == "$SUCC" ]] \
       && grep -q '^oversee-succeed: watch-restarted ' "$WATCH_ERR" 2>/dev/null; then
      NEW="$WATCH_PID"
      return 0
    fi
    sleep 0.1
  done
}
# succeed [OVERSEE_BIN] — the succession of the recorded overseer. Sets SUCC.
succeed() {
  run_oversee "${1:---}" ${1:+--} launch --predecessor "$PRED" --wait-secs 20
  SUCC="$(recorded pane)"
}

echo "=== oversee launch --predecessor: the fleet watch ==="

new_predecessor
fresh_output
succeed
wait_restart
assert_eq "$RC|$SUCC|$(grep -c "^oversee: watch-handover pid=$OLD pane=$SUCC log=$TMP_ROOT/work/tmp/oversee-watch.err $SETSID_LINE\$" <<<"$OUT")" \
  "0|$SUCC|1" \
  "the succession names the watch it hands to the successor pane"
assert_eq "$(grep -c "^stopped $OLD\$" "$TMP_ROOT/watch.log")" \
  "1" \
  "the watch serving the predecessor's pane is stopped, once"
assert_eq "${NEW:+found}|$(started_line "${NEW:-none}" | sed 's/ tmux=[^ ]* / /')" \
  "found|pane=$SUCC origin=succession lane=$H/.claude cwd=$TMP_ROOT/work argv=$WATCH_ARGS --handoff tmp/handoffs/OVERSEER-HANDOFF.md --harness claude -- --model fable --effort high $COMPACT $QUESTION_OFF $BYPASS" \
  "and started again from the successor pane, with the successor's harness, flags and account"
assert_eq "$(started_line "${NEW:-none}" | sed -n 's/.* tmux=\([^,]*\),\([0-9]*\),[0-9]* .*/\1 \2/p')" "$SOCKET $SERVER_PID" \
  "a launch from outside tmux hands the restarted watch the successor's tmux server"
assert_eq "$(grep -c "^oversee-succeed: watch-restarted pid=$NEW pane=$SUCC $SETSID_LINE\$" "$WATCH_ERR")" "1" \
  "the restart is written beside the fleet state with the new loop's pid and the successor pane"
watch_stop "$NEW" "$FLEET_STATE" || true

# The same complete command survives either claim state.
mkdir -p "$TMP_ROOT/configured"
WATCH_START_CWD="$TMP_ROOT/configured"
DEFAULT_WATCH_ARGS="$WATCH_ARGS"
WATCH_ARGS="--repeat 9 --interval 7 --state $FLEET_STATE --since 2026-01-01T00:00:00Z --repo custom/repo --item KEN-1 --hosted remote --root remote-root --handoff=old-handoff --harness codex"
for COMMAND_CASE in live released; do
  new_predecessor
  fresh_output
  COMMAND_BIN="$OVERSEE"
  if [[ "$COMMAND_CASE" != live ]]; then
    watch_stop "$OLD" "$FLEET_STATE"
    assert_eq "$(test -e "$WATCH_PID_FILE" && echo present || echo absent)" absent \
      "$COMMAND_CASE: normal release removed the live claim"
  fi
  succeed "$COMMAND_BIN"
  [[ "$COMMAND_CASE" != live ]] || wait_restart
  watch_pid_live "$FLEET_STATE" || true
  NEW="${WATCH_PID:-}"
  EXPECT_COMMAND="pane=$SUCC origin=succession lane=$H/.claude cwd=$TMP_ROOT/configured argv=${WATCH_ARGS% --handoff=old-handoff --harness codex} --handoff tmp/handoffs/OVERSEER-HANDOFF.md --harness claude -- --model fable --effort high $COMPACT $QUESTION_OFF $BYPASS"
  ACTUAL_COMMAND="$(started_line "${NEW:-none}" | sed 's/ tmux=[^ ]* / /')"
  assert_eq "$RC|$ACTUAL_COMMAND" "0|$EXPECT_COMMAND" \
    "$COMMAND_CASE: replay keeps script, cwd, selection and cadence and replaces only successor values"
  assert_eq "$WATCH_SCRIPT" "$FIXTURE_WATCH" "$COMMAND_CASE: the configured script remains the replay owner"
  [[ -z "$NEW" ]] || watch_stop "$NEW" "$FLEET_STATE" || true
done
WATCH_ARGS="$DEFAULT_WATCH_ARGS"
unset WATCH_START_CWD

# An unknown claim cannot grant permission to run any watch command.
UNKNOWN_RESULT="$(
  source "$SRC_DIR/lib/watch-handover.sh"
  SCRIPT_DIR="$SRC_DIR" DEP_ERR="$TMP_ROOT/unknown.err" HANDOFF=handoff
  watch_pid_live() { return 2; }
  watch_job_launch() { echo unexpected-launch; }
  unknown_rc=0
  watch_handover old new LANE_HOME account claude || unknown_rc=$?
  printf '%s|%s|%s' "$unknown_rc" "$WATCH_HANDOVER_KEY" "${WATCH_HANDOVER_FIELDS[*]}"
)"
assert_eq "$UNKNOWN_RESULT" '1|watch-restart-failed|step=claim' \
  "an unknown claim refuses before either fresh launch or replay"

ARGV_BOUNDARY="$(mutant_scripts argv-boundary)" || exit 1
rm -- "$ARGV_BOUNDARY/oversee-watch"
cp -p -- "$FIXTURE_WATCH" "$ARGV_BOUNDARY/oversee-watch"
for DESCRIPTOR_CASE in live released malformed legacy; do
  new_predecessor
  [[ "$DESCRIPTOR_CASE" == live ]] || watch_stop "$OLD" "$FLEET_STATE"
  DESCRIPTOR_BIN="$ARGV_BOUNDARY/oversee"
  if [[ "$DESCRIPTOR_CASE" == legacy* ]]; then
    printf '%s\0' --repeat 9 --state "$FLEET_STATE" --repo legacy/repo > "$WATCH_ARGV_FILE"
  elif [[ "$DESCRIPTOR_CASE" == malformed ]]; then
    printf 'unterminated' > "$WATCH_ARGV_FILE"
  else
    rm -- "$WATCH_ARGV_FILE"
  fi
  printf 'EVENT fixture retained\n' > "$WATCH_LOG_FILE"
  succeed "$DESCRIPTOR_BIN"
  if [[ "$DESCRIPTOR_CASE" == live ]]; then
    assert_eq "$RC|$(recorded pane)|$(grep -c '^oversee: watch-restart-failed step=argv' <<<"$OUT")" "1|$PRED|1" \
      "$DESCRIPTOR_CASE: refusal keeps the predecessor before close"
    [[ "$DESCRIPTOR_CASE" != live ]] || watch_pid_live "$FLEET_STATE"
  else
    watch_pid_live "$FLEET_STATE"
    assert_eq "$RC|$WATCH_ORIGIN|$WATCH_PANE|$(grep -c '^oversee: watch-started ' <<<"$OUT")|$(grep -c '^oversee: overseer-launched ' <<<"$OUT")" \
      "0|succession|$SUCC|1|1" "$DESCRIPTOR_CASE: the successor owns the started watch"
    UNREAD_COUNT="$(grep -cF "unread=$WATCH_ARGV_FILE" <<<"$OUT" || true)"
    if [[ "$DESCRIPTOR_CASE" == legacy ]]; then
      assert_eq "$UNREAD_COUNT" 0 "$DESCRIPTOR_CASE: the unread assertion detects an omitted field"
    else
      assert_eq "$UNREAD_COUNT" 1 "$DESCRIPTOR_CASE: the default selection names its unread command"
    fi
    if [[ "$DESCRIPTOR_CASE" == legacy ]]; then
      watch_argv_read "$FLEET_STATE"
      assert_eq "$(printf '%s\n' "${WATCH_ARGV[@]}" | sed -n '/^--repo$/{n;p;}')" legacy/repo \
        "the released pre-1.0 command retains its repository selection"
    fi
    watch_stop "$WATCH_PID" "$FLEET_STATE"
  fi
  assert_eq "$(grep -c '^EVENT fixture retained$' "$WATCH_LOG_FILE")" 1 \
    "$DESCRIPTOR_CASE: succession retains the log cursor's lines"
  [[ "$DESCRIPTOR_CASE" != live ]] || watch_stop "$OLD" "$FLEET_STATE"
done

# Older installed watches wrote argv alone and kept metadata in the claim.
# Keep its arguments after the claim releases its script and directory.
LEGACY_STATE="$TMP_ROOT/work/tmp/legacy-state.json"
watch_pid_write "$LEGACY_STATE" old hand "$FIXTURE_WATCH" --repo legacy/repo --repeat 9
python3 - "$WATCH_ARGV_FILE" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_bytes(b'\0'.join(p.read_bytes().split(b'\0')[3:]))
PY
watch_argv_read "$LEGACY_STATE" 2>"$TMP_ROOT/legacy.err"
assert_eq "$WATCH_SCRIPT|$WATCH_CWD|${WATCH_ARGV[*]}" \
  "$FIXTURE_WATCH|$PWD|--repo legacy/repo --repeat 9" \
  "the retired argv form keeps its complete command when its claim supplies metadata"
assert_eq "$(grep -c '^watch-pid: deprecated=argv replacement=watch-command-v1$' "$TMP_ROOT/legacy.err")" 1 \
  "the retired command form names its replacement once per read"
watch_pid_release "$LEGACY_STATE"
SCRIPT_DIR="$SRC_DIR"
LEGACY_RC=0
watch_argv_read "$LEGACY_STATE" 2>"$TMP_ROOT/legacy.err" || LEGACY_RC=$?
assert_eq "$LEGACY_RC|$WATCH_SCRIPT|$WATCH_CWD|${WATCH_ARGV[*]}" \
  "0|$SRC_DIR/oversee-watch|$PWD|--repo legacy/repo --repeat 9" \
  "a released retired descriptor uses the fresh pair and keeps its arguments"

# A first launch and a succession each start a missing repeat watch.
tm kill-window -a -t "$KEEP_WINDOW"
tm move-window -r -t fleet
rm -f -- "$FLEET_STATE"
FIRST_HANDOFF="$TMP_ROOT/work/tmp/custom-handoff.md"
run_oversee -- launch --handoff "$FIRST_HANDOFF" --wait-secs 20
[[ "$RC" -eq 0 ]] || printf '%s\ncustom-handoff-launch-exit=%s\n' "$OUT" "$RC" >&2
PRED="$(recorded pane)"
LIVE_RC=0
watch_pid_live "$FLEET_STATE" || LIVE_RC=$?
assert_eq "$RC|$LIVE_RC|$WATCH_PANE|$(sed -n 's/^runner=//p' "$WATCH_RUNNER_FILE")" \
  "0|0|$PRED|setsid" "a first launch leaves a repeat watch claimed under the job runner"
watch_handoff_read
assert_eq "$WATCH_HANDOFF" "$FIRST_HANDOFF" "the first watch keeps the launch's handoff path as one argument"
FIRST_SINCE="$WATCH_SINCE"
watch_stop "$WATCH_PID" "$FLEET_STATE"
fresh_output
succeed
LIVE_RC=0
watch_pid_live "$FLEET_STATE" || LIVE_RC=$?
assert_eq "$RC|$LIVE_RC|$WATCH_PANE" "0|0|$SUCC" \
  "a succession starts a missing repeat watch for its new pane"
watch_handoff_read
assert_eq "$WATCH_SINCE" "$FIRST_SINCE" "a missing-watch succession keeps the fleet start with no lane records"
watch_stop "$WATCH_PID" "$FLEET_STATE"

# Stop keeps the fleet state and its handled event logs. A fresh reader
# starts from line one; a successor retains its previous reader cursor.
LOG_BOUNDARY="$(mutant_scripts log-boundary)" || exit 1
rm -- "$LOG_BOUNDARY/oversee-watch"
cp -p -- "$FIXTURE_WATCH" "$LOG_BOUNDARY/oversee-watch"
for LOG_CASE in fresh succession; do
  LOG_BIN="$LOG_BOUNDARY"
  PRED="$(recorded pane)"
  printf 'EVENT fixture retained\n' > "$WATCH_LOG_FILE"
  printf 'fixture retained\n' > "$WATCH_ERR_FILE"
  ROW_ENV=(OVERSEE_WATCH_LOG_CASE="$LOG_CASE")
  if [[ "$LOG_CASE" != succession ]]; then
    tm kill-window -t "$PRED"
    run_oversee "$LOG_BIN/oversee" -- launch --wait-secs 20
  else
    run_oversee "$LOG_BIN/oversee" -- launch --predecessor "$PRED" --wait-secs 20
  fi
  ROW_ENV=()
  watch_handoff_read
  assert_eq "$RC" 0 "$LOG_CASE: the stopped-watch launch succeeds against the retained fleet state"
  for LOG_STREAM in "$WATCH_LOG_FILE" "$WATCH_ERR_FILE"; do
    assert_file_contains "$LOG_STREAM" "current-$LOG_CASE" "$LOG_CASE: the new watch writes its current event"
    if [[ "$LOG_CASE" == fresh ]]; then
      assert_file_not_contains "$LOG_STREAM" retained "$LOG_CASE: a reader from line one cannot receive a handled event"
    elif [[ "$LOG_CASE" == succession ]]; then
      assert_file_contains "$LOG_STREAM" retained "$LOG_CASE: the successor keeps unread log lines and their cursor positions"
      RETAINED_LINE='fixture retained'
      [[ "$LOG_STREAM" != "$WATCH_LOG_FILE" ]] || RETAINED_LINE='EVENT fixture retained'
      assert_eq "$(sed -n '1p' "$LOG_STREAM")" "$RETAINED_LINE" \
        "$LOG_CASE: the old event keeps its numbered reader position"
    fi
  done
  watch_stop "$WATCH_PID" "$FLEET_STATE"
done

# The floor comes from the first lane. Repository selection stays with the
# watch's existing default and ORCH_CONNECTED_REPOS resolution.
SINCE_FLOOR="$(mutant_scripts since-floor)" || exit 1
for SINCE_CASE in floor; do
  SINCE_BIN="$SINCE_FLOOR"
  rm -- "${SINCE_BIN:?}/oversee-watch"
  cp -p -- "$FIXTURE_WATCH" "$SINCE_BIN/oversee-watch"
  tm kill-window -a -t "$KEEP_WINDOW"
  printf '%s\n' '{"lanes":[{"item":"KEN-1","status":"done","launched_at":"2026-01-01T00:00:00Z"}]}' > "$FLEET_STATE"
  run_oversee "$SINCE_BIN/oversee" -- launch --wait-secs 20
  watch_handoff_read
  EXPECT_SINCE=2026-01-01T00:00:00Z
  assert_eq "$RC|$WATCH_SINCE" "0|$EXPECT_SINCE" "$SINCE_CASE: the first watch carries the fixed fleet start"
  watch_stop "$WATCH_PID" "$FLEET_STATE"
done

# A start that gives up on a job whose watch may still run gives the job up
# through its own record: stopped there and the record removed, or the record
# kept and named in the refusal with the stop's error. One row per give-up:
#   unpublished  the watch adds no pid by the bound, so a setsid job names no
#                group to stop and its record stays
#   unknown      the watch's pid runs but ps cannot read it, nor then can the
#                stop, so the record stays
#   runner       the watch claims, but its record cannot become the runner
#                record: its group is stopped and the record removed
#   unit         unpublished under the user manager, where one answers: the
#                unit is stopped by its name and the record removed
#   unit-launch  a unit launch the client reports failed while the manager
#                cannot say whether it took it, whose stop fails as well, so
#                the record stays
# The rows run through a stand-in watch whose mode file picks what it does:
# quiet runs on and adds no pid, publish adds it, claim runs the fixture
# watch, which adds it and claims. The control removes the record and stops
# nothing, as the start did before, and must fail every row.
GIVEUP_WATCH="$TMP_ROOT/fixture/giveup-watch"
cat > "$GIVEUP_WATCH" <<EOF
#!/usr/bin/env bash
echo "\$\$" > "$TMP_ROOT/giveup.pid"
mode="\$(cat "$TMP_ROOT/giveup.mode")"
[[ "\$mode" != claim ]] || exec "$FIXTURE_WATCH" "\$@"
source "$SRC_DIR/lib/watch-pid.sh"
[[ "\$mode" != publish ]] || watch_job_pid_write "\$OVERSEE_WATCH_JOB_RECORD"
while :; do sleep 1; done
EOF
chmod +x "$GIVEUP_WATCH"
mkdir -p "$TMP_ROOT/ps-refuse" "$TMP_ROOT/mv-refuse" "$TMP_ROOT/linger" "$TMP_ROOT/unit-launch"
cat > "$TMP_ROOT/ps-refuse/ps" <<EOF
#!/bin/sh
pid="\$(cat "$TMP_ROOT/giveup.pid" 2>/dev/null)"
prev=""
for arg in "\$@"; do
  if [ -n "\$pid" ] && [ "\$prev" = -p ] && [ "\$arg" = "\$pid" ]; then echo "fixture: ps refused" >&2; exit 1; fi
  prev="\$arg"
done
exec "$(command -v ps)" "\$@"
EOF
cat > "$TMP_ROOT/mv-refuse/mv" <<EOF
#!/bin/sh
for last in "\$@"; do :; done
case "\$last" in */oversee-watch.runner) echo "fixture: mv refused" >&2; exit 1 ;; esac
exec "$(command -v mv)" "\$@"
EOF
cp "$NO_MANAGER/loginctl" "$TMP_ROOT/linger/loginctl"
cp "$NO_MANAGER/loginctl" "$TMP_ROOT/unit-launch/loginctl"
printf '#!/bin/sh\ncase "$*" in *--unit=*) echo "fixture: launch timed out" >&2; exit 1 ;; esac\nexit 0\n' \
  > "$TMP_ROOT/unit-launch/systemd-run"
printf '#!/bin/sh\necho "fixture: bus timeout" >&2\nexit 1\n' > "$TMP_ROOT/unit-launch/systemctl"
chmod +x "$TMP_ROOT/ps-refuse/ps" "$TMP_ROOT/mv-refuse/mv" "$TMP_ROOT/unit-launch/systemd-run" "$TMP_ROOT/unit-launch/systemctl"
UNIT_HOST=(XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}")
GIVEUP="$(mutant_scripts giveup lib/watch-handover.sh)" || exit 1
GIVEUP_CONTROL="$(mutant_scripts giveup-control lib/watch-handover.sh)" || exit 1
mutate_file "$GIVEUP_CONTROL/lib/watch-handover.sh" '      watch_job_abandon "$WATCH_JOB_RECORD" 0 || true' \
  '      rm -f -- "$WATCH_JOB_RECORD"'
mutate_file "$GIVEUP_CONTROL/lib/watch-handover.sh" '  watch_job_abandon "$record" "${WATCH_JOB_PID:-0}" || true' \
  '  rm -f -- "$record"'
mutate_file "$GIVEUP_CONTROL/lib/watch-handover.sh" '("${refusal[@]}" "${WATCH_JOB_STOP[@]}" "$runner")' \
  '("${refusal[@]}" "$runner")'
for GIVEUP_DIR in "$GIVEUP" "$GIVEUP_CONTROL"; do
  rm -- "$GIVEUP_DIR/oversee-watch"
  cp -p -- "$GIVEUP_WATCH" "$GIVEUP_DIR/oversee-watch"
done
# giveup_row ROW SCRIPTS — a first launch through SCRIPTS under ROW's
# failure, the job then stopped and its kept record removed. Sets
# GIVEUP_RESULT and GIVEUP_EXPECT: the exit, the refusal line with the
# launch's unit name as UNIT, whether a job record stays, and whether the
# started watch runs.
giveup_row() {
  local row="$1" scripts="$2" mode=quiet line kept job runs
  case "$row" in
    unpublished) ROW_ENV=() ;;
    unknown) mode=publish ROW_ENV=(PATH="$TMP_ROOT/ps-refuse:$NO_MANAGER:$BIN:$PATH") ;;
    runner) mode=claim ROW_ENV=(PATH="$TMP_ROOT/mv-refuse:$NO_MANAGER:$BIN:$PATH") ;;
    unit) ROW_ENV=(PATH="$TMP_ROOT/linger:$BIN:$PATH" "${UNIT_HOST[@]}") ;;
    unit-launch) ROW_ENV=(PATH="$TMP_ROOT/unit-launch:$BIN:$PATH") ;;
  esac
  printf '%s\n' "$mode" > "$TMP_ROOT/giveup.mode"
  rm -f -- "$TMP_ROOT/giveup.pid" "${FLEET_STATE:?}"
  tm kill-window -a -t "$KEEP_WINDOW"
  run_oversee "$scripts/oversee" -- launch --wait-secs 20
  ROW_ENV=()
  line="$(grep '^oversee: watch-restart-failed ' <<<"$OUT" | sed 's/orch-watch-start-[0-9TZ]*-[0-9]*/UNIT/g' || true)"
  kept="$(find "$TMP_ROOT/work/tmp" -name 'oversee-watch.runner.*')"
  job="$(cat "$TMP_ROOT/giveup.pid" 2>/dev/null || echo none)"
  runs=stopped
  ! watch_pid_runs "$job" 2>/dev/null || runs=running
  GIVEUP_RESULT="$RC|$line|${kept:+kept}|$runs"
  case "$row" in
    unpublished) GIVEUP_EXPECT="1|oversee: watch-restart-failed step=claim log=$WATCH_ERR stop=failed record=$kept stop-error=kill-group-failed pid=0 step=read $SETSID_LINE|kept|running" ;;
    unknown) GIVEUP_EXPECT="1|oversee: watch-restart-failed step=claim log=$WATCH_ERR stop=failed record=$kept stop-error=kill-group-failed pid=$job step=read $SETSID_LINE|kept|running" ;;
    runner) GIVEUP_EXPECT="1|oversee: watch-restart-failed step=runner pid=$job stop=stopped $SETSID_LINE||stopped" ;;
    unit) GIVEUP_EXPECT="1|oversee: watch-restart-failed step=claim log=$WATCH_ERR stop=stopped runner=systemd unit=UNIT||stopped" ;;
    unit-launch) GIVEUP_EXPECT="1|oversee: watch-restart-failed step=start stop=failed record=$kept stop-error=stop-failed unit=UNIT.service detail=fixture: bus timeout error=launch-failed unit=UNIT.service step=show detail=fixture: launch timed out|kept|stopped" ;;
  esac
  if [[ "$runs" == running ]]; then
    kill -TERM "$job" 2>/dev/null || true
    for _ in $(seq 1 100); do watch_pid_runs "$job" || break; sleep 0.1; done
  fi
  find "$TMP_ROOT/work/tmp" -name 'oversee-watch.runner.*' -delete
}
GIVEUP_ROWS=(unpublished unknown runner unit-launch)
if systemd-run --user --quiet --collect true </dev/null >/dev/null 2>&1; then
  GIVEUP_ROWS+=(unit)
else
  printf '  skip  no user manager answers; the unit give-up row did not run\n'
fi
for GIVEUP_CASE in "${GIVEUP_ROWS[@]}"; do
  giveup_row "$GIVEUP_CASE" "$GIVEUP"
  assert_eq "$GIVEUP_RESULT" "$GIVEUP_EXPECT" \
    "$GIVEUP_CASE: a start that gives up stops its job through its record or keeps the record and names it" "$WATCH_ERR"
  giveup_row "$GIVEUP_CASE" "$GIVEUP_CONTROL"
  assert_eq "$([[ "$GIVEUP_RESULT" == "$GIVEUP_EXPECT" ]] && echo held || echo caught)" caught \
    "control: $GIVEUP_CASE: a start that removes the record and stops nothing fails the row"
done

# The runner refuses the job: a setsid that starts nothing. A first launch
# must close the new pane.
mkdir -p "$TMP_ROOT/no-start"
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/no-start/setsid"
chmod +x "$TMP_ROOT/no-start/setsid"
for ERROR_CASE in retained; do
  ERROR_BIN="$OVERSEE"
  EXPECT_ERROR=1
  tm kill-window -a -t "$KEEP_WINDOW"
  rm -f -- "${FLEET_STATE:?}"
  ROW_ENV=(PATH="$TMP_ROOT/no-start:$NO_MANAGER:$BIN:$PATH")
  run_oversee "$ERROR_BIN" -- launch --wait-secs 20
  ROW_ENV=()
  LIVE_RC=0
  watch_pid_live "$FLEET_STATE" || LIVE_RC=$?
  assert_eq "$RC|$LIVE_RC|$(grep -c '^oversee: overseer-launched ' <<<"$OUT")|$(grep -c '^oversee: watch-restart-failed step=start error=launch-failed ' <<<"$OUT")" \
    "1|1|0|$EXPECT_ERROR" "$ERROR_CASE: a refused job keeps its failed status and the restoration preserves the launch error"
done

# A $TMUX tmux will not state for the successor's session is a notice, and
# the succession still stands with no helper started: a tmux on the run's
# PATH refuses the one read that names the server.
TMUX_FAIL="$TMP_ROOT/tmux-fail-bin"
mkdir -p "$TMUX_FAIL"
printf '#!/bin/sh\ncase "$*" in *session_id*) echo "fixture: display refused" >&2; exit 1 ;; esac\nexec %s "$@"\n' \
  "$(command -v tmux)" > "$TMUX_FAIL/tmux"
chmod +x "$TMUX_FAIL/tmux"
new_predecessor
fresh_output
ROW_ENV=(PATH="$TMUX_FAIL:$NO_MANAGER:$BIN:$PATH")
succeed
ROW_ENV=()
sleep 2
assert_eq "$RC|$(grep -A2 '^oversee: watch-restart-failed ' <<<"$OUT" | sed -n '1p;3p')|$(grep -c '^oversee: watch-handover ' <<<"$OUT")|$(kill -0 "$OLD" 2>/dev/null && echo alive || echo gone)" \
  "1|$(grep '^oversee: watch-restart-failed ' <<<"$OUT")
fixture: display refused|0|alive" \
  "an unreadable successor server refuses the succession and keeps the old watch"
watch_stop "$OLD" "$FLEET_STATE" || true

# A launch from inside the predecessor's window dies at the stop, so the
# handover is arranged before it: modelled by a tmux that, having run the
# stop's swap, kills the process group of the launch that called it, which is
# started as a group of its own. The restart, left to a helper the orch job
# runner started under setsid in a session of its own, still happens. A host
# with no setsid has no runner here and no row.
if command -v setsid >/dev/null 2>&1; then
  REAL_TMUX="$(command -v tmux)"
  TEST_PGID="$(ps -o pgid= -p $$ | tr -d ' ')"
  mkdir -p "$TMP_ROOT/killbin"
  cat > "$TMP_ROOT/killbin/tmux" <<EOF
#!/usr/bin/env bash
"$REAL_TMUX" "\$@"
rc=\$?
if [ "\$1" = kill-window ]; then
  pg=\$(ps -o pgid= -p \$\$ | tr -d ' ')
  [ "\$pg" = "$TEST_PGID" ] || kill -KILL -- "-\$pg"
fi
exit \$rc
EOF
  chmod +x "$TMP_ROOT/killbin/tmux"
  new_predecessor
  fresh_output
  ROW_ENV=(PATH="$TMP_ROOT/killbin:$NO_MANAGER:$BIN:$PATH")
  ROW_LAUNCH=setsid succeed
  ROW_ENV=()
  wait_restart
  assert_eq "$RC|$(tm list-panes -a -F '#{pane_id}' | grep -cxF -- "$PRED" || true)|${NEW:+restarted}|$(grep -c "^stopped $OLD\$" "$TMP_ROOT/watch.log")" \
    "137|0|restarted|1" \
    "a launch killed with its process group at the stop still has the watch restarted from the successor pane"
  watch_stop "$NEW" "$FLEET_STATE" || true
else
  printf '  skip  the process-group kill row needs setsid\n'
fi

# `oversee resume` serves its new pane as a succession does. The recorded
# overseer's session is gone with its server and its native id is bound; the
# watch it ran may still hold its claim on the lost pane's id (live), or have
# released it with its command and unread log lines retained (released). A
# new server numbers its panes afresh, so the live claim's id is one the
# server lists, here the fleet's own first pane, which no restarted watch
# takes over: resume replays that watch from the resumed pane, naming it for
# the replay to stop and replace, before it returns. A released one is
# replayed there with the log kept. Its controls restore the resume guard on
# step 9, defer the live claim to the helper and drop --closed, each of which
# must fail its row.
KEEP_PANE="$(tm display-message -p -t "$KEEP_WINDOW" '#{pane_id}')"
resume_watch_row() { # live|released [OVERSEE_BIN]
  STAND_IN_PANE=""
  [[ "$1" != live ]] || STAND_IN_PANE="$KEEP_PANE"
  new_predecessor
  STAND_IN_PANE=""
  fresh_output
  [[ "$1" == live ]] || watch_stop "$OLD" "$FLEET_STATE"
  printf 'EVENT fixture retained\n' > "$WATCH_LOG_FILE"
  jq '.overseer.session_id = "native-claude"' "$FLEET_STATE" > "$FLEET_STATE.next" && mv -- "$FLEET_STATE.next" "$FLEET_STATE"
  tm kill-window -t "$PRED"
  run_oversee "${2:---}" ${2:+--} resume --wait-secs 20
  SUCC="$(recorded pane)"
  NEW=""
  if watch_pid_live "$FLEET_STATE" && [[ "$WATCH_ORIGIN" == succession && "$WATCH_PANE" == "$SUCC" ]]; then NEW="$WATCH_PID"; fi
  if [[ "$1" == live ]]; then
    assert_eq "$RC|$(grep -c "^oversee: watch-started pid=${NEW:-none} pane=$SUCC log=$WATCH_LOG_FILE err=$WATCH_ERR stopped=$OLD $SETSID_LINE\$" <<<"$OUT")|$(grep -c "^stopped $OLD\$" "$TMP_ROOT/watch.log")|$(started_line "${NEW:-none}" | sed 's/ lane=.*//')|$(grep -c '^EVENT fixture retained$' "$WATCH_LOG_FILE")" \
      "0|1|1|pane=$SUCC origin=succession|1" \
      "resume returns with the watch that claimed a listed pane id stopped and replayed from the resumed pane"
  else
    assert_eq "$RC|$(grep -c "^oversee: watch-started pid=${NEW:-none} pane=$SUCC " <<<"$OUT")|$(started_line "${NEW:-none}" | sed 's/ tmux=[^ ]* / /')|$(grep -c '^EVENT fixture retained$' "$WATCH_LOG_FILE")" \
      "0|1|pane=$SUCC origin=succession lane=$H/.claude cwd=$TMP_ROOT/work argv=$WATCH_ARGS --handoff tmp/handoffs/OVERSEER-HANDOFF.md --harness claude -- --model fable --effort high $COMPACT $QUESTION_OFF $BYPASS|1" \
      "resume replays the released watch's command from the resumed pane and keeps its unread log lines"
  fi
  [[ -z "$NEW" ]] || watch_stop "$NEW" "$FLEET_STATE" || true
}
resume_watch_control() { # NAME CASE FILE FROM TO
  local dir saved_fail="$FAIL" control_fail
  dir="$(mutant_scripts "resume-watch-$1" "$3")" || exit 1
  rm -- "${dir:?}/oversee-watch"
  cp -p -- "$FIXTURE_WATCH" "$dir/oversee-watch"
  mutate_file "$dir/$3" "$4" "$5"
  FAIL=0
  resume_watch_row "$2" "$dir/oversee" > "$TMP_ROOT/resume-watch-control.out"
  control_fail="$FAIL"
  FAIL="$saved_fail"
  ! watch_pid_live "$FLEET_STATE" || watch_stop "$WATCH_PID" "$FLEET_STATE" || true
  assert_eq "$(( control_fail > 0 ))" 1 "control: the $1 copy fails the $2 resume watch row" "$TMP_ROOT/resume-watch-control.out"
}
echo "=== oversee resume: the fleet watch ==="
for RESUME_CASE in live released; do resume_watch_row "$RESUME_CASE"; done
resume_watch_control unguarded live oversee '      hand_over_watch ;;' '      [[ "$COMMAND" == resume ]] || hand_over_watch ;;'
resume_watch_control deferred live lib/watch-handover.sh '  if (( closed )); then' '  if false; then'
resume_watch_control unclosed released oversee '  [[ "$COMMAND" != resume ]] || closed=(--closed)' '  :'

# The new server can hand the lost pane's id to the resumed pane itself. The
# watch claiming it was started by an earlier succession, so its record names
# origin succession and that very pane: both readiness checks hold for it. Its
# command runs through a copy that waits a second before it execs the
# stand-in, so the old claim is still live when resume first reads, and resume
# must report the replay's own pid, never the old one. The id is the one the
# server hands out after a probe pane's. The control drops the pid comparison
# and must report the old watch. Sets REUSED_RESULT.
SLOW_WATCH="$TMP_ROOT/slow-watch/oversee-watch"
mkdir -p "${SLOW_WATCH%/*}"
printf '#!/bin/sh\nsleep 1\nexec %s "$@"\n' "$FIXTURE_WATCH" > "$SLOW_WATCH"
chmod +x "$SLOW_WATCH"
resume_reused_row() { # [OVERSEE_BIN]
  local probe reused reported
  STAND_IN_ENV=(FIXTURE_RECORD_SCRIPT="$SLOW_WATCH")
  new_predecessor
  STAND_IN_ENV=()
  fresh_output
  jq '.overseer.session_id = "native-claude"' "$FLEET_STATE" > "$FLEET_STATE.next" && mv -- "$FLEET_STATE.next" "$FLEET_STATE"
  tm kill-window -t "$PRED"
  probe="$(tm new-window -d -P -F '#{pane_id}' -t fleet)"
  tm kill-pane -t "$probe"
  reused="%$(( ${probe#%} + 1 ))"
  awk -v p="$reused" '/^pane=/ { $0 = "pane=" p } /^origin=/ { $0 = "origin=succession" } { print }' \
    "$WATCH_PID_FILE" > "$WATCH_PID_FILE.next" && mv -- "$WATCH_PID_FILE.next" "$WATCH_PID_FILE"
  run_oversee "${1:---}" ${1:+--} resume --wait-secs 20
  SUCC="$(recorded pane)"
  NEW=""
  if watch_pid_live "$FLEET_STATE" && [[ "$WATCH_PID" != "$OLD" && "$WATCH_PANE" == "$SUCC" ]]; then NEW="$WATCH_PID"; fi
  reported="$(sed -n 's/^oversee: watch-started pid=\([0-9]*\) .* stopped=.*/\1/p' <<<"$OUT")"
  case "$reported" in
    "$OLD") reported=old ;;
    "${NEW:-none}") reported=new ;;
    *) reported="other:$reported" ;;
  esac
  REUSED_RESULT="$RC|$SUCC|$reported"
  for _ in $(seq 1 100); do
    if watch_pid_live "$FLEET_STATE" && [[ "$WATCH_PID" != "$OLD" ]]; then watch_stop "$WATCH_PID" "$FLEET_STATE" || true; break; fi
    sleep 0.1
  done
  REUSED_PANE="$reused"
}
resume_reused_row
assert_eq "$REUSED_RESULT" "0|$REUSED_PANE|new" \
  "resume reports the replay's own claim where the replaced watch's record names the resumed pane" "$WATCH_ERR"
REUSED_CONTROL="$(mutant_scripts resume-reused lib/watch-handover.sh)" || exit 1
mutate_file "$REUSED_CONTROL/lib/watch-handover.sh" '"$WATCH_PID" != "$prior" && ' ''
resume_reused_row "$REUSED_CONTROL/oversee"
assert_eq "${REUSED_RESULT##*|}" old \
  "control: without the pid comparison resume reports the replaced watch's claim as the replay's" "$WATCH_ERR"

# The owner's acceptance row: the real watch, started by hand from the
# predecessor's pane as an overseer starts it, is handed over, and the
# successor dies right after. The restarted watch reads the successor's pane
# and reports the death, `overseer-dead`, calling the relaunch on that pane.
# The watch's other readers are stubs: GitHub, the tracker and the accounts
# answer nothing, and oversee-succeed, whose relaunch is its own suite's,
# records how it was called. The launch carries their settings, since the
# restarted watch runs under the launch's environment.
WSTUBS="$TMP_ROOT/watch-stubs"
mkdir -p "$WSTUBS"
cat > "$WSTUBS/succeed" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WSTUBS/succeed.args"
case "\$1" in
  --print-launch-line) exit 1 ;;
  --check-marks)
    if [ -f "$HARNESS_PIDS/wall-\${TMUX_PANE#%}" ]; then
      echo "oversee-succeed: mark-reached kind=headroom value=0 mark=5 succession=on"
    else
      echo "oversee-succeed: account-below-mark headroom=80"
    fi ;;
  *) exec "\$(cat "$WSTUBS/succeed.bin")" "\$@" ;;
esac
EOF
printf '%s\n' "$SRC_DIR/oversee-succeed" > "$WSTUBS/succeed.bin"
printf '#!/bin/sh\n[ "$1 $2" != "auth status" ] || echo "Logged in"\n' > "$WSTUBS/gh"
printf '#!/bin/sh\n' > "$WSTUBS/silent"
printf '#!/bin/sh\necho "[]"\n' > "$WSTUBS/lanes"
chmod +x "$WSTUBS"/*
WATCH_ENV=(PATH="$WSTUBS:$NO_MANAGER:$BIN:$PATH" ORCH_REPORT=off ORCH_WATCH_MAIL_INTERVAL=0
  OVERSEE_WATCH_SUCCEED="$WSTUBS/succeed" OVERSEE_WATCH_PR_WATCH="$WSTUBS/silent"
  OVERSEE_WATCH_TRACKER="$WSTUBS/silent" OVERSEE_WATCH_LANES="$WSTUBS/lanes")

# `oversee resume` while the watch claiming the lost pane is part way through
# a lane-close: stopped, the stand-in releases its record and runs on until
# the row releases it. Its record names the real watch, which the resume
# replays and which must wait the old one out under watch-finishing before
# its first pass, the one this gh marks `pass` in watch.log at its auth read.
# The row holds the old watch until the replay waits, its first pass lands or
# a minute passes, then reads the order once both have landed, within another
# minute: a real watch's first pass can take tens of seconds on a loaded
# host, and the stand-in's own two-minute hold outlasts both. The control
# stops the old watch in the handover, before the replay starts, which must
# let the first pass in before the old close ends. Sets FINISH_RESULT and
# FINISH_ORDER.
# The wrapper's own auth, before its claim, carries no OVERSEE_WATCH_REPEAT_OWNER
# and marks nothing.
FINISH_BIN="$TMP_ROOT/finish-bin"
mkdir -p "$FINISH_BIN"
printf '#!/bin/sh\n[ "$1 $2" != "auth status" ] || { [ -z "$OVERSEE_WATCH_REPEAT_OWNER" ] || echo pass >> %s/watch.log; echo "Logged in"; }\n' "$TMP_ROOT" > "$FINISH_BIN/gh"
chmod +x "$FINISH_BIN/gh"
resume_finishing_row() { # [OVERSEE_BIN]
  local deadline start
  rm -f -- "${TMP_ROOT:?}/finish-release"
  STAND_IN_PANE="$KEEP_PANE"
  STAND_IN_ENV=(FIXTURE_RECORD_SCRIPT="$SRC_DIR/oversee-watch" FIXTURE_FINISH_HOLD="$TMP_ROOT/finish-release")
  new_predecessor
  STAND_IN_PANE="" STAND_IN_ENV=()
  fresh_output
  # The long-pass row an earlier watch on this state wrote defers the
  # replay's first long pass, and its auth read, by up to the cadence.
  rm -f -- "${TMP_ROOT:?}/state/"*.mail
  jq '.overseer.session_id = "native-claude"' "$FLEET_STATE" > "$FLEET_STATE.next" && mv -- "$FLEET_STATE.next" "$FLEET_STATE"
  tm kill-window -t "$PRED"
  start="$(awk 'END { print NR }' "$TMP_ROOT/watch.log")"
  ROW_ENV=("${WATCH_ENV[@]}" PATH="$FINISH_BIN:$WSTUBS:$NO_MANAGER:$BIN:$PATH")
  run_oversee "${1:---}" ${1:+--} resume --wait-secs 20
  ROW_ENV=()
  SUCC="$(recorded pane)"
  NEW=""
  if watch_pid_live "$FLEET_STATE" && [[ "$WATCH_ORIGIN" == succession && "$WATCH_PANE" == "$SUCC" ]]; then NEW="$WATCH_PID"; fi
  deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    grep -q "^oversee-watch: watch-finishing pid=$OLD\$" "$WATCH_ERR" 2>/dev/null && break
    awk -v s="$start" 'NR > s && $0 == "pass" { f = 1 } END { exit !f }' "$TMP_ROOT/watch.log" && break
    sleep 0.1
  done
  touch "$TMP_ROOT/finish-release"
  deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    awk -v s="$start" -v f="finished $OLD" 'NR > s && $0 == f { o = 1 } NR > s && $0 == "pass" { p = 1 } END { exit !(o && p) }' \
      "$TMP_ROOT/watch.log" && break
    sleep 0.1
  done
  FINISH_ORDER="$(awk -v s="$start" -v f="finished $OLD" 'NR > s && ($0 == f || $0 == "pass") && !seen[$0]++ { printf "%s ", ($0 == "pass" ? "pass" : "finished") }' "$TMP_ROOT/watch.log")"
  FINISH_RESULT="$RC|$(grep -c "^oversee: watch-started pid=${NEW:-none} pane=$SUCC log=$WATCH_LOG_FILE err=$WATCH_ERR stopped=$OLD $SETSID_LINE\$" <<<"$OUT" || true)|$(grep -c "^oversee-watch: watch-taken-over pid=$OLD pane=$KEEP_PANE reason=replace\$" "$WATCH_ERR" || true)|$(grep -c "^oversee-watch: watch-finishing pid=$OLD\$" "$WATCH_ERR" || true)|$FINISH_ORDER"
  [[ -z "$NEW" ]] || watch_stop "$NEW" "$FLEET_STATE" || true
}
echo "=== oversee resume: a replaced watch finishing a lane-close ==="
resume_finishing_row
assert_eq "$FINISH_RESULT" "0|1|1|1|finished pass " \
  "resume's replay takes over the watch it names and waits out its close before its first pass" "$WATCH_ERR"
FINISH_CONTROL="$(mutant_scripts resume-finishing lib/watch-handover.sh)" || exit 1
mutate_file "$FINISH_CONTROL/lib/watch-handover.sh" '    watch_start "replace=$old" "$state" "${@:2}" || return 1' \
  $'    watch_stop "$old" "$state" 2>"$DEP_ERR" || return 1\n    watch_start replay "$state" "${@:2}" || return 1'
resume_finishing_row "$FINISH_CONTROL/oversee"
assert_eq "$FINISH_ORDER" "pass finished " \
  "control: a handover that stops the old watch itself lets the replay's first pass in before the old close ends" "$WATCH_ERR"

# The auth acknowledgement orders the first long pass after the harness exit.
# A pass's auth is held, never the wrapper's own before its claim, which the
# pass's OVERSEE_WATCH_REPEAT_OWNER tells apart.
REAL_GH="$WSTUBS/gh.real"
cp "$WSTUBS/gh" "$REAL_GH"
cat > "$WSTUBS/gh" <<EOF
#!/bin/sh
if [ "\$1 \$2" = 'auth status' ] && [ -n "\${OVERSEE_WATCH_REPEAT_OWNER:-}" ]; then
  echo waiting > "$WSTUBS/auth.waiting"
  while [ ! -f "$WSTUBS/harness.dead" ]; do sleep 0.1; done
fi
exec "$REAL_GH" "\$@"
EOF
chmod +x "$WSTUBS/gh"
for MANAGER in setsid unit; do
if [[ "$MANAGER" == unit ]]; then
  if ! systemd-run --user --quiet --collect true </dev/null >/dev/null 2>&1; then
    printf '  skip  no user manager answers; the initial unit death row did not run\n'
    continue
  fi
  mkdir -p "$WSTUBS/lingering"
  cp "$NO_MANAGER/loginctl" "$WSTUBS/lingering/loginctl"
fi
tm kill-window -a -t "$KEEP_WINDOW"
rm -f -- "${FLEET_STATE:?}"
rm -f -- "${WSTUBS:?}/auth.waiting" "${WSTUBS:?}/harness.dead"
ROW_ENV=("${WATCH_ENV[@]}" GH_REPO=owner/repo ORCH_OVERSEER_DEAD_PASSES=1
  OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/death-state-$MANAGER")
if [[ "$MANAGER" == unit ]]; then
  ROW_ENV+=(PATH="$WSTUBS/lingering:$WSTUBS:$BIN:$PATH"
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}")
fi
run_oversee -- launch --wait-secs 20
ROW_ENV=()
FIRST_PANE="$(recorded pane)"
watch_pid_live "$FLEET_STATE"
FIRST_PID="$WATCH_PID"
if [[ "$MANAGER" == unit ]]; then
  UNIT="$(sed -n 's/^unit=//p' "$WATCH_RUNNER_FILE")"
  GROUP="$(systemctl --user show -p ControlGroup --value -- "$UNIT.service")"
  assert_eq "${GROUP##*/}|$(systemctl --user show -p MainPID --value -- "$UNIT.service")" \
    "$UNIT.service|$FIRST_PID" "the initial watcher owns a service outside the launching agent scope"
fi
for _ in $(seq 1 100); do
  [[ ! -f "$WSTUBS/auth.waiting" ]] || break
  sleep 0.1
done
assert_eq "$(test -f "$WSTUBS/auth.waiting" && echo ready || echo missing)" ready \
  "the detached first watch reaches the auth acknowledgement"
kill "$(cat "$HARNESS_PIDS/${FIRST_PANE#%}")"
touch "$WSTUBS/harness.dead"
FIRST_DEAD=""
for _ in $(seq 1 300); do
  FIRST_DEAD="$(grep "^EVENT overseer-dead $FIRST_PANE " "$WATCH_LOG_FILE" 2>/dev/null || true)"
  [[ -z "$FIRST_DEAD" ]] || break
  sleep 0.1
done
SUCC=""
for _ in $(seq 1 300); do
  SUCC="$(recorded pane)"
  [[ "$SUCC" == "$FIRST_PANE" || "$SUCC" == none ]] || break
  sleep 0.1
done
wait_restart
assert_eq "$RC|${FIRST_DEAD:+dead}|$(grep -c "^--dead-pane $FIRST_PANE " "$WSTUBS/succeed.args" 2>/dev/null || true)|${NEW:+watched}|$WATCH_PANE" \
  "0|dead|1|watched|$SUCC" "the first detached watch recovers death through the real launcher and watches its successor" "$WATCH_ERR_FILE"
[[ -z "$NEW" ]] || watch_stop "$NEW" "$FLEET_STATE"
done
mv "$REAL_GH" "$WSTUBS/gh"

# A live repeat watch sees the harness's wall and invokes the real successor.
make_lane "$H" eclaude
claude_usage 80 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
for RECOVERY_CASE in walled; do
  RECOVERY_BIN="$SRC_DIR/oversee-succeed"
  printf '%s\n' "$RECOVERY_BIN" > "$WSTUBS/succeed.bin"
  cat > "$WSTUBS/gh" <<EOF
#!/bin/sh
if [ "\$1 \$2" = 'auth status' ] && [ -n "\${OVERSEE_WATCH_REPEAT_OWNER:-}" ]; then
  echo waiting > "$WSTUBS/auth.waiting"
  while [ ! -f "$WSTUBS/harness.dead" ]; do sleep 0.1; done
  echo Logged in
fi
EOF
  chmod +x "$WSTUBS/gh"
  tm kill-window -a -t "$KEEP_WINDOW"
  rm -f -- "${FLEET_STATE:?}" "${WSTUBS:?}/auth.waiting" "${WSTUBS:?}/harness.dead"
  fresh_output
  ROW_ENV=("${WATCH_ENV[@]}" GH_REPO=owner/repo ORCH_OVERSEER_DEAD_PASSES=1
    ORCH_LANE_DIRS="$H/.claude:$H/.eclaude"
    OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/recovery-state-$RECOVERY_CASE")
  run_oversee -- launch --wait-secs 20
  ROW_ENV=()
  PRED="$(recorded pane)"
  watch_pid_live "$FLEET_STATE"
  RECOVERY_OLD="$WATCH_PID"
  for _ in $(seq 1 100); do
    [[ ! -f "$WSTUBS/auth.waiting" ]] || break
    sleep 0.1
  done
  assert_eq "$(test -f "$WSTUBS/auth.waiting" && echo ready || echo missing)" ready \
    "$RECOVERY_CASE: the watch reaches the auth barrier before the wall"
  touch "$HARNESS_PIDS/wall-${PRED#%}"
  for _ in $(seq 1 100); do
    SCREEN="$(tm capture-pane -p -t "$PRED")"
    [[ "$SCREEN" != *"You've hit your limit"* ]] || break
    sleep 0.1
  done
  assert_eq "$(case "$SCREEN" in (*"You've hit your limit"*) echo walled ;; (*) echo missing ;; esac)" walled \
    "$RECOVERY_CASE: the harness acknowledges the wall before the pass proceeds"
  touch "$WSTUBS/harness.dead"
  SUCC="$PRED"
  for _ in $(seq 1 300); do
    SUCC="$(recorded pane)"
    [[ "$SUCC" == "$PRED" || "$SUCC" == none ]] || break
    sleep 0.1
  done
  wait_restart
  EXPECT_RECOVERY=watched
  LIVE_RC=0
  watch_pid_live "$FLEET_STATE" || LIVE_RC=$?
  RECOVERY_RESULT=absent
  if [[ "$LIVE_RC" == 0 && "$WATCH_PANE" == "$SUCC" && "$WATCH_PID" != "$RECOVERY_OLD" ]]; then
    RECOVERY_RESULT=watched
  fi
  assert_eq "$RC|$(test "$SUCC" != "$PRED" && echo replaced || echo same)|$(grep -c "^EVENT overseer-walled $PRED " "$WATCH_LOG_FILE" || true)|$RECOVERY_RESULT" \
    "0|replaced|1|$EXPECT_RECOVERY" "$RECOVERY_CASE: successful automatic wall recovery retains a watch for the running successor" "$WATCH_ERR_FILE"
  [[ "$LIVE_RC" != 0 ]] || watch_stop "$WATCH_PID" "$FLEET_STATE"
done
printf '%s\n' "$SRC_DIR/oversee-succeed" > "$WSTUBS/succeed.bin"

# Death replay has a complete command and no new flag array. The watch must
# keep that command rather than replace it with its print helper's command.
printf '#!/bin/sh\n[ "$1 $2" != "auth status" ] || { echo ready >> %s/auth.calls; echo Logged in; }\n' "$WSTUBS" > "$WSTUBS/gh"
chmod +x "$WSTUBS/gh"
for REPLAY_CASE in replay; do
  REPLAY_BIN="$SRC_DIR/oversee-succeed"
  new_predecessor
  watch_stop "$OLD" "$FLEET_STATE"
  watch_argv_read "$FLEET_STATE"
  (
    cd -- "$WATCH_CWD" || exit 1
    watch_pid_write "$FLEET_STATE" "$PRED" hand "${REPLAY_BIN%/*}/oversee-watch" "${WATCH_ARGV[@]}"
    watch_pid_release "$FLEET_STATE"
  )
  REPLAY_LINE="$(recorded launch_line)"
  printf '%s\n' "$REPLAY_LINE" > "$TMP_ROOT/replay.line"
  kill "$(cat "$HARNESS_PIDS/${PRED#%}")"
  rm -f -- "${WSTUBS:?}/auth.calls"
  ROW_ENV=("${WATCH_ENV[@]}" GH_REPO=owner/repo OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/replay-state-$REPLAY_CASE"
    TMUX="$(tm display-message -p -t "$PRED" '#{socket_path},#{pid},0')")
  printf 'EVENT fixture retained\n' > "$WATCH_LOG_FILE"
  printf 'fixture retained\n' > "$WATCH_ERR_FILE"
  run_oversee "$REPLAY_BIN" -- --dead-pane "$PRED" --line-file "$TMP_ROOT/replay.line" --wait-secs 20
  ROW_ENV=()
  printf '%s\n' "$OUT" > "$TMP_ROOT/replay.out"
  for _ in $(seq 1 100); do
    [[ ! -f "$WSTUBS/auth.calls" ]] || break
    sleep 0.1
  done
  LIVE_RC=0
  watch_pid_live "$FLEET_STATE" || LIVE_RC=$?
  assert_eq "$RC|$LIVE_RC|$(test -f "$WSTUBS/auth.calls" && echo ready || echo missing)" \
    "0|0|ready" "$REPLAY_CASE: death recovery with no watch starts a detached repeat watch" "$TMP_ROOT/replay.out"
  assert_file_contains "$WATCH_LOG_FILE" retained "$REPLAY_CASE: death recovery keeps unread stdout events"
  assert_file_contains "$WATCH_ERR_FILE" retained "$REPLAY_CASE: death recovery keeps the previous error log"
  assert_eq "$(recorded launch_line)" "$REPLAY_LINE" "the replay watch keeps the complete recorded command"
  watch_stop "$WATCH_PID" "$FLEET_STATE"
done

tm kill-window -a -t "$KEEP_WINDOW"
tm move-window -r -t fleet
rm -f -- "$FLEET_STATE"
run_oversee -- launch --wait-secs 20
PRED="$(recorded pane)"
! watch_pid_live "$FLEET_STATE" || watch_stop "$WATCH_PID" "$FLEET_STATE"
fresh_output
PRED_TMUX="$(tm display-message -p -t "$PRED" '#{socket_path},#{pid},#{session_id}')"
( cd "$TMP_ROOT/work" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$H" TMUX="${PRED_TMUX/,\$/,}" TMUX_PANE="$PRED" \
    OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state" "${WATCH_ENV[@]}" \
    "$SRC_DIR/oversee-watch" --repeat 1 --interval 0 --state "$FLEET_STATE" --repo owner/repo \
    </dev/null >"$TMP_ROOT/first-watch.log" 2>&1 & )
REAL_OLD=""
for _ in $(seq 1 100); do
  if watch_pid_live "$FLEET_STATE"; then REAL_OLD="$WATCH_PID"; break; fi
  sleep 0.1
done
ROW_ENV=("${WATCH_ENV[@]}")
succeed
ROW_ENV=()
wait_restart
kill "$(cat "$HARNESS_PIDS/${SUCC#%}")"
DEAD=""
for _ in $(seq 1 300); do
  DEAD="$(grep "^EVENT overseer-dead $SUCC " "$TMP_ROOT/work/tmp/oversee-watch.log" 2>/dev/null || true)"
  [[ -z "$DEAD" ]] || break
  sleep 0.1
done
printf '%s\n' "$OUT" >> "$TMP_ROOT/work/tmp/oversee-watch.err"
assert_eq "$RC|${REAL_OLD:+recorded}|${NEW:+restarted}|${DEAD:+dead}|$(grep -c "^--dead-pane $SUCC " "$WSTUBS/succeed.args" 2>/dev/null || true)" \
  "0|recorded|restarted|dead|1" \
  "a successor that dies right after the handover is reported overseer-dead by the watch handed to it, and relaunched" \
  "$TMP_ROOT/work/tmp/oversee-watch.err"
RECOVERED_FROM="$SUCC"
for _ in $(seq 1 300); do
  SUCC="$(recorded pane)"
  [[ "$SUCC" == "$RECOVERED_FROM" || "$SUCC" == none ]] || break
  sleep 0.1
done
wait_restart
assert_eq "${NEW:+watched}|$WATCH_PANE" "watched|$SUCC" \
  "automatic successor death leaves its replacement with a repeat watch" "$WATCH_ERR_FILE"
[[ -z "$NEW" ]] || watch_stop "$NEW" "$FLEET_STATE"
[[ -z "$REAL_OLD" ]] || kill -TERM "$REAL_OLD" 2>/dev/null || true

# --- the watch's GitHub credentials ------------------------------------------
# The real watch authenticates before it claims, in the environment its
# launcher hands it. This gh answers only the successor's token and has no
# keyring, so a launcher with no GH_TOKEN starts a watch no credential serves,
# while the successor pane's own environment carries one. With CRED_BIN/slow
# present its token check takes twelve seconds, past the stop bound alone.
# The caller runs claude and its successor codex, whose harness the restarted
# watch's command takes: the successor's credential is its own session's,
# whatever harness the caller ran.
CRED_BIN="$TMP_ROOT/cred-bin"
mkdir -p "$CRED_BIN/unit" "$BIN/processes"
# A native fixture named codex holds the successor's pane, since only that
# exact process name reads as codex. The stub keeps the words it was launched
# with, one per line, the last its opening prompt.
fixture_named_process "$BIN/processes/codex"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s"\necho "esc to interrupt"\nexec "%s" 100000\n' \
  "$TMP_ROOT/codex.args" "$BIN/processes/codex" > "$BIN/codex"
chmod +x "$BIN/codex"
make_codex_lane "$H/.codex"
jq -n '{rate_limit: {primary_window: {used_percent: 20, reset_at: 1785000000, limit_window_seconds: 18000}, secondary_window: null}}' \
  > "$FIXTURE_DIR/.codex.json"
CODEX_SUCCESSOR=(ORCH_OVERSEER_PREFERENCE=codex:gpt-5.6-sol:high ORCH_LANE_DIRS="$H/.claude:$H/.codex")
cat > "$CRED_BIN/gh" <<EOF
#!/bin/sh
[ "\${GH_TOKEN:-}" = fixture-successor-token ] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
if [ -f "$CRED_BIN/account-free" ]; then
  [ "\${CLAUDE_CONFIG_DIR:-}" = "$H/inherited-claude" ] &&
  [ "\${PI_CODING_AGENT_DIR:-}" = "$H/inherited-pi" ] &&
  [ "\${OPENAI_API_KEY:-}" = fixture-provider-token ] || exit 1
fi
case "\$1 \$2" in
  "api user") [ ! -f "$CRED_BIN/slow" ] || sleep 12; echo fixture ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$CRED_BIN/gh"
CRED_ENV=("${WATCH_ENV[@]}" PATH="$CRED_BIN:$WSTUBS:$NO_MANAGER:$BIN:$PATH" GH_REPO=owner/repo
  OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/cred-state")
SUCCESSOR_TOKEN=(GH_TOKEN=fixture-successor-token)
# The real user manager, with a loginctl that reports it lingering, where one
# answers: the watch then runs as a unit.
cp "$NO_MANAGER/loginctl" "$CRED_BIN/unit/loginctl"
UNIT_ENV=(PATH="$CRED_BIN/unit:$CRED_BIN:$WSTUBS:$BIN:$PATH"
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}")
# run_restart PANE [ENV=VAL...] [-- OVERSEE_BIN] — `oversee watch-restart` as
# PANE's own shell runs it: its $TMUX and $TMUX_PANE, the watch settings and
# the words given. Sets OUT and RC.
run_restart() {
  local pane="$1" bin="$OVERSEE" env_args=()
  shift
  while [[ $# -gt 0 && "$1" != -- ]]; do env_args+=("$1"); shift; done
  [[ $# -lt 2 ]] || bin="$2"
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$H" TMUX_TMPDIR="$TMUX_DIR" \
    TMUX="$(tm display-message -p -t "$pane" '#{socket_path},#{pid},0')" TMUX_PANE="$pane" \
    "${CRED_ENV[@]}" ${env_args[@]+"${env_args[@]}"} "$bin" watch-restart 2>&1 </dev/null)" || RC=$?
}
# claim_of — the live claim's pid, or none.
claim_of() { if watch_pid_live "$FLEET_STATE"; then printf '%s' "$WATCH_PID"; else printf none; fi; }
# retain WORD_INDEX VALUE — the retained watch command with one word replaced:
# 1 is its script, and a later index one of its arguments.
retain() {
  python3 - "$WATCH_ARGV_FILE" "$1" "$2" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
words = p.read_bytes().split(b'\0')
words[int(sys.argv[2])] = sys.argv[3].encode()
p.write_bytes(b'\0'.join(words))
PY
}
# flags_of PID — the words after the `--` of that watch's command line, as
# flag_units prints them.
flags_of() { local args; args="$(ps -ww -o args= -p "$1")" || return 1; tr ' ' '\n' <<<"${args#* -- }" | flag_units; }
# flag_units — words one per line on stdin as one option per line, a `-c` or
# `-m` joined to its value, sorted: a launch writes the same options in an
# order of its own, and none of them reads another's place.
flag_units() { awk '$0 == "-c" || $0 == "-m" { k = $0; next } k != "" { print k " " $0; k = ""; next } { print }' | LC_ALL=C sort; }
echo "=== the fleet watch's GitHub credentials ==="

# Slow, valid authentication: a first launch waits for the claim past the
# stop bound, while the started watch runs.
tm kill-window -a -t "$KEEP_WINDOW"
rm -f -- "$FLEET_STATE"
fresh_output
touch "$CRED_BIN/slow"
ROW_ENV=("${CRED_ENV[@]}" "${SUCCESSOR_TOKEN[@]}" KENDEX_GITHUB_AUTH_TIMEOUT=15)
run_oversee -- launch --wait-secs 20
ROW_ENV=()
rm -f -- "$CRED_BIN/slow"
PRED="$(recorded pane)"
LIVE_RC=0
watch_pid_live "$FLEET_STATE" || LIVE_RC=$?
assert_eq "$RC|$LIVE_RC|$WATCH_PANE" "0|0|$PRED" \
  "a first launch waits out slow valid GitHub authentication and leaves the watch claimed" "$WATCH_ERR_FILE"
watch_handoff_read
CRED_SINCE="$WATCH_SINCE"
CRED_SCRIPT="$WATCH_SCRIPT"
printf 'EVENT fixture unread\n' >> "$WATCH_LOG_FILE"
UNREAD_LINE="$(awk 'END { print NR }' "$WATCH_LOG_FILE")"

# A succession launched from an environment with no GitHub credential: the
# helper's restarted watch inherits that environment, refuses before it
# claims, and the helper reports the restart failed, never restarted.
ROW_ENV=("${CRED_ENV[@]}" "${CODEX_SUCCESSOR[@]}")
succeed
ROW_ENV=()
HELPER_LINE=""
for _ in $(seq 1 300); do
  HELPER_LINE="$(grep -E '^oversee-succeed: watch-restart(ed|-failed) ' "$WATCH_ERR_FILE" 2>/dev/null || true)"
  [[ -z "$HELPER_LINE" ]] || break
  sleep 0.1
done
LIVE_PANE=none
! watch_pid_live "$FLEET_STATE" || LIVE_PANE="$WATCH_PANE"
printf '%s\n' "$OUT" >> "$WATCH_ERR_FILE"
assert_eq "$RC|${HELPER_LINE%% log=*}|$(grep -c '^oversee-watch: auth-failed service=github$' "$WATCH_ERR_FILE" || true)|$(test "$LIVE_PANE" = "$SUCC" && echo claimed || echo unclaimed)" \
  "0|oversee-succeed: watch-restart-failed step=claim|1|unclaimed" \
  "a caller with no GitHub credential hands over a watch that refuses before it claims, reported failed" "$WATCH_ERR_FILE"

# The successor restarts the watch from its own pane and environment: the
# watch claims for that pane, under the successor's harness and the flags of
# the session it serves, with the retained command, its handoff, the log and
# the cursor. The fleet brief here names a handoff of its own.
watch_handoff_read
for (( i = 0; i < ${#WATCH_ARGV[@]}; i++ )); do
  [[ "${WATCH_ARGV[i]}" != --handoff ]] || retain "$((i + 4))" tmp/handoffs/fleet-brief.md
done
run_restart "$SUCC" "${SUCCESSOR_TOKEN[@]}"
CRED_NEW="$(claim_of)"
watch_handoff_read || true
SUCC_FLAGS="$(sed '$d' "$TMP_ROOT/codex.args" | flag_units)"
assert_eq "$RC|$(grep -cE "^oversee: watch-started pid=$CRED_NEW pane=$SUCC log=$WATCH_LOG_FILE err=$WATCH_ERR_FILE( stopped=[0-9]+)? $SETSID_LINE\$" <<<"$OUT")|$WATCH_ORIGIN|$WATCH_PANE|$(recorded harness)|$WATCH_HARNESS|$WATCH_SINCE|$WATCH_HANDOFF|$(sed -n "${UNREAD_LINE}p" "$WATCH_LOG_FILE")" \
  "0|1|succession|$SUCC|codex|codex|$CRED_SINCE|tmp/handoffs/fleet-brief.md|EVENT fixture unread" \
  "a codex successor's watch-restart starts the watch with its own credential after a claude caller had none, keeping the command, handoff, log and cursor" "$WATCH_ERR_FILE"
assert_eq "$(flags_of "$CRED_NEW" || echo unread)" "${SUCC_FLAGS:-none}" \
  "the restarted watch carries the flags the successor session was launched with"

# A pane the fleet state does not record as its overseer owns no watch.
run_restart "$KEEP_PANE" "${SUCCESSOR_TOKEN[@]}"
assert_eq "$RC|$(grep -c "^oversee: not-overseer session=$KEEP_PANE " <<<"$OUT")|$(claim_of)" "1|1|$CRED_NEW" \
  "watch-restart from a pane the record does not name refuses and leaves the watch"

# No credential anywhere: the restart refuses with the claim step as soon as
# the started watch exits, well inside the bound a start that never says it
# runs is given, with that watch's auth-failed in the log it names and the
# live watch kept, its runner record as it was and no job record of its own
# left. Its control waits without the started watch's pid and runs into that
# bound.
# restart_refused [OVERSEE_BIN] — the row; sets REFUSED_RESULT and
# REFUSED_SECS.
restart_refused() {
  local before after started=$SECONDS runner records
  before="$(grep -c '^oversee-watch: auth-failed service=github$' "$WATCH_ERR_FILE" || true)"
  runner="$(cat -- "$WATCH_RUNNER_FILE" 2>/dev/null)" || runner=absent
  records="$(find "$TMP_ROOT/work/tmp" -name 'oversee-watch.runner.*' | LC_ALL=C sort)"
  run_restart "$SUCC" ${1:+--} ${1:+"$1"}
  REFUSED_SECS=$((SECONDS - started))
  after="$(grep -c '^oversee-watch: auth-failed service=github$' "$WATCH_ERR_FILE" || true)"
  REFUSED_RESULT="$RC|$(grep -c "^oversee: watch-restart-failed step=claim log=$WATCH_ERR_FILE " <<<"$OUT")|$(( after - before ))|$(claim_of)"
  REFUSED_RESULT+="|$([[ "$(cat -- "$WATCH_RUNNER_FILE" 2>/dev/null || echo absent)" == "$runner" ]] && echo kept || echo changed)"
  REFUSED_RESULT+="|$([[ "$(find "$TMP_ROOT/work/tmp" -name 'oversee-watch.runner.*' | LC_ALL=C sort)" == "$records" ]] && echo none || echo left)"
}
restart_refused
assert_eq "$REFUSED_RESULT|$(( REFUSED_SECS < 2 * WATCH_STOP_SECS ))" "1|1|1|$CRED_NEW|kept|none|1" \
  "watch-restart with no GitHub credential refuses once the watch exits, names the failure and keeps the live watch and its runner record" "$WATCH_ERR_FILE"
UNPUBLISHED="$(mutant_scripts unpublished lib/watch-handover.sh)" || exit 1
mutate_file "$UNPUBLISHED/lib/watch-handover.sh" '    elif [[ -n "$WATCH_JOB_PID" ]]; then' '    elif false; then'
restart_refused "$UNPUBLISHED/oversee"
assert_eq "${REFUSED_RESULT%%|*}|$(( REFUSED_SECS < 2 * WATCH_STOP_SECS ))" "1|0" \
  "control: a claim wait blind to the started watch's exit runs out its bound"

# Under a user manager, a replacement that refuses leaves the live watch's
# runner record naming that watch's unit, so the documented stop-job stops
# it. Its control writes the started job's record over the runner record, as
# the start did before, and the stop then misses the surviving watch.
# unit_refused_row OVERSEE_BIN — a unit watch restarted, a credential-less
# restart through OVERSEE_BIN, then the stop; sets UNIT_RESULT.
unit_refused_row() {
  local live stop_rc=0
  run_restart "$SUCC" "${SUCCESSOR_TOKEN[@]}" "${UNIT_ENV[@]}"
  live="$(claim_of)"
  run_restart "$SUCC" "${UNIT_ENV[@]}" -- "$1"
  "$SRC_DIR/lib/job-unit.sh" stop-job "$WATCH_RUNNER_FILE" "$live" '*oversee-watch*' >/dev/null 2>&1 || stop_rc=$?
  for _ in $(seq 1 200); do watch_pid_runs "$live" || break; sleep 0.1; done
  UNIT_RESULT="$RC|$stop_rc|$(watch_pid_runs "$live" && echo running || echo stopped)"
  ! watch_pid_runs "$live" || watch_stop "$live" "$FLEET_STATE" || true
}
if systemd-run --user --quiet --collect true </dev/null >/dev/null 2>&1; then
  unit_refused_row "$OVERSEE"
  assert_eq "$UNIT_RESULT" "1|0|stopped" \
    "a refused replacement leaves the unit watch it kept stoppable through its runner record" "$WATCH_ERR_FILE"
  SHARED_RECORD="$(mutant_scripts shared-record lib/watch-handover.sh)" || exit 1
  mutate_file "$SHARED_RECORD/lib/watch-handover.sh" 'mktemp "$WATCH_RUNNER_FILE.XXXXXX"' 'printf %s "$WATCH_RUNNER_FILE"'
  unit_refused_row "$SHARED_RECORD/oversee"
  assert_eq "${UNIT_RESULT%|*}|${UNIT_RESULT##*|}" "1|2|running" \
    "control: a replacement writing its record over the runner record leaves the kept watch unstoppable"
else
  printf '  skip  no user manager answers; the unit stop rows did not run\n'
fi

# The start authenticates before it claims. Its control replays a copy of
# the watch that claims before it authenticates, the order before this
# change, and reports a false start.
CLAIM_FIRST="$(mutant_scripts claim-first oversee-watch)" || exit 1
mutate_file "$CLAIM_FIRST/oversee-watch" $'      ( github_ready ) || exit "$?"\n' ''
retain 1 "$CLAIM_FIRST/oversee-watch"
restart_refused
assert_eq "${REFUSED_RESULT%%|*}" 0 \
  "control: a watch that claims before it authenticates reports the credential-less restart started" "$WATCH_ERR_FILE"
! watch_pid_live "$FLEET_STATE" || watch_stop "$WATCH_PID" "$FLEET_STATE" || true

# ol_pick_lane and ol_command_line produce an account-free Pi successor.
# Its public recovery must keep the inherited provider environment, including
# the Claude variable an unconditional fallback prefix would clear.
fixture_named_process "$BIN/processes/pi"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s"\necho "esc to interrupt"\nexec "%s" 100000\n' \
  "$TMP_ROOT/pi.args" "$BIN/processes/pi" > "$BIN/pi"
chmod +x "$BIN/pi"
# A Pi caller uses its native successor producer; public oversee launch has
# no caller permission posture and intentionally skips Pi preferences.
PI_AGENT="$H/.pi/agent"
mkdir -p "$PI_AGENT/packages/@vanillagreen/pi-hooks/extensions"
jq -n '{compaction: {enabled: false}}' > "$PI_AGENT/settings.json"
printf 'payload.context_window = usage.contextWindow;\n' > "$PI_AGENT/packages/@vanillagreen/pi-hooks/extensions/stop.ts"
tm kill-window -a -t "$KEEP_WINDOW"
PI_CALLER="$(tm new-window -d -t fleet:1 -c "$TMP_ROOT/work" -P -F '#{pane_id}' \
  "'$BIN/pi' --model openai/gpt-5 --thinking high")"
PI_TMUX="$(tm display-message -p -t "$PI_CALLER" '#{socket_path},#{pid},0')"
fixture_succession_handoff "$FLEET_STATE" "$TMP_ROOT/work/tmp/handoffs/fleet-brief.md"
retain 1 "$CRED_SCRIPT"
RC=0
OUT="$(cd "$TMP_ROOT/work" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$H" \
  TMUX_TMPDIR="$TMUX_DIR" TMUX="$PI_TMUX" TMUX_PANE="$PI_CALLER" "${CRED_ENV[@]}" "${SUCCESSOR_TOKEN[@]}" \
  ORCH_OVERSEER_PREFERENCE= ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=0 \
  "$SRC_DIR/oversee-succeed" --harness pi --context 900000:1000000 --wait-secs 20 \
  --handoff tmp/handoffs/fleet-brief.md \
  -- --model openai/gpt-5 --thinking high 2>&1 </dev/null)" || RC=$?
if [[ "$RC" -ne 0 ]]; then
  printf '%s\n' "$OUT" >&2
  assert_eq "$RC" 0 "the account-free Pi successor setup succeeds"
  exit 1
fi
SUCC="$(recorded pane)"
assert_eq "$RC|$(jq -c '[.overseer.harness,.overseer.account,.overseer.home,.overseer.model,.overseer.effort]' "$FLEET_STATE")" \
  '0|["pi",null,null,"openai/gpt-5","high"]' \
  "the shipped Pi successor records its provider with no account override" "$WATCH_ERR_FILE"
wait_restart
watch_handoff_read
assert_eq "$WATCH_HANDOFF" tmp/handoffs/fleet-brief.md \
  "the Pi setup records the custom handoff before public recovery" "$WATCH_ERR_FILE"
! watch_pid_live "$FLEET_STATE" || watch_stop "$WATCH_PID" "$FLEET_STATE"
retain 1 "$CRED_SCRIPT"
PI_FLAGS="$(sed '$d' "$TMP_ROOT/pi.args" | flag_units)"
PI_INHERITED=(CLAUDE_CONFIG_DIR="$H/inherited-claude" PI_CODING_AGENT_DIR="$H/inherited-pi" OPENAI_API_KEY=fixture-provider-token)
touch "$CRED_BIN/account-free"
# The unchanged identity refusal is the must-fail control for this one row.
PI_ACCOUNT_CONTROL="$(mutant_scripts pi-account-control oversee)" || exit 1
mutate_file "$PI_ACCOUNT_CONTROL/oversee" '  [[ -n "$OL_CUR_HARNESS" ]] \' \
  '  [[ -n "$OL_CUR_HARNESS" && -n "$home" ]] \'
for PI_RECOVERY in unchanged current; do
  PI_BIN="$OVERSEE" PI_EXPECT=0
  [[ "$PI_RECOVERY" != unchanged ]] || { PI_BIN="$PI_ACCOUNT_CONTROL/oversee"; PI_EXPECT=1; }
  run_restart "$SUCC" "${SUCCESSOR_TOKEN[@]}" "${PI_INHERITED[@]}" -- "$PI_BIN"
  PI_NEW="$(claim_of)"
  PI_ASSERT_RC=0
  (
    FAIL=0
    assert_eq "$RC|${PI_NEW:+$([[ "$PI_NEW" != none ]] && echo claimed || echo absent)}" "0|claimed" \
      "account-free Pi public recovery authenticates under its inherited environment" "$WATCH_ERR_FILE"
    if [[ "$PI_NEW" != none ]]; then
      watch_handoff_read
      assert_eq "$WATCH_ORIGIN|$WATCH_PANE|$WATCH_HARNESS|$WATCH_SINCE|$WATCH_HANDOFF|$(sed -n "${UNREAD_LINE}p" "$WATCH_LOG_FILE")" \
        "succession|$SUCC|pi|$CRED_SINCE|tmp/handoffs/fleet-brief.md|EVENT fixture unread" \
        "account-free Pi recovery keeps its binding, retained command, handoff and unread log"
      assert_eq "$(flags_of "$PI_NEW" || echo unread)" "$PI_FLAGS" \
        "account-free Pi recovery keeps the successor's Pi flags"
    fi
    [[ "$FAIL" -eq 0 ]]
  ) > "$TMP_ROOT/pi-recovery-$PI_RECOVERY.out" 2>&1 || PI_ASSERT_RC=$?
  assert_eq "$PI_ASSERT_RC" "$PI_EXPECT" \
    "$PI_RECOVERY: account-free Pi public recovery regression" "$TMP_ROOT/pi-recovery-$PI_RECOVERY.out"
  ! watch_pid_live "$FLEET_STATE" || watch_stop "$WATCH_PID" "$FLEET_STATE"
done

# Run only the startup regression in the disposable control. Its own fixture
# root keeps the control's real EXIT cleanup separate from this suite's root.
STARTUP_CONTROL="$TMP_ROOT/startup-output-control.sh"
awk '
  /^echo "=== oversee launch --predecessor: the fleet watch ==="$/ { setup = 1 }
  /^# A hand-started child can exit after its started event but before its claim\.$/ { regression = 1 }
  !setup || regression { print }
  END { if (!setup || !regression) exit 1 }
' "${BASH_SOURCE[0]}" > "$STARTUP_CONTROL"
for STARTUP_HELPER in git-env.sh named-process.sh lanes-fixture.sh growth-state.sh assertions.sh; do
  mutate_file "$STARTUP_CONTROL" 'source "$(dirname "${BASH_SOURCE[0]}")/lib/'"$STARTUP_HELPER"'"' \
    "source $(printf '%q' "$TEST_DIR/lib/$STARTUP_HELPER")"
done
mutate_file "$STARTUP_CONTROL" $'\nTEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
  "$(printf '\nTEST_DIR=%q' "$TEST_DIR")"
mutate_file "$STARTUP_CONTROL" $'    cat "$capture/output" || printf \'child-output=unread\\n\'' \
  $'    : # cat "$capture/output" || printf \'child-output=unread\\n\''
STARTUP_CONTROL_RC=0
"$BASH" "$STARTUP_CONTROL" > "$TMP_ROOT/startup-output-control.out" 2>&1 || STARTUP_CONTROL_RC=$?
assert_eq "$STARTUP_CONTROL_RC" 1 \
  "control: removing captured output fails the startup regression" "$TMP_ROOT/startup-output-control.out"

# A hand-started child can exit after its started event but before its claim.
# Run this last: its real EXIT cleanup removes the evidence, leaving only
# what new_predecessor printed. The planted defect stays in this private copy.
FAILED_WATCH="$TMP_ROOT/startup-failure/oversee-watch"
mkdir -p "${FAILED_WATCH%/*}"
cp -p -- "$FIXTURE_WATCH" "$FAILED_WATCH"
mutate_file "$FAILED_WATCH" 'watch_pid_write "$state" "${TMUX_PANE:-none}" "${OVERSEE_WATCH_ORIGIN:-hand}" "${FIXTURE_RECORD_SCRIPT:-$0}" "${base[@]}"' \
  $'printf "fixture-startup stream=stdout pid=%s\\n" "$$"\nprintf "fixture-startup stream=stderr pid=%s\\n" "$$" >&2\nexit 37'
STARTUP_RC=0
STARTUP_OUT="$(
  (
    trap cleanup EXIT
    FIXTURE_WATCH="$FAILED_WATCH"
    STAND_IN_ENV=()
    new_predecessor
  ) 2>&1
)" || STARTUP_RC=$?
FAILED_CHILD="$(sed -n 's/^fixture: operation=new_predecessor step=claim child-pid=\([0-9]*\) .*/\1/p' <<<"$STARTUP_OUT")"
assert_eq "$STARTUP_RC|$([[ "$FAILED_CHILD" =~ ^[1-9][0-9]*$ ]] && echo child || echo unread)|$([[ ! -e "$TMP_ROOT" ]] && echo removed || echo retained)" \
  '1|child|removed' "a failed stand-in startup reports its operation and child before real cleanup"
assert_contains "$STARTUP_OUT" 'claim-result=1 claim-pid=unread claim-pane=unread startup-exit=37' \
  "the startup exit is available while the missing claim remains unread"
for STARTUP_STREAM in stdout stderr; do
  assert_contains "$STARTUP_OUT" "fixture-startup stream=$STARTUP_STREAM pid=$FAILED_CHILD" \
    "the failed child's $STARTUP_STREAM survives cleanup"
done
assert_contains "$STARTUP_OUT" "started $FAILED_CHILD pane=" \
  "the failed child's ordered startup event survives cleanup"

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
