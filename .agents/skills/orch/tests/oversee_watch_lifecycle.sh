#!/usr/bin/env bash
# Tests for what binds a watch to the place it was started from, and what it
# must not take from there once that place is gone: the tmux session its bare
# lane names are read in, the host its hosted lanes live on, and the record it
# keeps of itself beside the fleet state (lib/watch-pid.sh) — the one pid a
# stop reaches with its pass, the refusal of a second watch on one fleet, the
# takeover of the watch a succession restarted for this pane or of one whose
# pane is gone, and the output a restarted watch left for the next start; and
# the watch the launch fence starts through the orch job runner, a unit or a
# setsid group, read, stopped and taken over part way through a lane-close.
# The restart itself is oversee-succeed's, in oversee_succeed_watch.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# shellcheck source=../scripts/lib/watch-pid.sh
source "$REPO_ROOT/skills/orch/scripts/lib/watch-pid.sh"
# mutant_scripts, under the mutant helper below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"

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

# mutant NAME FILE FROM TO — the scripts, as mutant_scripts links them, whose
# FILE (relative to scripts/) is a private copy with the one line FROM
# replaced by TO; MUTANT is its oversee-watch. It keeps orch's place in a
# skills tree so its libraries resolve the github skill beside it. Refuses
# unless FROM is exactly one line of the file.
mutant() { # NAME FILE FROM TO
  local scripts src="$REPO_ROOT/skills/orch/scripts/$2"
  [[ "$(grep -cxF -- "$3" "$src")" == 1 ]] || { echo "mutant $1: the line to replace is not one line of $2" >&2; exit 1; }
  scripts="$(mutant_scripts "mutant-$1/orch" "$2")" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mutant-$1/github"
  # Through the environment, never -v, which would read each backslash as an
  # escape and match nothing.
  FROM="$3" TO="$4" awk '$0 == ENVIRON["FROM"] { print ENVIRON["TO"]; next } { print }' "$src" > "$scripts/$2"
  ! cmp -s "$src" "$scripts/$2" || { echo "mutant $1: $2 unchanged" >&2; exit 1; }
  MUTANT="$scripts/oversee-watch"
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
  printf 'Do you want to proceed?\n   \xe2\x9d\xaf 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="$TMP_ROOT/bin/watch-child-stub.sh" run_watch TMUX_PANE= OVERSEE_WATCH_SESSION=work \
    CHILD_WATCH_BIN="${2:-$WATCH_SRC}" OVERSEE_WATCH_SUCCEED=/nonexistent -- --max-loops 1 gh-1 gh-2 2>"$err")" \
    && rc=0 || rc=$?
}
session_case session_recorded
assert_eq "rc=$rc events=$(awk '/^EVENT / { printf "%s%s", sep, $2 " " $3; sep = " " }' <<<"$out")" "rc=0 events=lane-asking gh-2" \
  "a pass reads a bare lane in the recorded session after its launching pane is gone, and reads that lane's own screen" "$err"
assert_eq "$(grep -c '^oversee-watch: session-resolved' "$err")" "0" "a pass names no session: its wrapper already did" "$err"
# oversee-watch's one must-fail control: a bare name listed through whatever
# session tmux calls current, which is where the watch read it before the
# session was recorded.
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
assert_eq "$(grep -c '^oversee-watch: session-resolved session=main server=fake$' "$err")" "1" \
  "a standalone run names the session its bare lanes are read in, and the server, on one line" "$err"

# A watch run from OUTSIDE tmux, with ORCH_TMUX_SESSION naming the fleet's
# session: no $TMUX, the lanes read in that session on the person's own tmux
# server, whose socket the resolved line names. The setting outranks the pane,
# so the pane's own session is never asked.
DEFAULT_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default"
new_case session_setting_outside
printf 'Do you want to proceed?\n   \xe2\x9d\xaf 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e-session_setting_outside"
out="$(run_watch TMUX= TMUX_PANE= ORCH_TMUX_SESSION=main OVERSEE_WATCH_SUCCEED=/nonexistent -- --max-loops 1 gh-1 gh-2 2>"$err")" \
  && rc=0 || rc=$?
assert_eq "rc=$rc events=$(awk '/^EVENT / { printf "%s%s", sep, $2 " " $3; sep = " " }' <<<"$out") line=$(grep -c "^oversee-watch: session-resolved session=main server=$DEFAULT_SOCKET\$" "$err")" \
  "rc=0 events=lane-asking gh-2 line=1" \
  "outside tmux, ORCH_TMUX_SESSION names the session the lanes are read in and the resolved line names the person's server" "$err"
new_case session_setting_over_pane
touch "$STUB_DIR/session-fail"
printf 'Do you want to proceed?\n   \xe2\x9d\xaf 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e-session_setting_over_pane"
out="$(run_watch ORCH_TMUX_SESSION=main OVERSEE_WATCH_SUCCEED=/nonexistent -- --max-loops 1 gh-1 gh-2 2>"$err")" \
  && rc=0 || rc=$?
assert_eq "rc=$rc events=$(awk '/^EVENT / { printf "%s%s", sep, $2 " " $3; sep = " " }' <<<"$out")" "rc=0 events=lane-asking gh-2" \
  "inside tmux, ORCH_TMUX_SESSION outranks a pane whose session read fails" "$err"
# A name the server does not hold is refused, never read as a session with no
# windows: that would report every lane gone.
new_case session_setting_missing
err="$TMP_ROOT/e-session_setting_missing"
out="$(run_watch TMUX= ORCH_TMUX_SESSION=nosuch OVERSEE_WATCH_SUCCEED=/nonexistent -- --max-loops 1 gh-1 2>"$err")" \
  && rc=0 || rc=$?
assert_eq "rc=$rc first=$(sed -n 1p "$err")" \
  "rc=2 first=oversee-watch: session-missing session=nosuch source=ORCH_TMUX_SESSION server=$DEFAULT_SOCKET lanes=gh-1" \
  "an ORCH_TMUX_SESSION tmux does not hold is refused naming it, its source and the server" "$err"
# A has-session answer that is not "can't find session" is the call failing,
# not a missing session: a socket with no server is tmux-failed, not
# session-missing, so the fix it prescribes is not "start that session".
new_case session_setting_no_server
touch "$STUB_DIR/has-session-fail"
err="$TMP_ROOT/e-session_setting_no_server"
out="$(run_watch TMUX= ORCH_TMUX_SESSION=main OVERSEE_WATCH_SUCCEED=/nonexistent -- --max-loops 1 gh-1 2>"$err")" \
  && rc=0 || rc=$?
assert_eq "rc=$rc first=$(sed -n 1p "$err")" \
  "rc=2 first=oversee-watch: tmux-failed operation=has-session server=$DEFAULT_SOCKET lanes=gh-1" \
  "a has-session that answers no-server is refused tmux-failed, not session-missing" "$err"
# The must-fail control: without the answer split every failure is read as a
# missing session, so a dead server prescribes starting the session.
mutant session_no_server_unsplit lib/tmux-server.sh '    "can'"'"'t find session"*) return 3 ;;' '    *) return 3 ;;'
new_case session_no_server_unsplit_mutant
touch "$STUB_DIR/has-session-fail"
err="$TMP_ROOT/e-session_no_server_unsplit"
out="$(WATCH_BIN="$MUTANT" run_watch TMUX= ORCH_TMUX_SESSION=main OVERSEE_WATCH_SUCCEED=/nonexistent -- --max-loops 1 gh-1 2>"$err")" \
  && rc=0 || rc=$?
assert_eq "first=$(sed -n 1p "$err" | sed 's/ session=[^ ]*//')" \
  "first=oversee-watch: session-missing source=ORCH_TMUX_SESSION server=$DEFAULT_SOCKET lanes=gh-1" \
  "control: without the answer split a dead server is misreported as a missing session" "$err"
# The must-fail control: a resolver that reads the setting without asking tmux
# for it takes the missing session as resolved, and the lane reads gone.
mutant session_setting_unchecked lib/watch-session.sh '    tmux_session_present "$ORCH_TMUX_SESSION" || probe=$?' '    :'
new_case session_setting_unchecked_mutant
err="$TMP_ROOT/e-session_setting_unchecked_mutant"
out="$(WATCH_BIN="$MUTANT" run_watch TMUX= ORCH_TMUX_SESSION=nosuch OVERSEE_WATCH_SUCCEED=/nonexistent -- --max-loops 1 gh-1 2>"$err")" \
  && rc=0 || rc=$?
assert_contains "$out" "EVENT window-gone gh-1" \
  "control: a resolver that trusts the setting reads the lane gone in a session that is not there" "$err"

# No session to read a bare name in: refused, naming the lane and the state.
unresolved_case() { # NAME
  new_case "$1"
  touch "$STUB_DIR/session-fail"
  fleet_state "$(lane_rec issue-1 gh-1 '' '')"
  err="$TMP_ROOT/e-$1"
  out="$(run_watch OVERSEE_WATCH_SUCCEED=/nonexistent -- --max-loops 1 --state "$STUB_DIR/state.json" 2>"$err")" \
    && rc=0 || rc=$?
}
unresolved_case session_unresolved
assert_eq "rc=$rc first=$(head -1 "$err") out=${out:-none}" \
  "rc=2 first=oversee-watch: session-unresolved lane=gh-1 path=$STUB_DIR/state.json out=none" \
  "a bare lane with no session resolved is refused, naming the lane and the state file" "$err"

# --- the host hosted lanes live on ------------------------------------------
# The hosted lane's disk holds one ask, which only a run that read the lane
# through its host reports.
host_case() { # NAME HOST [WATCH_BIN]
  new_case "$1"
  mkdir -p "$STUB_DIR/remote/srv/lane/ken-10/tmp/lane-mail/KEN-10"
  printf 'gitdir: /srv/clone/.git/worktrees/ken-10\n' > "$STUB_DIR/remote/srv/lane/ken-10/.git"
  printf '{"id":"remote-1","kind":"ask","at":"t","text":"Hosted question"}\n' \
    > "$STUB_DIR/remote/srv/lane/ken-10/tmp/lane-mail/KEN-10/to-overseer.jsonl"
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${3:-}" run_watch ORCH_LANE_HOST="$2" OVERSEE_WATCH_SUCCEED=/nonexistent \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote" -- \
    --max-loops 1 --item KEN-10 --hosted KEN-10=/srv/lane/ken-10 2>"$err")" && rc=0 || rc=$?
}
host_case hosted_local local
assert_eq "rc=$rc first=$(head -1 "$err") out=${out:-none}" \
  "rc=2 first=oversee-watch: hosted-without-host items=KEN-10 host=local out=none" \
  "a hosted lane on a host lane-host resolves local is refused before any read" "$err"
host_case hosted_provider "$FIXTURE_HOST"
assert_eq "rc=$rc refused=$(grep -c '^oversee-watch: hosted-without-host' "$err") event=$(grep -c '^EVENT lane-question KEN-10 remote-1$' <<<"$out")" \
  "rc=0 refused=0 event=1" "a hosted lane on a host lane-host resolves to a provider is read" "$err"
# lane-host itself failing to answer: refused with its words, never read as a
# host. The scripts, linked, with a lane-host that fails in its own voice.
RESOLVE_FAILS="$(mutant_scripts resolve-fails/orch lane-host)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/resolve-fails/github"
printf '#!/usr/bin/env bash\necho "lane-host: settings-rejected" >&2\nexit 4\n' > "$RESOLVE_FAILS/lane-host"
host_case hosted_resolve_fails "$FIXTURE_HOST" "$RESOLVE_FAILS/oversee-watch"
assert_eq "rc=$rc first=$(head -1 "$err") out=${out:-none}" \
  "rc=2 first=oversee-watch: host-resolve-failed path=$TMP_ROOT/resolve-fails/orch/scripts/lane-host out=none" \
  "a lane-host that cannot answer refuses the hosted lane, naming it" "$err"
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
record_case() { # NAME [WATCH ARGS...]
  local name="$1"
  shift
  new_case "$name"
  sleep_stub
  fleet_state
  # Seconds each account read of a long pass is held, for a case that stops a
  # loop while one is in flight.
  [[ -z "${RECORD_LANES_SLEEP:-}" ]] || printf '%s\n' "$RECORD_LANES_SLEEP" > "$STUB_DIR/lanes.sleep"
  ( repeat_watch_run -- "$@" -- --model old --verbose >"$TMP_ROOT/o-$name" 2>"$TMP_ROOT/e-$name" && rc=0 || rc=$?
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
watch_stop "$LOOP" "$STUB_DIR/state.json" || stop_rc=$?
wait "$LAUNCHER" 2>/dev/null || true
assert_eq "stop=$stop_rc rc=$(cat "$STUB_DIR/loop.rc") record=$([[ -f "$STUB_DIR/oversee-watch.pid" ]] && echo left || echo removed)" \
  "stop=0 rc=143 record=removed" "a stopped loop exits 143 and removes its record" "$TMP_ROOT/e-record_loop"


# A stop whose clock ticks at once still waits its whole bound for a watch that
# holds its record. The clock reads 0 at the start, 1 on the next four reads
# and 2 after, so a one-second bound gives up on the sixth read. watch_stop's
# one control is the deadline on the bare bound, which gives up on the second.
stop_bound_case() { # NAME WATCH_PID_LIB
  local holder
  new_case "$1"
  bash -c 'trap "" TERM; while :; do "$1" 0.1; done' oversee-watch "$REAL_SLEEP" & holder=$!
  printf 'pid=%s\n' "$holder" > "$STUB_DIR/oversee-watch.pid"
  STOP_READS="$( source "$2"; WATCH_STOP_SECS=1; reads=0
    watch_clock() { reads=$((reads + 1)); WATCH_NOW=$(( reads == 1 ? 0 : reads <= 5 ? 1 : 2 )); }
    watch_stop "$holder" "$STUB_DIR/state.json" && echo "rc=0 reads=$reads" || echo "rc=$? reads=$reads" )"
  kill -KILL "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}
stop_bound_case stop_bound "$REPO_ROOT/skills/orch/scripts/lib/watch-pid.sh"
assert_eq "$STOP_READS" "rc=1 reads=6" "a stop whose clock ticks at once waits its whole bound"
mutant stop_bare_bound lib/watch-pid.sh '  deadline=$((WATCH_NOW + WATCH_STOP_SECS + 1))' '  deadline=$((WATCH_NOW + WATCH_STOP_SECS))'
stop_bound_case stop_bare_bound "$(dirname "$MUTANT")/lib/watch-pid.sh"
assert_eq "$STOP_READS" "rc=1 reads=2" "control: a deadline on the bare bound gives up as the clock ticks"

# A plain kill -TERM on the recorded pid, while a pass sits in its interval,
# ends that pass with the loop: a pass left behind would keep reading the
# fleet, and draining the overseer mailbox, beside the next watch.
term_case() { # NAME
  record_case "$1" --interval 30 --max-loops 2
  PASS_PID=""
  for _ in $(seq 1 100); do
    PASS_PID="$(pgrep -P "$LOOP" 2>/dev/null || true)"
    [[ -z "$PASS_PID" ]] || [[ "$(ps -o args= -p "$PASS_PID" 2>/dev/null)" != *oversee-watch* ]] || break
    PASS_PID=""
    "$REAL_SLEEP" 0.1
  done
  LIVE_PIDS+=" $PASS_PID"
  kill -TERM "$LOOP"
  # Both on one bound: the loop runs its EXIT trap after the pass is gone.
  for _ in $(seq 1 50); do
    { kill -0 "$PASS_PID" || kill -0 "$LOOP"; } 2>/dev/null || break
    "$REAL_SLEEP" 0.1
  done
  PASS_STATE="$(kill -0 "$PASS_PID" 2>/dev/null && echo alive || echo gone)"
  LOOP_STATE="$(kill -0 "$LOOP" 2>/dev/null && echo alive || echo gone)"
}
term_case term_loop
assert_eq "pass=${PASS_PID:+found} $PASS_STATE loop=$LOOP_STATE" \
  "pass=found gone loop=gone" "a TERM on the loop pid ends the pass it is running" "$TMP_ROOT/e-term_loop"

# descendant ROOT PATTERN — the first process under ROOT, breadth first, whose
# command line matches the extended regex PATTERN; empty when none does.
descendant() {
  local queue=("$1") pid kid
  while [[ ${#queue[@]} -gt 0 ]]; do
    pid="${queue[0]}"
    queue=(${queue[@]+"${queue[@]:1}"})
    for kid in $(pgrep -P "$pid" 2>/dev/null || true); do
      [[ ! "$(ps -o args= -p "$kid" 2>/dev/null)" =~ $2 ]] || { printf '%s\n' "$kid"; return 0; }
      queue+=("$kid")
    done
  done
}
# gone_within PID... — waits up to 5 s for every PID to end; STATES holds each
# one's `alive` or `gone`, in order.
gone_within() {
  local pid
  for _ in $(seq 1 50); do
    STATES=""
    for pid in "$@"; do STATES+=" $(kill -0 "$pid" 2>/dev/null && echo alive || echo gone)"; done
    [[ "$STATES" == *alive* ]] || break
    "$REAL_SLEEP" 0.1
  done
  STATES="${STATES# }"
}

# The same stop while the pass has a long pass in flight, held in its account
# read: the long pass ends with its pass rather than being waited out, which
# would leave it reading the fleet, and committing baselines, beside the next
# watch.
watch_child() { # PARENT — the one oversee-watch process PARENT started, or empty
  local pid
  for pid in $(pgrep -P "$1" 2>/dev/null || true); do
    [[ "$(ps -o args= -p "$pid" 2>/dev/null)" != *oversee-watch* ]] || { printf '%s\n' "$pid"; return 0; }
  done
}
term_long_case() { # NAME
  RECORD_LANES_SLEEP=30 record_case "$1" --interval 30 --max-loops 2
  PASS_PID=""
  LONG_PASS_PID=""
  for _ in $(seq 1 100); do
    [[ ! -s "$STUB_DIR/lanes.args" ]] || {
      PASS_PID="$(watch_child "$LOOP")"
      [[ -z "$PASS_PID" ]] || LONG_PASS_PID="$(watch_child "$PASS_PID")"
      [[ -z "$LONG_PASS_PID" ]] || break
    }
    "$REAL_SLEEP" 0.1
  done
  # The account read's own child: the lanes stub's sleep, under `timeout`,
  # which runs it in a process group of its own.
  HELD_PID=""
  for _ in $(seq 1 50); do
    HELD_PID="$(descendant "${LONG_PASS_PID:-0}" 'sleep 30$')"
    [[ -z "$HELD_PID" ]] || break
    "$REAL_SLEEP" 0.1
  done
  LIVE_PIDS+=" $PASS_PID $LONG_PASS_PID $HELD_PID"
  kill -TERM "$LOOP"
  gone_within "$LONG_PASS_PID" "$PASS_PID" "$LOOP" "$HELD_PID"
  read -r LONG_PASS_STATE PASS_STATE LOOP_STATE HELD_STATE <<<"$STATES"
}
term_long_case term_long_pass
assert_eq "long=${LONG_PASS_PID:+found} $LONG_PASS_STATE pass=$PASS_STATE loop=$LOOP_STATE" \
  "long=found gone pass=gone loop=gone" \
  "a TERM on the loop pid ends the long pass its pass has in flight" "$TMP_ROOT/e-term_long_pass"
assert_eq "held=${HELD_PID:+found} $HELD_STATE" "held=found gone" \
  "and the command that long pass was waiting on" "$TMP_ROOT/e-term_long_pass"

# A pass waiting out its mail interval in a tick sleep: a TERM ends it within
# the bound and takes the sleep with it.
tick_case() { # NAME
  new_case "$1"
  ( run_watch ORCH_WATCH_MAIL_INTERVAL=600 -- --interval 3600 --max-loops 2 \
      >"$TMP_ROOT/o-$1" 2>"$TMP_ROOT/e-$1" ) &
  LIVE_PIDS+=" $!"
  TICK_PID=""
  for _ in $(seq 1 100); do
    TICK_PID="$(descendant "$!" '^sleep [0-9]{2,}$')"
    [[ -z "$TICK_PID" ]] || break
    "$REAL_SLEEP" 0.1
  done
  TICK_PASS_PID="$(descendant "$!" 'oversee-watch --interval')"
  LIVE_PIDS+=" $TICK_PID $TICK_PASS_PID"
  kill -TERM "$TICK_PASS_PID" 2>/dev/null || true
  gone_within "$TICK_PASS_PID" "$TICK_PID"
  TICK_STATES="sleep=${TICK_PID:+found} pass=${STATES% *} sleep=${STATES#* }"
}
tick_case tick_term
assert_eq "$TICK_STATES" "sleep=found pass=gone sleep=gone" \
  "a TERM on a pass in its tick sleep ends it and its sleep within the bound" "$TMP_ROOT/e-tick_term"

# A TERM while the overseer mailbox read waits on its cursor lock, which a
# second process holds for 2 s: the note is peeked, printed and only then
# acknowledged, so it is printed or still unread, never taken and unsaid.
mid_read_case() { # NAME
  local box="$CASE_REPO_ROOT/tmp/lane-mail/overseer" pass read
  new_case "$1"
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  printf 'Owner ruling.\n' > "$TMP_ROOT/note.txt"
  (cd "$CASE_REPO_ROOT" && "$REPO_ROOT/skills/orch/scripts/lane-mail" send --item overseer --directive \
    --file "$TMP_ROOT/note.txt" >/dev/null)
  flock "$box/to-lane.cursor.lock" "$REAL_SLEEP" 2 &
  LIVE_PIDS+=" $!"
  ( run_watch -- --max-loops 1 >"$TMP_ROOT/o-$1" 2>"$TMP_ROOT/e-$1" ) &
  LIVE_PIDS+=" $!"
  read=""
  for _ in $(seq 1 100); do
    read="$(descendant "$!" 'lane-mail inbox --item overseer')"
    [[ -z "$read" ]] || break
    "$REAL_SLEEP" 0.1
  done
  pass="$(descendant "$!" 'oversee-watch --interval')"
  kill -TERM "$pass" 2>/dev/null || true
  gone_within "$pass"
  MID_READ="read=${read:+found} pass=$STATES note=lost"
  if grep -q '^EVENT owner-note ' "$TMP_ROOT/o-$1"; then
    MID_READ="${MID_READ% note=*} note=printed"
  elif (cd "$CASE_REPO_ROOT" && "$REPO_ROOT/skills/orch/scripts/lane-mail" pending --item overseer) \
    | grep -q 'Owner ruling'; then
    MID_READ="${MID_READ% note=*} note=unread"
  fi
}
mid_read_case mid_read_term
assert_eq "$MID_READ" "read=found pass=gone note=unread" \
  "a TERM during the overseer mailbox read leaves the note unread for the next reader" "$TMP_ROOT/e-mid_read_term"

# A stop between the print and the ack, as a kill of the watch's whole process
# tree or group from outside makes (a harness stopping its background command):
# the ack is held in a lane-mail wrapper and killed with its pass. A TERM to
# the pass alone waits for the ack. The note is printed, the cursor stays, and
# the next reader prints it again: at least once, never lost.
ack_stop_case() { # NAME
  local ack pass held
  new_case "$1"
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  (cd "$CASE_REPO_ROOT" && "$REPO_ROOT/skills/orch/scripts/lane-mail" send --item overseer --directive \
    --file "$TMP_ROOT/note.txt" >/dev/null)
  printf '#!/usr/bin/env bash\ncase " $* " in *" --ack "*) "%s" 30 ;; esac\nexec "%s" "$@"\n' \
    "$REAL_SLEEP" "$REPO_ROOT/skills/orch/scripts/lane-mail" > "$STUB_DIR/lane-mail-held"
  chmod +x "$STUB_DIR/lane-mail-held"
  ( run_watch OVERSEE_WATCH_LANE_MAIL="$STUB_DIR/lane-mail-held" -- --max-loops 1 \
      >"$TMP_ROOT/o-$1" 2>"$TMP_ROOT/e-$1" ) &
  LIVE_PIDS+=" $!"
  ack=""
  for _ in $(seq 1 100); do
    ack="$(descendant "$!" 'lane-mail-held .*--ack')"
    [[ -z "$ack" ]] || break
    "$REAL_SLEEP" 0.1
  done
  pass="$(descendant "$!" 'oversee-watch --interval')"
  held="$(descendant "${ack:-0}" 'sleep 30$')"
  LIVE_PIDS+=" $held"
  kill -TERM "$ack" "$held" "$pass" 2>/dev/null || true
  gone_within "$pass"
  ACK_STOP="ack=${ack:+found} pass=$STATES printed=$(grep -c '^EVENT owner-note ' "$TMP_ROOT/o-$1" || true)"
  ACK_STOP+=" again=$(run_watch -- --max-loops 1 2>/dev/null | grep -c '^EVENT owner-note ' || true)"
}
ack_stop_case ack_stop
assert_eq "$ACK_STOP" "ack=found pass=gone printed=1 again=1" \
  "a stop between the print and the ack reports the note, and the next reader reports it again" "$TMP_ROOT/e-ack_stop"

# The same stop on a lane's notice, whose mail row is committed only once its
# lines are out: a `sed` shim holds the payload's indent, the one call of that
# shape, after the event line is printed and is killed with its pass. The next
# run reports the notice again.
lane_stop_case() { # NAME
  local pass held
  new_case "$1"
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  mkdir -p -- "$CASE_REPO_ROOT/tmp/lane-mail/KEN-7" "$STUB_DIR/bin"
  (cd "$CASE_REPO_ROOT" && "$REPO_ROOT/skills/orch/scripts/lane-mail" notice --item KEN-7 \
    --file "$TMP_ROOT/note.txt" >/dev/null)
  printf '#!/usr/bin/env bash\n[[ "$*" != "s/^/  /" ]] || exec "%s" 30\nexec "%s" "$@"\n' \
    "$REAL_SLEEP" "$(command -v sed)" > "$STUB_DIR/bin/sed"
  chmod +x "$STUB_DIR/bin/sed"
  ( run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --item KEN-7 \
      >"$TMP_ROOT/o-$1" 2>"$TMP_ROOT/e-$1" ) &
  LIVE_PIDS+=" $!"
  held=""
  for _ in $(seq 1 100); do
    held="$(descendant "$!" 'sleep 30$')"
    [[ -z "$held" ]] || break
    "$REAL_SLEEP" 0.1
  done
  pass="$(descendant "$!" 'oversee-watch --interval')"
  LIVE_PIDS+=" $held"
  kill -TERM "$held" "$pass" 2>/dev/null || true
  gone_within "$pass"
  LANE_STOP="held=${held:+found} pass=$STATES printed=$(grep -c '^EVENT lane-notice KEN-7 ' "$TMP_ROOT/o-$1" || true)"
  LANE_STOP+=" again=$(run_watch -- --max-loops 1 --item KEN-7 2>/dev/null |
    grep -c '^EVENT lane-notice KEN-7 ' || true)"
}
lane_stop_case lane_stop
assert_eq "$LANE_STOP" "held=found pass=gone printed=1 again=1" \
  "a stop between a lane notice's print and its row commit reports it, and the next run reports it again" \
  "$TMP_ROOT/e-lane_stop"

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

# take_case NAME ORIGIN PANE — a watch of ORIGIN recorded for PANE with output
# waiting beside the state, %9 the one pane tmux lists, and a start from %9.
# ORIGIN none records no watch at all.
take_case() { # NAME ORIGIN PANE
  new_case "$1"
  sleep_stub
  fleet_state
  printf '%s\n' "${TAKE_PANES:-7000 %9}" > "$STUB_DIR/panes.txt"
  printf 'EVENT lane-question KEN-1 m-1\n  a question the restarted watch reported\n' > "$STUB_DIR/oversee-watch.log"
  printf 'oversee-succeed: watch-restarted pid=1 pane=%%9\n' > "$STUB_DIR/oversee-watch.err"
  printf 'runner=setsid\nline=runner=setsid reason=no-linger\n' > "$STUB_DIR/oversee-watch.runner"
  OLD=""
  if [[ "$2" != none ]]; then
    # Two forks deep, so the stopped stand-in is reaped by init and not left a
    # zombie this shell would still answer kill -0 for.
    ( "$FIXTURE_WATCH" "$STUB_DIR/state.json" "$3" "$2" "$STUB_DIR/fixture.log" & )
    OLD="$(wait_for_record)"
    LIVE_PIDS+=" $OLD"
  fi
  err="$TMP_ROOT/e-$1"
  out="$(repeat_watch_run ${TAKE_ENV[@]+"${TAKE_ENV[@]}"} TMUX_PANE=%9 LIFECYCLE_SLEEP_FAIL=1 -- 2>"$err")" && rc=0 || rc=$?
}
stopped() { cat "$STUB_DIR/fixture.log" 2>/dev/null || echo no; }
# Whether any of the files a restart leaves beside the state is still there.
leftover() {
  local f
  for f in log err runner; do [[ ! -e "$STUB_DIR/oversee-watch.$f" ]] || { echo left; return; }; done
  echo removed
}

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

# The same takeover from OUTSIDE tmux, ORCH_TMUX_SESSION naming the fleet: the
# person's server lists the panes just the same, so a stale record whose pane
# it no longer lists is taken over, not refused watch-running. watch_pane_gone
# gates on the same tmux_server_named its sibling checks read.
TAKE_ENV=(TMUX= ORCH_TMUX_SESSION=main)
take_case take_pane_gone_setting hand %8
assert_eq "stopped=$(stopped) taken=$(grep -c "^oversee-watch: watch-taken-over pid=$OLD pane=%8 reason=pane-gone\$" "$err")" \
  "stopped=stopped taken=1" "outside tmux with the setting, a pane the server no longer lists is taken over" "$err"
unset TAKE_ENV

take_case take_hand hand %9
assert_eq "rc=$rc refused=$(grep -c "^oversee-watch: watch-running pid=$OLD pane=%9 " "$err") stopped=$(stopped) out=${out:-none}" \
  "rc=2 refused=1 stopped=no out=none" "a watch serving a live pane, started by hand, is refused" "$err"
kill -TERM "$OLD" 2>/dev/null || true

# A succession watch serving ANOTHER live pane is not this start's to replace.
TAKE_PANES=$'7000 %8\n7000 %9' take_case take_other_pane succession %8
assert_eq "rc=$rc refused=$(grep -c "^oversee-watch: watch-running pid=$OLD pane=%8 " "$err") stopped=$(stopped)" \
  "rc=2 refused=1 stopped=no" "a watch a succession restarted for another live pane is refused" "$err"
kill -TERM "$OLD" 2>/dev/null || true

# A record whose pid now runs something that is no watch, a pid reused after
# the watch died without removing it, refuses nothing and stops nothing.
reused_case() { # NAME
  local canon
  new_case "$1"
  sleep_stub
  fleet_state
  printf '7000 %%9\n' > "$STUB_DIR/panes.txt"
  ( "$REAL_SLEEP" 60 & echo "$!" > "$STUB_DIR/sleep.pid" )
  REUSED="$(cat "$STUB_DIR/sleep.pid")"
  LIVE_PIDS+=" $REUSED"
  canon="$(cd "$STUB_DIR" && pwd -P)/state.json"
  printf 'pid=%s\nstate=%s\npane=%%9\norigin=hand\n' "$REUSED" "$canon" > "$STUB_DIR/oversee-watch.pid"
  err="$TMP_ROOT/e-$1"
  out="$(repeat_watch_run TMUX_PANE=%9 LIFECYCLE_SLEEP_FAIL=1 -- 2>"$err")" && rc=0 || rc=$?
}
reused_case take_reused_pid
assert_eq "refused=$(grep -c '^oversee-watch: watch-running' "$err") sleep=$(kill -0 "$REUSED" 2>/dev/null && echo alive || echo gone)" \
  "refused=0 sleep=alive" "a recorded pid that runs no watch is neither refused on nor stopped" "$err"
kill -TERM "$REUSED" 2>/dev/null || true

# The restarted watch already ended, its successor dead before starting a
# watch of its own: what it printed is still handed to the next start.
take_case take_exited none ''
assert_eq "$(grep -c '^oversee-watch: watch-replayed ' "$err")|$(sed -n 1p <<<"$out")|$(leftover)" \
  "1|EVENT lane-question KEN-1 m-1|removed" "output a restarted watch left behind is printed by a start with no live watch" "$err"

# --- the output of a watch a succession started -------------------------------
# The real watch started the way oversee-succeed's helper starts it: repeat
# mode, OVERSEE_WATCH_ORIGIN=succession, stdout and stderr appended to the
# files beside the state. It writes those files, so it must never print or
# remove them itself; its first pass then runs, and a later start from the
# same pane prints what it wrote. Started as a process group of its own, so a
# case can end it and everything under it.
if command -v perl >/dev/null 2>&1; then
  # shellcheck source=../../github/scripts/lib/group-leader.sh
  source "$REPO_ROOT/skills/github/scripts/lib/group-leader.sh"
  {
    printf '#!/usr/bin/env bash\necho "$$" > "$STUB_DIR/leader.pid"\nexec '
    printf '%q ' "${KENDEX_GROUP_LEADER[@]}"
    printf '"$LEADER_TARGET" "$@"\n'
  } > "$TMP_ROOT/bin/leader-watch.sh"
  chmod +x "$TMP_ROOT/bin/leader-watch.sh"
  restarted_case() { # NAME
    local i
    new_case "$1"
    sleep_stub
    fleet_state
    printf '7000 %%9\n' > "$STUB_DIR/panes.txt"
    ( WATCH_BIN="$TMP_ROOT/bin/leader-watch.sh" repeat_watch_run TMUX_PANE=%9 OVERSEE_WATCH_ORIGIN=succession \
        LEADER_TARGET="$WATCH_SRC" -- >>"$STUB_DIR/oversee-watch.log" 2>>"$STUB_DIR/oversee-watch.err" & )
    HELD=no
    for (( i = 0; i < 100; i++ )); do
      if grep -q '^EVENT heartbeat' "$STUB_DIR/oversee-watch.log" 2>/dev/null \
         && watch_pid_live "$STUB_DIR/state.json" && [[ "$WATCH_ORIGIN" == succession ]]; then
        HELD=yes
        break
      fi
      "$REAL_SLEEP" 0.1
    done
    LEADER="$(cat "$STUB_DIR/leader.pid" 2>/dev/null || true)"
  }
  end_leader() { [[ -z "${LEADER:-}" ]] || kill -KILL -- "-$LEADER" 2>/dev/null || true; }
  restarted_case restarted_output
  assert_eq "$HELD" "yes" "a watch a succession started runs its first pass with its record live" \
    "$STUB_DIR/oversee-watch.err"
  err="$TMP_ROOT/e-restarted_output_next"
  out="$(repeat_watch_run TMUX_PANE=%9 LIFECYCLE_SLEEP_FAIL=1 -- 2>"$err")" && rc=0 || rc=$?
  assert_eq "taken=$(grep -c '^oversee-watch: watch-taken-over .* reason=succession$' "$err") printed=$(grep -c '^EVENT heartbeat' <<<"$out") $(leftover)" \
    "taken=1 printed=2 removed" "the next start from its pane stops it and prints what it wrote" "$err"
  end_leader
else
  printf '  skip  the restarted-watch rows need perl\n'
fi

# --- the watch as a job unit ---------------------------------------------------
# The repeat watch started as an overseer starts it: through the launch fence
# of references/waiter-launch.md, which runs it under the orch job runner, once
# as a systemd user unit where a user manager answers on this host, behind a
# loginctl that says it lingers, and once under setsid behind a systemd-run
# that fails, as a host with no manager has. A host with no manager skips the
# unit rows and says so; a host with no setsid has no runner and skips them
# all.
awk '/^```sh$/ { a = 1; n++; next } /^```$/ && a { a = 0; next } a { print } END { if (n != 1) exit 1 }' \
  "$REPO_ROOT/skills/orch/references/waiter-launch.md" > "$TMP_ROOT/launch.sh"
mkdir -p "$TMP_ROOT/no-manager" "$TMP_ROOT/lingering"
printf '#!/bin/sh\necho "Failed to connect to bus: No medium found" >&2\nexit 1\n' > "$TMP_ROOT/no-manager/systemd-run"
printf '#!/bin/sh\necho yes\n' > "$TMP_ROOT/lingering/loginctl"
cp "$TMP_ROOT/lingering/loginctl" "$TMP_ROOT/no-manager/loginctl"
chmod +x "$TMP_ROOT/no-manager/systemd-run" "$TMP_ROOT"/lingering/loginctl "$TMP_ROOT"/no-manager/loginctl
# The fence, run as the watch command's launcher: FENCE_RUN_DIR is the run
# directory and FENCE_TARGET the oversee-watch it starts.
cat > "$TMP_ROOT/bin/fence-watch.sh" <<EOF
#!/usr/bin/env bash
exec sh "$TMP_ROOT/launch.sh" "\$FENCE_RUN_DIR/watch" "\$FENCE_TARGET" "\$@"
EOF
# A close that notes its start, holds until the case's release file exists,
# notes its end and exits SLOW_CLOSE_RC: it outlasts any stop bound until the
# case lets it go. It holds in a child process and fails when that child is
# signalled, as lane-close fails when its lane-host child dies.
cat > "$TMP_ROOT/bin/slow-close.sh" <<EOF
#!/usr/bin/env bash
printf 'started\n' >> "\$STUB_DIR/close.log"
bash -c 'while [[ ! -f "\$1/release" ]]; do "$REAL_SLEEP" 0.1; done' hold "\$STUB_DIR" || exit \$?
printf 'done\n' >> "\$STUB_DIR/close.log"
exit "\${SLOW_CLOSE_RC:-0}"
EOF
chmod +x "$TMP_ROOT/bin/fence-watch.sh" "$TMP_ROOT/bin/slow-close.sh"
# The repeat delay a fifth of a second, so a pass follows a pass; a start with
# LIFECYCLE_SLEEP_FAIL=1 ends after its first pass as sleep-failed. While the
# case's hold file exists the delay notes that it is held and waits, so a case
# can change the world between two passes.
unit_sleep_stub() {
  mkdir -p "$STUB_DIR/bin"
  cat > "$STUB_DIR/bin/sleep" <<EOF
#!/usr/bin/env bash
if [[ "\${OVERSEE_WATCH_SLEEP:-}" == repeat ]]; then
  [[ -z "\${LIFECYCLE_SLEEP_FAIL:-}" ]] || exit 3
  if [[ -f "\$STUB_DIR/hold" ]]; then
    echo held > "\$STUB_DIR/held"
    while [[ -f "\$STUB_DIR/hold" ]]; do "$REAL_SLEEP" 0.1; done
  fi
  exec "$REAL_SLEEP" 0.2
fi
exit 0
EOF
  chmod +x "$STUB_DIR/bin/sleep"
}
wait_file() { # PATH TRIES
  local i
  for (( i = 0; i < $2; i++ )); do
    [[ ! -s "$1" ]] || return 0
    "$REAL_SLEEP" 0.1
  done
  return 1
}
# fence_start RUNNER TARGET RUN_DIR [ENV=VAL...] -- [WATCH ARGS...] — the
# watch TARGET launched through the fence into RUN_DIR from pane %9.
fence_start() {
  local runner="$1" target="$2" dir="$3" prefix="$TMP_ROOT/lingering:"
  shift 3
  [[ "$runner" == systemd ]] || prefix="$TMP_ROOT/no-manager:"
  WATCH_BIN="$TMP_ROOT/bin/fence-watch.sh" repeat_watch_run \
    PATH="$prefix$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" FENCE_RUN_DIR="$dir" FENCE_TARGET="$target" \
    TMUX_PANE=%9 "$@" >/dev/null 2>&1
}
# The documented stop, the spans watch-delivery.md gives run as it gives them:
# the mark, the read, then stop-job on the record the launch wrote.
fence_stop() { # RUN_DIR
  local id="${1##*/waiter.}" leader
  printf 'stopped\n' > "$1/watch.exit"
  leader="$(pgrep -f "waiter[.]$id/watc[h] " || true)"
  [[ -n "$leader" && "$leader" != *$'\n'* ]] || return 0
  "$REPO_ROOT/skills/orch/scripts/lib/job-unit.sh" stop-job "$1/watch.runner" "$leader" "*waiter.$id/watch *" \
    >/dev/null 2>&1 || true
}

# A unit-started watch: its record names the pane TMUX_PANE gave it and the
# directory it was launched from, the log's first line names its runner and,
# under a unit, the run id; the documented read finds its launch shell, which
# leads the loop's group; a second start on the state is refused while it
# runs; and the documented stop ends it and its record.
unit_start_case() { # RUNNER
  local runner="$1" dir second read_out first
  new_case "unit_start_$runner"
  unit_sleep_stub
  fleet_state
  printf '7000 %%9\n' > "$STUB_DIR/panes.txt"
  dir="$(mktemp -d "$STUB_DIR/waiter.XXXXXX")"
  fence_start "$runner" "$WATCH_SRC" "$dir" --
  LOOP="$(wait_for_record)"
  LIVE_PIDS+=" $LOOP"
  first="$(sed -n 1p "$dir/watch.log")"
  case "$runner" in
    systemd) first="${first%-*}" ;;
    setsid) first="${first%% detail=*}" ;;
  esac
  assert_eq "record=${LOOP:+yes} $(sed -n 's/^pane=//p; s/^cwd=//p' "$STUB_DIR/oversee-watch.pid" | tr '\n' ' ')first=$first" \
    "record=yes %9 $TMP_ROOT/repo first=$( [[ "$runner" == systemd ]] && echo "runner=systemd unit=orch-watch-${dir##*/waiter.}" || echo "runner=setsid reason=probe-failed")" \
    "runner=$runner: a watch the fence starts serves the pane TMUX_PANE names, from the launch directory, and its log names the runner" "$dir/watch.log"
  read_out="$(pgrep -f "waiter[.]${dir##*/waiter.}/watc[h] " || true)"
  assert_eq "$([[ -n "$read_out" && "$read_out" != *$'\n'* ]] && ps -o pgid= -p "$LOOP" | tr -d ' ')" "$read_out" \
    "runner=$runner: the documented read finds one launch shell, which leads the loop's group"
  second="$(mktemp -d "$STUB_DIR/waiter.XXXXXX")"
  fence_start "$runner" "$WATCH_SRC" "$second" --
  wait_file "$second/watch.exit" 100 || true
  assert_eq "exit=$(cat "$second/watch.exit" 2>/dev/null) refused=$(grep -c "^oversee-watch: watch-running pid=$LOOP " "$second/watch.log") first=$(kill -0 "$LOOP" 2>/dev/null && echo alive || echo gone)" \
    "exit=2 refused=1 first=alive" "runner=$runner: a second fence start on the state is refused and the first runs on" "$second/watch.log"
  fence_stop "$dir"
  for _ in $(seq 1 100); do kill -0 "$LOOP" 2>/dev/null || break; "$REAL_SLEEP" 0.1; done
  assert_eq "loop=$(kill -0 "$LOOP" 2>/dev/null && echo alive || echo gone) read=$(pgrep -f "waiter[.]${dir##*/waiter.}/watc[h] " >/dev/null && echo live || echo none) record=$([[ -f "$STUB_DIR/oversee-watch.pid" ]] && echo left || echo removed) exit=$(cat "$dir/watch.exit")" \
    "loop=gone read=none record=removed exit=stopped" "runner=$runner: the documented stop ends the watch and its record, and the mark stands" "$dir/watch.log"
}

# A takeover while the old watch's pass is part way through a hosted lane's
# close, which holds until the case releases it: past WATCH_STOP_SECS, which
# a private copy of lib/watch-pid.sh sets to 1, so the takeover shows the stop waits for the
# record and not for the close. The old watch is the one a succession
# restarted for %9, which a start from %9 takes over. Its first pass learns
# the lane's clone from the worktree and sees the lane exit; the worktree
# then goes, and the second pass reports the exit and closes the lane. The
# new start runs one pass. Sets TAKEN; AT_EXIT, close.log as the old watch's
# exit status lands; OLD_EXIT; CLOSES, the closes made; and EVENT and FAILED,
# the lane-closed and lane-close-failed lines the old watch's log carries.
unit_takeover_case() { # NAME RUNNER TARGET CLOSE_RC
  local name="$1" runner="$2" target="$3" dir err host_env new_pid
  new_case "$name"
  unit_sleep_stub
  fleet_state
  printf '7000 %%9\n' > "$STUB_DIR/panes.txt"
  mkdir -p "$STUB_DIR/remote/srv/clone/tmp/lane-mail/issue-1" "$STUB_DIR/remote/srv/lane/issue-1"
  printf 'gitdir: /srv/clone/.git/worktrees/issue-1\n' > "$STUB_DIR/remote/srv/lane/issue-1/.git"
  touch "$STUB_DIR/hold"
  printf '{"handoff":{"written_at":"t"}}\n' > "$STUB_DIR/remote/srv/clone/tmp/workflow-state-issue-1.json"
  printf 'bash\n' > "$STUB_DIR/cmd-gh-1.txt"
  printf '[{"number": 1, "headRefName": "issue-1", "mergedAt": "2026-09-14T10:00:00Z"}]\n' > "$STUB_DIR/merged.json"
  host_env=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote"
    OVERSEE_WATCH_LANE_CLOSE="$TMP_ROOT/bin/slow-close.sh" SLOW_CLOSE_RC="$4")
  dir="$(mktemp -d "$STUB_DIR/waiter.XXXXXX")"
  fence_start "$runner" "$target" "$dir" OVERSEE_WATCH_ORIGIN=succession "${host_env[@]}" \
    -- --item issue-1 --hosted issue-1=/srv/lane/issue-1 gh-1
  wait_file "$STUB_DIR/held" 200 || true
  rm -rf -- "${STUB_DIR:?}/remote/srv/lane/issue-1" "${STUB_DIR:?}/hold"
  wait_file "$STUB_DIR/close.log" 200 || true
  err="$TMP_ROOT/e-$name"
  ( WATCH_BIN="$target" repeat_watch_run PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" TMUX_PANE=%9 LIFECYCLE_SLEEP_FAIL=1 \
      "${host_env[@]}" -- --item issue-1 --hosted issue-1=/srv/lane/issue-1 gh-1 >/dev/null 2>"$err"
    echo "$?" > "$STUB_DIR/new.rc" ) &
  new_pid=$!
  for _ in $(seq 1 100); do
    grep -q '^oversee-watch: watch-taken-over ' "$err" 2>/dev/null || [[ -s "$STUB_DIR/new.rc" ]] && break
    "$REAL_SLEEP" 0.1
  done
  TAKEN="$(grep -c '^oversee-watch: watch-taken-over .* reason=succession$' "$err" || true)"
  OLD_LOOP="$(sed -n 's/^oversee-watch: watch-taken-over pid=\([0-9]*\) .*/\1/p' "$err")"
  # The close is held until the old watch exits, which reads close.log at that
  # exit, or the new start ends, or three seconds pass with neither; then it is
  # released, and read when the old watch exits.
  AT_EXIT=""
  for _ in $(seq 1 30); do
    [[ ! -s "$dir/watch.exit" && ! -s "$STUB_DIR/new.rc" ]] || break
    "$REAL_SLEEP" 0.1
  done
  [[ ! -s "$dir/watch.exit" ]] || AT_EXIT="$(tr '\n' ' ' < "$STUB_DIR/close.log")"
  echo release > "$STUB_DIR/release"
  if [[ -z "$AT_EXIT" ]]; then
    wait_file "$dir/watch.exit" 100 || true
    AT_EXIT="$(tr '\n' ' ' < "$STUB_DIR/close.log")"
  fi
  OLD_EXIT="$(cat "$dir/watch.exit" 2>/dev/null || echo none)"
  wait "$new_pid" 2>/dev/null || true
  FINISHING="$(grep -c "^oversee-watch: watch-finishing pid=${OLD_LOOP:-none}\$" "$err" || true)"
  CLOSES="$(grep -c '^started$' "$STUB_DIR/close.log" || true)"
  EVENT="$(grep -c '^EVENT lane-closed issue-1$' "$dir/watch.log" || true)"
  FAILED="$(grep -c "^oversee-watch: lane-close-failed item=issue-1 exit=$4\$" "$dir/watch.log" || true)"
  fence_stop "$dir"
}

if command -v setsid >/dev/null 2>&1 && command -v pgrep >/dev/null 2>&1; then
  mutant short_stop lib/watch-pid.sh 'WATCH_STOP_SECS=10' 'WATCH_STOP_SECS=1'
  SHORT="$(dirname "$MUTANT")"
  RUNNERS=setsid
  if systemd-run --user --quiet --collect true </dev/null >/dev/null 2>&1; then
    RUNNERS="systemd setsid"
  else
    printf '  skip  no systemd user manager answers on this host; the runner=systemd rows did not run\n'
  fi
  for runner in $RUNNERS; do
    unit_start_case "$runner"
    unit_takeover_case "takeover_$runner" "$runner" "$SHORT/oversee-watch" 0
    assert_eq "taken=$TAKEN finishing=$FINISHING old=$OLD_EXIT at-exit=$AT_EXIT event=$EVENT" "taken=1 finishing=1 old=143 at-exit=started done  event=1" \
      "runner=$runner: a takeover during a lane-close outlasting the stop bound takes over, and the old watch reports the close before it exits" "$TMP_ROOT/e-takeover_$runner"
  done
  unit_takeover_case takeover_failed setsid "$SHORT/oversee-watch" 5
  assert_eq "taken=$TAKEN finishing=$FINISHING failed=$FAILED closes=$CLOSES" "taken=1 finishing=1 failed=1 closes=2" \
    "a close that fails during a takeover is reported, and the watch that took over retries it" "$TMP_ROOT/e-takeover_failed"
else
  printf '  skip  the job-unit rows need setsid and pgrep\n'
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
