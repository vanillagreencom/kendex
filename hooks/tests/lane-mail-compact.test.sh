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
  CALL_ENV=("HOME=$COP_HOME")
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
printf -v HANDOFF_SET '%q --state-dir %q set %q handoff' "$LANE/.agents/skills/orch/scripts/workflow-state" "$LANE/tmp" KEN-301
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
new_compact_overseer() { # NAME
  CALL_ENV=("HOME=$COP_HOME" "COPILOT_HOME=$TMP_ROOT")
  new_lane "$1" main
  unmark_lanes
  rm -f -- "${LANE:?}/.claude/hooks/lane-mail-check.sh"
  install_hook "$TEST_DIR/../lane-mail-compact.sh" "$LANE/.github/hooks/lane-mail-compact.sh"
  install_hook "$HOOK" "$LANE/.github/hooks/lane-mail-check.sh"
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
# The lane's turn-end refusal removed: a flagged lane ends its turn unheld.
mutant compact-unheld -e 's@^  \[ "\$COMPACTED" != true \] || refuse_handoff compacted auto$@  :@'
new_compact_lane control_unheld KEN-314 "$MUTANT_PATH"
REPORT_ITEM=KEN-314
compact auto
turn_end
assert_eq "RC=$RC decision=$(stdout_field .decision)" "RC=0 decision=" \
  "control: without the lane's refusal a flagged Copilot lane ends its turn unheld"

# The wrapper's arm swapped for the turn end's: the compaction is judged as a
# turn end and never flagged.
MUTANT_SOURCE="$TEST_DIR/../lane-mail-compact.sh" mutant compact-as-stop -e 's@ "\$JUDGE" compact$@ "$JUDGE"@'
new_compact_lane control_wrapper KEN-317 "$HOOK" "$MUTANT_PATH"
compact auto
assert_eq "flag=$(flag)" "flag=none" \
  "control: the wrapper running the turn-end arm never flags the compaction"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
