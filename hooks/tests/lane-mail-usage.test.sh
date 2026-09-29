#!/usr/bin/env bash
# The usage arm of lane-mail-check, the Copilot context reader, and the turn
# end that judges the reading it records: the judge installed where kendex
# renders it for Copilot, fed the payload the orch copilot-lane-context
# extension hands it from one `session.usage_info` event of the session's root
# agent, {session_id, cwd, current_tokens, token_limit}, and the agentStop
# that follows. The extension's own rules are skills/orch/tests/
# copilot-lane-context.sh's. The shared world is lib/lane-mail-world.sh;
# HOOK_UNDER_TEST overrides the judge the must-fail controls run against.
set -euo pipefail

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

# Every run's user home is COP_HOME, where the judge keeps its Copilot lead
# records.
CALL_ENV=("HOME=$COP_HOME")
# The two Copilot hooks as kendex renders them into DIR: each script beside
# its registry document.
install_copilot_hooks() { # DIR [JUDGE]
  install_hook "$TEST_DIR/../lane-mail-compact.sh" "$1/lane-mail-compact.sh"
  install_hook "${2:-$HOOK}" "$1/lane-mail-check.sh"
  printf '{}\n' > "$1/lane-mail-compact.json"
  printf '{}\n' > "$1/lane-mail-check.json"
}
new_usage_lane() { # NAME ITEM [JUDGE]
  new_lane "$1" "$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  rm -f -- "${LANE:?}/.claude/hooks/lane-mail-check.sh"
  install_copilot_hooks "$LANE/.github/hooks" "${3:-$HOOK}"
  mkdir -p "$LANE/tmp/lane-mail/$2"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init "$2" >/dev/null)
  BOX="$LANE/tmp/lane-mail/$2"
  JUDGE="$LANE/.github/hooks/lane-mail-check.sh"
  cop_clear_leads
  cop_lead_start "$JUDGE" s1
}
# One reading, handed to JUDGE as the extension hands it.
usage() { # TOKENS LIMIT [SESSION] [ENV=VAL...]
  local tokens="$1" limit="$2" session="${3:-s1}"
  shift $(($# < 3 ? $# : 3))
  CASE_HOOK="$JUDGE"
  ARM_ARGS=(usage)
  run_payload "$(jq -nc --argjson t "$tokens" --argjson l "$limit" --arg s "$session" --arg c "$LANE" \
    '{session_id:$s, cwd:$c, current_tokens:$t, token_limit:$l}')" "$@"
  ARM_ARGS=()
}
turn_end() { # [SESSION] [ENV=VAL...]
  local session="${1:-s1}"
  shift $(($# < 1 ? $# : 1))
  CASE_HOOK="$LANE/.github/hooks/lane-mail-check.sh"
  run_payload "$(jq -nc --arg s "$session" --arg p "$TMP_ROOT/session-state/$session/events.jsonl" \
    '{sessionId:$s, timestamp:1, cwd:"/w", transcriptPath:$p, stopReason:"end_turn", stop_hook_active:false}')" "$@"
}
# What a run wrote on both streams, the first stderr line keyed.
quiet() { printf 'RC=%s stdout=%s stderr=%s' "$RC" "$(cat "$TMP_ROOT/stdout")" "$(first_line)"; }
# The record in BOX as `tokens window session model`, or `none`.
record() {
  jq -r '"\(.tokens) \(.window) \(.session_id) \(.model)"' "$BOX/context.json" 2>/dev/null || echo none
}
stdout_field() { # JQ
  jq -r "$1" "$TMP_ROOT/stdout" 2>/dev/null || echo unparseable
}
MARK90=ORCH_HANDOFF_CONTEXT_PCT=90
SOURCE="80% of tokenLimit, Copilot's backgroundCompactionThreshold default"

echo "=== the reading ==="
new_usage_lane lane KEN-401
usage 150000 272000
assert_eq "$(quiet) record=$(record) source=$(jq -r '"\(.capacity_source) gap=\(.gap)"' "$BOX/context.json" 2>/dev/null)" \
  "RC=0 stdout= stderr=- record=150000 217600 s1 null source=$SOURCE gap=null" \
  "a lane's reading is recorded silently, its capacity 80 percent of the token limit, named as Copilot's default, with no gap"
usage 0 272000
assert_eq "$(quiet) record=$(record)" "RC=0 stdout= stderr=- record=0 217600 s1 null" \
  "a reading of no tokens is still a reading"
# The reading is judged in the directory its payload names, not the one the
# extension happens to run the hook from.
CALL_DIR="$TMP_ROOT"
usage 160000 272000
CALL_DIR=""
assert_eq "$(quiet) record=$(record)" "RC=0 stdout= stderr=- record=160000 217600 s1 null" \
  "a hook run from another directory records the lane its payload's cwd names"

echo "=== the turn end judges the reading under the shared rule ==="
usage 195840 272000
turn_end s1 "$MARK90"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" "RC=0 first=$GAP decision=" \
  "a reading at 90 percent of the compaction limit passes"
usage 195841 272000
turn_end s1 "$MARK90"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: context=195841 decision=block" \
  "a reading past it, 72 percent of the token limit, holds the turn end"
usage 400000 1000000
turn_end s1 "$MARK90"
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=lane-mail-check: context=400000" \
  "400000 tokens hold the turn end whatever the limit"
# A successor session in the same mailbox is not judged on its predecessor's
# reading: it is unmeasured until its own is recorded.
cop_lead_start "$JUDGE" s0
usage 199000 272000 s0
turn_end s1 "$MARK90"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: reading-unrecorded=$BOX/context.json decision=" \
  "another session's reading is reported unmeasured and holds nothing"
rm -f -- "${BOX:?}/context.json"
turn_end s1 "$MARK90"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: reading-unrecorded=$BOX/context.json decision=" \
  "no reading at all is reported unmeasured, never room"
if [ "$CAN_DENY_READS" -eq 1 ]; then
  usage 150000 272000
  chmod 000 "$BOX/context.json"
  turn_end s1 "$MARK90"
  chmod 600 "$BOX/context.json"
  assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
    "RC=0 first=lane-mail-check: record=$BOX/context.json decision=block" \
    "a reading that stands and cannot be read holds the turn end under its own key"
fi

echo "=== a reading handed on and not yet recorded ==="
# The extension's pending marker for s1: a reading of the session is on its
# way to the record.
PENDING="$COP_HOME/.cache/lane-mail/copilot-usage/s1"
pend() { mkdir -p "${PENDING%/*}" && : > "$PENDING"; }
# unpend_after SECONDS: the marker removed that long into the turn end, as
# the extension removes it once the run records. A real wait, the turn end's
# own poll being the thing under test.
unpend_after() { (sleep "$1" && rm -f -- "${PENDING:?}") & UNPEND_PID=$!; }
new_usage_lane pending KEN-421
usage 150000 272000
pend
# A real wait of the whole bound: the marker never goes.
turn_end s1 "$MARK90"
assert_eq "RC=$RC first=$(first_line) keys=$(grep -c '^lane-mail-check: ' "$ERR_FILE") decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: reading-pending=$PENDING keys=2 decision=" \
  "a marker standing through the wait leaves the context unmeasured, never the earlier record below the mark read as room"
usage 195841 272000
pend
unpend_after 0.5
turn_end s1 "$MARK90"
wait "$UNPEND_PID"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision) pending=$([ -e "$PENDING" ] && echo stands || echo gone)" \
  "RC=0 first=lane-mail-check: context=195841 decision=block pending=gone" \
  "a marker removed during the wait lets the turn end judge the record it waited for"

echo "=== a gap is refused at exit 2 on stderr, for the extension's timeline ==="
# A session no start or turn end recorded as a lead is recorded nowhere.
new_usage_lane unrecorded KEN-407
usage 150000 272000 s5
assert_eq "$(quiet) record=$(record)" "RC=2 stdout= stderr=lane-mail-check: session-unrecorded=s5 record=none" \
  "a reading of a session no lead record names is refused and recorded nowhere"
new_usage_lane unwritable KEN-402
rm -rf -- "${BOX:?}"
printf 'not a directory\n' > "$BOX"
usage 150000 272000 s1 LANE_MAIL_ITEM=KEN-402
assert_eq "$(quiet)" "RC=2 stdout= stderr=lane-mail-check: context-unrecorded=$BOX/context.json" \
  "a reading that cannot be written is its keyed line at exit 2"
# A write that fails where the directory still takes a removal: `date`, which
# stamps the record, fails, and the earlier reading is removed with it, so the
# turn end past the mark reports the context unmeasured rather than judging
# the older figure as room.
new_usage_lane stale KEN-408
mkdir -p "$TMP_ROOT/nodate"
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/nodate/date"
chmod +x "$TMP_ROOT/nodate/date"
usage 150000 272000
usage 199000 272000 s1 "PATH=$TMP_ROOT/nodate:$PATH"
assert_eq "$(quiet) record=$(record)" "RC=2 stdout= stderr=lane-mail-check: context-unrecorded=$BOX/context.json record=none" \
  "a reading past the mark that cannot be written is refused, and the earlier reading removed"
turn_end s1 "$MARK90"
expect 0 "lane-mail-check: reading-unrecorded=$BOX/context.json" \
  "the turn end after it reports the context unmeasured, not the earlier figure as room"
# An install the gate or the context library cannot use is refused under the
# key its turn end reports the same gap under.
new_usage_lane no-state KEN-409
hole_install workflow-state
usage 150000 272000
assert_eq "$(quiet) record=$(record)" \
  "RC=2 stdout= stderr=lane-mail-check: handoff-skipped=$LANE/.agents/skills/orch/scripts/workflow-state record=none" \
  "a lane whose install has no workflow-state is refused under handoff-skipped, naming it"
new_usage_lane no-lib KEN-410
hole_install lib/lane-context.sh
usage 150000 272000
assert_eq "$(quiet) record=$(record)" \
  "RC=2 stdout= stderr=lane-mail-check: handoff-skipped=$LANE/.agents/skills/orch/scripts/lib/lane-context.sh record=none" \
  "a lane whose install has no context library is refused under handoff-skipped, naming it"
new_usage_lane invalid KEN-403
usage 150000 0
assert_eq "$(quiet) record=$(record)" "RC=2 stdout= stderr=lane-mail-check: payload=invalid-json record=none" \
  "a reading naming no token limit is refused as a payload it cannot read"
new_usage_lane unmarked KEN-404
unmark_lanes
usage 150000 272000
assert_eq "$(quiet) record=$(record)" "RC=0 stdout= stderr=- record=none" \
  "a session no launch made a lane passes silently and is recorded nowhere"
new_usage_lane claude-copy KEN-405
install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
JUDGE="$LANE/.claude/hooks/lane-mail-check.sh"
usage 150000 272000
assert_eq "$(quiet) record=$(record)" "RC=2 stdout= stderr=lane-mail-check: harness-unlisted=$LANE/.claude/hooks record=none" \
  "an install that is not Copilot's refuses a reading it would record as another harness's"
# The global scope, under the Copilot home, with the orch skill in that
# home's own skills directory as a global install renders it: the judge is
# known as Copilot's by its registry document.
new_usage_lane global KEN-406
rm -rf -- "${LANE:?}/.github/hooks"
GLOBAL_HOME="$TMP_ROOT/copilot-home"
mkdir -p "$GLOBAL_HOME/skills/orch"
ln -s -f -n "$REPO_ROOT/skills/orch/scripts" "$GLOBAL_HOME/skills/orch/scripts"
install_copilot_hooks "$GLOBAL_HOME/hooks"
JUDGE="$GLOBAL_HOME/hooks/lane-mail-check.sh"
usage 150000 272000
assert_eq "$(quiet) record=$(record)" "RC=0 stdout= stderr=- record=150000 217600 s1 null" \
  "the judge in the Copilot home's global scope records the lane's reading"

echo "=== the overseer ==="
new_usage_overseer() { # NAME [JUDGE]
  new_lane "$1" main
  unmark_lanes
  rm -f -- "${LANE:?}/.claude/hooks/lane-mail-check.sh"
  install_copilot_hooks "$LANE/.github/hooks" "${2:-$HOOK}"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init oversee >/dev/null)
  # The fleet record names TMP_ROOT as the overseer's launch home, the
  # Copilot home its transcript sits under, so the transcript ownership gate
  # holds its turn end to its own session.
  record_overseer "$OVERSEER_PANE" "$OVERSEER_SERVER" "$TMP_ROOT"
  BOX="$LANE/tmp/lane-mail/overseer"
  JUDGE="$LANE/.github/hooks/lane-mail-check.sh"
  cop_clear_leads
  cop_lead_start "$JUDGE" s1
}
new_usage_overseer overseer
# shellcheck disable=SC2046
usage 199000 272000 s1 $(overseer_env)
assert_eq "$(quiet) record=$(record) key=$(jq -r .pane_key "$BOX/context.json" 2>/dev/null)" \
  "RC=0 stdout= stderr=- record=199000 217600 s1 null key=$OVERSEER_SERVER $OVERSEER_PANE" \
  "the overseer's reading is recorded in its mailbox under its pane key"
# shellcheck disable=SC2046
turn_end s1 $(overseer_env) "$MARK90"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision) route=$(stdout_field .reason | grep -cF -- '/oversee-succeed --context 199000:217600 -- [THE PERMISSION')" \
  "RC=0 first=lane-mail-check: context=199000 decision=block route=1" \
  "its turn end hands that reading to oversee-succeed, which judges it due, and names the succession carrying it"
rm -f -- "${BOX:?}/context.json"
# shellcheck disable=SC2046
usage 199000 272000 s1 $(overseer_env %3)
assert_eq "$(quiet) record=$(record)" "RC=0 stdout= stderr=- record=none" \
  "a session in a pane the fleet state does not name is no overseer, and recorded nowhere"
usage 199000 272000
assert_eq "$(quiet) record=$(record)" "RC=0 stdout= stderr=- record=none" \
  "nor is a session outside tmux"
# An overseer the fleet record lost writes a gap record at its turn end; named
# again, its turn end reads that record as no reading, never as room.
# overseer_named PANE: the fleet record names PANE as the overseer's.
overseer_named() { # PANE
  record_overseer "$1" "$OVERSEER_SERVER" "$TMP_ROOT"
}
# LOST is the lost turn end's first line and record; the run left is the
# turn end after it.
lost_overseer() { # NAME [JUDGE]
  new_usage_overseer "$@"
  # shellcheck disable=SC2046
  usage 199000 272000 s1 $(overseer_env)
  overseer_named %3
  # shellcheck disable=SC2046
  turn_end s1 $(overseer_env)
  LOST="first=$(first_line) record=$(jq -r '"\(.tokens) \(.gap)"' "$BOX/context.json" 2>/dev/null)"
  overseer_named "$OVERSEER_PANE"
  # shellcheck disable=SC2046
  turn_end s1 $(overseer_env) "$MARK90"
}
lost_overseer overseer_lost
assert_eq "$LOST" \
  "first=lane-mail-check: pane-unrecorded=$OVERSEER_SERVER $OVERSEER_PANE record=null pane-unrecorded" \
  "an overseer the fleet record lost writes the gap pane-unrecorded at its turn end"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: reading-unrecorded=$BOX/context.json decision=" \
  "named again, its turn end reports that gap record unmeasured and holds nothing"

echo "=== must-fail controls ==="
# The arm's dispatch removed: the reading runs the turn-end path, which
# records nothing.
mutant usage-undispatched -e 's@^if \[ "\$ARM" = usage \]; then$@if false; then@'
new_usage_lane control_dispatch KEN-411 "$MUTANT_PATH"
usage 150000 272000
assert_eq "record=$(record)" "record=none" "control: without its dispatch a reading is recorded nowhere"

# The payload's directory ignored: a hook run from outside the lane finds no
# lane and records nothing.
mutant usage-any-dir -e 's@^\[ "\$ARM" != usage \] || LANE_DIR=\$PAYLOAD_CWD$@:@'
new_usage_lane control_dir KEN-412 "$MUTANT_PATH"
CALL_DIR="$TMP_ROOT"
usage 150000 272000
CALL_DIR=""
assert_eq "record=$(record)" "record=none" \
  "control: without the payload's directory a hook run from elsewhere records no reading"

# The gate's answer ignored in this arm: a session no launch made a lane is
# taken on as one, and meets gaps that are none of its own.
mutant usage-ungated -e '/^usage_read() {$/,/^}$/ s@^    1) return 0 ;;$@    1) ;;@'
new_usage_lane control_gate KEN-413 "$MUTANT_PATH"
unmark_lanes
usage 150000 272000
assert_eq "RC=$RC" "RC=2" \
  "control: without the gate a session that is no lane is refused rather than passed silently"

# The gate's gap passed in this arm: a lane whose install cannot record a
# reading is passed with nothing said.
mutant usage-gap-passed -e '/^usage_read() {$/,/^}$/ s@^    \*) refuse "\$GATE_KEY" "\$FAIL_VALUE" "\$FAIL_CAUSE" ;;$@    *) return 0 ;;@'
new_usage_lane control_gap KEN-416 "$MUTANT_PATH"
hole_install workflow-state
usage 150000 272000
assert_eq "$(quiet)" "RC=0 stdout= stderr=-" \
  "control: without the gate's refusal a lane whose install has no workflow-state passes unreported"

# The context library's gap passed in this arm.
mutant usage-lib-passed -e '/^usage_read() {$/,/^}$/ s@^  load_context_lib || refuse "\$FAIL_KEY" "\$FAIL_VALUE" "\$FAIL_CAUSE"$@  load_context_lib || return 0@'
new_usage_lane control_lib KEN-417 "$MUTANT_PATH"
hole_install lib/lane-context.sh
usage 150000 272000
assert_eq "$(quiet)" "RC=0 stdout= stderr=-" \
  "control: without the library's refusal a lane whose install has no context library passes unreported"

# The earlier reading kept where the write failed: the turn end past the mark
# judges the older figure as room.
mutant usage-stale-kept -e 's@^    rm -f -- "\${BOX:?}/\$LANE_CONTEXT_RECORD" 2>>"\$WORK_DIR/record.err" || STALE_RECORD=stands$@    :@'
new_usage_lane control_stale KEN-418 "$MUTANT_PATH"
usage 150000 272000
usage 199000 272000 s1 "PATH=$TMP_ROOT/nodate:$PATH"
turn_end s1 "$MARK90"
expect 0 "$GAP" "control: without the removal the turn end past the mark passes on the earlier figure"

# The pending check removed: the earlier record below the mark is read as
# room while a reading is on its way.
mutant usage-pending-unread -e 's@^  if copilot_reading_pending; then$@  if false; then@'
new_usage_lane control_pending KEN-422 "$MUTANT_PATH"
usage 150000 272000
pend
turn_end s1 "$MARK90"
rm -f -- "${PENDING:?}"
expect 0 "$GAP" "control: without the pending check the earlier record passes the turn end as room"
# The wait removed: a run recording as the turn ends leaves it unmeasured.
mutant usage-pending-unwaited -e 's@^PENDING_POLLS=25$@PENDING_POLLS=0@'
new_usage_lane control_pending_wait KEN-423 "$MUTANT_PATH"
usage 195841 272000
pend
unpend_after 0.5
turn_end s1 "$MARK90"
wait "$UNPEND_PID"
expect 0 "lane-mail-check: reading-pending=$PENDING" \
  "control: without the wait a reading recorded as the turn ends is still reported pending"

# The session rule at the turn end removed: a successor is judged on its
# predecessor's reading.
mutant usage-any-session -e 's@^  if \[ "\$LANE_CTX_SESSION" != "\$SESSION" \] ||$@  if@'
new_usage_lane control_session KEN-414 "$MUTANT_PATH"
cop_lead_start "$JUDGE" s0
usage 199000 272000 s0
turn_end s1 "$MARK90"
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=lane-mail-check: context=199000" \
  "control: without the session rule a successor is held on its predecessor's reading"

# The lead-record rule removed from the usage arm: a session no lead record
# names is taken for the lead, and its reading recorded.
mutant usage-any-caller -e 's@^    copilot:deliver | copilot:halt | copilot:compact | copilot:usage)$@    copilot:deliver | copilot:halt | copilot:compact)@'
new_usage_lane control_caller KEN-419 "$MUTANT_PATH"
usage 150000 272000 s5
assert_eq "RC=$RC record=$(record)" "RC=0 record=150000 217600 s5 null" \
  "control: without the lead-record rule an unrecorded session's reading is recorded"

# The arm's refusal of an unknown caller removed: its reading is recorded.
mutant usage-unknown-recorded -e 's@^  \[ "\$CALLER" = lead \] || refuse session-unrecorded "\${SESSION:-none}"$@  :@'
new_usage_lane control_unknown KEN-420 "$MUTANT_PATH"
usage 150000 272000 s5
assert_eq "RC=$RC record=$(record)" "RC=0 record=150000 217600 s5 null" \
  "control: without the arm's refusal an unrecorded session's reading is recorded"

# The harness assertion removed: a claude copy records the reading as its own.
mutant usage-any-harness -e 's@^  \[ "\$HARNESS" = copilot \] || refuse harness-unlisted "\${BASH_SOURCE\[0\]%/\*}"$@  :@'
new_usage_lane control_harness KEN-415
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
JUDGE="$LANE/.claude/hooks/lane-mail-check.sh"
usage 150000 272000
assert_eq "RC=$RC record=$(record)" "RC=0 record=150000 217600 s1 null" \
  "control: without the harness assertion a claude copy records a Copilot reading"

# The capacity-source rule at the turn end removed: a gap record is read as
# the extension's reading of no figure, and the context goes unmeasured with
# nothing said.
mutant usage-gap-read -e '/^copilot_context_read() {/,/^}$/ s@^  if \[ "\$LANE_CTX_SESSION" != "\$SESSION" \] ||$@  if [ "$LANE_CTX_SESSION" != "$SESSION" ]; then return 1; fi; if false \&\&@'
lost_overseer control_gap_read "$MUTANT_PATH"
assert_eq "unrecorded=$(grep -c '^lane-mail-check: reading-unrecorded=' "$ERR_FILE")" "unrecorded=0" \
  "control: without the capacity-source rule a gap record leaves the overseer's context unmeasured in silence"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
