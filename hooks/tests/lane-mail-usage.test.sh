#!/usr/bin/env bash
# The usage arm of the lane-mail-check entry, the Copilot context reader: the
# entry installed where kendex renders it for Copilot, fed the payload the
# orch copilot-lane-context extension hands it from one `session.usage_info`
# event of the session's root agent, {session_id, cwd, current_tokens,
# token_limit}. The extension's own rules are skills/orch/tests/
# copilot-lane-context.sh's; how the turn end judges the reading is the
# runtime's rows' subject. These rows hold what reaches the verb through the
# entry: the arm, the install's directory as the harness spelled it, the
# payload's own directory, and a global install's walk. The shared world is
# lib/lane-mail-world.sh.
set -euo pipefail

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

# Every run's user home is COP_HOME, where the turn end keeps its Copilot lead
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
  CALL_ENV=("HOME=$COP_HOME")
  new_lane "$1" "$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  rm -f -- "${LANE:?}/.claude/hooks/lane-mail-check.sh"
  install_copilot_hooks "$LANE/.github/hooks" "${3:-$HOOK}"
  mkdir -p "$LANE/tmp/lane-mail/$2"
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
# What a run wrote on both streams, the first stderr line keyed.
quiet() { printf 'RC=%s stdout=%s stderr=%s' "$RC" "$(cat "$TMP_ROOT/stdout")" "$(first_line)"; }
# The record in BOX as `tokens window session model`, or `none`.
record() {
  jq -r '"\(.tokens) \(.window) \(.session_id) \(.model)"' "$BOX/context.json" 2>/dev/null || echo none
}

echo "=== the reading ==="
new_usage_lane lane KEN-401
usage 150000 272000
assert_eq "$(quiet) record=$(record)" "RC=0 stdout= stderr=- record=150000 217600 s1 null" \
  "a lane's reading reaches the verb through the entry and is recorded silently"
# The reading is judged in the directory its payload names, not the one the
# extension happens to run the hook from; the entry finds its install from
# its own directory.
CALL_DIR="$TMP_ROOT"
usage 160000 272000
CALL_DIR=""
assert_eq "$(quiet) record=$(record)" "RC=0 stdout= stderr=- record=160000 217600 s1 null" \
  "a hook run from another directory records the lane its payload's cwd names"

echo "=== a gap is refused at exit 2 on stderr, for the extension's timeline ==="
new_usage_lane unrecorded KEN-407
usage 150000 272000 s5
assert_eq "$(quiet) record=$(record)" "RC=2 stdout= stderr=lane-mail-check: session-unrecorded=s5 record=none" \
  "a reading of a session no lead record names is refused and recorded nowhere"
new_usage_lane invalid KEN-403
usage 150000 0
assert_eq "$(quiet) record=$(record)" "RC=2 stdout= stderr=lane-mail-check: payload=invalid-json record=none" \
  "a reading naming no token limit is refused as a payload it cannot read"
new_usage_lane claude-copy KEN-405
install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
JUDGE="$LANE/.claude/hooks/lane-mail-check.sh"
usage 150000 272000
assert_eq "$(quiet) record=$(record)" "RC=2 stdout= stderr=lane-mail-check: harness-unlisted=$LANE/.claude/hooks record=none" \
  "an install that is not Copilot's refuses a reading it would record as another harness's"
# The global scope, under the Copilot home, with the orch skill in that
# home's own skills directory as a global install renders it: the entry's
# walk finds the home's reader, and the verb knows the install as Copilot's
# by its registry document.
new_usage_lane global KEN-406
rm -rf -- "${LANE:?}/.github/hooks"
GLOBAL_HOME="$TMP_ROOT/copilot-home"
mkdir -p "$GLOBAL_HOME/skills/orch"
ln -s -f -n "$REPO_ROOT/skills/orch/scripts" "$GLOBAL_HOME/skills/orch/scripts"
mkdir -p "$GLOBAL_HOME/skills/mailbox"
ln -s -f -n "$REPO_ROOT/skills/mailbox/scripts" "$GLOBAL_HOME/skills/mailbox/scripts"
install_copilot_hooks "$GLOBAL_HOME/hooks"
JUDGE="$GLOBAL_HOME/hooks/lane-mail-check.sh"
usage 150000 272000
assert_eq "$(quiet) record=$(record)" "RC=0 stdout= stderr=- record=150000 217600 s1 null" \
  "the judge in the Copilot home's global scope records the lane's reading"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
