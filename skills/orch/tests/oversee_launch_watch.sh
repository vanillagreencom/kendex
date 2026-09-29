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
sleep 100000 &
echo \$! > "$HARNESS_PIDS/\${TMUX_PANE#%}"
wait
STUB
cat > "$BIN/kendex" <<'STUB'
#!/bin/sh
case "$1:$2:$3" in
  tier-model:claude:1) echo fable ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN/claude" "$BIN/kendex"

new_home fleet
make_lane "$H" claude
FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"

env PATH="$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" tmux -L default -f /dev/null new-session -d -s fleet -x 200 -y 40 'exec sleep 100000'
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
    ORCH_OVERSEER_PREFERENCE=claude:1:high ORCH_TMUX_SESSION=fleet \
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
source "$SRC_DIR/lib/watch-pid.sh"
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
  ! watch_pid_live "\$state" || watch_stop "\$WATCH_PID" "\$state"
fi
printf 'started %s pane=%s origin=%s lane=%s tmux=%s cwd=%s argv=%s\n' "\$\$" "\${TMUX_PANE:-none}" \\
  "\${OVERSEE_WATCH_ORIGIN:-hand}" "\${CLAUDE_CONFIG_DIR:-none}" "\${TMUX:-none}" "\$PWD" "\$*" >> "$TMP_ROOT/watch.log"
watch_pid_write "\$state" "\${TMUX_PANE:-none}" "\${OVERSEE_WATCH_ORIGIN:-hand}" "\$0" "\${base[@]}"
while :; do sleep 1; done
EOF
chmod +x "$FIXTURE_WATCH"
WATCH_ARGS="--repeat 60 --state $FLEET_STATE"

# new_predecessor — a first launch, whose overseer is the predecessor below,
# and the stand-in started by hand from its pane, as an overseer starts its
# watch, two forks deep so a stopped one is reaped rather than left a zombie
# that still answers kill -0. Sets PRED and OLD.
new_predecessor() {
  tm kill-window -a -t fleet:0
  rm -f -- "$FLEET_STATE"
  run_oversee -- launch --wait-secs 20
  PRED="$(recorded pane)"
  [[ "$RC" -eq 0 && "$PRED" == %* ]] || { printf 'fixture: the first launch failed\n%s\n' "$OUT" >&2; exit 1; }
  # shellcheck disable=SC2086
  ( cd "$TMP_ROOT/work" && TMUX_PANE="$PRED" CLAUDE_CONFIG_DIR="$H/.claude-old" \
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
assert_eq "$(grep -c "^stopped $OLD\$" "$TMP_ROOT/watch.log")|$(kill -0 "$OLD" 2>/dev/null && echo alive || echo gone)" \
  "1|gone" \
  "the watch serving the predecessor's pane is stopped, once"
assert_eq "${NEW:+found}|$(started_line "${NEW:-none}" | sed 's/ tmux=[^ ]* / /')" \
  "found|pane=$SUCC origin=succession lane=$H/.claude cwd=$TMP_ROOT/work argv=$WATCH_ARGS --harness claude -- --model fable --effort high $BYPASS $COMPACT $QUESTION_OFF" \
  "and started again from the successor pane, with the successor's harness, flags and account"
assert_eq "$(started_line "${NEW:-none}" | sed -n 's/.* tmux=\([^,]*\),\([0-9]*\),[0-9]* .*/\1 \2/p')" "$SOCKET $SERVER_PID" \
  "a launch from outside tmux hands the restarted watch the successor's tmux server"
assert_eq "$(grep -c "^oversee-succeed: watch-restarted pid=$NEW pane=$SUCC $SETSID_LINE\$" "$WATCH_ERR")" "1" \
  "the restart is written beside the fleet state with the new loop's pid and the successor pane"
watch_stop "$NEW" "$FLEET_STATE" || true

# No watch runs on the fleet state: nothing is started, and the run says so.
tm kill-window -a -t fleet:0
rm -f -- "$FLEET_STATE"
run_oversee -- launch --wait-secs 20
PRED="$(recorded pane)"
fresh_output
STARTED="$(grep -c '^started ' "$TMP_ROOT/watch.log")"
succeed
assert_eq "$RC|$(grep -c "^oversee: watch-absent path=$TMP_ROOT/work/tmp/workflow-state-oversee.json\$" <<<"$OUT")|$(grep -c '^started ' "$TMP_ROOT/watch.log")" \
  "0|1|$STARTED" \
  "a fleet with no running watch reports watch-absent and starts none"

# The control: the succession without the handover leaves the watch reading
# the predecessor's pane, which the stop closed.
UNHANDED="$(mutant_scripts unhanded oversee)" || exit 1
mutate_file "$UNHANDED/oversee" '      [[ -z "$PREDECESSOR" ]] || hand_over_watch ;;' '      ;;'
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
  "0|oversee: watch-restart-failed step=tmux session=$SUCC
fixture: display refused|0|alive" \
  "a successor server tmux will not name is a notice, the succession standing and no helper started"
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
if [ "\$1" = swap-window ]; then
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
  assert_eq "$RC|$(tm list-panes -a -F '#{pane_id}' | grep -cxF -- "$PRED" || true)|${NEW:+restarted}|$(kill -0 "$OLD" 2>/dev/null && echo alive || echo gone)" \
    "137|0|restarted|gone" \
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
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/succeed.args\ncase "$1" in --print-launch-line) echo "claude -n overseer brief" ;; --check-marks) echo "oversee-succeed: account-below-mark headroom=80" ;; esac\n' \
  "$WSTUBS" > "$WSTUBS/succeed"
printf '#!/bin/sh\n[ "$1 $2" != "auth status" ] || echo "Logged in"\n' > "$WSTUBS/gh"
printf '#!/bin/sh\n' > "$WSTUBS/silent"
printf '#!/bin/sh\necho "[]"\n' > "$WSTUBS/lanes"
chmod +x "$WSTUBS"/*
WATCH_ENV=(PATH="$WSTUBS:$NO_MANAGER:$BIN:$PATH" ORCH_REPORT=off ORCH_WATCH_MAIL_INTERVAL=0
  OVERSEE_WATCH_SUCCEED="$WSTUBS/succeed" OVERSEE_WATCH_PR_WATCH="$WSTUBS/silent"
  OVERSEE_WATCH_TRACKER="$WSTUBS/silent" OVERSEE_WATCH_LANES="$WSTUBS/lanes")
tm kill-window -a -t fleet:0
rm -f -- "$FLEET_STATE"
run_oversee -- launch --wait-secs 20
PRED="$(recorded pane)"
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
[[ -z "$NEW" ]] || watch_stop "$NEW" "$FLEET_STATE" || true
[[ -z "$REAL_OLD" ]] || kill -TERM "$REAL_OLD" 2>/dev/null || true

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
