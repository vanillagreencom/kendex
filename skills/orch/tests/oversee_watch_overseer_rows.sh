#!/usr/bin/env bash
# Tests for the overseer judgement oversee-watch takes from the session's own
# event rows (scripts/lib/session-rows.sh) rather than from its pane: a
# SessionEnd row is a death and a usage-limit StopFailure row a wall whatever
# the pane shows, and where no row can judge the pane is read as the named
# fallback and the pass says so. The pane-read judgement itself is
# oversee_watch_overseer.sh's subject.
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

echo "=== oversee-watch: the overseer judged from its session rows ==="

# Row shapes as Claude Code 2.1.283 emits them, read from that binary's hook
# input builders: every event carries session_id, transcript_path and cwd;
# SessionStart adds source and model, SessionEnd reason (clear, resume,
# logout, prompt_input_exit, other), StopFailure error (rate_limit among
# them), error_details and last_assistant_message, which the writer keeps as
# `message`. The writer adds at, event, harness and account.
ROWS_FILE() { printf '%s/tmp/lane-mail/overseer/session-7000-9.jsonl' "$CASE_REPO_ROOT"; }
row() { # EVENT HARNESS [KEY=VALUE]...
  local event="$1" harness="$2" args=()
  shift 2
  for kv in "$@"; do args+=(--arg "${kv%%=*}" "${kv#*=}"); done
  jq -cn --arg event "$event" --arg harness "$harness" ${args[@]+"${args[@]}"} \
    '{at: 1788364000, event: $event, harness: $harness, session_id: "5f0c", transcript_path: "/home/me/.claude/projects/x/5f0c.jsonl", cwd: "/home/me/kendex"} + ($ARGS.named | del(.event, .harness))'
}
START="$(row SessionStart claude source=startup model=claude-fable-5-1 account=/home/me/.claude)"
END_EXIT="$(row SessionEnd claude reason=prompt_input_exit)"
END_CLEAR="$(row SessionEnd claude reason=clear)"
WALL_MESSAGE="You've hit your limit · resets 9:50am (America/Los_Angeles)"
FAILURE="$(row StopFailure claude error=rate_limit "message=$WALL_MESSAGE")"
OVERLOADED="$(row StopFailure claude error=overloaded message=overloaded)"
# The failure a session whose context filled its window meets on every turn:
# Claude Code's own `Prompt is too long` as the turn's last message.
TOO_LONG="$(row StopFailure claude error=invalid_request "message=Prompt is too long")"
# The same failure with the words in `error_details` and an empty message,
# the two fields hooks/stop-failure-row.sh keeps apart.
TOO_LONG_DETAILS="$(row StopFailure claude error=invalid_request message= "error_details=Prompt is too long")"
STOP="$(row Stop claude)"
CODEX_START="$(row SessionStart codex source=startup)"
# A Pi overseer's rows, as the pi-hooks carrier's payloads give them: Pi's
# `quit` said as Claude Code's `prompt_input_exit` (pi-hooks vocab.ts).
PI_START="$(row SessionStart pi source=startup)"
PI_END="$(row SessionEnd pi reason=prompt_input_exit)"
# A Pi turn end: no end and no failure, which is all a Pi session whose
# carrier dispatches no StopFailure writes at a wall.
PI_STOP="$(row Stop pi)"

# rows_case NAME PANE_STATE ROW... — overseer_case's sandbox with the fleet
# state naming the rows file for this pane and ROW... written to it, one per
# line; no ROW leaves the file absent. The pane reads PANE_STATE, `blank` being
# a live harness process over a screen showing nothing at all.
rows_case() { # NAME PANE_STATE ROW...
  local name="$1" pane_state="$2" row
  shift 2
  if [[ "$pane_state" == blank ]]; then
    overseer_case "$name" idle
    : > "$STUB_DIR/pane-$PANE.txt"
  else
    overseer_case "$name" "$pane_state"
  fi
  touch "$STUB_DIR/repeat-child"
  state_with "$LINE"
  jq --arg rows "$(ROWS_FILE)" '.overseer.session_rows = $rows' "$STUB_DIR/oversee-state.json" \
    > "$STUB_DIR/state.tmp" && mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
  mkdir -p "$CASE_REPO_ROOT/tmp/lane-mail/overseer"
  for row in "$@"; do printf '%s\n' "$row" >> "$(ROWS_FILE)"; done
}
# A rows wall stands unless the account judgement measures room: the stub's
# default below-mark line is room, so a case that means the wall to stand
# gives it a mark reached above zero, which is no room and no zero wall.
FIVE_MARK="oversee-succeed: mark-reached kind=headroom value=5 mark=10 succession=on account=1claude resets=2026-09-28T03:00:00Z"
ZERO_MARK="oversee-succeed: mark-reached kind=headroom value=0 mark=10 succession=on account=1claude resets=2026-09-28T03:00:00Z"
no_room() { printf '%s\n' "$FIVE_MARK" > "$STUB_DIR/succeed.check"; }

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

# --- the overseer's context record, judged each long pass ------------------
# The turn-end hook writes context.json in the overseer mailbox at each turn
# end, a reading or a gap record naming why none was taken, and a Stop row
# beside it. A long pass over a working overseer reports a gap as
# overseer-context-unmeasured, and a record more than an hour old as
# overseer-context-stale where a Stop row came after it. A fresh record, a
# stale one with no Stop after it, one a StopFailure alone followed, since no
# turn-end hook runs on that turn, a turn in flight on the screen, and a
# record naming another pane print neither.
CTX_FILE() { printf '%s/tmp/lane-mail/overseer/context.json' "$CASE_REPO_ROOT"; }
# The rows above are stamped ROW_AT, so a record is placed before or after
# that turn by its offset from it.
ROW_AT=1788364000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
# context_case NAME PANE_STATE RECORD_OFFSET NOW_OFFSET GAP ROW... — a rows
# sandbox whose context record was written RECORD_OFFSET seconds after ROW_AT,
# naming the pane key CTX_KEY, with GAP as its gap or `-` for a reading, and a
# clock NOW_OFFSET seconds after ROW_AT; then one long pass. CONTEXT_EVENT is
# the context event it printed, or none. CTX_FLEET_HARNESS, where set, is the
# harness the fleet record names for this pane.
CTX_KEY="7000 $PANE"
CTX_FLEET_HARNESS=""
# A start in the same pane naming a new session, as a session opened there by
# hand, or a /clear, writes.
RESTART="$(row SessionStart claude source=startup model=claude-fable-5-1 session_id=9a1b)"
# ctx_record AT GAP — the context record the hook writes at AT, naming the
# pane key CTX_KEY: a reading below the mark where GAP is `-`, else GAP.
ctx_record() { # AT GAP
  if [[ "$2" == - ]]; then
    jq -cn --arg at "$1" --arg key "$CTX_KEY" '{harness: "claude", model: "claude-fable-5-1", tokens: 300000, window: 1000000,
      used_pct: 30, session_id: "5f0c", pane_key: $key, gap: null, at: $at}' > "$(CTX_FILE)"
  else
    jq -cn --arg at "$1" --arg gap "$2" --arg key "$CTX_KEY" '{harness: "claude", model: null, tokens: null, window: null,
      used_pct: null, session_id: "5f0c", pane_key: $key, gap: $gap, at: $at}' > "$(CTX_FILE)"
  fi
}
context_case() { # NAME PANE_STATE RECORD_OFFSET NOW_OFFSET GAP ROW...
  local name="$1" pane_state="$2" at now="$((ROW_AT + $4))" gap="$5"
  at="$(iso "$((ROW_AT + $3))")"
  shift 5
  rows_case "$name" "$pane_state" "$@"
  if [[ -n "$CTX_FLEET_HARNESS" ]]; then
    jq --arg h "$CTX_FLEET_HARNESS" '.overseer.harness = $h' "$STUB_DIR/oversee-state.json" > "$STUB_DIR/state.tmp" \
      && mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
  fi
  printf '%s\n' "$now" > "$STUB_DIR/now.epoch"
  ctx_record "$at" "$gap"
  run TMUX_PANE="$PANE" -- --max-loops 1
  CONTEXT_EVENT="$(grep '^EVENT overseer-context-' <<<"$OUT" || echo none)"
}
while IFS='|' read -r name key fleet pane record_offset now_offset gap rows expected; do
  set -f
  # shellcheck disable=SC2086  # the row names split into the row list.
  set -- $rows
  set +f
  row_args=()
  for r in "$@"; do
    case "$r" in
      start) row_args+=("$START") ;;
      restart) row_args+=("$RESTART") ;;
      overloaded) row_args+=("$OVERLOADED") ;;
      wall) row_args+=("$FAILURE") ;;
      stop) row_args+=("$STOP") ;;
      -) ;;
      *) echo "unknown row $r" >&2; exit 1 ;;
    esac
  done
  CTX_KEY="7000 $key" CTX_FLEET_HARNESS="${fleet#-}" context_case "$name" "$pane" "$record_offset" "$now_offset" "$gap" ${row_args[@]+"${row_args[@]}"}
  assert_eq "$CONTEXT_EVENT" "$expected" "$name" "$ERR"
done <<ROWS
context_gap|$PANE|-|blank|-60|0|home-unnamed|start|EVENT overseer-context-unmeasured $PANE gap=home-unnamed
context_gap_same_harness|$PANE|claude|blank|-60|0|home-unnamed|start|EVENT overseer-context-unmeasured $PANE gap=home-unnamed
context_gap_unrecorded|$PANE|-|blank|-60|0|pane-unrecorded|start|EVENT overseer-context-unmeasured $PANE gap=pane-unrecorded
context_gap_other_pane|%4|-|blank|-60|0|home-unnamed|start|none
context_gap_copilot|$PANE|copilot|idle|-60|0|home-unnamed|-|none
context_gap_new_session|$PANE|-|blank|-60|0|home-unnamed|start restart|none
context_stale_stop|$PANE|-|blank|-600|7200|-|start stop|EVENT overseer-context-stale $PANE age=7800
context_stale_lifted|$PANE|-|blank|-600|7200|-|start wall stop|EVENT overseer-context-stale $PANE age=7800
context_stale_new_session|$PANE|-|blank|-600|7200|-|start restart stop|none
context_stale_failure|$PANE|-|blank|-600|7200|-|start overloaded|none
context_stale_screen|$PANE|-|limit_text|-600|7200|-|-|none
context_stale_no_turn|$PANE|-|blank|-600|7200|-|start|none
context_turn_before|$PANE|-|blank|60|7200|-|start stop|none
context_fresh|$PANE|-|blank|-10|60|-|start stop|none
ROWS
# No record is a session that has not ended a turn under the hook: nothing to
# report. A record the hook does not write is noted and settles nothing.
rows_case context_absent blank "$START"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "$(grep -c '^EVENT overseer-context-' <<<"$OUT" || true)" "0" "no context record prints neither event" "$ERR"
rows_case context_unread blank "$START"
printf '{"tokens":"many"}\n' > "$(CTX_FILE)"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "events=$(grep -c '^EVENT overseer-context-' <<<"$OUT" || true) note=$(grep -c "^oversee-watch: overseer-context-unread path=$(CTX_FILE)" "$ERR" || true)" \
  "events=0 note=1" "a record the hook does not write is noted and judged on nothing" "$ERR"

# --- the overseer wedged at its context window -------------------------------
# A harness whose recorded reading fills the window it names takes no turn
# again, and writes no row a death judgement reads: its process stays up.
# Its context record at or past that window, with no Stop row after the
# record, is read as dead, `source=context`, on the passes a death takes, and
# relaunched from the recorded line with a fleet-log row naming the source.
# The same reading with a Stop row after it is a turn that ended since, and
# draws no death. A copilot reading's window is the point Copilot starts to
# compact, so a copilot reading at it is no wedge. WEDGE_HARNESS names the
# harness the record and the fleet record carry, claude where unset.
wedge_case() { # NAME TOKENS ROW... [WATCH_BIN via env]
  local name="$1" tokens="$2" harness="${WEDGE_HARNESS:-claude}"
  shift 2
  rows_case "$name" blank "$@"
  jq --arg h "$harness" '.overseer.harness = $h' "$STUB_DIR/oversee-state.json" > "$STUB_DIR/state.tmp" \
    && mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
  printf '%s\n' "$((ROW_AT + 600))" > "$STUB_DIR/now.epoch"
  jq -cn --arg at "$(iso "$((ROW_AT + 60))")" --argjson t "$tokens" --arg h "$harness" '{harness: $h, model: "claude-fable-5-1",
    tokens: $t, window: 1000000, used_pct: ($t / 10000 | floor), session_id: "5f0c", pane_key: "7000 %9", gap: null, at: $at}' > "$(CTX_FILE)"
  run TMUX_PANE="$PANE" -- --max-loops 2
  WEDGE="event=$(grep '^EVENT overseer-' <<<"$OUT" | head -n 1 || echo none) launched=$(succeed_calls --dead-pane)"
}
STOP_AFTER="$(row Stop claude | jq -c --argjson at "$((ROW_AT + 120))" '.at = $at')"
wedge_case wedged_context 1000000 "$START" "$STOP"
assert_eq "$WEDGE" "event=EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=context launched=1" \
  "a reading at its window with no Stop row after it is a wedge, relaunched from the recorded line" "$ERR"
assert_contains "$(fleet_log_text)" "source=context" "and names the source" "$ERR"
wedge_case wedged_context_turned 1000000 "$START" "$STOP_AFTER"
assert_eq "$WEDGE" "event=none launched=0" "the same reading with a Stop row after it is a turn that ended since, and no wedge" "$ERR"
wedge_case wedged_context_below 999999 "$START" "$STOP"
assert_eq "$WEDGE" "event=none launched=0" "a reading below its window is no wedge" "$ERR"
WEDGE_HARNESS=copilot wedge_case wedged_context_copilot 1000000 "$START" "$STOP"
assert_eq "$WEDGE" "event=none launched=0" "a copilot reading at its window, Copilot's compaction point, is no wedge" "$ERR"

# --- a gap the overseer does not close goes to the owner --------------------
# The first long pass a gap stands on tells the overseer; the next, it goes to
# the owner once, as a notice and a fleet-log row, and neither repeats while
# that gap stands. A notice the owner did not get is sent again the next
# pass, and a reading between two passes of the same gap starts it again.
# The owner notices the overseer mailbox holds naming the gap alert.
owner_alerts() {
  local file="$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-overseer.jsonl"
  [[ -f "$file" ]] || { echo 0; return; }
  jq -r 'select(.to == "owner") | .text' "$file" | grep -c 'overseer-context-unmeasured: the overseer in pane' || true
}
# The fleet-log rows naming the gap alert.
fleet_alerts() {
  jq '(.fleet_log // []) | map(select(.item == "overseer" and (.text // "" | contains("has recorded no context reading on two consecutive watch passes")))) | length' \
    "$STUB_DIR/oversee-state.json"
}
# A lane-mail whose `notice --to owner` fails while STUB_DIR/owner-fails
# stands, as it does where the overseer mailbox cannot be written, and which
# hands every other call to the real one.
cat > "$TMP_ROOT/bin/lane-mail-owner-fails.sh" <<'STUB'
#!/usr/bin/env bash
if [[ -e "$STUB_DIR/owner-fails" && " $* " == *" --to owner "* ]]; then
  echo "lane-mail: mailbox-unwritable item=overseer" >&2
  exit 1
fi
exec "$REAL_LANE_MAIL" "$@"
STUB
chmod +x "$TMP_ROOT/bin/lane-mail-owner-fails.sh"
# gap_seq NAME STEP... [WATCH_BIN via env] — the home-unnamed gap on the first
# long pass, then one long pass per STEP over the record it writes: `gap` the
# same gap, `failing` the same gap with the owner's notice failing, `reading`
# a reading below the mark, `aged` the same gap with every owner notice
# restamped 210 seconds before its own stamp, on whatever clock the watch
# reads: past lane-mail's minute rule and inside its 24-hour text rule, as a
# gap reopened later in the day finds it. GAP_SEQ is
# one word per pass: `event` for the
# overseer-context-unmeasured event, `alerted` for the owner's alert,
# `failed` for an owner's notice that failed, `none` for none of them; then
# the owner's notices and the fleet log's alert rows.
gap_seq() { # NAME STEP...
  local name="$1" step words="" word mailbox
  shift
  CTX_KEY="7000 $PANE" context_case "$name" blank -60 0 home-unnamed "$START"
  for step in first "$@"; do
    if [[ "$step" != first ]]; then
      rm -f -- "${STUB_DIR:?}/owner-fails"
      case "$step" in
        gap) ctx_record "$(iso "$((ROW_AT - 60))")" home-unnamed ;;
        failing) ctx_record "$(iso "$((ROW_AT - 60))")" home-unnamed; : > "$STUB_DIR/owner-fails" ;;
        reading) ctx_record "$(iso "$((ROW_AT - 60))")" - ;;
        aged)
          ctx_record "$(iso "$((ROW_AT - 60))")" home-unnamed
          mailbox="$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-overseer.jsonl"
          jq -c 'if .to == "owner" then .at = ((.at | fromdateiso8601) - 210 | todate) else . end' "$mailbox" > "$mailbox.aged"
          mv -- "$mailbox.aged" "$mailbox" ;;
        *) echo "gap_seq: unknown step $step" >&2; exit 1 ;;
      esac
      run TMUX_PANE="$PANE" OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/lane-mail-owner-fails.sh" \
        REAL_LANE_MAIL="$REAL_LANE_MAIL" -- --max-loops 1
    fi
    word=""
    ! grep -q "^EVENT overseer-context-unmeasured $PANE gap=home-unnamed$" <<<"$OUT" || word+="event"
    ! grep -q "^oversee-watch: overseer-context-alerted pane=$PANE gap=home-unnamed" "$ERR" || word+="alerted"
    ! grep -q '^oversee-watch: overseer-notice-failed channel=owner' "$ERR" || word+="failed"
    words+="${word:-none} "
  done
  GAP_SEQ="${words}owner=$(owner_alerts) fleet=$(fleet_alerts)"
}
gap_seq context_gap_alert gap gap
assert_eq "$GAP_SEQ" "event alerted none owner=1 fleet=1" \
  "a gap still standing on the second long pass goes to the owner once, and neither repeats" "$ERR"
gap_seq context_gap_owner_fails failing gap gap
assert_eq "$GAP_SEQ" "event failed alerted none owner=1 fleet=1" \
  "an owner's notice that failed is sent again the next pass, with one fleet-log row" "$ERR"
gap_seq context_gap_reopened gap reading gap
assert_eq "$GAP_SEQ" "event alerted none event owner=1 fleet=1" \
  "a reading between two passes of the same gap tells the overseer again" "$ERR"
# The reopened gap's alert repeats words the owner holds: lane-mail refuses
# it, the alert stands as sent and the fleet log records it, never a failure
# noted on every pass.
GAP_HELD_WANT="event alerted none event alerted owner=1 fleet=2"
gap_seq context_gap_held gap reading gap aged
assert_eq "$GAP_SEQ" "$GAP_HELD_WANT" \
  "a reopened gap's alert the owner already holds stands as sent, with its fleet-log row" "$ERR"

# --- control ----------------------------------------------------------------
# The held alert read as any failed notice: the reopened gap's row turns red.
HELD_SCRIPTS="$(mutant_scripts mutant-held/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mutant-held/github"
mutate_file "$HELD_SCRIPTS/oversee-watch" '      "lane-mail: owner-notice-repeated="*) ;;' '      "lane-mail: owner-notice-repeated="*) overseer_note overseer-notice-failed "channel=owner"; return 1 ;;'
WATCH_BIN="$HELD_SCRIPTS/oversee-watch" gap_seq context_gap_held_mutant gap reading gap aged
assert_eq "$([[ "$GAP_SEQ" != "$GAP_HELD_WANT" ]] && echo red)" "red" \
  "control: reading the held alert as a failure turns the reopened gap's row red" "$ERR"
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
# The context wedge dropped: a full window with no turn since reads live.
WEDGE_CTL="$(mutant_scripts wedge-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/wedge-ctl/github"
mutate_file "$WEDGE_CTL/oversee-watch" '    OV_VERDICT=exited OV_SOURCE=context' '    :'
WATCH_BIN="$WEDGE_CTL/oversee-watch" wedge_case wedged_context_mutant 1000000 "$START" "$STOP"
assert_eq "$WEDGE" "event=none launched=0" "control: without the context wedge a full window reads live" "$ERR"
# The copilot arm of the window judge dropped: a copilot reading at its
# compaction point is taken for a wedge and the working overseer relaunched.
COPILOT_CTL="$(mutant_scripts copilot-window-ctl/orch lib/lane-context.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/copilot-window-ctl/github"
mutate_file "$COPILOT_CTL/lib/lane-context.sh" '    copilot) return 1 ;;' '    copilot) ;;'
WEDGE_HARNESS=copilot WATCH_BIN="$COPILOT_CTL/oversee-watch" wedge_case wedged_context_copilot_mutant 1000000 "$START" "$STOP"
assert_eq "$WEDGE" "event=EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=context launched=1" \
  "control: without the copilot arm a copilot reading at its compaction point relaunches a working overseer" "$ERR"
# The Stop-since test dropped: a turn that ended after the reading is taken
# for a wedge and the working overseer is relaunched.
WEDGETURN_CTL="$(mutant_scripts wedgeturn-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/wedgeturn-ctl/github"
mutate_file "$WEDGETURN_CTL/oversee-watch" '  (( OVERSEER_CTX_STOP <= OVERSEER_CTX_AT ))' '  :'
WATCH_BIN="$WEDGETURN_CTL/oversee-watch" wedge_case wedged_context_turned_mutant 1000000 "$START" "$STOP_AFTER"
assert_eq "$WEDGE" "event=EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=context launched=1" \
  "control: without the Stop-since test a turn that ended after the reading relaunches a working overseer" "$ERR"
# The told arm dropped: a standing gap is the event on every pass and the
# owner is never told.
GAPTOLD_CTL="$(mutant_scripts gaptold-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/gaptold-ctl/github"
mutate_file "$GAPTOLD_CTL/oversee-watch" '    "$gap|told")' '    "$gap|never")'
WATCH_BIN="$GAPTOLD_CTL/oversee-watch" gap_seq context_gap_alert_mutant gap gap
assert_eq "$GAP_SEQ" "event event event owner=0 fleet=0" \
  "control: without the told arm the gap repeats as an event every pass and never reaches the owner" "$ERR"
# The failed alert's hold on the row dropped: an owner's notice that failed
# is taken as sent and never tried again.
GAPRETRY_CTL="$(mutant_scripts gapretry-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/gapretry-ctl/github"
mutate_file "$GAPRETRY_CTL/oversee-watch" '      overseer_gap_alert "$pane" "$gap" || return 0' '      overseer_gap_alert "$pane" "$gap" || :'
WATCH_BIN="$GAPRETRY_CTL/oversee-watch" gap_seq context_gap_owner_fails_mutant failing gap gap
assert_eq "$GAP_SEQ" "event failed none none owner=0 fleet=0" \
  "control: without the hold a failed owner's notice is never sent again" "$ERR"
# The reading's clear dropped: a gap back after a reading stays alerted and
# the overseer is never told again.
GAPCLEAR_CTL="$(mutant_scripts gapclear-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/gapclear-ctl/github"
mutate_file "$GAPCLEAR_CTL/oversee-watch" \
  '  OVERSEER_MARK_ROWS="$(lane_row_clear overseer-context-gap "$OVERSEER_MARK_ROWS" "$identity")"' '  :'
WATCH_BIN="$GAPCLEAR_CTL/oversee-watch" gap_seq context_gap_reopened_mutant gap reading gap
assert_eq "$GAP_SEQ" "event alerted none none owner=1 fleet=1" \
  "control: without the reading's clear a gap back after a reading is never told again" "$ERR"

# The context record's controls, one per rule: the gap read, the age bound,
# the Stop-since test, the pane test, the harness test and the session test
# each removed in turn.
context_control() { # NAME OLD NEW CASE_NAME PANE RECORD_OFFSET NOW_OFFSET GAP EXPECTED ROW...
  local ctl name="$1" old="$2" new="$3" case_name="$4" pane="$5" record_offset="$6" now_offset="$7" gap="$8" expected="$9"
  shift 9
  ctl="$(mutant_scripts "$name/orch" oversee-watch)" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/$name/github"
  mutate_file "$ctl/oversee-watch" "$old" "$new"
  WATCH_BIN="$ctl/oversee-watch" context_case "$case_name" "$pane" "$record_offset" "$now_offset" "$gap" "$@"
  assert_eq "$CONTEXT_EVENT" "$expected" "control: $name turns $case_name into $expected" "$ERR"
}
context_control gap-ctl '  if [[ -n "$LANE_CTX_GAP" ]]; then' '  if false; then' \
  context_gap_mutant blank -60 0 home-unnamed none "$START"
context_control age-ctl '  (( age > OVERSEER_CONTEXT_STALE_SECS )) || return 0' '  :' \
  context_fresh_mutant blank -10 60 - "EVENT overseer-context-stale $PANE age=70" "$START" "$STOP"
context_control turn-ctl '  (( row_at > at )) || return 0' '  :' \
  context_no_turn_mutant blank -600 7200 - "EVENT overseer-context-stale $PANE age=7800" "$START"
CTX_KEY="7000 %4" context_control pane-ctl '  [[ "$LANE_CTX_PANE_KEY" == "$identity" ]] || return 1' '  :' \
  context_other_pane_mutant blank -60 0 home-unnamed "EVENT overseer-context-unmeasured $PANE gap=home-unnamed" "$START"
CTX_FLEET_HARNESS=copilot context_control harness-ctl \
  '  [[ -z "$OVERSEER_RECORD_HARNESS" || "$LANE_CTX_HARNESS" == "$OVERSEER_RECORD_HARNESS" ]] || return 1' '  :' \
  context_copilot_mutant idle -60 0 home-unnamed "EVENT overseer-context-unmeasured $PANE gap=home-unnamed"
context_control session-ctl \
  '  [[ -z "$started" || -z "$LANE_CTX_SESSION" || "$started" == "$LANE_CTX_SESSION" ]] || return 1' '  :' \
  context_new_session_mutant blank -60 0 home-unnamed "EVENT overseer-context-unmeasured $PANE gap=home-unnamed" "$START" "$RESTART"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
