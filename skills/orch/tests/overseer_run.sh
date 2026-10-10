#!/usr/bin/env bash
# Tests for scripts/overseer-run, the wrapper every overseer launch line runs
# under: it hands back its command's own status, and writes that status into
# the oversee state's session record only where the record names the pane it
# runs in. tmux is a stub answering the server pid, and the server's start
# for lib/tmux-server.sh's read of it; workflow-state is the real script over
# a sandbox state directory.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
# mutant_scripts and mutate_file, the two halves of the control.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$TEST_DIR/../scripts" && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "overseer_run: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "overseer_run: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "overseer_run: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/state"
cat > "$TMP_ROOT/bin/tmux" <<'STUB'
#!/bin/sh
case "$*" in
  *'#{start_time}'*) printf '7000 1790000000\n' ;;
  *) printf '7000\n' ;;
esac
STUB
chmod +x "$TMP_ROOT/bin/tmux"

STATE="$TMP_ROOT/state/workflow-state-oversee.json"
# state PANE [START] — a fleet state whose record names PANE on server 7000,
# bound to the server started at START: by default the stub's own start,
# which every tmux record a launch, a watch start or `oversee register`
# writes carries, and `none` for a record carrying no start.
state() {
  jq -n --arg pane "$1" --arg start "${2:-1790000000}" '{issue_id: "oversee", overseer: ({runtime: "tmux", server: "7000", pane: $pane,
    window: "@1", launch_line: "claude"} + (if $start == "none" then {} else {server_start: ($start | tonumber)} end))}' > "$STATE"
}
exit_of() { jq -r '.overseer.exit.status // "none"' "$STATE"; }

# run [TMUX_PANE] -- COMMAND... — the wrapper from the sandbox, in that pane.
run() {
  local pane="$1"
  shift 2
  RC=0
  ERR="$TMP_ROOT/err"
  (cd "$TMP_ROOT" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$TMP_ROOT" PATH="$TMP_ROOT/bin:$PATH" ORCH_STATE_DIR="$TMP_ROOT/state" \
    ${pane:+TMUX=fake TMUX_PANE="$pane"} "${RUN_BIN:-$SCRIPTS/overseer-run}" "$@") >"$TMP_ROOT/out" 2>"$ERR" || RC=$?
}

echo "=== overseer-run ==="

# A record carrying no start names no session.
while IFS='|' read -r label recorded start pane want_rc want_exit; do
  state "$recorded" "$start"
  run "$pane" -- sh -c 'exit 7'
  assert_eq "rc=$RC exit=$(exit_of) err=$(wc -c < "$ERR" | tr -d ' ')" "rc=$want_rc exit=$want_exit err=0" "$label" "$ERR"
done <<'ROWS'
the record names this pane on this server's start: its status is written and handed back|%9|1790000000|%9|7|7
the record names this pane and carries no start: nothing is written|%9|none|%9|7|none
the record names this pane id on an earlier server handed the same pid: nothing is written|%9|1789996400|%9|7|none
the record names another pane: nothing is written|%3||%9|7|none
outside tmux: nothing is written|%9|||7|none
ROWS

state %9
run %9 -- true
assert_eq "rc=$RC exit=$(exit_of)" "rc=0 exit=0" "a clean exit is recorded as 0"
run %9 --
assert_eq "rc=$RC" "rc=2" "no command is a usage error"

# A status an earlier session in this pane left is dropped before the command
# runs: the command reads the record mid-run and exits 0 only where it is gone.
state_exit() { # PANE STATUS [START]
  state "$1" "${3:-}"
  jq --argjson s "$2" '.overseer.exit = {status: $s, at: "2026-09-28T01:00:00Z"}' "$STATE" > "$STATE.tmp"
  mv -- "$STATE.tmp" "$STATE"
}
CLEARED_CHECK="jq -e '.overseer.exit == null' '$STATE' >/dev/null"
state_exit %9 9
run %9 -- sh -c "$CLEARED_CHECK"
assert_eq "rc=$RC exit=$(exit_of)" "rc=0 exit=0" "a prior status in this pane is dropped before the line runs"
state_exit %3 9
run %9 -- sh -c "$CLEARED_CHECK"
assert_eq "rc=$RC exit=$(exit_of)" "rc=1 exit=9" "another pane's status is left where it stands"
state_exit %9 9 1789996400
run %9 -- sh -c "$CLEARED_CHECK"
assert_eq "rc=$RC exit=$(exit_of)" "rc=1 exit=9" "an earlier server's status for this pane id is left where it stands"

# A record that cannot be written is said under its key, and the status stands.
printf 'not json' > "$STATE"
run %9 -- sh -c 'exit 5'
assert_eq "rc=$RC keys=$(grep -o '^overseer-run: [a-z-]*=[a-z0-9]*' "$ERR" | tr '\n' ',')" \
  "rc=5 keys=overseer-run: exit-uncleared=pending,overseer-run: exit-unrecorded=5," \
  "an unwritable record is reported at both writes and the command's status handed back" "$ERR"

# --- control ----------------------------------------------------------------
# The start test removed from ol_names: an earlier server's record for this
# pane id takes the status.
START_CTL="$(mutant_scripts start-ctl lib/overseer-launch.sh)" || exit 1
mutate_file "$START_CTL/lib/overseer-launch.sh" \
  '    and (.server_start | tostring) == $start;' '    and true;'
state %9 1789996400
RUN_BIN="$START_CTL/overseer-run" run %9 -- sh -c 'exit 7'
assert_eq "exit=$(exit_of)" "exit=7" "control: without the start test an earlier server's record takes the status"

# Each writer's own start emptied, one control per call site: the bound
# record for this pane is no longer named, so the prior status stands through
# the line, and the line's status is never written.
CLEARSTART_CTL="$(mutant_scripts clearstart-ctl lib/overseer-launch.sh)" || exit 1
mutate_file "$CLEARSTART_CTL/lib/overseer-launch.sh" \
  'ol_names($server; $start; $pane)) then .overseer |= del(.exit)' 'ol_names($server; ""; $pane)) then .overseer |= del(.exit)'
state_exit %9 9
RUN_BIN="$CLEARSTART_CTL/overseer-run" run %9 -- sh -c "$CLEARED_CHECK"
assert_eq "rc=$RC" "rc=1" "control: a clear judged on no start leaves this pane's bound record its earlier status"
EXITSTART_CTL="$(mutant_scripts exitstart-ctl lib/overseer-launch.sh)" || exit 1
mutate_file "$EXITSTART_CTL/lib/overseer-launch.sh" \
  'ol_names($server; $start; $pane)) then .overseer.exit = {' 'ol_names($server; ""; $pane)) then .overseer.exit = {'
state %9
RUN_BIN="$EXITSTART_CTL/overseer-run" run %9 -- sh -c 'exit 7'
assert_eq "exit=$(exit_of)" "exit=none" "control: a write judged on no start leaves this pane's bound record without its status"

# The record's session test removed: another pane's record takes the status.
MUTANT="$(mutant_scripts mutant lib/overseer-launch.sh)" || exit 1
mutate_file "$MUTANT/lib/overseer-launch.sh" 'if (.overseer | ol_names($server; $start; $pane)) then .overseer.exit = {' 'if true then .overseer.exit = {'
state %3
RUN_BIN="$MUTANT/overseer-run" run %9 -- sh -c 'exit 7'
assert_eq "exit=$(exit_of)" "exit=7" "control: without the session test another pane's record takes the status"

# The clear removed from a copy of the wrapper: the prior status stands while
# the line runs.
CLEAR_CTL="$(mutant_scripts clear-ctl overseer-run)" || exit 1
mutate_file "$CLEAR_CTL/overseer-run" '    elif ! ol_record_exit_clear "${KEY%% *}" "${KEY#* }"; then' '    elif false; then'
state_exit %9 9
RUN_BIN="$CLEAR_CTL/overseer-run" run %9 -- sh -c "$CLEARED_CHECK"
assert_eq "rc=$RC" "rc=1" "control: without the clear the line runs under the earlier session's status"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
