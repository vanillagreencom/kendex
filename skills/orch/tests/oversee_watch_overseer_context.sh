#!/usr/bin/env bash
# Tests for oversee-watch's overseer context contract.
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
