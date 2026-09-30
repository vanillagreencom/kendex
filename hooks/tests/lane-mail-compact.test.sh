#!/usr/bin/env bash
# lane-mail-compact, and the backstop handoff mark it flags: the hook
# installed where kendex renders it for Copilot, beside the lane-mail-check
# judge it runs, fed the preCompact payload Copilot's hooks reference gives
# (camelCase: sessionId, timestamp, cwd, transcriptPath, trigger,
# customInstructions), and the agentStop that follows it, read by the same
# judge. The shared world is lib/lane-mail-world.sh; HOOK_UNDER_TEST overrides
# the judge the must-fail controls at the end run against.
set -euo pipefail

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

echo "=== lane-mail-compact: copilot ==="

# Every run's user home is COP_HOME, where the judge keeps its Copilot lead
# records.
CALL_ENV=("HOME=$COP_HOME")
# A Copilot lane: the judge and this hook under `.github/hooks`, the orch
# install the repository renders, a state file for the item, so the handoff
# record its refusal names can be written, and s1, the lead every row names
# unless it names another, recorded by its session start alone.
new_compact_lane() { # NAME ITEM [JUDGE] [WRAPPER]
  local branch
  branch="$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  new_lane "$1" "$branch"
  rm -f -- "${LANE:?}/.claude/hooks/lane-mail-check.sh"
  install_hook "${4:-$TEST_DIR/../lane-mail-compact.sh}" "$LANE/.github/hooks/lane-mail-compact.sh"
  install_hook "${3:-$HOOK}" "$LANE/.github/hooks/lane-mail-check.sh"
  mkdir -p "$LANE/tmp/lane-mail/$2"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init "$2" >/dev/null)
  BOX="$LANE/tmp/lane-mail/$2"
  cop_clear_leads
  cop_lead_start "$LANE/.github/hooks/lane-mail-check.sh" s1
}
# A lead's transcript sits in the directory named for its session, OWNER
# SESSION by default; a subagent's payload names its own session, which no
# start recorded, and the lead's transcript, OWNER naming the lead.
compact() { # TRIGGER [SESSION] [OWNER] [ENV=VAL...]
  local trigger="$1" session="${2:-s1}" owner="${3:-${2:-s1}}"
  shift $(($# < 3 ? $# : 3))
  CASE_HOOK="$LANE/.github/hooks/lane-mail-compact.sh"
  run_payload "$(jq -nc --arg t "$trigger" --arg s "$session" \
    --arg p "$TMP_ROOT/session-state/$owner/events.jsonl" \
    '{sessionId:$s, timestamp:1, cwd:"/w", transcriptPath:$p, trigger:$t, customInstructions:""}')" "$@"
}
turn_end() { # [ACTIVE] [SESSION] [ENV=VAL...]
  local active="${1:-false}" session="${2:-s1}"
  shift $(($# < 2 ? $# : 2))
  CASE_HOOK="$LANE/.github/hooks/lane-mail-check.sh"
  run_payload "$(jq -nc --arg s "$session" --argjson a "$active" \
    --arg p "$TMP_ROOT/session-state/$session/events.jsonl" \
    '{sessionId:$s, timestamp:1, cwd:"/w", transcriptPath:$p, stopReason:"end_turn", stop_hook_active:$a}')" "$@"
}
# The flag in BOX as `session trigger`, or `none`.
flag() {
  jq -r '"\(.session_id) \(.trigger)"' "$BOX/compaction.json" 2>/dev/null || echo none
}
stdout_field() { # JQ
  jq -r "$1" "$TMP_ROOT/stdout" 2>/dev/null || echo unparseable
}
# What a run wrote on both streams, the first stderr line keyed.
quiet() { printf 'RC=%s stdout=%s stderr=%s' "$RC" "$(cat "$TMP_ROOT/stdout")" "$(first_line)"; }
handoff_record() { # ITEM
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set "$1" handoff \
    '{"merged":[],"remaining":["rebase"],"branch":"b","worktree":"/w","open_pr":null,"traps":[]}' >/dev/null)
}
# A Copilot lane's turn end with no context reading of its session: the
# context and the account are both reported unmeasured, and nothing holds it.
# A lane that sets REPORT_ITEM reports a step before every turn end, so the
# idle judge, whose rows are in lane-mail-check.test.sh, holds none of its
# turn ends.
UNREAD_FIRST() { printf 'lane-mail-check: reading-unrecorded=%s/context.json' "$BOX"; }

new_compact_lane lane KEN-301
REPORT_ITEM=KEN-301
turn_end
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision) flag=$(flag)" \
  "RC=0 first=$(UNREAD_FIRST) decision= flag=none" \
  "a Copilot lead's turn end before any compaction is not held"
compact manual
assert_eq "$(quiet) flag=$(flag)" "RC=0 stdout= stderr=- flag=none" \
  "a manual compaction is the operator's own and flags nothing"
compact auto s7 s1
assert_eq "$(quiet) flag=$(flag)" "RC=0 stdout= stderr=lane-mail-check: session-unrecorded=s7 flag=none" \
  "a subagent's automatic compaction, its session no recorded lead, flags nothing and says so on stderr at exit 0"
compact manual s7 s1
assert_eq "$(quiet) flag=$(flag)" "RC=0 stdout= stderr=- flag=none" \
  "a subagent's manual compaction flags nothing, and says nothing"
compact auto
assert_eq "$(quiet) flag=$(flag)" "RC=0 stdout= stderr=- flag=s1 auto" \
  "the lead's automatic compaction is flagged, silently"
turn_end
printf -v HANDOFF_SET '%q set %q handoff' "$LANE/.agents/skills/orch/scripts/workflow-state" KEN-301
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision) set=$(stdout_field .reason | grep -cF -- "$HANDOFF_SET")" \
  "RC=0 first=lane-mail-check: compacted=auto decision=block set=1" \
  "the lead's next turn end is held with the documented block answer, naming the command that writes the record"
turn_end true
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision) flag=$(flag)" \
  "RC=0 first=lane-mail-check: compacted=auto decision=block flag=s1 auto" \
  "the turn Copilot continued is held again, the flag left standing"
handoff_record KEN-301
turn_end
assert_eq "$(quiet)" "RC=0 stdout= stderr=-" "the handoff record standing, the turn end passes"

# A successor session in the same mailbox is not held on its predecessor's
# compaction.
new_compact_lane successor KEN-302
REPORT_ITEM=KEN-302
cop_lead_start "$LANE/.github/hooks/lane-mail-check.sh" s0
compact auto s0
turn_end false s0
assert_eq "RC=$RC decision=$(stdout_field .decision)" "RC=0 decision=block" "the predecessor s0 was held on its compaction"
turn_end false s1
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" "RC=0 first=$(UNREAD_FIRST) decision=" \
  "its successor s1 is not"

# A session that is no launched lane flags nothing, and says nothing.
new_compact_lane unmarked KEN-303
unmark_lanes
compact auto
assert_eq "$(quiet) flag=$(flag)" "RC=0 stdout= stderr=- flag=none" \
  "a session no launch made a lane flags no compaction"

# Every gap is refused at exit 2, which Copilot shows the operator while the
# compaction goes on; nothing is on stdout.
new_compact_lane unwritable KEN-304
rm -rf -- "${BOX:?}"
printf 'not a directory\n' > "$BOX"
compact auto s1 s1 LANE_MAIL_ITEM=KEN-304
assert_eq "RC=$RC first=$(first_line) stdout=$(cat "$TMP_ROOT/stdout")" \
  "RC=2 first=lane-mail-check: compaction-unrecorded=$BOX/compaction.json stdout=" \
  "a compaction whose flag cannot be written is refused at exit 2 under its own key"
new_compact_lane no-state KEN-308
hole_install workflow-state
compact auto
assert_eq "$(quiet) flag=$(flag)" \
  "RC=2 stdout= stderr=lane-mail-check: compaction-unrecorded=$LANE/.agents/skills/orch/scripts/workflow-state flag=none" \
  "a lane whose install has no workflow-state is refused at exit 2, naming it"
new_compact_lane no-lib KEN-309
hole_install lib/lane-context.sh
compact auto
assert_eq "$(quiet) flag=$(flag)" \
  "RC=2 stdout= stderr=lane-mail-check: compaction-unrecorded=$LANE/.agents/skills/orch/scripts/lib/lane-context.sh flag=none" \
  "a lane whose install has no context library is refused at exit 2, naming it"
new_compact_lane missing KEN-305
rm -rf -- "${LANE:?}/tmp/lane-mail"
compact auto
assert_eq "RC=$RC first=$(first_line)" "RC=2 first=lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
  "a refusal the judge makes at a compaction is its keyed line at exit 2"
compact auto s7 s1
assert_eq "$(quiet)" "RC=0 stdout= stderr=lane-mail-check: session-unrecorded=s7" \
  "a subagent's compaction is passed before any gap of the lead's is reached"

# A flag standing that cannot be read holds the turn end, since whether the
# session compacted is unknown and the handoff record clears it.
if [ "$CAN_DENY_READS" -eq 1 ]; then
  new_compact_lane sealed KEN-306
  compact auto
  chmod 000 "$BOX/compaction.json"
  turn_end
  chmod 600 "$BOX/compaction.json"
  assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
    "RC=0 first=lane-mail-check: record=$BOX/compaction.json decision=block" \
    "a compaction flag that cannot be read holds the turn end under its own key"
fi

# The wrapper with no judge beside it refuses the gap at exit 2.
new_compact_lane nojudge KEN-307
rm -f -- "${LANE:?}/.github/hooks/lane-mail-check.sh"
compact auto
assert_eq "RC=$RC first=$(first_line)" "RC=2 first=lane-mail-compact: judge=$LANE/.github/hooks/lane-mail-check.sh" \
  "the hook with no judge beside it refuses the gap at exit 2"

# The overseer: a Copilot session in the pane the fleet state names. Its
# compaction is flagged in the overseer mailbox under its pane key, and its
# turn end is held whatever its succession setting, naming the succession.
new_compact_overseer() { # NAME [JUDGE]
  new_lane "$1" main
  unmark_lanes
  rm -f -- "${LANE:?}/.claude/hooks/lane-mail-check.sh"
  install_hook "$TEST_DIR/../lane-mail-compact.sh" "$LANE/.github/hooks/lane-mail-compact.sh"
  install_hook "${2:-$HOOK}" "$LANE/.github/hooks/lane-mail-check.sh"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init oversee >/dev/null)
  # The fleet record names TMP_ROOT as the overseer's launch home, the
  # Copilot home its transcript sits under, so the transcript ownership gate
  # holds its turn end to its own session.
  record_overseer "$OVERSEER_PANE" "$OVERSEER_SERVER" "$TMP_ROOT"
  BOX="$LANE/tmp/lane-mail/overseer"
  cop_clear_leads
  cop_lead_start "$LANE/.github/hooks/lane-mail-check.sh" s1
}
OVERSEER_ROUTE='/oversee-succeed -- [THE PERMISSION'
new_compact_overseer overseer
# shellcheck disable=SC2046
compact auto s1 s1 $(overseer_env)
assert_eq "$(quiet) flag=$(flag) key=$(jq -r .pane_key "$BOX/compaction.json" 2>/dev/null)" \
  "RC=0 stdout= stderr=- flag=s1 auto key=$OVERSEER_SERVER $OVERSEER_PANE" \
  "the overseer's automatic compaction is flagged in its mailbox under its pane key"
# shellcheck disable=SC2046
turn_end false s1 $(overseer_env)
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision) route=$(stdout_field .reason | grep -cF -- "$OVERSEER_ROUTE")" \
  "RC=0 first=lane-mail-check: compacted=auto decision=block route=1" \
  "its turn end is held, naming the succession as the route"
# shellcheck disable=SC2046
turn_end false s1 $(overseer_env) ORCH_OVERSEER_SUCCESSION=off
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: compacted=auto decision=block" \
  "with succession off the compacted overseer is still held"
# The same session in another pane, or outside tmux, is no overseer and no lane.
rm -f -- "${BOX:?}/compaction.json"
# shellcheck disable=SC2046
compact auto s1 s1 $(overseer_env %3)
assert_eq "$(quiet) flag=$(flag)" "RC=0 stdout= stderr=- flag=none" \
  "a session in a pane the fleet state does not name flags nothing"
compact auto
assert_eq "$(quiet) flag=$(flag)" "RC=0 stdout= stderr=- flag=none" \
  "nor does a session outside tmux"
# The handoff record naming this overseer ends the hold.
# shellcheck disable=SC2046
compact auto s1 s1 $(overseer_env)
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set oversee handoff \
  "$(jq -nc --arg k "$OVERSEER_SERVER $OVERSEER_PANE" '{handoff_file: "/h", pane_key: $k, session_id: "s1"}')" >/dev/null)
# shellcheck disable=SC2046
turn_end false s1 $(overseer_env)
assert_eq "RC=$RC decision=$(stdout_field .decision)" "RC=0 decision=" \
  "the overseer's own handoff record standing, its turn end passes"

echo "=== must-fail controls ==="
# The trigger rule removed: a manual compaction marks the lane.
mutant compact-any-trigger -e 's@ && \[ "\$TRIGGER" = auto \]; } || return 0$@; } || return 0@'
new_compact_lane control_trigger KEN-311 "$MUTANT_PATH"
compact manual
assert_eq "flag=$(flag)" "flag=s1 manual" \
  "control: without the trigger rule a manual compaction is flagged"

# The lead-record rule removed from the compact arm: a subagent's compaction
# is flagged as the lead's.
mutant compact-any-caller -e 's@^    copilot:deliver | copilot:halt | copilot:compact | copilot:usage)$@    copilot:deliver | copilot:halt | copilot:usage)@'
new_compact_lane control_caller KEN-312 "$MUTANT_PATH"
compact auto s7 s1
assert_eq "flag=$(flag)" "flag=s7 auto" \
  "control: without the lead-record rule a subagent's compaction is flagged"

# The early pass removed: a subagent's compaction meets the lead's gaps.
mutant compact-subagent-judged -e 's@^if \[ "\$ARM" = compact \] && \[ "\$CALLER" != lead \]; then$@if false; then@'
new_compact_lane control_subagent KEN-313 "$MUTANT_PATH"
rm -rf -- "${LANE:?}/tmp/lane-mail"
compact auto s7 s1
assert_eq "RC=$RC" "RC=2" \
  "control: without the early pass a subagent's compaction is refused on the lead's missing mailbox"

# The early pass's report dropped: an unrecorded session's automatic
# compaction passes with nothing said.
mutant compact-unknown-quiet -e 's@ || message session-unrecorded "\${SESSION:-none}"$@ || :@'
new_compact_lane control_quiet KEN-321 "$MUTANT_PATH"
compact auto s7 s1
assert_eq "$(quiet)" "RC=0 stdout= stderr=-" \
  "control: without its report an unrecorded session's compaction passes unsaid"

# The report's trigger rule removed: a subagent's manual compaction, which
# would flag nothing anyway, is reported as unflagged.
mutant compact-unknown-any-trigger -e 's@^  \[ "\$CALLER" != unknown \] || \[ "\$TRIGGER" != auto \] || @  [ "$CALLER" != unknown ] || @'
new_compact_lane control_quiet_trigger KEN-322 "$MUTANT_PATH"
compact manual s7 s1
assert_eq "$(quiet)" "RC=0 stdout= stderr=lane-mail-check: session-unrecorded=s7" \
  "control: without the trigger rule a subagent's manual compaction is reported"

# The lane's turn-end refusal removed: a flagged lane ends its turn unheld.
mutant compact-unheld -e 's@^  \[ "\$COMPACTED" != true \] || refuse_handoff compacted auto$@  :@'
new_compact_lane control_unheld KEN-314 "$MUTANT_PATH"
REPORT_ITEM=KEN-314
compact auto
turn_end
assert_eq "RC=$RC decision=$(stdout_field .decision)" "RC=0 decision=" \
  "control: without the lane's refusal a flagged Copilot lane ends its turn unheld"

# The overseer's refusal removed: a flagged overseer is judged on its reading
# alone, and has none.
mutant compact-overseer-unheld -e 's@^    \[ "\$COMPACTED" != true \] || refuse_handoff compacted auto$@    :@'
new_compact_overseer control_overseer "$MUTANT_PATH"
# shellcheck disable=SC2046
compact auto s1 s1 $(overseer_env)
# shellcheck disable=SC2046
turn_end false s1 $(overseer_env)
assert_eq "RC=$RC decision=$(stdout_field .decision)" "RC=0 decision=" \
  "control: without the overseer's refusal a flagged overseer is not held"

# The overseer's pane rule removed from the gate every arm asks: a session in
# a pane the fleet state does not name is taken for the overseer.
mutant gate-any-pane -e 's@^    overseer_identified || return 1$@    overseer_identified || :@'
new_compact_overseer control_pane "$MUTANT_PATH"
# shellcheck disable=SC2046
compact auto s1 s1 $(overseer_env %3)
assert_eq "flag=$(flag)" "flag=s1 auto" \
  "control: without the pane rule a session in another pane flags the overseer's compaction"

# The overseer's role dropped from the gate: its refusal is a lane's, naming
# no succession.
mutant gate-no-role -e 's@^    ROLE=overseer$@    :@'
new_compact_overseer control_role "$MUTANT_PATH"
# shellcheck disable=SC2046
compact auto s1 s1 $(overseer_env)
# shellcheck disable=SC2046
turn_end false s1 $(overseer_env)
assert_eq "route=$(stdout_field .reason | grep -cF -- "$OVERSEER_ROUTE")" "route=0" \
  "control: without its role the overseer's refusal names no succession"

# The fleet item dropped from the gate: the overseer's own handoff record is
# looked for under no item, and its turn end is held past it.
mutant gate-no-item -e 's@^    ITEM="\$OVERSEER_ITEM"$@    :@'
new_compact_overseer control_item "$MUTANT_PATH"
# shellcheck disable=SC2046
compact auto s1 s1 $(overseer_env)
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set oversee handoff \
  "$(jq -nc --arg k "$OVERSEER_SERVER $OVERSEER_PANE" '{handoff_file: "/h", pane_key: $k, session_id: "s1"}')" >/dev/null)
# shellcheck disable=SC2046
turn_end false s1 $(overseer_env)
assert_eq "RC=$RC decision=$(stdout_field .decision)" "RC=0 decision=block" \
  "control: without the fleet item the overseer's own handoff record does not end its hold"

# The flag's write gap passed: a compaction nothing flagged goes unreported.
mutant compact-unrecorded-passed -e 's@^    refuse compaction-unrecorded "\$BOX/\$LANE_CONTEXT_COMPACTION" "\$(cat -- "\$WORK_DIR/flag.err")"$@    :@'
new_compact_lane control_unwritable KEN-315 "$MUTANT_PATH"
rm -rf -- "${BOX:?}"
printf 'not a directory\n' > "$BOX"
compact auto s1 s1 LANE_MAIL_ITEM=KEN-315
assert_eq "$(quiet)" "RC=0 stdout= stderr=-" \
  "control: without its refusal a flag that cannot be written passes unreported"

# The gate's gap passed in this arm: a lane whose install cannot flag the
# compaction is passed with nothing said.
mutant compact-gap-passed -e '/^compaction_mark() {$/,/^}$/ s@^    \*) refuse compaction-unrecorded "\$FAIL_VALUE" "\$FAIL_CAUSE" ;;$@    *) return 0 ;;@'
new_compact_lane control_gap KEN-319 "$MUTANT_PATH"
hole_install workflow-state
compact auto
assert_eq "$(quiet)" "RC=0 stdout= stderr=-" \
  "control: without the gate's refusal a lane whose install has no workflow-state passes unreported"

# The context library's gap passed in this arm.
mutant compact-lib-passed -e '/^compaction_mark() {$/,/^}$/ s@^  load_context_lib || refuse compaction-unrecorded "\$FAIL_VALUE" "\$FAIL_CAUSE"$@  load_context_lib || return 0@'
new_compact_lane control_lib KEN-320 "$MUTANT_PATH"
hole_install lib/lane-context.sh
compact auto
assert_eq "$(quiet)" "RC=0 stdout= stderr=-" \
  "control: without the library's refusal a lane whose install has no context library passes unreported"

# The compact arm passed at exit 0 like a session start: its gaps reach no
# operator.
mutant compact-exit-zero -e 's@^    start | prompt) exit 0 ;;$@    start | prompt | compact) exit 0 ;;@'
new_compact_lane control_exit KEN-316 "$MUTANT_PATH"
rm -rf -- "${LANE:?}/tmp/lane-mail"
compact auto
assert_eq "RC=$RC" "RC=0" "control: passed like a session start, a compaction's gap exits 0"

# The wrapper's arm swapped for the turn end's: the compaction is judged as a
# turn end and never flagged.
MUTANT_SOURCE="$TEST_DIR/../lane-mail-compact.sh" mutant compact-as-stop -e 's@ "\$JUDGE" compact$@ "$JUDGE"@'
new_compact_lane control_wrapper KEN-317 "$HOOK" "$MUTANT_PATH"
compact auto
assert_eq "flag=$(flag)" "flag=none" \
  "control: the wrapper running the turn-end arm never flags the compaction"

# The wrapper's missing-judge exit made a pass: its gap reaches no operator.
MUTANT_SOURCE="$TEST_DIR/../lane-mail-compact.sh" mutant compact-no-judge-pass -e 's@^  exit 2$@  exit 0@'
new_compact_lane control_nojudge KEN-318 "$HOOK" "$MUTANT_PATH"
rm -f -- "${LANE:?}/.github/hooks/lane-mail-check.sh"
compact auto
assert_eq "RC=$RC" "RC=0" "control: with its exit made a pass the hook with no judge exits 0"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
