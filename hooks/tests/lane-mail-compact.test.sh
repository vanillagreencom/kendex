#!/usr/bin/env bash
# lane-mail-compact: the hook installed where kendex renders it for Copilot,
# beside the lane-mail-check entry it runs with the `compact` arm, fed the
# preCompact payload Copilot's hooks reference gives (camelCase: sessionId,
# timestamp, cwd, transcriptPath, trigger, customInstructions). What the
# turn end does with a compaction is the runtime's rows' subject; these rows
# hold the hook's own lines and the arm it hands the entry. The shared world
# is lib/lane-mail-world.sh; HOOK_UNDER_TEST overrides the entry the
# must-fail control runs beside.
set -euo pipefail

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

echo "=== lane-mail-compact: copilot ==="

# Every run's user home is COP_HOME, where the turn end keeps its Copilot lead
# records.
CALL_ENV=("HOME=$COP_HOME")
# A Copilot lane: the entry and this hook under `.github/hooks`, the orch
# install the repository renders, and s1, the lead every row names unless it
# names another, recorded by its session start alone.
new_compact_lane() { # NAME ITEM [JUDGE] [WRAPPER]
  CALL_ENV=("HOME=$COP_HOME")
  local branch
  branch="$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  new_lane "$1" "$branch"
  rm -f -- "${LANE:?}/.claude/hooks/lane-mail-check.sh"
  install_hook "${4:-$TEST_DIR/../lane-mail-compact.sh}" "$LANE/.github/hooks/lane-mail-compact.sh"
  install_hook "${3:-$HOOK}" "$LANE/.github/hooks/lane-mail-check.sh"
  mkdir -p "$LANE/tmp/lane-mail/$2"
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
# The flag in BOX as `session trigger`, or `none`.
flag() {
  jq -r '"\(.session_id) \(.trigger)"' "$BOX/compaction.json" 2>/dev/null || echo none
}
# What a run wrote on both streams, the first stderr line keyed.
quiet() { printf 'RC=%s stdout=%s stderr=%s' "$RC" "$(cat "$TMP_ROOT/stdout")" "$(first_line)"; }

new_compact_lane lane KEN-301
compact auto s7 s1
assert_eq "$(quiet) flag=$(flag)" "RC=0 stdout= stderr=lane-mail-check: session-unrecorded=s7 flag=none" \
  "a subagent's automatic compaction, its session no recorded lead, flags nothing and says so on stderr at exit 0"
compact auto
assert_eq "$(quiet) flag=$(flag)" "RC=0 stdout= stderr=- flag=s1 auto" \
  "the lead's automatic compaction is flagged, silently"

# The wrapper with no judge beside it refuses the gap at exit 2.
new_compact_lane nojudge KEN-307
rm -f -- "${LANE:?}/.github/hooks/lane-mail-check.sh"
compact auto
assert_eq "RC=$RC first=$(first_line)" "RC=2 first=lane-mail-compact: judge=$LANE/.github/hooks/lane-mail-check.sh" \
  "the hook with no judge beside it refuses the gap at exit 2"

echo "=== must-fail controls ==="
# The wrapper's arm swapped for the turn end's: the compaction is judged as a
# turn end and never flagged.
MUTANT_SOURCE="$TEST_DIR/../lane-mail-compact.sh" mutant compact-as-stop -e 's@ "\$JUDGE" compact$@ "$JUDGE"@'
new_compact_lane control_wrapper KEN-317 "$HOOK" "$MUTANT_PATH"
compact auto
assert_eq "flag=$(flag)" "flag=none" \
  "control: the wrapper running the turn-end arm never flags the compaction"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
