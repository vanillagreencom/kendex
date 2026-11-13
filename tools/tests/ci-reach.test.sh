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
# The lock record: the orch-rest shard, which holds the two orch suites that
# read it, and the lanes every measured class runs select it; the UI lane and
# the orch-oversee shard, which holds no suite that reads it, do not.
printf '%s\n' .kendex-lock.json >"$TMP/paths"

reach() { # CLASS NAMES — the answer lines, then `exit=N`
  local status=0 out
  out="$(QUEUE_REACH_CLASS="$1" QUEUE_REACH_DOCS_ONLY=false QUEUE_REACH_PATHS="$TMP/paths" \
    "$REACH" <<<"$2" 2>"$TMP/err")" || status=$?
  printf '%s\nexit=%s' "$out" "$status"
}

nl='
'
orch_rest="Skill suites shard (orch-rest, ubuntu-latest)"
oversee="Skill suites shard (orch-oversee, ubuntu-latest)"
ui="UI (vitest, tsc, biome)"
macos="macOS cargo kendex-core"
bot="Bot instructions"
unmapped="Classify the diff"

check "each check answered by its lane or shard, CI by the others" \
  "within $orch_rest${nl}outside $ui${nl}outside $oversee${nl}within $bot${nl}within $macos${nl}within CI${nl}exit=0" \
  "$(reach micro "$orch_rest$nl$ui$nl$oversee$nl$bot$nl$macos$nl$unmapped${nl}CI")"
check "CI outside where every other failed check is" \
  "outside $ui${nl}outside $oversee${nl}outside CI${nl}exit=0" \
  "$(reach micro "$ui$nl$oversee${nl}CI")"
check "no answer for a check no job maps to, nor for CI beside it" \
  "${nl}exit=0" "$(reach micro "$unmapped${nl}CI")"
check "no answer for CI alone" "${nl}exit=0" "$(reach micro CI)"
check "a class the selector refuses is refused" "${nl}exit=2" "$(reach bogus "$orch_rest")"
grep -q '^ci-reach: cause=selection-refused' "$TMP/err" &&
  grep -q '^ci-job-set: cause=unknown-class' "$TMP/err" &&
  ok "the refusal names the selector's cause" || bad "the refusal names the selector's cause ($(cat "$TMP/err"))"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
