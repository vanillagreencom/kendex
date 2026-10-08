#!/usr/bin/env bash
# Tests for what `oversee launch --predecessor` does to the fleet watch: the
# watch served the predecessor's pane, which the succession stops, so the
# launch hands it to the successor pane through lib/watch-handover.sh, the
# handover `oversee-succeed` runs. Run over a real tmux server at the default
# socket under a private TMUX_TMPDIR, from outside tmux as oversee_launch.sh
# runs the verb, whose suite owns everything else a launch does. The watch
# handed over is a stand-in that records itself through lib/watch-pid.sh, as
# the real one does, save in the last row, where the real watch runs and the
# successor dies under it. What the helper does once started is
# oversee_succeed_watch.sh's.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"
# mutant_scripts and mutate_file, for the controls below.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"

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
  TMUX_TMPDIR="$TMUX_DIR" tmux -L default kill-server 2>/dev/null || true
  for pid in $(sed -n 's/^started \([0-9]*\) .*/\1/p' "$TMP_ROOT/watch.log" 2>/dev/null); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  # The real watch of the last row, where a failed row left it running.
  ! watch_pid_live "$TMP_ROOT/work/tmp/workflow-state-oversee.json" || kill -TERM "$WATCH_PID" 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { TMUX_TMPDIR="$TMUX_DIR" tmux -L default "$@"; }

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

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
  OUT="$(cd "$TMP_ROOT/work" && ${ROW_LAUNCH:+"$ROW_LAUNCH"} env -i HOME="$H" PATH="$NO_MANAGER:$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" \
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
# it replaces, as the real start does for a watch whose pane is gone (that
# rule is oversee_watch_lifecycle.sh's).
FIXTURE_WATCH="$TMP_ROOT/fixture/oversee-watch"
cat > "$FIXTURE_WATCH" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$SRC_DIR/lib/watch-pid.sh"
trap 'watch_pid_release "\$state"; echo "stopped \$\$" >> "$TMP_ROOT/watch.log"; exit 143' TERM
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
  ! watch_pid_live "\$state" || watch_stop "\$WATCH_PID" "\$state"
fi
printf 'started %s pane=%s origin=%s lane=%s tmux=%s cwd=%s argv=%s\n' "\$\$" "\${TMUX_PANE:-none}" \\
  "\${OVERSEE_WATCH_ORIGIN:-hand}" "\${CLAUDE_CONFIG_DIR:-none}" "\${TMUX:-none}" "\$PWD" "\$*" >> "$TMP_ROOT/watch.log"
watch_pid_write "\$state" "\${TMUX_PANE:-none}" "\${OVERSEE_WATCH_ORIGIN:-hand}" "\$0" "\${base[@]}"
while :; do sleep 1; done
EOF
chmod +x "$FIXTURE_WATCH"
WATCH_ARGS="--repeat 60 --state $FLEET_STATE --since 2026-01-01T00:00:00Z --repo owner/repo"

# new_predecessor — a first launch, whose overseer is the predecessor below,
# and the stand-in started by hand from its pane, as an overseer starts its
# watch, two forks deep so a stopped one is reaped rather than left a zombie
# that still answers kill -0. Sets PRED and OLD.
new_predecessor() {
  tm kill-window -a -t "$KEEP_WINDOW"
  tm move-window -r -t fleet
  rm -f -- "$FLEET_STATE"
  run_oversee -- launch --wait-secs 20
  PRED="$(recorded pane)"
  ! watch_pid_live "$FLEET_STATE" || watch_stop "$WATCH_PID" "$FLEET_STATE"
  [[ "$RC" -eq 0 && "$PRED" == %* ]] || { printf 'fixture: the first launch failed\n%s\n' "$OUT" >&2; exit 1; }
  # shellcheck disable=SC2086
  ( ( cd "$TMP_ROOT/work" || exit 1
      exec env TMUX_PANE="$PRED" CLAUDE_CONFIG_DIR="$H/.claude-old" \
        "$FIXTURE_WATCH" $WATCH_ARGS -- --model old --verbose </dev/null >/dev/null 2>&1 ) &
    echo $! > "$TMP_ROOT/stand-in.pid" )
  OLD="$(cat "$TMP_ROOT/stand-in.pid")"
  for _ in $(seq 1 50); do
    if watch_pid_live "$FLEET_STATE" && [[ "$WATCH_PID" == "$OLD" ]]; then return 0; fi
    sleep 0.1
  done
  echo "fixture: the stand-in watch never recorded itself" >&2
  exit 1
}
started_line() { grep "^started $1 " "$TMP_ROOT/watch.log" | sed "s/^started $1 //"; }
watch_handoff_read() {
  local word prev=""
  watch_pid_live "$FLEET_STATE" || { printf '%s\n' "$OUT" >&2; cat -- "$WATCH_ERR" >&2; return 1; }
  watch_argv_read "$FLEET_STATE"
  WATCH_HANDOFF="" WATCH_SINCE=""
  for word in "${WATCH_ARGV[@]}"; do
    [[ "$prev" != --handoff ]] || WATCH_HANDOFF="$word"
    [[ "$prev" != --since ]] || WATCH_SINCE="$word"
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
  "found|pane=$SUCC origin=succession lane=$H/.claude cwd=$TMP_ROOT/work argv=$WATCH_ARGS --harness claude -- --model fable --effort high $BYPASS $COMPACT $QUESTION_OFF" \
  "and started again from the successor pane, with the successor's harness, flags and account"
assert_eq "$(started_line "${NEW:-none}" | sed -n 's/.* tmux=\([^,]*\),\([0-9]*\),[0-9]* .*/\1 \2/p')" "$SOCKET $SERVER_PID" \
  "a launch from outside tmux hands the restarted watch the successor's tmux server"
assert_eq "$(grep -c "^oversee-succeed: watch-restarted pid=$NEW pane=$SUCC $SETSID_LINE\$" "$WATCH_ERR")" "1" \
  "the restart is written beside the fleet state with the new loop's pid and the successor pane"
watch_stop "$NEW" "$FLEET_STATE" || true

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

# The floor comes from the first lane. Repository selection stays with the
# watch's existing default and ORCH_CONNECTED_REPOS resolution.
SINCE_CONTROL="$(mutant_scripts since-control lib/watch-handover.sh)" || exit 1
SINCE_FLOOR="$(mutant_scripts since-floor)" || exit 1
mutate_file "$SINCE_CONTROL/lib/watch-handover.sh" '--since "$since" ' ''
for SINCE_CASE in floor control; do
  SINCE_BIN="$SINCE_FLOOR"
  [[ "$SINCE_CASE" != control ]] || SINCE_BIN="$SINCE_CONTROL"
  rm -- "${SINCE_BIN:?}/oversee-watch"
  cp -p -- "$FIXTURE_WATCH" "$SINCE_BIN/oversee-watch"
  tm kill-window -a -t "$KEEP_WINDOW"
  printf '%s\n' '{"lanes":[{"item":"KEN-1","status":"done","launched_at":"2026-01-01T00:00:00Z"}]}' > "$FLEET_STATE"
  run_oversee "$SINCE_BIN/oversee" -- launch --wait-secs 20
  watch_handoff_read
  EXPECT_SINCE=2026-01-01T00:00:00Z
  [[ "$SINCE_CASE" != control ]] || EXPECT_SINCE=""
  assert_eq "$RC|$WATCH_SINCE" "0|$EXPECT_SINCE" "$SINCE_CASE: the first watch carries the fixed fleet start"
  watch_stop "$WATCH_PID" "$FLEET_STATE"
done

# The runner accepts this first-watch job, but the command exits without a
# claim. The control changes only the claim-deadline refusal to success.
NORECORD="$(mutant_scripts norecord lib/watch-handover.sh)" || exit 1
CLAIM_CONTROL="$(mutant_scripts claim-control lib/watch-handover.sh)" || exit 1
mutate_file "$CLAIM_CONTROL/lib/watch-handover.sh" \
  '      WATCH_HANDOVER_FIELDS=(step=claim "log=$WATCH_ERR_FILE" "$runner")
      return 1' \
  '      WATCH_HANDOVER_FIELDS=(step=claim "log=$WATCH_ERR_FILE" "$runner")
      return 0'
for CLAIM_CASE in refusal control; do
  CLAIM_BIN="$NORECORD"
  [[ "$CLAIM_CASE" != control ]] || CLAIM_BIN="$CLAIM_CONTROL"
  rm -- "${CLAIM_BIN:?}/oversee-watch"
  printf '#!/bin/sh\nexit 0\n' > "$CLAIM_BIN/oversee-watch"
  chmod +x "$CLAIM_BIN/oversee-watch"
  tm kill-window -a -t "$KEEP_WINDOW"
  rm -f -- "${FLEET_STATE:?}"
  run_oversee "$CLAIM_BIN/oversee" -- launch --wait-secs 20
  LIVE_RC=0
  watch_pid_live "$FLEET_STATE" || LIVE_RC=$?
  EXPECT_CLAIM='1|1|0|none|1'
  [[ "$CLAIM_CASE" != control ]] || EXPECT_CLAIM='0|1|1|present|2'
  RECORD_PRESENT=none
  [[ "$(recorded pane)" == none ]] || RECORD_PRESENT=present
  assert_eq "$RC|$LIVE_RC|$(grep -c '^oversee: overseer-launched ' <<<"$OUT")|$RECORD_PRESENT|$(tm list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')" \
    "$EXPECT_CLAIM" "$CLAIM_CASE: an accepted job with no claim refuses and restores the pane and record"
  assert_eq "$(sed -n 's/^runner=//p' "$WATCH_RUNNER_FILE")" setsid \
    "$CLAIM_CASE: the watcher job was accepted before the claim deadline"
done

# The runner cannot write its record. A first launch must close the new pane.
tm kill-window -a -t "$KEEP_WINDOW"
rm -f -- "${FLEET_STATE:?}"
mkdir "$TMP_ROOT/work/tmp/oversee-watch.runner.part"
run_oversee -- launch --wait-secs 20
rmdir "$TMP_ROOT/work/tmp/oversee-watch.runner.part"
LIVE_RC=0
watch_pid_live "$FLEET_STATE" || LIVE_RC=$?
assert_eq "$RC|$LIVE_RC|$(grep -c '^oversee: overseer-launched ' <<<"$OUT")|$(grep -c '^job-unit: record-unwritable ' <<<"$OUT")" \
  "1|1|0|1" "a refused first-watch job cannot report the overseer launch done"

UNSTARTED="$(mutant_scripts unstarted oversee)" || exit 1
mutate_file "$UNSTARTED/oversee" '      hand_over_watch ;;' '      ;;'
tm kill-window -a -t "$KEEP_WINDOW"
rm -f -- "${FLEET_STATE:?}"
run_oversee "$UNSTARTED/oversee" -- launch --wait-secs 20
LIVE_RC=0
watch_pid_live "$FLEET_STATE" || LIVE_RC=$?
assert_eq "$RC|$LIVE_RC" "0|1" "control: a launch without the start leaves no watch claim"

HANDOFF_CONTROL="$(mutant_scripts handoff-control lib/watch-handover.sh)" || exit 1
mutate_file "$HANDOFF_CONTROL/lib/watch-handover.sh" '--handoff "$HANDOFF" ' ''
rm -- "$HANDOFF_CONTROL/oversee-watch"
cp -p -- "$FIXTURE_WATCH" "$HANDOFF_CONTROL/oversee-watch"
tm kill-window -a -t "$KEEP_WINDOW"
rm -f -- "${FLEET_STATE:?}"
run_oversee "$HANDOFF_CONTROL/oversee" -- launch --handoff "$FIRST_HANDOFF" --wait-secs 20
[[ "$RC" -eq 0 ]] || printf '%s\ncustom-handoff-control-exit=%s\n' "$OUT" "$RC" >&2
watch_handoff_read
assert_eq "$RC|$WATCH_HANDOFF" '0|' "control: omitting the handoff word loses the first watch's custom path"
watch_stop "$WATCH_PID" "$FLEET_STATE"

# The control: the succession without the handover leaves the watch reading
# the predecessor's pane, which the stop closed.
UNHANDED="$(mutant_scripts unhanded oversee)" || exit 1
mutate_file "$UNHANDED/oversee" '      hand_over_watch ;;' '      ;;'
new_predecessor
fresh_output
succeed "$UNHANDED/oversee"
sleep 2
assert_eq "$RC|$(kill -0 "$OLD" 2>/dev/null && echo alive || echo gone)|$(started_line "$OLD" | sed 's/ .*//')|$(tm list-panes -a -F '#{pane_id}' | grep -cxF -- "$PRED" || true)|$(grep -c '^oversee: watch-' <<<"$OUT")" \
  "0|alive|pane=$PRED|0|0" \
  "control: without the handover the watch keeps serving the gone predecessor pane"
watch_stop "$OLD" "$FLEET_STATE" || true

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
  --print-launch-line) echo "claude -n overseer brief" ;;
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

# The auth acknowledgement orders the first long pass after the harness exit.
REAL_GH="$WSTUBS/gh.real"
cp "$WSTUBS/gh" "$REAL_GH"
cat > "$WSTUBS/gh" <<EOF
#!/bin/sh
if [ "\$1 \$2" = 'auth status' ]; then
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
# The control keeps the successful launch and removes only its watch restart.
RECOVERY_CONTROL="$(mutant_scripts recovery-control oversee-succeed)" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/recovery-control"
make_lane "$H" eclaude
claude_usage 80 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
mutate_file "$RECOVERY_CONTROL/oversee-succeed" \
  '  local cwd="$7" script="$8" argc="$9"' \
  '  return 0
  local cwd="$7" script="$8" argc="$9"'
for RECOVERY_CASE in walled control; do
  RECOVERY_BIN="$SRC_DIR/oversee-succeed"
  [[ "$RECOVERY_CASE" != control ]] || RECOVERY_BIN="$RECOVERY_CONTROL/oversee-succeed"
  printf '%s\n' "$RECOVERY_BIN" > "$WSTUBS/succeed.bin"
  cat > "$WSTUBS/gh" <<EOF
#!/bin/sh
if [ "\$1 \$2" = 'auth status' ]; then
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
  if [[ "$RECOVERY_CASE" == walled ]]; then
    wait_restart
    EXPECT_RECOVERY=watched
  else
    for _ in $(seq 1 300); do
      LIVE_RC=0
      watch_pid_live "$FLEET_STATE" || LIVE_RC=$?
      [[ "$LIVE_RC" != 1 ]] || break
      sleep 0.1
    done
    NEW=""
    EXPECT_RECOVERY=absent
  fi
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
REPLAY_CONTROL="$(mutant_scripts replay-control lib/watch-overseer-record.sh)" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/replay-control"
mutate_file "$REPLAY_CONTROL/lib/watch-overseer-record.sh" \
  '  if [[ "${OVERSEE_WATCH_ORIGIN:-hand}" == succession && ${#OVERSEER_FLAGS[@]} -eq 0 && "$held" != none && "$held" != unread ]]; then' \
  '  if false; then'
printf '#!/bin/sh\n[ "$1 $2" != "auth status" ] || { echo ready >> %s/auth.calls; echo Logged in; }\n' "$WSTUBS" > "$WSTUBS/gh"
chmod +x "$WSTUBS/gh"
for REPLAY_CASE in replay control; do
  new_predecessor
  watch_stop "$OLD" "$FLEET_STATE"
  REPLAY_LINE="$(recorded launch_line)"
  printf '%s\n' "$REPLAY_LINE" > "$TMP_ROOT/replay.line"
  kill "$(cat "$HARNESS_PIDS/${PRED#%}")"
  rm -f -- "${WSTUBS:?}/auth.calls"
  ROW_ENV=("${WATCH_ENV[@]}" GH_REPO=owner/repo OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/replay-state-$REPLAY_CASE"
    TMUX="$(tm display-message -p -t "$PRED" '#{socket_path},#{pid},0')")
  REPLAY_BIN="$SRC_DIR/oversee-succeed"
  [[ "$REPLAY_CASE" != control ]] || REPLAY_BIN="$REPLAY_CONTROL/oversee-succeed"
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
  if [[ "$REPLAY_CASE" == replay ]]; then
    assert_eq "$(recorded launch_line)" "$REPLAY_LINE" "the replay watch keeps the complete recorded command"
  else
    assert_eq "$(recorded launch_line)" 'claude -n overseer brief' \
      "control: printing without replay flag words overwrites the complete command"
  fi
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
( cd "$TMP_ROOT/work" && env -i HOME="$H" TMUX="${PRED_TMUX/,\$/,}" TMUX_PANE="$PRED" \
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

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
