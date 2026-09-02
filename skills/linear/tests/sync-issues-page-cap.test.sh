#!/usr/bin/env bash
# An issues pull that reaches its safety cap still returns the rows it fetched,
# but says that the cache is truncated and how many rows it contains.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC="$SKILL_DIR/scripts/commands/sync.sh"
assert_tmpdir TMP_ROOT

git -C "$TMP_ROOT" init -q -b main
cd "$TMP_ROOT"
# shellcheck disable=SC1090
source "$SYNC"

COUNTER="$TMP_ROOT/calls"
graphql_query() {
  local n
  n=$(( $(cat "$COUNTER") + 1 ))
  echo "$n" >"$COUNTER"

  if [[ "$STUB_MODE" == "complete" ]]; then
    printf '{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"identifier":"T-1"}]}}'
    return 0
  fi

  printf '{"issues":{"pageInfo":{"hasNextPage":true,"endCursor":"c%s"},"nodes":[{"identifier":"T-%s"}]}}' "$n" "$n"
}

ERR_FILE="$TMP_ROOT/err"

STUB_MODE=complete
echo 0 >"$COUNTER"
run_output OUT rc sync_issues '' 2>"$ERR_FILE"
assert_eq "a complete pull succeeds" "$rc" "0"
assert_eq "a complete pull returns its issue" "$(printf '%s' "$OUT" | jq 'length')" "1"
assert_eq "a complete pull does not warn" "$(cat "$ERR_FILE")" ""

STUB_MODE=capped
echo 0 >"$COUNTER"
run_output OUT rc sync_issues '' 2>"$ERR_FILE"
assert_eq "a capped pull still returns its fetched issues" "$rc" "0"
assert_eq "the page cap stops the pull at 200 requests" "$(cat "$COUNTER")" "200"
assert_eq "a capped pull returns every fetched issue" "$(printf '%s' "$OUT" | jq 'length')" "200"
assert_file_contains "a capped pull warns with the page cap" "$ERR_FILE" "200-page safety cap"
assert_file_contains "a capped pull warning names the number of issues cached" "$ERR_FILE" "200 issues"
assert_file_contains "a capped pull warning says the cache is truncated" "$ERR_FILE" "cache is truncated"
