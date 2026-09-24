#!/usr/bin/env bash
# Tests for what binds a watch to the place it was started from, and what it
# must not take from there once that place is gone: the tmux session its bare
# lane names are read in, the host its hosted lanes live on, and the record it
# keeps of itself beside the fleet state (lib/watch-pid.sh) — the one pid a
# stop reaches with its pass, the refusal of a second watch on one fleet, the
# takeover of the watch a succession restarted for this pane or of one whose
# pane is gone, and the output a restarted watch left for the next start. The
# restart itself is oversee-succeed's, in oversee_succeed_watch.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# shellcheck source=../scripts/lib/watch-pid.sh
source "$REPO_ROOT/skills/orch/scripts/lib/watch-pid.sh"

REAL_SLEEP="$(command -v sleep)"
FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
WATCH_SRC="$REPO_ROOT/skills/orch/scripts/oversee-watch"

# Every process a case leaves running is stopped with the sandbox.
LIVE_PIDS=""
lifecycle_cleanup() {
  local pid
  for pid in $LIVE_PIDS; do kill -TERM "$pid" 2>/dev/null || true; done
  rm -rf "$TMP_ROOT"
}
trap lifecycle_cleanup EXIT

# mutant NAME FILE FROM TO — a copy of the script tree whose FILE (relative to
# scripts/) has the one line FROM replaced by TO; MUTANT is its oversee-watch.
# Refuses unless FROM is exactly one line of the shipped file.
mutant() { # NAME FILE FROM TO
  local dir="$TMP_ROOT/mutant-$1" src="$REPO_ROOT/skills/orch/scripts/$2"
  [[ "$(grep -cxF -- "$3" "$src")" == 1 ]] || { echo "mutant $1: the line to replace is not one line of $2" >&2; exit 1; }
  mkdir -p "$dir/orch"
  cp -R "$REPO_ROOT/skills/orch/scripts" "$dir/orch/scripts"
  ln -s "$REPO_ROOT/skills/github" "$dir/github"
  # Through the environment, never -v, which would read each backslash as an
  # escape and match nothing.
  FROM="$3" TO="$4" awk '$0 == ENVIRON["FROM"] { print ENVIRON["TO"]; next } { print }' "$src" > "$dir/orch/scripts/$2"
  ! cmp -s "$src" "$dir/orch/scripts/$2" || { echo "mutant $1: $2 unchanged" >&2; exit 1; }
  MUTANT="$dir/orch/scripts/oversee-watch"
}

# A repeat pass: the wrapper's child, which inherits its session and records
# nothing of its own.
cat > "$TMP_ROOT/bin/watch-child-stub.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
export OVERSEE_WATCH_REPEAT_OWNER=$$
"$CHILD_WATCH_BIN" "$@"
EOF
chmod +x "$TMP_ROOT/bin/watch-child-stub.sh"

# The repeat loop's own delay: a real sleep, so a started loop stays running
# until a case stops it, or, in a loop started with LIFECYCLE_SLEEP_FAIL=1, a
# failure, so a loop a case runs in the foreground ends after its first pass
# as sleep-failed while one it started earlier keeps sleeping. A pass's own
# sleeps return at once, except an --interval of 30, which a case names to
# hold a pass running.
sleep_stub() {
  mkdir -p "$STUB_DIR/bin"
  cat > "$STUB_DIR/bin/sleep" <<EOF
#!/usr/bin/env bash
if [[ "\${OVERSEE_WATCH_SLEEP:-}" == repeat ]]; then
  [[ -z "\${LIFECYCLE_SLEEP_FAIL:-}" ]] || exit 3
  exec "$REAL_SLEEP" 30
fi
[[ "\${1:-}" == 30 ]] || exit 0
exec "$REAL_SLEEP" 30
EOF
  chmod +x "$STUB_DIR/bin/sleep"
}

# An empty fleet state, or one naming the lane records given.
fleet_state() { # [RECORD...]
  printf '%s\n' "$@" | jq -s '{issue_id: "oversee", triaged: [], lanes: .}' > "$STUB_DIR/state.json"
}
lane_rec() { # ITEM WINDOW HOST MAIL_ROOT
  jq -cn --arg item "$1" --arg window "$2" --arg host "$3" --arg root "$4" \
    '{item: $item, window: $window, host: $host, mail_root: $root, status: "running"} | map_values(if . == "" then null else . end)'
}

# repeat_watch_run [ENV=VAL...] -- [WATCH ARGS...] — a repeat loop on the
# case's state with the loop's sleep stubbed and no overseer to record.
repeat_watch_run() {
  local env_args=()
  while [[ $# -gt 0 && "$1" != -- ]]; do env_args+=("$1"); shift; done
  shift
  run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" OVERSEE_WATCH_SUCCEED=/nonexistent \
    ${env_args[@]+"${env_args[@]}"} -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" "$@"
}

# wait_for_record — the pid the record beside the case's state names once it
# names a live watch, or empty after the bound.
wait_for_record() {
  local i
  for (( i = 0; i < 100; i++ )); do
    if watch_pid_live "$STUB_DIR/state.json"; then
      printf '%s\n' "$WATCH_PID"
      return 0
    fi
    "$REAL_SLEEP" 0.1
  done
}
# recorded_pid — the pid the record names, read raw once the file exists, live
# or not and whatever it runs.
recorded_pid() {
  local i
  for (( i = 0; i < 100; i++ )); do
    if [[ -f "$STUB_DIR/oversee-watch.pid" ]]; then
      sed -n 's/^pid=//p' "$STUB_DIR/oversee-watch.pid"
      return 0
    fi
    "$REAL_SLEEP" 0.1
  done
}

echo "=== oversee-watch lifecycle ==="

# --- the session bare lane names are read in -------------------------------
# A pass the wrapper launched after the pane it started from died: TMUX_PANE
# names nothing, tmux names no session of its own, and a window list that asks
# tmux for the current one answers another session's. The wrapper's recorded
# session is what the pass reads its bare names in.
session_case() { # NAME [WATCH_BIN]
  new_case "$1"
  printf 'work\n' > "$STUB_DIR/session.txt"
  touch "$STUB_DIR/session-fail"
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="$TMP_ROOT/bin/watch-child-stub.sh" run_watch TMUX_PANE= OVERSEE_WATCH_SESSION=work \
    CHILD_WATCH_BIN="${2:-$WATCH_SRC}" OVERSEE_WATCH_SUCCEED=/nonexistent -- --max-loops 1 gh-1 gh-2 2>"$err")" \
    && rc=0 || rc=$?
}
session_case session_recorded
assert_eq "rc=$rc events=$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")" "rc=0 events=heartbeat" \
  "a pass reads a bare lane in the recorded session after its launching pane is gone, and finds it" "$err"
assert_eq "$(grep -c '^oversee-watch: session-resolved' "$err")" "0" "a pass names no session: its wrapper already did" "$err"
# The must-fail control: a bare name listed through whatever session tmux calls
# current, which is where the watch read it before the session was recorded.
mutant session_current oversee-watch '  out="$(tmux list-windows -t "=$session" -F '"'#W'"' 2>&1)" && { printf '"'%s\\n'"' "$out"; return 0; }' \
  '  [[ "$1" == *:* ]] || { tmux list-windows -F '"'#W'"' 2>&1; return; }; out="$(tmux list-windows -t "=$session" -F '"'#W'"' 2>&1)" && { printf '"'%s\\n'"' "$out"; return 0; }'
session_case session_current_mutant "$MUTANT"
assert_contains "$out" "EVENT window-gone gh-1" \
  "control: listed through tmux's current session, the recorded lane reads window-gone" "$err"

# A standalone run resolves its session and names it once, however many bare
# lanes it reads in it.
new_case session_named
err="$TMP_ROOT/e-session_named"
run_watch OVERSEE_WATCH_SUCCEED=/nonexistent -- --max-loops 1 gh-1 gh-2 >/dev/null 2>"$err" || true
assert_eq "$(grep -c '^oversee-watch: session-resolved session=main$' "$err")" "1" \
  "a standalone run names the session its bare lanes are read in, on one line" "$err"

# No session to read a bare name in: refused, naming the lane and the state.
unresolved_case() { # NAME [WATCH_BIN]
  new_case "$1"
  touch "$STUB_DIR/session-fail"
  fleet_state "$(lane_rec issue-1 gh-1 '' '')"
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${2:-}" run_watch OVERSEE_WATCH_SUCCEED=/nonexistent -- --max-loops 1 --state "$STUB_DIR/state.json" 2>"$err")" \
    && rc=0 || rc=$?
}
unresolved_case session_unresolved
assert_eq "rc=$rc first=$(head -1 "$err") out=${out:-none}" \
  "rc=2 first=oversee-watch: session-unresolved lane=gh-1 path=$STUB_DIR/state.json out=none" \
  "a bare lane with no session resolved is refused, naming the lane and the state file" "$err"
mutant session_unrefused oversee-watch \
  '      || die session-unresolved "$WATCH_SESSION_DETAIL" "lane=$lane" "path=${STATE_FILE:-none}"' \
  '      || :'
unresolved_case session_unrefused_mutant "$MUTANT"
assert_eq "$(grep -c '^oversee-watch: session-unresolved' "$err")" "0" \
  "control: without the refusal the bare lane is carried with no session" "$err"

# --- the host hosted lanes live on ------------------------------------------
host_case() { # NAME HOST [WATCH_BIN]
  new_case "$1"
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${3:-}" run_watch ORCH_LANE_HOST="$2" OVERSEE_WATCH_SUCCEED=/nonexistent -- \
    --max-loops 1 --item KEN-10 --hosted KEN-10=/srv/lane/ken-10 2>"$err")" && rc=0 || rc=$?
}
host_case hosted_local local
assert_eq "rc=$rc first=$(head -1 "$err") out=${out:-none}" \
  "rc=2 first=oversee-watch: hosted-without-host items=KEN-10 host=local out=none" \
  "a hosted lane on a host lane-host resolves local is refused before any read" "$err"
host_case hosted_provider "$FIXTURE_HOST"
assert_eq "$(grep -c '^oversee-watch: hosted-without-host' "$err")" "0" \
  "a hosted lane on a host lane-host resolves to a provider is read" "$err"
mutant hosted_unchecked oversee-watch '  [[ "$LANE_HOST_SPEC" == local ]] || return 0' '  return 0'
host_case hosted_unchecked_mutant local "$MUTANT"
assert_eq "$(grep -c '^oversee-watch: hosted-without-host' "$err")" "0" \
  "control: without the check the hosted lane is carried with no host" "$err"
# Repeat mode refuses at its first read of a state recording a hosted lane,
# before any pass runs, and never loops.
new_case hosted_repeat
sleep_stub
fleet_state "$(lane_rec KEN-10 '' /srv/provider /srv/lane/ken-10)"
err="$TMP_ROOT/e-hosted_repeat"
out="$(repeat_watch_run ORCH_LANE_HOST=local -- 2>"$err")" && rc=0 || rc=$?
assert_eq "rc=$rc refused=$(grep -c '^oversee-watch: hosted-without-host items=KEN-10 host=local$' "$err") passes=$(cat "$STUB_DIR"/prwatch.calls.* 2>/dev/null || echo 0)" \
  "rc=2 refused=1 passes=0" "a repeat loop carrying a hosted lane with no host ends before its first pass" "$err"

# --- the watch's own record ---------------------------------------------------
# A loop started under a shell that is not itself the watch, with overseer
# flags after its `--`: the record names the loop, whose command line carries
# --repeat, and never the shell above it, and records the loop's own words
# without the overseer's flags, which a restart replaces.
record_case() { # NAME [WATCH_BIN] [WATCH ARGS...]
  local name="$1" bin="${2:-}"
  shift
  [[ $# -eq 0 ]] || shift
  new_case "$name"
  sleep_stub
  fleet_state
  ( WATCH_BIN="$bin" repeat_watch_run -- "$@" -- --model old --verbose >"$TMP_ROOT/o-$name" 2>"$TMP_ROOT/e-$name" && rc=0 || rc=$?
    echo "$rc" > "$STUB_DIR/loop.rc" ) &
  LAUNCHER=$!
  LIVE_PIDS+=" $LAUNCHER"
  LOOP="$(recorded_pid)"
  LIVE_PIDS+=" $LOOP"
}
record_case record_loop
# The loop's command line, which only the loop carries: a pass is run without
# --repeat, and the launcher above it is a shell.
loop_args() { ps -o args= -p "${1:-0}" 2>/dev/null | grep -c -- 'oversee-watch.* --repeat 0 ' || true; }
assert_eq "read=${LOOP:+yes}|$(loop_args "$LOOP")" "read=yes|1" \
  "the record names the repeat loop itself, whatever launched it" "$TMP_ROOT/e-record_loop"
RECORDED_ARGV="$(tr '\0' ' ' < "$STUB_DIR/oversee-watch.argv")"
assert_eq "$RECORDED_ARGV|$(sed -n 's/^cwd=//p' "$STUB_DIR/oversee-watch.pid")" \
  "--interval 0 --max-loops 2 --repo owner/repo --max-loops 1 --repeat 0 --state $STUB_DIR/state.json |$TMP_ROOT/repo" \
  "the record keeps the loop's own words and directory, and none of the overseer's flags"

# A second start on the same state is refused, naming the live loop, and
# leaves the record and the loop as they were.
err="$TMP_ROOT/e-record_second"
out="$(repeat_watch_run LIFECYCLE_SLEEP_FAIL=1 -- 2>"$err")" && rc=0 || rc=$?
watch_pid_live "$STUB_DIR/state.json" || WATCH_PID=none
assert_eq "rc=$rc refused=$(grep -c "^oversee-watch: watch-running pid=$LOOP pane=none path=$STUB_DIR/state.json\$" "$err") out=${out:-none} record=$WATCH_PID" \
  "rc=2 refused=1 out=none record=$LOOP" "a second watch on one fleet state is refused, naming the live pid" "$err"

# Stopped through the record's pid, the loop ends at once and removes it.
stop_rc=0
watch_stop "$LOOP" || stop_rc=$?
wait "$LAUNCHER" 2>/dev/null || true
assert_eq "stop=$stop_rc rc=$(cat "$STUB_DIR/loop.rc") record=$([[ -f "$STUB_DIR/oversee-watch.pid" ]] && echo left || echo removed)" \
  "stop=0 rc=143 record=removed" "a stopped loop exits 143 and removes its record" "$TMP_ROOT/e-record_loop"

# Controls, one per rule above: the record naming the launcher, the overseer's
# flags recorded with the loop's words, the second start let through, and a
# stopped loop that leaves its record behind.
mutant record_parent lib/watch-pid.sh \
  '    "$$" "$WATCH_STATE_CANON" "$pane" "$origin" "$script" "$PWD" \' \
  '    "$PPID" "$WATCH_STATE_CANON" "$pane" "$origin" "$script" "$PWD" \'
record_case record_parent_mutant "$MUTANT"
assert_eq "read=${LOOP:+yes}|$(loop_args "$LOOP")" "read=yes|0" \
  "control: a record naming its parent names no repeat loop"
for pid in $(pgrep -P "$LOOP" 2>/dev/null || true); do watch_stop "$pid" || true; done

mutant record_whole_argv oversee-watch \
  '    "$SCRIPT_DIR/${BASH_SOURCE[0]##*/}" "${@:1:$ARGV_BASE_COUNT}" \' \
  '    "$SCRIPT_DIR/${BASH_SOURCE[0]##*/}" "$@" \'
record_case record_whole_argv_mutant "$MUTANT"
assert_contains "$(tr '\0' ' ' < "$STUB_DIR/oversee-watch.argv")" "-- --model old --verbose" \
  "control: recording every word keeps the overseer's flags a restart must replace"
watch_stop "$LOOP" || true

mutant record_unrefused oversee-watch \
  '      || die watch-running "" "pid=$WATCH_PID" "pane=$WATCH_PANE" "path=$STATE_FILE"' '      || :'
record_case record_unrefused_first
err="$TMP_ROOT/e-record_unrefused"
WATCH_BIN="$MUTANT" repeat_watch_run LIFECYCLE_SLEEP_FAIL=1 -- >/dev/null 2>"$err" || true
assert_eq "first=$(kill -0 "$LOOP" 2>/dev/null && echo alive || echo gone) refused=$(grep -c '^oversee-watch: watch-running' "$err")" \
  "first=alive refused=0" "control: without the refusal a second watch starts beside the live one" "$err"
watch_stop "$LOOP" || true

mutant record_unreleased oversee-watch "  trap 'watch_pid_release \"\$STATE_FILE\"' EXIT" '  :'
record_case record_unreleased "$MUTANT"
watch_stop "$LOOP" || true
wait "$LAUNCHER" 2>/dev/null || true
assert_eq "$([[ -f "$STUB_DIR/oversee-watch.pid" ]] && echo left || echo removed)" "left" \
  "control: a loop that does not release its record leaves it behind when stopped"

# A plain kill -TERM on the recorded pid, while a pass sits in its interval,
# ends that pass with the loop: a pass left behind would keep reading the
# fleet, and draining the overseer mailbox, beside the next watch.
term_case() { # NAME [WATCH_BIN]
  record_case "$1" "${2:-}" --interval 30 --max-loops 2
  PASS_PID=""
  for _ in $(seq 1 100); do
    PASS_PID="$(pgrep -P "$LOOP" 2>/dev/null || true)"
    [[ -z "$PASS_PID" ]] || [[ "$(ps -o args= -p "$PASS_PID" 2>/dev/null)" != *oversee-watch* ]] || break
    PASS_PID=""
    "$REAL_SLEEP" 0.1
  done
  LIVE_PIDS+=" $PASS_PID"
  kill -TERM "$LOOP"
  for _ in $(seq 1 50); do
    kill -0 "$PASS_PID" 2>/dev/null || break
    "$REAL_SLEEP" 0.1
  done
  PASS_STATE="$(kill -0 "$PASS_PID" 2>/dev/null && echo alive || echo gone)"
}
term_case term_loop
assert_eq "pass=${PASS_PID:+found} $PASS_STATE loop=$(kill -0 "$LOOP" 2>/dev/null && echo alive || echo gone)" \
  "pass=found gone loop=gone" "a TERM on the loop pid ends the pass it is running" "$TMP_ROOT/e-term_loop"
mutant term_untrapped oversee-watch "  trap 'repeat_stop 143' TERM" '  :'
term_case term_untrapped_mutant "$MUTANT"
assert_eq "pass=${PASS_PID:+found} $PASS_STATE" "pass=found alive" \
  "control: with no TERM trap the loop dies and its pass runs on"
kill -TERM "$PASS_PID" 2>/dev/null || true

# --- taking over a watch ------------------------------------------------------
# A stand-in for a watch another start left running: it records itself as the
# real loop does, through the same library, and notes when it is stopped.
FIXTURE_WATCH="$TMP_ROOT/fixture/oversee-watch"
mkdir -p "$TMP_ROOT/fixture"
cat > "$FIXTURE_WATCH" <<EOF
#!/usr/bin/env bash
source "$REPO_ROOT/skills/orch/scripts/lib/watch-pid.sh"
trap 'echo stopped >> "\$4"; exit 143' TERM
watch_pid_write "\$1" "\$2" "\$3" "\$0"
while :; do "$REAL_SLEEP" 1; done
EOF
chmod +x "$FIXTURE_WATCH"

# take_case NAME ORIGIN PANE [WATCH_BIN] — a watch of ORIGIN recorded for PANE
# with output waiting beside the state, %9 the one pane tmux lists, and a
# start from %9. ORIGIN none records no watch at all.
take_case() { # NAME ORIGIN PANE [WATCH_BIN]
  new_case "$1"
  sleep_stub
  fleet_state
  printf '7000 %%9\n' > "$STUB_DIR/panes.txt"
  printf 'EVENT lane-question KEN-1 m-1\n  a question the restarted watch reported\n' > "$STUB_DIR/oversee-watch.log"
  printf 'oversee-succeed: watch-restarted pid=1 pane=%%9\n' > "$STUB_DIR/oversee-watch.err"
  OLD=""
  if [[ "$2" != none ]]; then
    # Two forks deep, so the stopped stand-in is reaped by init and not left a
    # zombie this shell would still answer kill -0 for.
    ( "$FIXTURE_WATCH" "$STUB_DIR/state.json" "$3" "$2" "$STUB_DIR/fixture.log" & )
    OLD="$(wait_for_record)"
    LIVE_PIDS+=" $OLD"
  fi
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${4:-}" repeat_watch_run TMUX_PANE=%9 LIFECYCLE_SLEEP_FAIL=1 -- 2>"$err")" && rc=0 || rc=$?
}
stopped() { cat "$STUB_DIR/fixture.log" 2>/dev/null || echo no; }
leftover() { if [[ -e "$STUB_DIR/oversee-watch.log" || -e "$STUB_DIR/oversee-watch.err" ]]; then echo left; else echo removed; fi; }

take_case take_succession succession %9
assert_eq "stopped=$(stopped) taken=$(grep -c "^oversee-watch: watch-taken-over pid=$OLD pane=%9 reason=succession\$" "$err")" \
  "stopped=stopped taken=1" "a start from the pane a succession restarted a watch for stops that watch and says so" "$err"
assert_eq "$(sed -n 1,2p <<<"$out")|$(leftover)" "$(cat <<'EOF'
EVENT lane-question KEN-1 m-1
  a question the restarted watch reported|removed
EOF
)" "the restarted watch's output is printed first on stdout, then removed" "$err"
assert_contains "$(cat "$err")" "oversee-succeed: watch-restarted pid=1 pane=%9" \
  "and what the restart said, on stderr" "$err"

take_case take_pane_gone hand %8
assert_eq "stopped=$(stopped) taken=$(grep -c "^oversee-watch: watch-taken-over pid=$OLD pane=%8 reason=pane-gone\$" "$err")" \
  "stopped=stopped taken=1" "a watch serving a pane tmux no longer lists is stopped and replaced" "$err"

take_case take_hand hand %9
assert_eq "rc=$rc refused=$(grep -c "^oversee-watch: watch-running pid=$OLD pane=%9 " "$err") stopped=$(stopped) out=${out:-none}" \
  "rc=2 refused=1 stopped=no out=none" "a watch serving a live pane, started by hand, is refused" "$err"
kill -TERM "$OLD" 2>/dev/null || true

# The restarted watch already ended, its successor dead before starting a
# watch of its own: what it printed is still handed to the next start.
take_case take_exited none ''
assert_eq "$(grep -c '^oversee-watch: watch-replayed ' "$err")|$(sed -n 1p <<<"$out")|$(leftover)" \
  "1|EVENT lane-question KEN-1 m-1|removed" "output a restarted watch left behind is printed by a start with no live watch" "$err"

# Controls, one per way a watch is taken over or its output handed on.
mutant take_never oversee-watch \
  '    if [[ "$WATCH_ORIGIN" == succession && -n "${TMUX_PANE:-}" && "$WATCH_PANE" == "$TMUX_PANE" ]]; then' \
  '    if false; then'
take_case take_never_mutant succession %9 "$MUTANT"
assert_eq "$(grep -c '^oversee-watch: watch-taken-over' "$err")|$(stopped)" "0|no" \
  "control: without the succession rule the successor's own start is refused" "$err"
kill -TERM "$OLD" 2>/dev/null || true

mutant take_gone_never oversee-watch '    elif watch_pane_gone "$WATCH_PANE"; then' '    elif false; then'
take_case take_gone_never_mutant hand %8 "$MUTANT"
assert_eq "$(grep -c '^oversee-watch: watch-taken-over' "$err")|$(stopped)" "0|no" \
  "control: without the pane rule a watch serving a closed pane is refused" "$err"
kill -TERM "$OLD" 2>/dev/null || true

mutant take_unprinted oversee-watch '    [[ ! -f "$WATCH_LOG_FILE" ]] || cat -- "$WATCH_LOG_FILE"' '    :'
take_case take_unprinted_mutant succession %9 "$MUTANT"
assert_not_contains "$out" "EVENT lane-question KEN-1 m-1" \
  "control: with no print the restarted watch's event is lost" "$err"

mutant take_live_only oversee-watch \
  '  if [[ -s "$WATCH_LOG_FILE" || -s "$WATCH_ERR_FILE" ]]; then' \
  '  if [[ -n "$why" ]] && [[ -s "$WATCH_LOG_FILE" || -s "$WATCH_ERR_FILE" ]]; then'
take_case take_live_only_mutant none '' "$MUTANT"
assert_eq "$(grep -c '^oversee-watch: watch-replayed ' "$err")|$(leftover)" "0|left" \
  "control: printed only on a takeover, an exited watch's output waits unread" "$err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
