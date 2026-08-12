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

# --- same-round records are IMMUTABLE: the delegated set is stamped once ---
# An identical re-invocation is an idempotent retry → success, same path,
# content untouched. A DIFFERENT set under the same round id would silently
# rewrite the authoritative delegated set (e.g. a retry with a partial list) —
# refused: a changed delegation needs a NEW round id.
out_rerun="$("$WRITE" --worktree "$worktree" --issue issue-1230 --round-id "$RID" \
  --item 1 "$ITEM1" --item 2 "$ITEM2")"
assert_eq "$out_rerun" "$out" "identical re-invocation is idempotent (exit 0, same path)"
assert_eq "$(jq -c '[.items[].n]' "$out")" "[1,2]" "identical re-invocation leaves the record unchanged"
assert_exit2 "a different item set under the same round id exits 2 (immutable round)" \
  --worktree "$worktree" --issue issue-1230 --round-id "$RID" --item 3 "replacement"
assert_eq "$(jq -c '[.items[].n]' "$out")" "[1,2]" "the refused rewrite left the original record intact"

# --- a fresh round id scopes a distinct file; the prior round's record survives ---
out2="$("$WRITE" --worktree "$worktree" --issue issue-1230 --round-id 2-2 --item 1 "next round")"
assert_eq "$([[ "$out2" != "$out" && -f "$out" && -f "$out2" ]] && echo yes)" "yes" \
  "a new round id writes a distinct record without clobbering the prior round's"

# --- --items-file: the harness-safe route for shell-hostile item text ---
# Real review blocks carry backticks and quotes; Codex rejects a literal
# backtick in a command even single-quoted, so the orchestrator builds the JSON
# with the harness file-write tool and passes one plain --items-file path.
items_file="$TMP_ROOT/items.json"
printf '%s' '[{"n":1,"text":"#1 | fix `parse()` — do not touch '"'"'raw'"'"' mode"},{"n":4,"text":"#4 | second item"}]' > "$items_file"
outf="$("$WRITE" --worktree "$worktree" --issue issue-1230 --round-id 3-3 --items-file "$items_file")"
assert_eq "$(jq -c '[.items[].n]' "$outf")" "[1,4]" "--items-file records the file's item numbers"
assert_eq "$(jq -r '.items[0].text' "$outf")" '#1 | fix `parse()` — do not touch '"'"'raw'"'"' mode' \
  "--items-file preserves backticks/quotes in item text verbatim"
# extra keys in an element are dropped, not stored (the record schema is {n, text})
printf '%s' '[{"n":1,"text":"t","extra":"x"}]' > "$items_file"
outf="$("$WRITE" --worktree "$worktree" --issue issue-1230 --round-id 4-4 --items-file "$items_file")"
assert_eq "$(jq -c '.items[0] | keys_unsorted' "$outf")" '["n","text"]' "--items-file normalizes elements to {n, text}"

assert_exit2 "--items-file with --item exits 2 (one item source)" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file" --item 1 t
assert_exit2 "--items-file with a nonexistent path exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$TMP_ROOT/nope.json"
printf 'not json' > "$items_file"
assert_exit2 "--items-file with unparseable JSON exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '{"n":1,"text":"t"}' > "$items_file"
assert_exit2 "--items-file with a non-array top level exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '[]' > "$items_file"
assert_exit2 "--items-file with an empty array exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '[{"n":1}]' > "$items_file"
assert_exit2 "--items-file element without text exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '[{"n":1.5,"text":"t"}]' > "$items_file"
assert_exit2 "--items-file with a non-integer n exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '[{"n":-1,"text":"t"}]' > "$items_file"
assert_exit2 "--items-file with a negative n exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '[{"n":1,"text":"a"},{"n":1,"text":"b"}]' > "$items_file"
assert_exit2 "--items-file with a duplicate n exits 2 (a set, not a list)" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '[{"n":1,"text":"   "}]' > "$items_file"
assert_exit2 "--items-file with whitespace-only text exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"

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
assert_exit2 "leading-zero --item N exits 2 (not a canonical integer)" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 01 t
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
