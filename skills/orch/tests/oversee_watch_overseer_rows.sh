#!/usr/bin/env bash
# Tests for oversee-watch's overseer rows contract.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"
# The pane, the oversee-succeed stub, overseer_case and run.
# shellcheck source=lib/overseer-watch-case.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/overseer-watch-case.sh"

source "$(dirname "${BASH_SOURCE[0]}")/lib/overseer-row-world.sh"

# One table: the rows a file holds and the pane beside it, and what two passes
# make of them. The adapter's `inspect` snapshots the screen on every read;
# the note says whether the watch judged by it, the fallback, and every row
# whose rows judge says none.
while IFS='|' read -r name pane rows expected_event expected_launch expected_note; do
  set -f
  # shellcheck disable=SC2086  # the row names split into the row list.
  set -- $rows
  set +f
  row_args=()
  for r in "$@"; do
    case "$r" in
      start) row_args+=("$START") ;;
      end) row_args+=("$END_EXIT") ;;
      clear) row_args+=("$END_CLEAR") ;;
      wall) row_args+=("$FAILURE") ;;
      overloaded) row_args+=("$OVERLOADED") ;;
      toolong) row_args+=("$TOO_LONG") ;;
      toolongdetails) row_args+=("$TOO_LONG_DETAILS") ;;
      stop) row_args+=("$STOP") ;;
      codex) row_args+=("$CODEX_START") ;;
      pistart) row_args+=("$PI_START") ;;
      piend) row_args+=("$PI_END") ;;
      pistop) row_args+=("$PI_STOP") ;;
      -) ;;
      *) echo "unknown row $r" >&2; exit 1 ;;
    esac
  done
  rows_case "$name" "$pane" ${row_args[@]+"${row_args[@]}"}
  [[ "$name" != wall_rows ]] || no_room
  [[ "$name" != pi_stop_walled_pane ]] || wall_confirmed
  run TMUX_PANE="$PANE" -- --max-loops 2
  event="$(grep '^EVENT overseer-' <<<"$OUT" | head -n 1 || true)"
  note=none
  if grep -q '^oversee-watch: overseer-fallback ' "$ERR"; then
    note="$(grep '^oversee-watch: overseer-fallback ' "$ERR" | head -n 1 | sed 's/^oversee-watch: //')"
  fi
  assert_eq "event=${event:-none} launched=$(head -n 1 "$STUB_DIR/succeed.launched" 2>/dev/null | cut -d' ' -f1 || true) note=$note" \
    "event=$expected_event launched=$expected_launch note=$expected_note" \
    "$name" "$ERR"
done <<ROWS
dead_rows|exited|start end|EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=rows|--dead-pane|none
end_over_live|blank|start end|none||none
wall_rows|blank|start wall|EVENT overseer-walled $PANE window=$WINDOW passes=1 succession=on source=rows|--walled-pane|none
clear_is_live|blank|start clear|none||none
lifted_wall|blank|start wall stop|none||none
other_failure|blank|start overloaded|none||none
wedged_rows|blank|start toolong|EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=context|--dead-pane|none
wedged_details|blank|start toolongdetails|EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=context|--dead-pane|none
wedged_rows_exited|exited|start toolong|EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=process|--dead-pane|none
wedge_lifted|blank|start toolong stop|none||none
killed_process|exited|start|EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=process|--dead-pane|none
no_rows_fallback|exited|-|EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=pane|--dead-pane|overseer-fallback pane=$PANE cause=none
codex_fallback|exited|codex|EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=pane|--dead-pane|overseer-fallback pane=$PANE cause=unsupported
pi_dead_rows|exited|pistart piend|EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=rows|--dead-pane|none
pi_stop_walled_pane|walled|pistart pistop|EVENT overseer-walled $PANE window=$WINDOW passes=2 succession=on source=pane|--walled-pane|overseer-fallback pane=$PANE cause=unsupported
ROWS

# The verdict over a Pi session, SessionStart then one row, read from the
# library itself. A Pi row is judged only from the evidence it carries: a
# SessionEnd, or a StopFailure whose `message`, the failed response's text,
# alone tells a wall from a wedge, since Pi names no error kind. Every other
# Pi last row reads unsupported, so the pane judges it. The same rows under
# Copilot, whose rows the verdict does not answer for, read unsupported. Two
# controls, one per rule: with the Claude-only harness test restored every Pi
# row reads unsupported, and with the evidence rule taken out each row it
# holds reads live.
verdict_of() { # LIB_DIR HARNESS EVENT [FIELD]
  local file="$TMP_ROOT/verdict-rows.jsonl"
  { row SessionStart "$2" source=startup; row "$3" "$2" ${4:+"$4"}; } > "$file"
  "$BASH" -euo pipefail -c '. "$1/lane-state.sh" && . "$1/session-rows.sh"
    session_rows_verdict "$2" && printf "%s\n" "$SESSION_ROWS_VERDICT"' _ "$1" "$file" 2>&1 || echo "rc=$?"
}
LIB_DIR="$REPO_ROOT/skills/orch/scripts/lib"
CLAUDE_ONLY_CTL="$(mutant_scripts claude-only-ctl/orch lib/session-rows.sh)" || exit 1
mutate_file "$CLAUDE_ONLY_CTL/lib/session-rows.sh" \
  'if .harness != "claude" and .harness != "pi" then "unsupported"' 'if .harness != "claude" then "unsupported"'
EVIDENCE_CTL="$(mutant_scripts evidence-ctl/orch lib/session-rows.sh)" || exit 1
mutate_file "$EVIDENCE_CTL/lib/session-rows.sh" \
  'elif .harness == "pi" and (.event != "StopFailure" or (.message // "") == "") then "unsupported"' \
  'elif false then "unsupported"'
while IFS='|' read -r name event field expected without_rule; do
  [[ "$field" != - ]] || field=""
  pi="$(verdict_of "$LIB_DIR" pi "$event" "$field")"
  copilot="$(verdict_of "$LIB_DIR" copilot "$event" "$field")"
  claude_only="$(verdict_of "$CLAUDE_ONLY_CTL/lib" pi "$event" "$field")"
  evidence="$(verdict_of "$EVIDENCE_CTL/lib" pi "$event" "$field")"
  assert_eq "pi=$pi copilot=$copilot" "pi=$expected copilot=unsupported" "pi row $name"
  assert_eq "$claude_only" unsupported "control: pi row $name with the claude-only test restored"
  assert_eq "$evidence" "$without_rule" "control: pi row $name with the evidence rule taken out"
done <<PI_ROWS
quit|SessionEnd|reason=prompt_input_exit|ended|ended
clear|SessionEnd|reason=clear|live|live
usage_limit|StopFailure|message=$WALL_MESSAGE|walled|walled
prompt_too_long|StopFailure|message=prompt is too long: 212011 tokens > 200000 maximum|wedged|wedged
other_failure|StopFailure|message=overloaded_error: Overloaded|live|live
turn_end|Stop|-|unsupported|live
start_only|SessionStart|source=startup|unsupported|live
no_message|StopFailure|-|unsupported|live
PI_ROWS

# A rows wall carries the harness's own words, the limit and its reset, under
# its line, and `message=unrecorded` where its row holds none.
rows_case wall_payload blank "$START" "$FAILURE"
no_room
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "$(sed -n 2p <<<"$OUT")" "$WALL_MESSAGE" "the rows wall's message follows its event line" "$ERR"
rows_case wall_no_message blank "$START" "$(row StopFailure claude error=rate_limit)"
no_room
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "$(sed -n 2p <<<"$OUT")" "message=unrecorded" "a rows wall whose row holds no message says so under its line" "$ERR"

# Only a finished turn writes the Stop that lifts a rows wall, so the turn
# after the reset still has the StopFailure as its last row: an account the
# judgement measures with room refutes the wall, and the overseer reads live.
rows_case wall_after_reset blank "$START" "$FAILURE"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "walled=$(grep -c '^EVENT overseer-walled' <<<"$OUT" || true) launched=$(succeed_calls --walled-pane) note=$(grep -c '^oversee-watch: overseer-wall-lifted ' "$ERR" || true)" \
  "walled=0 launched=0 note=1" "a rows wall whose account measures room reads live, and says the wall lifted" "$ERR"

# Succeeded in one pass: a wall the rows state, and an account mark reached
# at value 0 under a live session, each run the walled
# succession in the first pass that reads them. A mark above zero is reported
# as the mark and succeeds nothing.
one_pass() { # NAME MARK_LINE ROW... [WATCH_BIN via env]
  local name="$1" mark="$2"
  shift 2
  rows_case "$name" blank "$@"
  [[ -z "$mark" ]] || printf '%s\n' "$mark" > "$STUB_DIR/succeed.check"
  run TMUX_PANE="$PANE" -- --max-loops 1
  ONE_PASS="rc=$RC walled=$(grep -c '^EVENT overseer-walled' <<<"$OUT" || true) marks=$(grep -c '^EVENT overseer-mark' <<<"$OUT" || true) launched=$(succeed_calls --walled-pane)"
}
one_pass wall_one_pass "$FIVE_MARK" "$START" "$FAILURE"
assert_eq "$ONE_PASS" "rc=3 walled=1 marks=0 launched=1" "a rows wall is succeeded in the first pass that reads it" "$ERR"
one_pass zero_mark "$ZERO_MARK" "$START"
assert_eq "$ONE_PASS" "rc=3 walled=1 marks=0 launched=1" "an account mark reached at value 0 is succeeded in the same pass" "$ERR"
assert_eq "$(grep '^EVENT overseer-walled' <<<"$OUT")|$(sed -n 2p <<<"$OUT")" \
  "EVENT overseer-walled $PANE window=$WINDOW passes=1 succession=on source=account|account=1claude headroom=0 resets=2026-09-28T03:00:00Z" \
  "the event names the account as its source and the account's own figures follow it" "$ERR"
one_pass five_mark "$FIVE_MARK" "$START"
assert_eq "$ONE_PASS" "rc=0 walled=0 marks=1 launched=0" "a mark above zero is reported as the mark alone" "$ERR"

# exit_case_state NAME STATUS [PANE_STATE] — a rows sandbox over PANE_STATE,
# exited by default, whose record carries STATUS as overseer-run's exit
# status, none where it is empty.
exit_case_state() { # NAME STATUS [PANE_STATE]
  rows_case "$1" "${3:-exited}" "$START"
  if [[ -n "$2" ]]; then
    jq --argjson status "$2" '.overseer.exit = {status: $status, at: "2026-09-28T01:00:00Z"}' \
      "$STUB_DIR/oversee-state.json" > "$STUB_DIR/state.tmp" && mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
  fi
}
# The exit status overseer-run writes into the record once the launch line
# returns settles the session, `source=record`, over the bare shell that
# return leaves. A harness started again in the same pane is that shell's
# child and writes a later SessionStart row: the status is an earlier
# session's and the rows judge, saying live. With no status the process and
# the rows judge as before.
exit_case() { # NAME PANE_STATE [STATUS]
  exit_case_state "$1" "${3:-}" "$2"
  run TMUX_PANE="$PANE" -- --max-loops 2
  EXIT_CASE="event=$(grep '^EVENT overseer-dead' <<<"$OUT" || echo none) launched=$(succeed_calls --dead-pane)"
}
exit_case record_exit exited 137
assert_eq "$EXIT_CASE" "event=EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=record launched=1" \
  "a recorded exit status over a bare shell is the death, from the record" "$ERR"
exit_case record_resumed blank 137
assert_eq "$EXIT_CASE" "event=none launched=0" \
  "a recorded status under a harness started again in the pane is an earlier session's: the rows say live" "$ERR"
exit_case record_no_exit blank
assert_eq "$EXIT_CASE" "event=none launched=0" "with no status the rows judge, and they say live" "$ERR"

# The mail pass memoises a rows wall's account judgement on its row, as it
# does a screen wall's on its banner: one unchanged StopFailure row the
# account refutes, over three mail passes and one long pass in a run whose
# next long pass is an hour away, is judged once by the mail passes and once
# by the long pass.
rows_wall_judged() { # [WATCH_BIN via env]
  rows_case "$1" blank "$START" "$FAILURE"
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail/KEN-5"
  mkdir -p "$CASE_REPO_ROOT/tmp/lane-mail/KEN-5"
  run TMUX_PANE="$PANE" ORCH_WATCH_MAIL_INTERVAL=1 NOTE_AT=3 \
    OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/lane-mail-note-at.sh" REAL_LANE_MAIL="$REAL_LANE_MAIL" \
    -- --max-loops 2 --interval 3600 --item KEN-5
  JUDGED="$(succeed_calls --check-marks)"
}
rows_wall_judged rows_wall_memo
assert_eq "judged=$JUDGED" "judged=2" "a standing rows wall is judged once by the mail passes and once by the long pass" "$ERR"

# The record names another pane's rows: they are not this pane's, and the
# pane is the fallback, said as `unrecorded`.
rows_case other_session blank "$START" "$END_EXIT"
jq '.overseer.pane = "%3"' "$STUB_DIR/oversee-state.json" > "$STUB_DIR/state.tmp" \
  && mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_contains "$(cat -- "$ERR")" "oversee-watch: overseer-fallback pane=$PANE cause=unrecorded" \
  "another session's rows file is no reading of this pane" "$ERR"
# The record names this pane id on this pid, bound to an earlier server's
# start (the stub's server started at 1790000000): a later server handed the
# same pid and pane id, and neither that record's rows nor its exit status is
# this pane's. Its control is ol_names without the start test, which reads the
# earlier server's exit status as this session's death.
earlier_server_case() { # NAME [WATCH_BIN]
  exit_case_state "$1" 137
  jq '.overseer.server_start = 1789996400' "$STUB_DIR/oversee-state.json" > "$STUB_DIR/state.tmp" \
    && mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
  WATCH_BIN="${2:-}" run TMUX_PANE="$PANE" -- --max-loops 2
}
earlier_server_case earlier_server
assert_eq "$(grep '^EVENT overseer-dead' <<<"$OUT" | grep -o 'source=[a-z]*')|$(grep -c "^oversee-watch: overseer-fallback pane=$PANE cause=unrecorded" "$ERR")" \
  "source=pane|1" "an earlier server's record for this pane id is no reading of it: the pane judges, not its status or its rows" "$ERR"
EARLIER_CTL="$(mutant_scripts earlier-ctl/orch lib/overseer-launch.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/earlier-ctl/github"
mutate_file "$EARLIER_CTL/lib/overseer-launch.sh" \
  '    and (.server_start | tostring) == $start;' '    and true;'
earlier_server_case earlier_server_mutant "$EARLIER_CTL/oversee-watch"
assert_eq "$(grep '^EVENT overseer-dead' <<<"$OUT" | grep -o 'source=[a-z]*')" "source=record" \
  "control: without the start test the earlier server's exit status is read as this session's death" "$ERR"
# The same record carrying no start names no session: its rows are not this
# pane's, and the pane judges.
rows_case startless_rows exited "$START" "$END_EXIT"
jq 'del(.overseer.server_start)' "$STUB_DIR/oversee-state.json" > "$STUB_DIR/state.tmp" \
  && mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "$(grep '^EVENT overseer-dead' <<<"$OUT" | grep -o 'source=[a-z]*')|$(grep -c "^oversee-watch: overseer-fallback pane=$PANE cause=unrecorded" "$ERR")" \
  "source=pane|1" "a record carrying no start names no session: the pane judges, not its rows" "$ERR"
# The pane read's own start emptied: this pane's bound record reads as
# another session's, and the pane judges in place of its rows.
PANESTART_CTL="$(mutant_scripts panestart-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/panestart-ctl/github"
mutate_file "$PANESTART_CTL/oversee-watch" 'ol_names(\"$server\"; \"$OV_START\"; \"$pane\")' 'ol_names(\"$server\"; \"\"; \"$pane\")'
rows_case dead_rows_start_mutant exited "$START" "$END_EXIT"
WATCH_BIN="$PANESTART_CTL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "$(grep '^EVENT overseer-dead' <<<"$OUT" | grep -o 'source=[a-z]*')|$(grep -c "^oversee-watch: overseer-fallback pane=$PANE cause=unrecorded" "$ERR")" \
  "source=pane|1" "control: a pane read judged on no start reads this pane's bound record as another session's" "$ERR"

# The rows verdict ignored: the SessionEnd row then settles nothing, and the
# death is the pane fallback's.
MUTANT_SCRIPTS="$(mutant_scripts mutant/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mutant/github"
mutate_file "$MUTANT_SCRIPTS/oversee-watch" '    ended) OV_STATE=exited; OV_SOURCE=rows; return 0 ;;' '    ended) ;;'
rows_case dead_rows_mutant exited "$START" "$END_EXIT"
WATCH_BIN="$MUTANT_SCRIPTS/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "$(grep '^EVENT overseer-dead' <<<"$OUT" || echo none)" \
  "EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=pane" \
  "control: without the rows verdict the SessionEnd row settles nothing and the pane answers" "$ERR"
# The SessionEnd taken over a live harness: another session's end in this
# pane succeeds the working overseer.
END_CTL="$(mutant_scripts end-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/end-ctl/github"
mutate_file "$END_CTL/oversee-watch" '|| (( bare )) || cause=live' '|| (( bare )) || :'
rows_case end_over_live_mutant blank "$START" "$END_EXIT"
WATCH_BIN="$END_CTL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "launched=$(succeed_calls --dead-pane)" "launched=1" \
  "control: a SessionEnd taken over a live harness succeeds the working overseer" "$ERR"

# The recorded exit ignored: the bare shell reads dead from its process.
EXIT_CTL="$(mutant_scripts exit-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/exit-ctl/github"
mutate_file "$EXIT_CTL/oversee-watch" '&& (( bare )); then OV_STATE=exited; OV_SOURCE=record; return 0; fi' '&& (( bare )); then :; fi'
WATCH_BIN="$EXIT_CTL/oversee-watch" exit_case record_exit_mutant exited 137
assert_eq "$EXIT_CASE" "event=EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=process launched=1" \
  "control: without the recorded exit the death is the process rung's, not the record's" "$ERR"
# The status taken whatever the pane runs: a harness started again reads dead.
RESUME_CTL="$(mutant_scripts resume-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/resume-ctl/github"
mutate_file "$RESUME_CTL/oversee-watch" '[[ -n "$exit_status" ]] && (( bare )); then' \
  '[[ -n "$exit_status" ]]; then'
WATCH_BIN="$RESUME_CTL/oversee-watch" exit_case record_resumed_mutant blank 137
assert_eq "$EXIT_CASE" "event=EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=record launched=1" \
  "control: a status taken over a live harness succeeds the session started again in the pane" "$ERR"
# The rows wall's refutation removed: an account with room still reads walled.
LIFT_CTL="$(mutant_scripts lift-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/lift-ctl/github"
mutate_file "$LIFT_CTL/oversee-watch" \
  '        if ! overseer_marks_judge || [[ "$OVERSEER_MARK_KEY" != below-mark ]]; then OV_VERDICT=walled' \
  '        if true; then OV_VERDICT=walled'
rows_case wall_after_reset_mutant blank "$START" "$FAILURE"
WATCH_BIN="$LIFT_CTL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "launched=$(succeed_calls --walled-pane)" "launched=1" \
  "control: without the account's refutation the turn after the reset is succeeded" "$ERR"

# The rows wall's memo key dropped: every mail pass judges the account again.
MEMO_CTL="$(mutant_scripts memo-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/memo-ctl/github"
mutate_file "$MEMO_CTL/oversee-watch" '    if [[ "$OV_SOURCE" == rows ]]; then banner="$SESSION_ROW"' \
  '    if [[ "$OV_SOURCE" == rows ]]; then banner="$RANDOM"'
WATCH_BIN="$MEMO_CTL/oversee-watch" rows_wall_judged rows_wall_memo_mutant
assert_eq "more=$(( JUDGED > 2 ))" "more=1" "control: without the rows wall's memo key each mail pass judges again" "$ERR"

# The zero mark left to the walled session: the pass only reports the mark.
MARK_CTL="$(mutant_scripts mark-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mark-ctl/github"
mutate_file "$MARK_CTL/oversee-watch" '    OV_VERDICT=walled OV_SOURCE=account' '    :'
WATCH_BIN="$MARK_CTL/oversee-watch" one_pass zero_mark_mutant "$ZERO_MARK" "$START"
assert_eq "$ONE_PASS" "rc=0 walled=0 marks=1 launched=0" \
  "control: without the zero-mark wall the pass only reports the mark and succeeds nothing" "$ERR"

# The prompt-too-long row read as any other failure: the wedged harness reads
# live and nothing relaunches it.
TOOLONG_CTL="$(mutant_scripts toolong-ctl/orch lib/session-rows.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/toolong-ctl/github"
mutate_file "$TOOLONG_CTL/lib/session-rows.sh" '    then "wedged"' '    then "live"'
rows_case wedged_rows_mutant blank "$START" "$TOO_LONG"
WATCH_BIN="$TOOLONG_CTL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "event=$(grep '^EVENT overseer-' <<<"$OUT" || echo none) launched=$(succeed_calls --dead-pane)" "event=none launched=0" \
  "control: without the prompt-too-long verdict a wedged harness reads live and is never relaunched" "$ERR"
# The error_details read dropped: a prompt-too-long failure whose words sit
# there alone reads live and nothing relaunches it.
DETAILS_CTL="$(mutant_scripts details-ctl/orch lib/session-rows.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/details-ctl/github"
mutate_file "$DETAILS_CTL/lib/session-rows.sh" '+ (.error_details // "")' '+ ("")'
rows_case wedged_details_mutant blank "$START" "$TOO_LONG_DETAILS"
WATCH_BIN="$DETAILS_CTL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "event=$(grep '^EVENT overseer-' <<<"$OUT" || echo none) launched=$(succeed_calls --dead-pane)" "event=none launched=0" \
  "control: without the error_details read a prompt-too-long failure named there reads live" "$ERR"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
