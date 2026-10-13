#!/usr/bin/env bash
# Tests for oversee-watch's overseer record fallback contract.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# mutant_scripts and mutate_file, the two halves of the one control below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"
# The fleet log's `at` is written by `workflow-state append-file`, not by the
# publisher here, so a row that checks it reads the stamp back through the
# same ladder every other reader of that field uses.
# shellcheck source=../scripts/lib/date-ladder.sh
source "$REPO_ROOT/skills/orch/scripts/lib/date-ladder.sh"
# OL_DEFAULT_PREFERENCE, the ladder an unset preference walks, for the mark
# row that reads it back.
# shellcheck source=../scripts/lib/overseer-launch.sh
source "$REPO_ROOT/skills/orch/scripts/lib/overseer-launch.sh"

# The pane, the oversee-succeed stub, overseer_case and run.
# shellcheck source=lib/overseer-watch-case.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/overseer-watch-case.sh"


# --- a record the start cannot write is a notice, and the pane is still judged
# A start that cannot build or record its command leaves the record as it
# stood and says so, on stderr and in the fleet log, and then watches the
# session it was started from. These records name no rows file, so its death
# and its wall are read off the pane, the named fallback. What the failed record costs is the line a dead-pane
# relaunch replays, and only where the fleet state holds none. A refusal here
# would leave the overseer unwatched with every lane still working, over a
# pane whose harness the builder could not name.
# The builder sits at a path of at least 120 bytes, as an install under a deep
# home or organisation directory does: the stderr line names it, and the
# fleet log row, held to ORCH_FLEET_LOG_ROW_BYTES, carries the reason and
# pane without it and still lands.
LONG_SUCCEED_DIR="$TMP_ROOT/deep"
while (( ${#LONG_SUCCEED_DIR} < 104 )); do LONG_SUCCEED_DIR+="/install-dir"; done
LONG_SUCCEED="$LONG_SUCCEED_DIR/oversee-succeed"
mkdir -p "$LONG_SUCCEED_DIR" && cp "$TMP_ROOT/bin/succeed-stub.sh" "$LONG_SUCCEED"
overseer_case record_derivation_failure idle
state_with "$BYPASS_LINE"
touch "$STUB_DIR/succeed.print-fail"
run TMUX_PANE="$PANE" OVERSEE_WATCH_SUCCEED="$LONG_SUCCEED" -- --max-loops 2 -- --model fable
assert_eq "rc=$RC events=$(grep -c '^EVENT overseer-dead' <<<"$OUT" || true) launched=$(succeed_calls --dead-pane)" \
  "rc=0 events=0 launched=0" "a line the builder cannot build does not stop the watch" "$ERR"
assert_eq "$(grep -c -x -F -- "oversee-watch: overseer-line-missing pane=$PANE path=$LONG_SUCCEED held=$BYPASS_LINE" "$ERR")" "1" \
  "and is noted once on stderr, naming the builder's path and the line a death would replay" "$ERR"
assert_eq "$(grep -c "^oversee-succeed: harness-unnamed pane=" "$ERR")" "1" \
  "with the builder's own refusal under it" "$ERR"
assert_eq "$(fleet_log_kind)|$(fleet_log_text | cut -d: -f1)|$(grep -c '^oversee-watch: overseer-notice-failed' "$ERR")" "close|overseer-line-missing pane=$PANE|0" \
  "and in the fleet log under the same reason and pane, the path left out so a deep install still fits the row" "$ERR"
assert_eq "$(recorded launch_line)" "$BYPASS_LINE" \
  "the line the fleet state already held is left where it was" "$ERR"
assert_contains "$(fleet_log_text)" "A line is held for this pane, at overseer.pending.launch_line if set, else overseer.launch_line." \
  "and the fleet log row says a line is held, and where" "$ERR"
# The held line's read with its own start emptied: this pane's bound record
# reads as another session's, and the notice says no line is held.
HELDSTART_CTL="$(mutant_scripts heldstart-ctl/orch lib/watch-overseer-record.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/heldstart-ctl/github"
mutate_file "$HELDSTART_CTL/lib/watch-overseer-record.sh" \
  'if overseer_record_read "$server" "$start" "$pane"; then' 'if overseer_record_read "$server" "" "$pane"; then'
overseer_case record_derivation_failure_start_mutant idle
state_with "$BYPASS_LINE"
touch "$STUB_DIR/succeed.print-fail"
WATCH_BIN="$HELDSTART_CTL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2 -- --model fable
assert_eq "$(grep -c -- "^oversee-watch: overseer-line-missing pane=$PANE .* held=none\$" "$ERR")" "1" \
  "control: a held-line read judged on no start says no line is held for this pane" "$ERR"

# The line held is what a death then replays: a start whose pane already
# reads exited cannot build a line, since a dead pane names no harness,
# and the death is reported and recovered from the recorded one all the same.
# Through repeat mode, which is where a start records and then watches.
overseer_case record_failure_dead exited
state_with "$LINE"
jq -n '{issue_id: "oversee", triaged: [], lanes: []}' > "$STUB_DIR/state.json"
run TMUX_PANE="$PANE" -- --max-loops 2 --repeat 0 --state "$STUB_DIR/state.json"
assert_eq "rc=$RC events=$(grep -c '^EVENT overseer-dead' <<<"$OUT" || true) launched=$(succeed_calls --dead-pane)" \
  "rc=0 events=1 launched=1" "a start on a dead pane notes the missing line and still relaunches the overseer" "$ERR"
assert_eq "$(grep -c "^oversee-watch: overseer-line-missing pane=$PANE" "$ERR")" "1" \
  "the notice is on stderr" "$ERR"
assert_eq "$(cat "$STUB_DIR/succeed.line-file")" "$LINE" \
  "and the relaunch sent the line the fleet state held" "$ERR"

# The held line is replayed only where the record binds it to THIS pane on
# THIS server. A record naming another session is that session's, and its
# line carries that session's account and permission words: a start whose
# print fails leaves such a record standing, and the death here is reported
# with no successor, naming that record, rather than relaunched as the other
# session. Two rows, one per half of the binding: another pane on this
# server, and this pane id on another server, which is the record a previous
# tmux server left behind, pane ids restarting at %0 on the next. The same
# row shape as the one above, the record's key the one difference.
# A third row binds this pane id on this pid to an earlier server's start.
other_dead_run() { # SERVER PANE START [WATCH_BIN]
  overseer_case "record_failure_dead_other_$1_${2#%}_$3${4:+_mutant}" exited
  jq -n --arg window "$WINDOW" --arg line "$BYPASS_LINE" --arg server "$1" --arg pane "$2" --arg start "$3" \
    '{triaged: [], overseer: {server: $server, pane: $pane, window: $window, launch_line: $line,
      server_start: ($start | tonumber)}}' \
    > "$STUB_DIR/oversee-state.json"
  jq -n '{issue_id: "oversee", triaged: [], lanes: []}' > "$STUB_DIR/state.json"
  WATCH_BIN="${4:-}" run TMUX_PANE="$PANE" -- --max-loops 2 --repeat 0 --state "$STUB_DIR/state.json"
}
for row in "7000|%4|1790000000|another pane" "7001|$PANE|1790000000|this pane id on another server" \
  "7000|$PANE|1789996400|this pane id on an earlier server handed the same pid"; do
  IFS='|' read -r row_server row_pane row_start row_what <<<"$row"
  other_dead_run "$row_server" "$row_pane" "$row_start"
  assert_eq "rc=$RC event=$(grep '^EVENT overseer-dead' <<<"$OUT" || true) launched=$(succeed_calls --dead-pane) noted=$(grep -c -x -F -- "oversee-watch: overseer-line-missing pane=$PANE path=$TMP_ROOT/bin/succeed-stub.sh held=none" "$ERR")" \
    "rc=0 event=EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=pane record=$row_server:$row_pane launched=0 noted=1" \
    "a death over a record naming $row_what is reported with that record and never relaunched from its line" "$ERR"
  assert_contains "$(fleet_log_text)" "The fleet state record names another session, tmux server $row_server pane $row_pane, whose launch line is not replayed as this pane's, so no successor is launched; start one by hand." \
    "and the notice names the record that stood in the way" "$ERR"
  assert_contains "$(jq -r '.fleet_log[] | select(.item == "overseer") | .text' "$STUB_DIR/oversee-state.json")" "No line is held for this pane." \
    "and the start's fleet log row, ahead of the death's, says no line is held for this pane" "$ERR"
done
# The first watch of a fleet, whose state holds no overseer record since no
# launch, succession, watch start or `oversee register` wrote one yet, started
# on a pane that already reads exited: the death names no record and no
# successor is launched.
overseer_case record_failure_dead_none exited
printf '{"triaged":[]}\n' > "$STUB_DIR/oversee-state.json"
jq -n '{issue_id: "oversee", triaged: [], lanes: []}' > "$STUB_DIR/state.json"
run TMUX_PANE="$PANE" -- --max-loops 2 --repeat 0 --state "$STUB_DIR/state.json"
assert_eq "rc=$RC event=$(grep '^EVENT overseer-dead' <<<"$OUT" || true) launched=$(succeed_calls --dead-pane)" \
  "rc=0 event=EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=pane record=none launched=0" \
  "a death over a fleet state with no overseer record is reported as such and never relaunched" "$ERR"
assert_contains "$(fleet_log_text)" "The fleet state holds no overseer record, so no successor is launched; start one by hand." \
  "and the notice says the state holds no record" "$ERR"
# Two controls on the shared reader, one per half. A reader that takes the
# held line whatever record stands relaunches the other session's full-bypass
# line into this window on both rows; one that compares the pane id alone
# passes the other-pane row and replays the previous server's line on the
# other-server row.
PANE_MUTANT="$(mutant_scripts mutant-pane/orch lib/watch-overseer-record.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mutant-pane/github"
mutate_file "$PANE_MUTANT/lib/watch-overseer-record.sh" \
  'else "" end) ]' 'else ($o.pending.launch_line // $o.launch_line // "") end) ]'
for row in "7000|%4" "7001|$PANE"; do
  IFS='|' read -r row_server row_pane <<<"$row"
  other_dead_run "$row_server" "$row_pane" 1790000000 "$PANE_MUTANT/oversee-watch"
  assert_eq "launched=$(succeed_calls --dead-pane) line=$(cat "$STUB_DIR/succeed.line-file" 2>/dev/null || echo none)" \
    "launched=1 line=$BYPASS_LINE" \
    "control: a reader that takes the line whatever record stands replays the other session's command over $row_server $row_pane" "$ERR"
done
SERVER_MUTANT="$(mutant_scripts mutant-server/orch lib/watch-overseer-record.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mutant-server/github"
mutate_file "$SERVER_MUTANT/lib/watch-overseer-record.sh" \
  $'($o | ol_names("\'"$1"\'"; "\'"$2"\'"; "\'"$3"\'"))' $'(($o.pane // $o.session // "") == "\'"$3"\'")'
other_dead_run 7001 "$PANE" 1790000000 "$SERVER_MUTANT/oversee-watch"
assert_eq "launched=$(succeed_calls --dead-pane) line=$(cat "$STUB_DIR/succeed.line-file" 2>/dev/null || echo none)" \
  "launched=1 line=$BYPASS_LINE" \
  "control: a reader that compares the pane id alone replays the previous server's command" "$ERR"
# The notice's control: one that takes any record for this session's own says
# the earlier server's record is this pane's with no line.
MINE_CTL="$(mutant_scripts mine-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mine-ctl/github"
mutate_file "$MINE_CTL/oversee-watch" '      elif [[ "$7" == 1 ]]; then' '      elif [[ -n "$7" ]]; then'
other_dead_run 7000 "$PANE" 1789996400 "$MINE_CTL/oversee-watch"
assert_contains "$(fleet_log_text)" "The fleet state record for this pane holds no launch line" \
  "control: a notice that ignores whether the record is this session's calls the earlier server's record this pane's" "$ERR"
# The start test's control on the same reader: ol_names without it replays
# the earlier server's command for the session now in its pane id.
READSTART_CTL="$(mutant_scripts readstart-ctl/orch lib/overseer-launch.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/readstart-ctl/github"
mutate_file "$READSTART_CTL/lib/overseer-launch.sh" \
  '    and (.server_start | tostring) == $start;' '    and true;'
other_dead_run 7000 "$PANE" 1789996400 "$READSTART_CTL/oversee-watch"
assert_eq "launched=$(succeed_calls --dead-pane) line=$(cat "$STUB_DIR/succeed.line-file" 2>/dev/null || echo none)" \
  "launched=1 line=$BYPASS_LINE" \
  "control: a reader that ignores the server start replays the earlier server's command" "$ERR"
# The relaunch's own start emptied: this pane's bound record reads as another
# session's, and the death is relaunched from no line.
DEADSTART_CTL="$(mutant_scripts deadstart-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/deadstart-ctl/github"
mutate_file "$DEADSTART_CTL/oversee-watch" 'overseer_record_read "${identity%% *}" "$OV_START" "$pane"' \
  'overseer_record_read "${identity%% *}" "" "$pane"'
overseer_case dead_relaunch_start_mutant exited
state_with "$LINE"
WATCH_BIN="$DEADSTART_CTL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "launched=$(succeed_calls --dead-pane)" "launched=0" \
  "control: a relaunch judged on no start never replays this pane's bound line" "$ERR"
# A pane whose server start cannot be read settles nothing that pass: judged
# on no start, its own bound record reads as another session's, and its death
# is reported with no line and never relaunched.
start_unread_dead_run() { # NAME [WATCH_BIN]
  overseer_case "$1" exited
  state_with "$LINE"
  touch "$STUB_DIR/start-fail-$PANE"
  WATCH_BIN="${2:-}" run TMUX_PANE="$PANE" -- --max-loops 2
}
start_unread_dead_run dead_start_unread
assert_eq "event=$(grep -c '^EVENT overseer-dead' <<<"$OUT") launched=$(succeed_calls --dead-pane) noted=$(grep -c "^oversee-watch: overseer-unreadable pane=$PANE field=server-start\$" "$ERR")" \
  "event=0 launched=0 noted=1" \
  "a dead pane whose server start cannot be read is noted unreadable and neither reported nor relaunched" "$ERR"
# Its control: a pane read that takes an unread start as none reports the
# death against its own record as another session's.
UNREADDEAD_CTL="$(mutant_scripts unreaddead-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/unreaddead-ctl/github"
mutate_file "$UNREADDEAD_CTL/oversee-watch" \
  '    || { overseer_note overseer-unreadable "pane=$pane" "field=server-start"; return 1; }' '    || OV_START=""'
start_unread_dead_run dead_start_unread_mutant "$UNREADDEAD_CTL/oversee-watch"
assert_eq "event=$(grep -c "^EVENT overseer-dead $PANE .* record=7000:$PANE\$" <<<"$OUT") launched=$(succeed_calls --dead-pane)" \
  "event=1 launched=0" \
  "control: a pane read that takes an unread start as none reports the death against another session's record" "$ERR"

# A walled overseer whose start could not record it: the wall is read from
# the pane and confirmed by the account judgement, and the recovery picks its
# own account, so the missing record costs it nothing. Once for a claude pane
# and once for a codex one, whose banner and composer are the usage-limit
# suite's fixture text.
CODEX_WALL_BANNER='Usage limit reached. Increase your limits to continue.'
CODEX_COMPOSER='\xe2\x80\xba Ask Codex to do anything'
for row in "claude|walled" "codex|walled_codex"; do
  IFS='|' read -r row_harness row_state <<<"$row"
  overseer_case "record_failure_walled_$row_harness" "$row_state"
  state_with "$LINE"
  touch "$STUB_DIR/succeed.print-fail"
  wall_confirmed
  jq -n '{issue_id: "oversee", triaged: [], lanes: []}' > "$STUB_DIR/state.json"
  run TMUX_PANE="$PANE" -- --max-loops 2 --repeat 0 --state "$STUB_DIR/state.json" -- --verbose
  assert_eq "rc=$RC events=$(grep -c '^EVENT overseer-walled' <<<"$OUT" || true) launched=$(succeed_calls --walled-pane) noted=$(grep -c "^oversee-watch: overseer-line-missing pane=$PANE" "$ERR") ended=$(grep -c "^oversee-watch: overseer-succeeded pane=$PANE" "$ERR")" \
    "rc=0 events=1 launched=1 noted=1 ended=1" \
    "a $row_harness overseer the start could not record is still read walled and recovered" "$ERR"
  assert_eq "$(cat "$STUB_DIR/succeed.launched")" \
    "--walled-pane $PANE --handoff $HANDOFF_DEFAULT -- --verbose" \
    "and the recovery carries the overseer's own flags" "$ERR"
done

# The control: a record library whose line-missing notice still ends the
# watch. The same walled pane is then never judged and no recovery runs.
REG_MUTANT="$(mutant_scripts mutant-reg/orch lib/watch-overseer-record.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mutant-reg/github"
mutate_file "$REG_MUTANT/lib/watch-overseer-record.sh" \
  '    overseer_record_notice "$detail" "$held" overseer-line-missing "pane=$pane" "path=$SUCCEED"' \
  '    overseer_record_notice "$detail" "$held" overseer-line-missing pane="$pane" "path=$SUCCEED"; exit 2'
overseer_case record_failure_walled_mutant walled
state_with "$LINE"
touch "$STUB_DIR/succeed.print-fail"
wall_confirmed
jq -n '{issue_id: "oversee", triaged: [], lanes: []}' > "$STUB_DIR/state.json"
WATCH_BIN="$REG_MUTANT/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2 --repeat 0 --state "$STUB_DIR/state.json" -- --verbose
assert_eq "rc=$RC launched=$(succeed_calls --walled-pane) noted=$(grep -c "^oversee-watch: overseer-line-missing pane=$PANE" "$ERR")" \
  "rc=2 launched=0 noted=1" \
  "control: a start that refuses on the missing line leaves the walled overseer unrecovered" "$ERR"

overseer_case record_write_failure idle
state_with "$BYPASS_LINE"
printf '2\n' > "$STUB_DIR/workflow-state.rc"
run TMUX_PANE="$PANE" -- --max-loops 2 -- --model fable
assert_eq "line=$(grep -c -x -F -- "oversee-watch: overseer-unrecorded pane=$PANE step=write held=unread" "$ERR") launched=$(succeed_calls --dead-pane)" \
  "line=1 launched=0" "a state-write failure is noted on its step and reaches no launcher; a state that fails every verb reads no held line" "$ERR"
assert_eq "$(grep -c "^oversee-watch: overseer-notice-failed channel=fleet-log\$" "$ERR")" "1" \
  "and the fleet log row that could not be written on the same state is named too" "$ERR"
assert_eq "$(recorded launch_line)" "$BYPASS_LINE" \
  "the failed write leaves the older line where it was" "$ERR"

# The window the record names is read on its own, after the key: a pane whose
# window tmux will not report, and one it reports as something that is not a
# window id, both leave the record unwritten rather than naming a window a
# successor cannot be opened in.
overseer_case record_window_unreadable idle
state_with "$BYPASS_LINE"
touch "$STUB_DIR/window-id-fail-$PANE"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC line=$(grep -c -x -F -- "oversee-watch: overseer-unrecorded pane=$PANE step=window held=$BYPASS_LINE" "$ERR")" \
  "rc=0 line=1" "a window tmux will not report leaves the record unwritten, naming the step and the line a death would replay" "$ERR"
assert_eq "$(grep -c "^E_WINDOW pane=$PANE\$" "$ERR")" "1" \
  "and tmux's own words are replayed under that line, not swallowed" "$ERR"
assert_eq "$(recorded launch_line)" "$BYPASS_LINE" \
  "and the older line is left where it was" "$ERR"

overseer_case record_window_malformed idle
state_with "$BYPASS_LINE"
printf 'window7\n' > "$STUB_DIR/window-id-$PANE.txt"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC line=$(grep -c -x -F -- "oversee-watch: overseer-unrecorded pane=$PANE step=window held=$BYPASS_LINE" "$ERR")" \
  "rc=0 line=1" "a window id that is not @N leaves the record unwritten on the same step" "$ERR"

# The key is read through the orch library, which discards tmux's stderr, so a
# notice there cannot replay it. It names the read that failed instead: a
# `step=identity` line with nothing under it leaves the operator no reason at
# all, which is the whole difference between these two steps.
overseer_case record_identity_unreadable idle
state_with "$BYPASS_LINE"
printf 'E_PID pane=%s\n' "$PANE" > "$STUB_DIR/pane-key-fail-$PANE"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC line=$(grep -c -x -F -- "oversee-watch: overseer-unrecorded pane=$PANE step=identity held=unread" "$ERR")" \
  "rc=0 line=1" "a key tmux will not answer leaves the record unwritten, naming the step; with no key the held line is unread" "$ERR"
assert_eq "$(grep -c "^tmux reported no server pid for pane $PANE\$" "$ERR")" "1" \
  "and the notice carries a reason of its own, since the library keeps tmux's" "$ERR"
assert_eq "$(recorded launch_line)" "$BYPASS_LINE" \
  "and the older line is left where it was" "$ERR"
assert_contains "$(fleet_log_text)" "Whether a line is held was not read." \
  "and the fleet log row says the held line was not read" "$ERR"

overseer_case record_identity_malformed idle
state_with "$BYPASS_LINE"
printf 'not-a-pid\n' > "$STUB_DIR/pane-key-$PANE.txt"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC line=$(grep -c -x -F -- "oversee-watch: overseer-unrecorded pane=$PANE step=identity held=unread" "$ERR")" \
  "rc=0 line=1" "a key that is not <pid> <pane> leaves the record unwritten on the same step" "$ERR"
assert_eq "$(grep -c "^the pane key read back as: not-a-pid $PANE\$" "$ERR")" "1" \
  "and the notice replays what it read" "$ERR"

# A death count from another tmux server does not apply to a pane number that
# the new server reused.
overseer_case death_new_server exited
state_with "$LINE"
run TMUX_PANE="$PANE" -- --max-loops 1
printf '8000 %s\n' "$PANE" > "$STUB_DIR/pane-key-$PANE.txt"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC launched=$(succeed_calls --dead-pane)" "rc=0 launched=0" \
  "a new server starts a new death count for its reused pane number" "$ERR"

# A watch started without --handoff records a line whose brief still points at
# a file: the default path is the one ../workflows/oversee.md § 5. Stop names.
overseer_case record_default_handoff idle
printf '{"triaged":[]}\n' > "$STUB_DIR/oversee-state.json"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "$(grep -- '^--print-launch-line' "$STUB_DIR/succeed.args")" \
  "--print-launch-line --handoff $HANDOFF_DEFAULT" \
  "a watch given no handoff path passes the workflow's own" "$ERR"


printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
