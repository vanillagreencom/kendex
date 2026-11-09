#!/usr/bin/env bash
# Tests for tools/ci-reach: each failed merge-group check answered within or
# outside the change's selection by the real tools/ci-job-set over this
# checkout, no answer for a check no job maps to, and a refused selection
# refused.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"

REACH="$ROOT/tools/ci-reach"
# A skill's own prose: the skill's `rest` shard and the lanes every measured
# class runs select it; the UI lane, the macOS lanes of an all-prose diff and
# another package's shard do not.
printf '%s\n' skills/price-handling/SKILL.md >"$TMP/paths"

reach() { # CLASS NAMES [PATHS] — the answer lines, then `exit=N`
  local status=0 out
  out="$(QUEUE_REACH_CLASS="$1" QUEUE_REACH_DOCS_ONLY=false QUEUE_REACH_PATHS="${3:-$TMP/paths}" \
    "$REACH" <<<"$2" 2>"$TMP/err")" || status=$?
  printf '%s\nexit=%s' "$out" "$status"
}

nl='
'
rest="Skill suites shard (rest, ubuntu-latest)"
bridge="Skill suites shard (pi-claude-bridge, ubuntu-latest)"
ui="UI (vitest, tsc, biome)"
macos="macOS cargo kendex-core"
bot="Bot instructions"
unmapped="Classify the diff"

check "each check answered by its lane or shard, CI by the others" \
  "within $rest${nl}outside $ui${nl}outside $bridge${nl}within $bot${nl}outside $macos${nl}within CI${nl}exit=0" \
  "$(reach micro "$rest$nl$ui$nl$bridge$nl$bot$nl$macos$nl$unmapped${nl}CI")"
check "CI outside where every other failed check is" \
  "outside $ui${nl}outside $bridge${nl}outside CI${nl}exit=0" \
  "$(reach micro "$ui$nl$bridge${nl}CI")"
check "no answer for a check no job maps to, nor for CI beside it" \
  "${nl}exit=0" "$(reach micro "$unmapped${nl}CI")"
check "no answer for CI alone" "${nl}exit=0" "$(reach micro CI)"
check "a class the selector refuses is refused" "${nl}exit=2" "$(reach bogus "$rest")"
grep -q '^ci-reach: cause=selection-refused' "$TMP/err" &&
  grep -q '^ci-job-set: cause=unknown-class' "$TMP/err" &&
  ok "the refusal names the selector's cause" || bad "the refusal names the selector's cause ($(cat "$TMP/err"))"

# Failed steps, read against the workflow's own steps: one that runs nothing
# of the checkout fails alike at every head.
t='	'
tmux_step="tmux for pane delivery tests"
check "a check whose every failed step runs nothing of the checkout is setup" \
  "setup $rest${nl}setup $ui${nl}setup CI${nl}exit=0" \
  "$(reach micro "$rest$t$tmux_step$nl$ui${t}Set up job${nl}CI")"
check "a failed suite step beside a setup step keeps the check's selection" \
  "within $rest${nl}within CI${nl}exit=0" \
  "$(reach micro "$rest$t$tmux_step${t}all other skill suites${nl}CI")"
check "a step that runs cargo over the checkout is no setup step" \
  "within $rest${nl}exit=0" "$(reach micro "$rest${t}kendex from this checkout")"
check "a failed step the workflow names nowhere keeps the check's selection" \
  "within $rest${nl}exit=0" "$(reach micro "$rest${t}a step no job has")"
check "CI is outside where the other checks are setup or outside" \
  "setup $rest${nl}outside $ui${nl}outside CI${nl}exit=0" \
  "$(reach micro "$rest$t$tmux_step$nl$ui${nl}CI")"
printf '%s\n' .github/workflows/skill-tests.yml >"$TMP/workflow-paths"
check "a change under .github/ reads no step as setup" \
  "within $rest${nl}exit=0" "$(reach micro "$rest$t$tmux_step" "$TMP/workflow-paths")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
