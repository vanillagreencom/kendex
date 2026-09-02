#!/usr/bin/env bash
# An issues pull that reaches its safety cap still returns the rows it fetched,
# but says that the pull is incomplete and how many issues it fetched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC="$SKILL_DIR/scripts/commands/sync.sh"
assert_tmpdir TMP_ROOT

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
git -C "$TMP_ROOT" init -q -b main
cd "$TMP_ROOT"
# shellcheck disable=SC1090
source "$SYNC"

COUNTER="$TMP_ROOT/calls"
graphql_query() {
  local n has_next=true
  n=$(( $(cat "$COUNTER") + 1 ))
  echo "$n" >"$COUNTER"

  case "$STUB_MODE" in
    complete) has_next=false ;;
    under-cap)
      if (( n >= 3 )); then
        has_next=false
      fi
      ;;
    exact-cap)
      if (( n >= 200 )); then
        has_next=false
      fi
      ;;
    capped) ;;
    *) return 1 ;;
  esac

  if [[ "$STUB_MODE" == "capped" ]]; then
    printf '{"issues":{"pageInfo":{"hasNextPage":%s,"endCursor":"c%s"},"nodes":[{"identifier":"T-%s-a"},{"identifier":"T-%s-b"}]}}' "$has_next" "$n" "$n" "$n"
  else
    printf '{"issues":{"pageInfo":{"hasNextPage":%s,"endCursor":"c%s"},"nodes":[{"identifier":"T-%s"}]}}' "$has_next" "$n" "$n"
  fi
}

ERR_FILE="$TMP_ROOT/err"

STUB_MODE=complete
echo 0 >"$COUNTER"
run_output OUT rc sync_issues '' 2>"$ERR_FILE"
assert_eq "a complete pull succeeds" "$rc" "0"
assert_eq "a complete pull returns its issue" "$(printf '%s' "$OUT" | jq 'length')" "1"
assert_eq "a complete pull does not warn" "$(cat "$ERR_FILE")" ""

STUB_MODE=under-cap
echo 0 >"$COUNTER"
run_output OUT rc sync_issues '' 2>"$ERR_FILE"
assert_eq "an under-cap pull succeeds" "$rc" "0"
assert_eq "an under-cap pull reaches its terminal page" "$(cat "$COUNTER")" "3"
assert_eq "an under-cap pull returns every fetched issue" "$(printf '%s' "$OUT" | jq 'length')" "3"
assert_eq "an under-cap pull does not warn" "$(cat "$ERR_FILE")" ""

STUB_MODE=exact-cap
echo 0 >"$COUNTER"
run_output OUT rc sync_issues '' 2>"$ERR_FILE"
assert_eq "a pull completed on page 200 succeeds" "$rc" "0"
assert_eq "a pull completed on page 200 reaches its terminal page" "$(cat "$COUNTER")" "200"
assert_eq "a pull completed on page 200 returns every fetched issue" "$(printf '%s' "$OUT" | jq 'length')" "200"
assert_eq "a pull completed on page 200 does not warn" "$(cat "$ERR_FILE")" ""

STUB_MODE=capped
echo 0 >"$COUNTER"
run_output OUT rc sync_issues '' 2>"$ERR_FILE"
assert_eq "a capped pull still returns its fetched issues" "$rc" "0"
assert_eq "the page cap stops the pull at 200 requests" "$(cat "$COUNTER")" "200"
assert_eq "a capped pull returns every fetched issue" "$(printf '%s' "$OUT" | jq 'length')" "400"
assert_eq "a capped pull emits one warning" "$(awk '/Sync warning:/ { count++ } END { print count + 0 }' "$ERR_FILE")" "1"
assert_file_contains "a capped pull warns with the page cap" "$ERR_FILE" "200-page safety cap"
assert_file_contains "a capped pull warning names the number of issues fetched" "$ERR_FILE" "fetching 400 issues"
assert_file_contains "a capped pull warning says the pull is incomplete" "$ERR_FILE" "pull is incomplete"
