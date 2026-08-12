#!/usr/bin/env bash
# Regression tests for dev-round-write: the orchestrator-side writer that
# persists a fix round's delegated item set to the round-scoped record
# ([WORKTREE]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json) at delegation time
# (vstack#1230). Without it the delegated set exists only in the orchestrator's
# context: a respawned dev agent cannot write a truthful completion artifact,
# and dev-artifact-check --expect-items has no on-disk source of truth. The
# record follows the dev-return round-token discipline (vstack#776): the round
# token in the filename AND as internal "round_id".

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
WRITE="$REPO_ROOT/skills/orch/scripts/dev-round-write"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# Assert an invocation fails validation with exit code 2.
assert_exit2() {
  local name="$1"; shift
  set +e
  "$WRITE" "$@" >/dev/null 2>&1
  local rc=$?
  set -e
  assert_eq "$rc" "2" "$name"
}

echo "=== dev-round-write ==="

worktree="$TMP_ROOT/wt"
mkdir -p "$worktree"
RID="1750000000-77"

# --- valid: two-item round record ---
ITEM1='#1 | security-review | src/auth.rs
Description: "token refresh races"
Recommendation: "serialize refresh behind the existing lock"'
ITEM2='#2 | test-review | tests/auth.rs
Description: "no coverage for expired token"
Recommendation: "add expiry regression test"'
out="$("$WRITE" --worktree "$worktree" --issue issue-1230 --round-id "$RID" \
  --item 1 "$ITEM1" --item 2 "$ITEM2")"
assert_eq "$out" "$worktree/tmp/dev-round-issue-1230-$RID.json" "prints the round-scoped record path"
assert_eq "$([[ -f "$out" ]] && echo yes)" "yes" "wrote the file"
assert_eq "$(jq -r '.schema_version' "$out")" "1" ".schema_version is 1"
assert_eq "$(jq -r '.schema_version | type' "$out")" "number" ".schema_version is a JSON number"
assert_eq "$(jq -r '.round_id' "$out")" "$RID" ".round_id matches --round-id (internal token binding)"
assert_eq "$(jq -r '.issue' "$out")" "issue-1230" ".issue is the normalized state key"
assert_eq "$(jq -r '.items | length' "$out")" "2" ".items carries one entry per --item"
assert_eq "$(jq -r '.items[0].n' "$out")" "1" "first item keeps its delegated number"
assert_eq "$(jq -r '.items[0].n | type' "$out")" "number" ".items[].n is a JSON number"
assert_eq "$(jq -r '.items[1].text' "$out")" "$ITEM2" ".items[].text preserves the formatted block verbatim (multi-line)"

# --- re-running for the same round replaces the record (atomic overwrite) ---
"$WRITE" --worktree "$worktree" --issue issue-1230 --round-id "$RID" --item 3 "replacement" >/dev/null
assert_eq "$(jq -c '[.items[].n]' "$out")" "[3]" "re-run for the same round replaces the record"

# --- a fresh round id scopes a distinct file; the prior round's record survives ---
out2="$("$WRITE" --worktree "$worktree" --issue issue-1230 --round-id 2-2 --item 1 "next round")"
assert_eq "$([[ "$out2" != "$out" && -f "$out" && -f "$out2" ]] && echo yes)" "yes" \
  "a new round id writes a distinct record without clobbering the prior round's"

# --- usage/validation errors: all exit 2, nothing written ---
assert_exit2 "no --item exits 2 (an empty delegated set is not a fix round)" \
  --worktree "$worktree" --issue i --round-id 1-1
assert_exit2 "missing --worktree exits 2" --issue i --round-id 1-1 --item 1 t
assert_exit2 "nonexistent --worktree exits 2" \
  --worktree "$TMP_ROOT/nope" --issue i --round-id 1-1 --item 1 t
assert_exit2 "missing --issue exits 2" --worktree "$worktree" --round-id 1-1 --item 1 t
assert_exit2 "missing --round-id exits 2" --worktree "$worktree" --issue i --item 1 t
assert_exit2 "path-unsafe --issue (slash) exits 2" \
  --worktree "$worktree" --issue "a/b" --round-id 1-1 --item 1 t
assert_exit2 "path-traversal --round-id (..) exits 2" \
  --worktree "$worktree" --issue i --round-id ".." --item 1 t
assert_exit2 "non-numeric --item N exits 2" \
  --worktree "$worktree" --issue i --round-id 1-1 --item x t
assert_exit2 "empty --item TEXT exits 2" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 1 ""
assert_exit2 "whitespace-only --item TEXT exits 2" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 1 "   "
assert_exit2 "--item TEXT that is one of the writer's own flags exits 2 (forgotten value)" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 1 --worktree
assert_exit2 "--item with too few arguments exits 2" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 1
assert_exit2 "duplicate item number exits 2 (a set, not a list)" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 1 a --item 1 b
assert_exit2 "duplicate --issue exits 2 (no silent last-wins)" \
  --worktree "$worktree" --issue i --issue j --round-id 1-1 --item 1 t
assert_exit2 "unknown argument exits 2" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 1 t --bogus

set +e
"$WRITE" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h prints usage and exits 0"
set -e

# a failed invocation must not leave a partial record behind
bad="$worktree/tmp/dev-round-i-1-1.json"
assert_eq "$([[ -f "$bad" ]] && echo yes || echo no)" "no" "failed invocations write nothing"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
