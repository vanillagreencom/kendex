#!/usr/bin/env bash
# lane-mail-check after the fleet overseer's tool calls: the lane-mail-deliver
# hook runs the judge with `deliver`, and for the session the fleet record
# names the judge reads and records its context and judges the context mark,
# handing a reached mark, and once per gap what it could not judge, to the
# model as context at exit 0 beside any mail the same call hands over. The
# overseer session, the judge beside it and the payload runner are
# lib/lane-mail-world.sh's; the overseer's turn end is lane-mail-check.test.sh's.
# HOOK_UNDER_TEST overrides the script the must-fail controls run against.
set -euo pipefail

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

echo "=== lane-mail-check: the overseer's tool calls ==="

overseer_transcript
# A finished call of the overseer session s1, its payload naming TRANSCRIPT,
# or of the session SESSION a row names.
overseer_tool() { # TRANSCRIPT [SESSION] [ENV=VAL...]
  local path="$1" session="${2:-s1}" judge="$CASE_HOOK"
  shift
  [ "$#" -eq 0 ] || shift
  CASE_HOOK="$LANE/.claude/hooks/lane-mail-deliver.sh"
  # shellcheck disable=SC2046
  run_payload "$(jq -nc --arg p "$path" --arg s "$session" \
    '{session_id:$s,transcript_path:$p,tool_name:"Bash",tool_input:{command:"git status"}}')" \
    $(overseer_env) "$@"
  CASE_HOOK="$judge"
}
# An overseer session with the tool-call arm installed, in a checkout whose
# overseer mailbox directory stands.
tool_overseer() { # NAME [JUDGE]
  new_overseer "$1"
  install_arms "${2:-$HOOK}"
  mkdir -p "$LANE/tmp/lane-mail/overseer"
  judge_says "$BELOW_MARK_LINE"
}
tool_record() { jq -r '"\(.tokens) \(.gap)"' "$LANE/tmp/lane-mail/overseer/context.json" 2>/dev/null || echo none; }

tool_overseer overseer_tool_mark
write_transcript "$TRANSCRIPT" 100000
overseer_tool "$TRANSCRIPT"
assert_eq "RC=$RC context=$(context_line) record=$(tool_record) judged=$(judge_calls)" \
  "RC=0 context=- record=100000 null judged=0" \
  "an overseer tool call below its mark hands over nothing and records the reading, asking no account judge" "$ERR_FILE"
append_transcript "$TRANSCRIPT" 600000
overseer_tool "$TRANSCRIPT"
assert_eq "RC=$RC context=$(context_line) record=$(tool_record) route=$(jq -r '.hookSpecificOutput.additionalContext' "$TMP_ROOT/stdout" | grep -cF -- "/oversee-succeed --context 600000:1000000 -- [THE PERMISSION")" \
  "RC=0 context=PostToolUse lane-mail-check: context=600000 record=600000 null route=1" \
  "the tool call after the mark is crossed hands the overseer the context mark and its succession as context" "$ERR_FILE"
overseer_tool "$TRANSCRIPT"
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=PostToolUse lane-mail-check: context=600000" \
  "and at every tool call after it while no handoff record stands" "$ERR_FILE"
record_overseer_handoff
append_transcript "$TRANSCRIPT" 700000
overseer_tool "$TRANSCRIPT"
assert_eq "RC=$RC context=$(context_line) record=$(tool_record)" "RC=0 context=- record=700000 null" \
  "an overseer whose own handoff record stands is handed nothing, its reading still recorded" "$ERR_FILE"
variant never-held -e 's/^    stands) handoff_is_mine ;;$/    stands) return 1 ;;/'
tool_overseer control_overseer_tool_held "$VARIANT_PATH"
write_transcript "$TRANSCRIPT" 600000
record_overseer_handoff
overseer_tool "$TRANSCRIPT"
assert_eq "$(context_line)" "PostToolUse lane-mail-check: context=600000" \
  "control: a hook that never reads the record as its own hands the mark over past it"
variant held-first -e 's|^    ( overseer_tool_judge ) 2>"\$WORK_DIR/tool-judge.err"$|    if ( overseer_tool_held ); then : >"$WORK_DIR/tool-judge.err"; else ( overseer_tool_judge ) 2>"$WORK_DIR/tool-judge.err"; fi|'
tool_overseer control_overseer_tool_held_first "$VARIANT_PATH"
write_transcript "$TRANSCRIPT" 600000
overseer_tool "$TRANSCRIPT"
record_overseer_handoff
append_transcript "$TRANSCRIPT" 700000
overseer_tool "$TRANSCRIPT"
assert_eq "record=$(tool_record)" "record=600000 null" \
  "control: a hook that asks the handoff before the judgement records no reading while it is held"
# A handoff state the call cannot read holds the call silent: the turn end
# reports it under the keys that say which.
standing_unread_rows() { # NAME [JUDGE]
  tool_overseer "$1" "${2:-$HOOK}"
  write_transcript "$TRANSCRIPT" 600000
  state_stub standing-fails
  overseer_tool "$TRANSCRIPT"
  UNREAD="RC=$RC context=$(context_line) asked=$(grep -cx handoff-standing "$STATE_LOG" || :)"
}
standing_unread_rows overseer_tool_standing_unread
assert_eq "$UNREAD" "RC=0 context=- asked=1" \
  "an overseer past its mark whose handoff state cannot be read is handed nothing at a tool call" "$ERR_FILE"
variant unread-not-held -e '/^overseer_tool_held() {$/,/^}$/s/^    \*) return 0 ;;$/    *) return 1 ;;/'
standing_unread_rows control_overseer_tool_standing_unread "$VARIANT_PATH"
assert_eq "${UNREAD% asked=*}" "RC=0 context=PostToolUse lane-mail-check: context=600000" \
  "control: a hook that reads an unread handoff state as none hands the mark over"
# The handoff is asked only of a call with something to say: a call below the
# mark runs no workflow-state handoff-standing.
asked_rows() { # NAME [JUDGE]
  tool_overseer "$1" "${2:-$HOOK}"
  state_stub delegate
  write_transcript "$TRANSCRIPT" 100000
  overseer_tool "$TRANSCRIPT"
  local below
  below="$(grep -cx handoff-standing "$STATE_LOG" || :)"
  : >"$STATE_LOG"
  append_transcript "$TRANSCRIPT" 600000
  overseer_tool "$TRANSCRIPT"
  ASKED="below=$below past=$(grep -cx handoff-standing "$STATE_LOG" || :)"
}
asked_rows overseer_tool_asked
assert_eq "$ASKED" "below=0 past=1" \
  "a tool call below the mark asks no handoff state, and one past it asks once" "$ERR_FILE"
variant ask-every-call -e 's/^    if \[ -s "\$WORK_DIR\/tool-judge.err" \] && ( overseer_tool_held ); then$/    if ( overseer_tool_held ); then/'
asked_rows control_overseer_tool_asked "$VARIANT_PATH"
assert_eq "${ASKED% past=*}" "below=1" \
  "control: a hook that asks the handoff at every call asks it below the mark"
# A subagent's call is the subagent's window, never the overseer's.
tool_overseer overseer_tool_subagent
CASE_HOOK_SAVED="$CASE_HOOK"
CASE_HOOK="$LANE/.claude/hooks/lane-mail-deliver.sh"
# shellcheck disable=SC2046
run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",agent_id:"a1",transcript_path:$p,tool_name:"Bash"}')" $(overseer_env)
CASE_HOOK="$CASE_HOOK_SAVED"
assert_eq "RC=$RC context=$(context_line) record=$(tool_record)" "RC=0 context=- record=none" \
  "a subagent's tool call in the overseer's pane is judged on nothing" "$ERR_FILE"
# A record that lost its identity is healed at a tool call as at a turn end.
tool_overseer overseer_tool_lost
startless_record
overseer_tool "$TRANSCRIPT" s1 "CLAUDE_CONFIG_DIR=$OVERSEER_HOME_DIR"
assert_eq "RC=$RC context=$(context_line) start=$(recorded_field server_start) home=$(recorded_field home)" \
  "RC=0 context=PostToolUse lane-mail-check: context=600000 start=$OVERSEER_SERVER_START home=$OVERSEER_HOME_DIR" \
  "a tool call of the overseer whose record lost its identity heals it and hands over the mark" "$ERR_FILE"
# A judgement that could not run is handed over once per session and gap: a
# session pointed at a transcript it does not own reads nothing, is told why,
# and is not told again while that gap stands; a clean reading clears it.
told_rows() { # NAME [JUDGE]
  tool_overseer "$1" "${2:-$HOOK}"
  write_transcript "$TRANSCRIPT" 100000
  local first second third
  overseer_tool "$TRANSCRIPT" s2
  first="$(context_line) $(tool_record)"
  overseer_tool "$TRANSCRIPT" s2
  second="$(context_line)"
  overseer_tool "$TRANSCRIPT"
  overseer_tool "$TRANSCRIPT" s2
  third="$(context_line)"
  TOLD="first=$first second=$second third=$third"
}
told_rows overseer_tool_told
assert_eq "$TOLD" \
  "first=PostToolUse lane-mail-check: transcript-unowned=$TRANSCRIPT null session-mismatch second=- third=PostToolUse lane-mail-check: transcript-unowned=$TRANSCRIPT" \
  "a gap is handed over once while it stands, and again once it returns after a clean reading" "$ERR_FILE"
variant told-always -e 's/^  if \[ "\$TOLD_LAST" = "\$SESSION\$TAB\$TOLD_LINE" \]; then$/  if false; then/'
told_rows control_overseer_tool_told "$VARIANT_PATH"
assert_eq "${TOLD#* second=}" "PostToolUse lane-mail-check: transcript-unowned=$TRANSCRIPT third=PostToolUse lane-mail-check: transcript-unowned=$TRANSCRIPT" \
  "control: without the told test a standing gap is handed over at every tool call"
# The tool-call judgement skipped: the crossing waits for a turn end the
# window may never let the session reach.
write_transcript "$TRANSCRIPT" 600000
variant no-tool-check -e 's/^  overseer_tool_check$/  :/'
tool_overseer control_overseer_tool_mark "$VARIANT_PATH"
overseer_tool "$TRANSCRIPT"
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" \
  "control: a hook that judges no tool call leaves a crossing untold until a turn end"
# Handed over as a refusal, the mark would replace the tool's own output on
# one harness: it goes as context at exit 0.
variant tool-mark-refused -e 's/^  if \[ "\$ARM" = deliver \]; then$/  if false; then/'
tool_overseer control_overseer_tool_refused "$VARIANT_PATH"
overseer_tool "$TRANSCRIPT"
assert_eq "RC=$RC context=$(context_line)" "RC=2 context=-" \
  "control: a hook that refuses the crossing at a tool call exits 2 over a tool that already ran"

# The additionalContext a deliver run handed over, whole; empty for none.
tool_context() {
  [ -s "$TMP_ROOT/stdout" ] || return 0
  jq -r '.hookSpecificOutput.additionalContext' "$TMP_ROOT/stdout"
}

# Another lead session in the checkout, in another pane, is no overseer: its
# tool call leaves the overseer's told record as it stands, so the overseer is
# not handed a standing gap again for it.
other_pane_rows() { # NAME [JUDGE]
  tool_overseer "$1" "${2:-$HOOK}"
  write_transcript "$TRANSCRIPT" 100000
  local first other
  overseer_tool "$TRANSCRIPT" s2
  first="$(context_line)"
  overseer_tool "$TRANSCRIPT" s3 "TMUX_PANE=%3"
  other="$(context_line) $(tool_record)"
  overseer_tool "$TRANSCRIPT" s2
  OTHER="first=$first other=$other second=$(context_line)"
}
other_pane_rows overseer_tool_other_pane
assert_eq "$OTHER" \
  "first=PostToolUse lane-mail-check: transcript-unowned=$TRANSCRIPT other=- null session-mismatch second=-" \
  "a call from another pane between two overseer calls touches nothing, and the second overseer call hands nothing" "$ERR_FILE"
variant any-pane-told -e 's/^  if \[ "\$IDENTIFIED" != yes \] && \[ "\$LOST_OVERSEER" -eq 0 \]; then$/  if false; then/'
other_pane_rows control_overseer_tool_other_pane "$VARIANT_PATH"
assert_eq "${OTHER#* second=}" "PostToolUse lane-mail-check: transcript-unowned=$TRANSCRIPT" \
  "control: a hook that lets any session clear the told record hands the overseer its gap again after another pane's call"

# What the judgement hands over rides with the mail the same call hands over,
# in one context: a gap told once, and a reached mark, each above the note.
mail_rides_rows() { # NAME [JUDGE]
  tool_overseer "$1" "${2:-$HOOK}"
  write_transcript "$TRANSCRIPT" 100000
  peer_send 'Gap and note.'
  overseer_tool "$TRANSCRIPT" s2
  local gap
  gap="$(context_line) note=$(tool_context | grep -cF 'Gap and note.') unread=$(tool_context | grep -c '^lane-mail-check: unread=1$')"
  append_transcript "$TRANSCRIPT" 600000
  peer_send 'Mark and note.'
  overseer_tool "$TRANSCRIPT"
  RIDES="gap=$gap mark=$(context_line) note=$(tool_context | grep -cF 'Mark and note.') unread=$(tool_context | grep -c '^lane-mail-check: unread=1$')"
}
mail_rides_rows overseer_tool_mail
assert_eq "$RIDES" \
  "gap=PostToolUse lane-mail-check: transcript-unowned=$TRANSCRIPT note=1 unread=1 mark=PostToolUse lane-mail-check: context=600000 note=1 unread=1" \
  "a gap and a reached mark are each handed over above the note the same call hands over" "$ERR_FILE"
variant mail-drops-notice -e 's/^  jq -nc --arg text "\$TOOL_NOTICE\$1" /  jq -nc --arg text "$1" /'
mail_rides_rows control_overseer_tool_mail "$VARIANT_PATH"
assert_eq "$RIDES" \
  "gap=PostToolUse lane-mail-check: unread=1 note=1 unread=1 mark=PostToolUse lane-mail-check: unread=1 note=1 unread=1" \
  "control: a hook whose mail hand-over drops the judgement's notice hands the note alone"

# A mailbox refusal on the same call is the deliver arm's other writer: it
# carries the gap ahead of its own keyed line, on stderr beside its exit 2,
# and the gap is then told, so the next call hands nothing.
told_refused_rows() { # NAME [JUDGE]
  tool_overseer "$1" "${2:-$HOOK}"
  write_transcript "$TRANSCRIPT" 100000
  peer_send 'Held by a refusal.'
  state_stub path-fails
  overseer_tool "$TRANSCRIPT" s2
  local refused
  refused="RC=$RC first=$(first_line) fleet=$(grep -c '^lane-mail-check: fleet-state=' "$ERR_FILE")"
  state_stub delegate
  overseer_tool "$TRANSCRIPT" s2
  HELD="$refused then=$(context_line)"
}
told_refused_rows overseer_tool_told_refused
assert_eq "$HELD" "RC=2 first=lane-mail-check: transcript-unowned=$TRANSCRIPT fleet=1 then=PostToolUse lane-mail-check: unread=1" \
  "a refused call carries the gap ahead of its refusal, and the next call does not tell it again" "$ERR_FILE"
variant refuse-drops-notice -e 's/^  \[ "\$ARM" != deliver \] || text="\$TOOL_NOTICE\$text"$/  :/'
told_refused_rows control_overseer_tool_told_refused "$VARIANT_PATH"
assert_eq "${HELD%% fleet=*}" "RC=2 first=lane-mail-check: fleet-state=$LANE/.claude/skills/orch/scripts/workflow-state" \
  "control: a hook whose refusal drops the notice refuses the call with the gap withheld"

# A transcript the payload names and nothing can read is a refusal the
# handoff record clears, and after a tool call it is told once per session
# as a gap is, so a standing one does not fill the window.
unreadable_rows() { # NAME [JUDGE]
  tool_overseer "$1" "${2:-$HOOK}"
  rm -f -- "${TRANSCRIPT:?}"
  overseer_tool "$TRANSCRIPT"
  local first
  first="$(context_line)"
  overseer_tool "$TRANSCRIPT"
  UNREADABLE="first=$first second=$(context_line)"
  overseer_transcript
}
unreadable_rows overseer_tool_unreadable
assert_eq "$UNREADABLE" "first=PostToolUse lane-mail-check: transcript=unreadable second=-" \
  "an unreadable transcript is handed over once while it stands" "$ERR_FILE"
variant transcript-every-call -e 's/^    context | setting | setting-range)$/    context | setting | setting-range | transcript)/'
unreadable_rows control_overseer_tool_unreadable "$VARIANT_PATH"
assert_eq "${UNREADABLE#* second=}" "PostToolUse lane-mail-check: transcript=unreadable" \
  "control: a hook that tells a transcript refusal at every call hands a standing one over again"

# Pi's carrier puts the model's window on the tool call's payload, and the
# overseer's reading is judged on it. A payload naming none, the lane mail
# wake's run or an older carrier's tool call, takes no reading, writes no
# record and hands nothing over, so the turn end's reading and judgement stand.
PI_TOOL_TRANSCRIPT="$TMP_ROOT/pi-tool-overseer.jsonl"
pi_tool_rows() { # NAME WINDOW_FIELDS [JUDGE]
  tool_overseer "$1" "${3:-$HOOK}"
  mkdir -p "$LANE/.pi/skills"
  ln -s "$LANE/.claude/skills/orch" "$LANE/.pi/skills/orch"
  install_hook "$TEST_DIR/../lane-mail-deliver.sh" "$LANE/.pi/kendex/hooks/lane-mail-deliver.sh"
  install_hook "${3:-$HOOK}" "$LANE/.pi/kendex/hooks/lane-mail-check.sh"
  usage_line pi 180000 > "$PI_TOOL_TRANSCRIPT"
  CASE_HOOK="$LANE/.pi/kendex/hooks/lane-mail-deliver.sh"
  # shellcheck disable=SC2046
  run_payload "$(jq -nc --arg p "$PI_TOOL_TRANSCRIPT" --argjson w "$2" \
    '{session_id:"s1",transcript_path:$p,tool_name:"Bash",tool_input:{command:"git status"}} + $w')" $(overseer_env)
  PI_TOOL="context=$(context_line) window=$(jq -r '.window' "$LANE/tmp/lane-mail/overseer/context.json" 2>/dev/null || echo none)"
}
pi_tool_rows overseer_tool_pi '{"context_window":200000}'
assert_eq "$PI_TOOL" "context=PostToolUse lane-mail-check: context=180000 window=200000" \
  "a Pi overseer's tool call is judged on the window its payload carries" "$ERR_FILE"
variant pi-window-unread -e 's/^   whole(\.context_window),$/   "",/'
pi_tool_rows control_overseer_tool_pi '{"context_window":200000}' "$VARIANT_PATH"
assert_eq "$PI_TOOL" "context=- window=none" \
  "control: a hook that reads no window off the payload judges no Pi tool call"
pi_tool_rows overseer_tool_pi_windowless '{}'
assert_eq "$PI_TOOL" "context=- window=none" \
  "a Pi tool call naming no window takes no reading, writes no record and hands nothing over" "$ERR_FILE"
variant pi-windowless-read -e '/^  \[ "\$HARNESS" != pi \] || \[ -n "\$PAYLOAD_WINDOW" \] || return 0$/d'
pi_tool_rows control_overseer_tool_pi_windowless '{}' "$VARIANT_PATH"
assert_eq "$PI_TOOL" "context=PostToolUse lane-mail-check: window-unread=pi-claude/m window=null" \
  "control: a hook that reads a windowless Pi tool call records it with no window and tells it unread"

# The overseer the fleet record lost, its pane named by the context record and
# not by the fleet record, is told so once at its tool call, as a gap.
lost_tool_rows() { # NAME [JUDGE]
  tool_overseer "$1" "${2:-$HOOK}"
  write_transcript "$TRANSCRIPT" 100000
  overseer_tool "$TRANSCRIPT"
  record_overseer %4 "$OVERSEER_SERVER"
  overseer_tool "$TRANSCRIPT"
  LOST_TOOL="$(context_line) $(tool_record)"
}
lost_tool_rows overseer_tool_lost_pane
assert_eq "$LOST_TOOL" "PostToolUse lane-mail-check: pane-unrecorded=$OVERSEER_SERVER $OVERSEER_PANE null pane-unrecorded" \
  "the overseer the fleet record lost is told so at its tool call" "$ERR_FILE"
variant lost-untold -e 's/^  if \[ "\$IDENTIFIED" != yes \] && \[ "\$LOST_OVERSEER" -eq 0 \]; then$/  if [ "$IDENTIFIED" != yes ]; then/'
lost_tool_rows control_overseer_tool_lost_pane "$VARIANT_PATH"
assert_eq "$LOST_TOOL" "- null pane-unrecorded" \
  "control: a hook that tells only the named session leaves the lost overseer untold at its tool calls"

# One call asks whether this session is the overseer once: the mailbox check
# takes the tool-call judgement's answer, so a heal whose write fails is tried
# and reported once per call.
once_rows() { # NAME [JUDGE]
  tool_overseer "$1" "${2:-$HOOK}"
  startless_record "{\"server_start\":$OVERSEER_SERVER_START}"
  state_stub update-fails
  peer_send 'Asked once.'
  overseer_tool "$TRANSCRIPT"
  ONCE="unhealed=$(grep -c '^lane-mail-check: record-unhealed=' "$ERR_FILE") context=$(context_line) note=$(tool_context | grep -cF 'Asked once.')"
}
once_rows overseer_tool_once
assert_eq "$ONCE" "unhealed=1 context=PostToolUse lane-mail-check: record-unhealed=$OVERSEER_SERVER $OVERSEER_PANE note=1" \
  "a call that reads the overseer mailbox identifies the overseer once, and a failed heal is reported once" "$ERR_FILE"
variant identify-each-ask -e 's/^  if \[ -z "\$IDENTIFIED" \]; then$/  if true; then/'
once_rows control_overseer_tool_once "$VARIANT_PATH"
assert_eq "${ONCE%% *}" "unhealed=2" \
  "control: a hook that identifies at each ask heals and reports twice on one call"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
