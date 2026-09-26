#!/usr/bin/env bash
# lib/lane-launch.sh's one reading of ORCH_QUESTION_TOOL: what a launched
# overseer carries for each value, and the words the fleet's own launchers
# take from the same table. One row per value the setting takes, plus the
# value it does not; the control below removes the policy's default arm.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$TEST_DIR/../scripts/lib" && pwd)/lane-launch.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# read_policy LIB SETTING FUNCTION ARGS... — `rc|stdout` of FUNCTION under
# the setting, in a shell that sourced LIB and carries none of this suite's
# own environment for the key; SETTING `unset` exports no value at all.
read_policy() {
  local lib="$1" setting="$2" rc=0 out
  shift 2
  if [[ "$setting" == unset ]]; then
    out="$(env -u ORCH_QUESTION_TOOL bash -c 'source "$1"; shift; "$@"' _ "$lib" "$@" 2>/dev/null)" || rc=$?
  else
    out="$(ORCH_QUESTION_TOOL="$setting" bash -c 'source "$1"; shift; "$@"' _ "$lib" "$@" 2>/dev/null)" || rc=$?
  fi
  printf '%s|%s' "$rc" "$out"
}

echo "=== lane-launch question-tool policy ==="

# SETTING|POLICY rc|out|CLAUDE WORDS rc|out|WHAT
while IFS='|' read -r setting policy_rc policy words_rc words what; do
  assert_eq "$(read_policy "$LIB" "$setting" launch_overseer_question_tool)" "$policy_rc|$policy" \
    "policy: $what"
  assert_eq "$(read_policy "$LIB" "$setting" launch_overseer_question_words claude)" "$words_rc|$words" \
    "claude words: $what"
done <<'ROWS'
unset|0|off|0|--disallowedTools=AskUserQuestion,EnterPlanMode|unset is off, and a launched overseer carries the words
off|0|off|0|--disallowedTools=AskUserQuestion,EnterPlanMode|off carries the words
overseer|0|keep|0||overseer keeps the tool: no words
on|3||3||on is not a value: refused as 3 before any word is chosen
ROWS

# A harness the table names no words for carries none under off, and the
# policy still answers.
assert_eq "$(read_policy "$LIB" off launch_overseer_question_words opencode)" "0|" \
  "opencode has no words to carry under off"

# Control: the policy without its default arm. An unset setting then answers
# nothing and refuses, so the default, the arm every launcher rests on, is
# what the rows above pin rather than the setting's spelling alone.
MUTANT="$TMP_ROOT/lane-launch.sh"
sed 's@case "${ORCH_QUESTION_TOOL:-off}" in@case "${ORCH_QUESTION_TOOL:-}" in@' "$LIB" > "$MUTANT"
assert_eq "$(cmp -s "$MUTANT" "$LIB" && echo same || echo differs)" "differs" \
  "control: the mutant really differs from lane-launch.sh"
assert_eq "$(read_policy "$MUTANT" unset launch_overseer_question_tool)" "3|" \
  "control: without the default arm an unset setting decides nothing"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
