#!/usr/bin/env bash
# Tests for what a self-succession does to the fleet watch: the watch served
# the caller's pane, which the succession closes, so `oversee-succeed` stops it
# and starts it again from the successor pane. Run over a real tmux server on a
# private socket with the harness and tier stubs of oversee_succeed.sh, whose
# suite owns everything else the succession does. The watch is a stand-in that
# records itself through lib/watch-pid.sh, as the real one does, and notes
# what it was started with; what the real watch does with that record is
# oversee_watch_lifecycle.sh's.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"
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

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN" "$TMP_ROOT/work/tmp" "$TMP_ROOT/fixture"
# The successor's harness: it shows a running turn and holds its pane.
cat > "$BIN/claude" <<'STUB'
#!/bin/sh
echo 'esc to interrupt'
exec sleep 100000
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

env PATH="$BIN:$PATH" tmux -L "$SOCK" -f /dev/null new-session -d -s fleet -x 220 -y 50 'exec sleep 100000'
tm set-option -g default-shell /bin/sh
tm set-option -g default-command "PATH=$BIN:\$PATH; export PATH; exec /bin/sh"
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"

# A caller past the context mark, so every run below succeeds itself: the
# reading its turn-end hook would have taken, 95 percent of a 1M window, handed
# in as --context, and recorded for its pane, which names its model.
# shellcheck source=../scripts/lib/lane-context.sh
source "$SRC_DIR/lib/lane-context.sh"
MARK='  kendex (ken-1453) Fable 5.1 (1M context) 95% (fixture@example.com)     /rc'
SERVER_PID="$(tm display-message -p '#{pid}')"
new_caller() {
  local f="$TMP_ROOT/caller.screen" spec
  printf '%s\n' "$MARK" > "$f"
  tm kill-window -a -t fleet:0
  spec="$(tm new-window -d -t fleet:1 -P -F '#{pane_id} #{window_id}' "cat '$f'; exec sleep 100000")"
  read -r CALLER_PANE CALLER_WINDOW <<<"$spec"
  mkdir -p "$TMP_ROOT/work/tmp/lane-mail/overseer"
  lane_context_record "$TMP_ROOT/work/tmp/lane-mail/overseer" claude 950000 1000000 claude-fable-5-1 s1 \
    "$SERVER_PID $CALLER_PANE"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ "$(tm capture-pane -p -t "$CALLER_PANE")" != *'(fixture@example.com)'* ]] || return 0
    sleep 0.2
  done
  echo "fixture: caller pane never drew its screen" >&2
  exit 1
}

# The fleet state the succession records its line in, and beside which the
# watch keeps its record.
FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
printf '{"issue_id": "oversee"}\n' > "$FLEET_STATE"

# The fleet state the succession records its line in, and beside which the
# watch keeps its record and a restarted watch its output.
FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
printf '{"issue_id": "oversee"}\n' > "$FLEET_STATE"
WATCH_ERR="$TMP_ROOT/work/tmp/oversee-watch.err"
fresh_output() { rm -f -- "${TMP_ROOT:?}/work/tmp/oversee-watch.log" "${TMP_ROOT:?}/work/tmp/oversee-watch.err"; }

# The orch job runner starts the helper and the restarted watch. Every row but
# the unit row runs them where no user manager answers: behind a systemd-run
# whose probe fails, so under setsid. The unit row passes the variables a
# user manager is reached by instead. Both run behind a loginctl that says the
# manager lingers, the one manager the runner starts a unit under, which this
# host's may not.
NO_MANAGER="$TMP_ROOT/no-manager"
LINGERING="$TMP_ROOT/lingering"
mkdir -p "$NO_MANAGER" "$LINGERING"
printf '#!/bin/sh\necho "Failed to connect to bus: No medium found" >&2\nexit 1\n' > "$NO_MANAGER/systemd-run"
printf '#!/bin/sh\necho yes\n' > "$LINGERING/loginctl"
cp "$LINGERING/loginctl" "$NO_MANAGER/loginctl"
chmod +x "$NO_MANAGER/systemd-run" "$NO_MANAGER/loginctl" "$LINGERING/loginctl"
SETSID_LINE='runner=setsid reason=probe-failed detail=Failed to connect to bus: No medium found'

# run_succeed [SUCCEED_BIN] — the script from outside the caller's pane, under
# a whole environment, with the flags an overseer on the claude:1 entry passes.
# ROW_PATH, when set, goes ahead of the stubs on PATH, and ROW_LAUNCH, when
# set, is the word the run is started under. ROW_MANAGER=unit reaches this
# host's user manager; any other value runs behind the failing systemd-run.
ROW_PATH="" ROW_LAUNCH="" ROW_MANAGER=""
run_succeed() {
  local manager=(PATH="${ROW_PATH:+$ROW_PATH:}$NO_MANAGER:$BIN:$PATH")
  [[ "$ROW_MANAGER" != unit ]] || manager=(PATH="${ROW_PATH:+$ROW_PATH:}$LINGERING:$BIN:$PATH"
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}")
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && ${ROW_LAUNCH:+"$ROW_LAUNCH"} env -i HOME="$H" "${manager[@]}" \
    TMUX="$TMUX_ADDR" TMUX_PANE="$CALLER_PANE" \
    LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state" \
    CLAUDE_CONFIG_DIR="$H/.claude" ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="$H/.claude" \
    ORCH_OVERSEER_PREFERENCE=claude:1:high ORCH_OVERSEER_WALL_MINUTES=0 ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=0 \
    "${1:-$SUCCEED}" --context 950000:1000000 -- --permission-mode dontAsk --verbose 2>&1)" || RC=$?
  # The window the caller held, which the successor holds once the close ran.
  SUCC_PANE="$(tm list-panes -t fleet:1 -F '#{pane_id}' 2>/dev/null || true)"
}

# The stand-in watch: it records itself as the real loop does, with its words
# before `--`, and appends one `started` line, with its pane, origin, account,
# directory and arguments, to watch.log, and one `stopped` line when it is
# stopped. Started by a succession, it first stops the live watch it replaces,
# as the real start does for a watch whose pane is gone (that rule is
# oversee_watch_lifecycle.sh's); where norecord exists, such a start ends
# before it records anything, a restart that never comes up.
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

echo "=== oversee-succeed: the fleet watch ==="

new_caller
fresh_output
start_watch
run_succeed
wait_restart
assert_eq "$RC|$(grep -c "^oversee-succeed: watch-handover pid=$OLD pane=$SUCC_PANE log=.*/tmp/oversee-watch.err $SETSID_LINE\$" <<<"$OUT")" \
  "0|1" \
  "the succession names the watch it hands over before the close"
assert_eq "$(grep -c "^stopped $OLD\$" "$TMP_ROOT/watch.log")|$(kill -0 "$OLD" 2>/dev/null && echo alive || echo gone)" \
  "1|gone" \
  "the watch serving the caller's pane is stopped, once"
assert_eq "${NEW:+found}|$(started_line "${NEW:-none}")" \
  "found|pane=$SUCC_PANE origin=succession lane=$H/.claude cwd=$TMP_ROOT/work argv=$WATCH_ARGS -- --model fable --effort high --settings={\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}} --permission-mode dontAsk --verbose" \
  "and started again from the successor pane, with the successor's flags and account"
assert_eq "$(grep -c "^oversee-succeed: watch-restarted pid=$NEW pane=$SUCC_PANE $SETSID_LINE\$" "$WATCH_ERR")|$(grep -c '^started ' "$TMP_ROOT/watch.log")" \
  "1|2" \
  "the restart is written beside the fleet state with the new loop's pid and the successor pane"
watch_stop "$NEW" "$FLEET_STATE" || true

# The same handover where a user manager answers: the helper and the watch it
# restarts are units of their own, named for the handover and the restart and
# the second each was made in, and the watch is its unit's main process, in
# the recorded directory and serving the successor pane.
if systemd-run --user --quiet --collect true </dev/null >/dev/null 2>&1; then
  new_caller
  fresh_output
  start_watch
  STARTED="$(grep -c '^started ' "$TMP_ROOT/watch.log")"
  ROW_MANAGER=unit run_succeed
  wait_restart
  unit_of() { # KEY — the unit a KEY line names, its stamp and pid folded
    sed -n "s/^oversee-succeed: $1 .* runner=systemd unit=\\(orch-[a-z-]*\\)-[0-9]\\{8\\}T[0-9]\\{6\\}Z-[0-9]*\$/\\1/p" "${2:-/dev/stdin}"
  }
  RESTART_UNIT="$(sed -n 's/^oversee-succeed: watch-restarted .* runner=systemd unit=//p' "$WATCH_ERR")"
  assert_eq "$RC|$(unit_of watch-handover <<<"$OUT")|$(unit_of watch-restarted "$WATCH_ERR")" \
    "0|orch-watch-handover|orch-watch-restart" \
    "under a user manager the helper and the restarted watch run as units named for the handover and the restart"
  assert_eq "${NEW:+found}|$(systemctl --user show -p MainPID --value -- "${RESTART_UNIT:-none}.service" 2>/dev/null)|$(started_line "${NEW:-none}" | sed 's/ origin=.* cwd=/ cwd=/; s/ argv=.*//')|$(( $(grep -c '^started ' "$TMP_ROOT/watch.log") - STARTED ))" \
    "found|${NEW:-none}|pane=$SUCC_PANE cwd=$TMP_ROOT/work|1" \
    "and the restarted watch is its unit's main process, serving the successor pane from the recorded directory"
  watch_stop "$NEW" "$FLEET_STATE" || true
else
  printf '  skip  no systemd user manager answers on this host; the unit handover row did not run\n'
fi

# No watch runs on the fleet state: nothing is started, and the run says so.
new_caller
fresh_output
STARTED="$(grep -c '^started ' "$TMP_ROOT/watch.log")"
run_succeed
assert_eq "$RC|$(grep -c '^oversee-succeed: watch-absent path=.*/tmp/workflow-state-oversee.json$' <<<"$OUT")|$(grep -c '^started ' "$TMP_ROOT/watch.log")" \
  "0|1|$STARTED" \
  "a fleet with no running watch reports watch-absent and starts none"

# The suite's one must-fail control: the succession as it stood before the
# handover, which closes the caller and leaves its watch reading the pane that
# closed. The line is matched whole, so the mutation lands on that one site.
UNPATCHED="$(mutant_scripts unpatched oversee-succeed)" || exit 1
awk '$0 == "if [[ \"$MODE\" == succeed ]]; then" { print "if false; then"; hits++; next } { print }
     END { if (hits != 1) exit 1 }' "$SUCCEED" > "$UNPATCHED/oversee-succeed" \
  || { echo "fixture: the handover mutant found no single site" >&2; exit 1; }
new_caller
fresh_output
start_watch
run_succeed "$UNPATCHED/oversee-succeed"
sleep 2
assert_eq "$RC|$(kill -0 "$OLD" 2>/dev/null && echo alive || echo gone)|$(started_line "$OLD" | sed 's/ .*//')|$(grep -c '^oversee-succeed: watch-' <<<"$OUT")" \
  "0|alive|pane=$CALLER_PANE|0" \
  "control: without the handover the watch keeps serving the closed pane"
watch_stop "$OLD" "$FLEET_STATE" || true

# A harness that kills its tool call's whole process group once the close has
# ended it: modelled by a tmux that, having run the close, kills the process
# group of the run that called it, which is started as a group of its own. The
# restart, left to a helper the orch job runner started under setsid in a
# session of its own, still happens. A host with no setsid has no runner here
# and no row.
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
  new_caller
  fresh_output
  start_watch
  ROW_PATH="$TMP_ROOT/killbin" ROW_LAUNCH=setsid run_succeed
  wait_restart
  assert_eq "$RC|$(tm list-windows -t fleet -F '#{window_id}' | grep -cxF -- "$CALLER_WINDOW" || true)|${NEW:+restarted}|$(kill -0 "$OLD" 2>/dev/null && echo alive || echo gone)" \
    "137|0|restarted|gone" \
    "a run killed with its process group at the close still has the watch restarted from the successor pane"
  watch_stop "$NEW" "$FLEET_STATE" || true
else
  printf '  skip  the process-group kill rows need setsid\n'
fi

# A restart that fails is a notice the next start prints, and the succession
# still exits 0 and starts nothing. One row per step that can fail once the
# close has happened: the recorded command gone, and a restarted watch that
# never records itself.
wait_failed() { # TRIES
  FAILED_LINE=""
  for _ in $(seq 1 "$1"); do
    FAILED_LINE="$(grep '^oversee-succeed: watch-restart-failed ' "$WATCH_ERR" 2>/dev/null || true)"
    [[ -z "$FAILED_LINE" ]] || break
    sleep 0.1
  done
}
new_caller
fresh_output
start_watch
rm -f -- "${TMP_ROOT:?}/work/tmp/oversee-watch.argv"
STARTED="$(grep -c '^started ' "$TMP_ROOT/watch.log")"
run_succeed
wait_failed 100
assert_eq "$RC|$FAILED_LINE|$(grep -c '^started ' "$TMP_ROOT/watch.log")" \
  "0|oversee-succeed: watch-restart-failed step=argv pid=$OLD|$STARTED" \
  "a restart with no recorded command is a notice beside the fleet state, and starts nothing"
watch_stop "$OLD" "$FLEET_STATE" || true

touch "$TMP_ROOT/norecord"
new_caller
fresh_output
start_watch
STARTED="$(grep -c '^started ' "$TMP_ROOT/watch.log")"
run_succeed
wait_failed 300
rm -f -- "${TMP_ROOT:?}/norecord"
assert_eq "$RC|$FAILED_LINE|$(grep -c '^started ' "$TMP_ROOT/watch.log")" \
  "0|oversee-succeed: watch-restart-failed step=start log=$(cd "$TMP_ROOT/work/tmp" && pwd -P)/oversee-watch.err|$STARTED" \
  "a restarted watch that never records itself is a notice beside the fleet state"
watch_stop "$OLD" "$FLEET_STATE" || true

# A launch the runner refuses is a notice carrying the runner's own error,
# never a handover or a restart. The helper's: a record the runner cannot
# write, its temporary file's path taken by a directory. The restart's: a
# setsid that starts the helper and fails every other start.
if command -v setsid >/dev/null 2>&1; then
  RUNNER_PART="$TMP_ROOT/work/tmp/oversee-watch.runner.part"
  new_caller
  fresh_output
  start_watch
  mkdir -p "$RUNNER_PART"
  STARTED="$(grep -c '^started ' "$TMP_ROOT/watch.log")"
  run_succeed
  rmdir -- "$RUNNER_PART"
  HELPER_LINE="$(grep '^oversee-succeed: watch-restart-failed step=helper ' <<<"$OUT" || true)"
  assert_eq "$RC|$HELPER_LINE|$(grep -c '^oversee-succeed: watch-handover ' <<<"$OUT")|$(grep -c '^started ' "$TMP_ROOT/watch.log")" \
    "0|oversee-succeed: watch-restart-failed step=helper pid=$OLD error=record-unwritable path=$(cd "$TMP_ROOT/work/tmp" && pwd -P)/oversee-watch.runner|0|$STARTED" \
    "a helper the runner refuses is a notice with the runner's error, and no handover or restart"
  watch_stop "$OLD" "$FLEET_STATE" || true

  REAL_SETSID="$(command -v setsid)"
  mkdir -p "$TMP_ROOT/helper-only"
  printf '#!/bin/sh\ncase "$*" in *--watch-restart*) exec %s "$@" ;; esac\nexit 1\n' "$REAL_SETSID" \
    > "$TMP_ROOT/helper-only/setsid"
  chmod +x "$TMP_ROOT/helper-only/setsid"
  new_caller
  fresh_output
  start_watch
  STARTED="$(grep -c '^started ' "$TMP_ROOT/watch.log")"
  ROW_PATH="$TMP_ROOT/helper-only" run_succeed
  wait_failed 100
  assert_eq "$RC|$FAILED_LINE|$(grep -c '^started ' "$TMP_ROOT/watch.log")" \
    "0|oversee-succeed: watch-restart-failed step=start dir=$TMP_ROOT/work error=launch-failed status=1|$STARTED" \
    "a restart the runner refuses is a notice beside the fleet state with the runner's error, and starts nothing"
  watch_stop "$OLD" "$FLEET_STATE" || true
else
  printf '  skip  the refused-launch rows need setsid\n'
fi

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
