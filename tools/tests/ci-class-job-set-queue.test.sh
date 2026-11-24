#!/usr/bin/env bash
# Tests for the CI ci class job set queue contract.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"

source "$TEST_DIR/lib/ci-job-set-case.sh"

# --- 1c. The queue's macOS legs ---------------------------------------------
# queue_macos_shards per row.
# WORLD (tree or fixture)|CLASS|PATHS (blank-separated)|MACOS
queue_table() {
  cat <<ROWS
tree|micro|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|false
tree|micro|skills/orch/scripts/resolve-base-branch|true
tree|standard|.github/instructions/code-review.md|false
tree|standard|skills/orch/SKILL.md|false
tree|render|.agents/skills/orch/SKILL.md|false
fixture|micro|skills/price-handling/scripts/x|true
fixture|micro|$PI|false
fixture|micro|.claude/hooks/lane-mail-check|true
fixture|micro|$PRICE $PI|true
ROWS
}
queue_selection() { # EVENT WORLD CLASS PATHS
  local world="$ROOT"
  [ "$2" = tree ] || world="$SEL_WORLD"
  SELECT_IN="$world" SELECT_EVENT="$1" \
    selection "$3" false "$(printf '%s\n' $4)"
}
queue_rows=0
while IFS='|' read -r world class paths macos; do
  for event in pull_request merge_group; do
    queue_rows=$((queue_rows + 1))
    got="$(queue_selection "$event" "$world" "$class" "$paths")"
    expected='[]'
    [ "$macos" = false ] || expected="$(macos_shards "$(field shards <<<"$got")")"
    check "queue legs: $class on $event over '$paths'" "$expected" "$(field queue_macos_shards <<<"$got")"
  done
done < <(queue_table)
[ "$queue_rows" -ge 9 ] || { echo "the queue table read $queue_rows rows" >&2; exit 1; }
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
