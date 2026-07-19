#!/usr/bin/env bash
# Regression tests for the numeric-key → issue-N state-file alias (vstack#660).
# GitHub-issue orchestration stores state under the normalized `issue-N` key,
# but managed workflow callers historically substituted the bare tracker
# number (e.g. `workflow-state append 290 …`), which targeted the nonexistent
# tmp/workflow-state-290.json and errored. Every subcommand except init now
# resolves a purely numeric key to the `issue-N` file when only that file
# exists; the exact-key file wins when present; when files exist under BOTH
# keys the command errors loudly (exit 2) instead of guessing; non-numeric
# keys never alias.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"

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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_file_exists() {
  local file="$1" name="$2"
  if [[ -f "$file" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected file to exist: %s\n' "$name" "$file"
  fi
}

assert_file_absent() {
  local file="$1" name="$2"
  if [[ ! -f "$file" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected file to be absent: %s\n' "$name" "$file"
  fi
}

echo "=== workflow-state numeric-key issue-N alias ==="

# Test 1: numeric key falls through to the issue-N file when only that exists,
# uniformly across get / append / increment / set / set-now / update / path /
# exists — and never creates a bare-number file as a side effect.
sd_alias="$TMP_ROOT/alias"
"$WS" --state-dir "$sd_alias" init issue-290 \
  --worktree "$REPO_ROOT" --branch issue-290 >/dev/null

branch_val="$("$WS" --state-dir "$sd_alias" get 290 .branch)"
assert_eq "$branch_val" "issue-290" "numeric get aliases to the issue-N file"

"$WS" --state-dir "$sd_alias" append 290 pr_comment_review.replied \
  '{"source_id":"T1","commit":"abc123","outcome":"applied"}'
replied_id="$("$WS" --state-dir "$sd_alias" get issue-290 '.pr_comment_review.replied[0].source_id')"
assert_eq "$replied_id" "T1" "numeric append writes into the issue-N file"

"$WS" --state-dir "$sd_alias" increment 290 pr_comment_review.iterations
iterations="$("$WS" --state-dir "$sd_alias" get issue-290 .pr_comment_review.iterations)"
assert_eq "$iterations" "1" "numeric increment writes into the issue-N file"

"$WS" --state-dir "$sd_alias" set 290 skip_qa true
skip_qa="$("$WS" --state-dir "$sd_alias" get issue-290 .skip_qa)"
assert_eq "$skip_qa" "true" "numeric set writes into the issue-N file"

"$WS" --state-dir "$sd_alias" set-now 290 review_delegated_at
delegated_at="$("$WS" --state-dir "$sd_alias" get issue-290 .review_delegated_at)"
assert_eq "$([[ "$delegated_at" =~ ^[0-9]+$ ]] && echo numeric)" "numeric" \
  "numeric set-now writes epoch seconds into the issue-N file"

"$WS" --state-dir "$sd_alias" update 290 '.cycles += 2'
cycles="$("$WS" --state-dir "$sd_alias" get issue-290 .cycles)"
assert_eq "$cycles" "2" "numeric update applies jq against the issue-N file"

path_val="$("$WS" --state-dir "$sd_alias" path 290)"
assert_eq "$path_val" "$sd_alias/workflow-state-issue-290.json" \
  "numeric path prints the issue-N file path"

exists_json="$("$WS" --state-dir "$sd_alias" exists --json 290)"
assert_eq "$(jq -r '.exists' <<<"$exists_json")" "true" \
  "numeric exists --json reports the issue-N state"
assert_eq "$(jq -r '.path' <<<"$exists_json")" "$sd_alias/workflow-state-issue-290.json" \
  "numeric exists --json reports the resolved issue-N path"

assert_file_absent "$sd_alias/workflow-state-290.json" \
  "aliased writes never create a bare-number state file"

# Test 2: exact-key file wins when it exists — a numeric key with its own
# state file is untouched by the alias.
sd_exact="$TMP_ROOT/exact"
"$WS" --state-dir "$sd_exact" init 123 \
  --worktree "$REPO_ROOT" --branch bare-123 >/dev/null
assert_file_exists "$sd_exact/workflow-state-123.json" \
  "init always creates the exact key given"
exact_branch="$("$WS" --state-dir "$sd_exact" get 123 .branch)"
assert_eq "$exact_branch" "bare-123" "exact-key file wins for numeric get"

# Test 3: both files exist → loud error (exit 2), never a guess, for reads
# and writes alike; neither file is modified.
sd_both="$TMP_ROOT/both"
"$WS" --state-dir "$sd_both" init issue-777 \
  --worktree "$REPO_ROOT" --branch issue-777 >/dev/null
"$WS" --state-dir "$sd_both" init 777 \
  --worktree "$REPO_ROOT" --branch bare-777 >/dev/null

set +e
both_get_out="$("$WS" --state-dir "$sd_both" get 777 .branch 2>&1)"
both_get_status=$?
both_set_out="$("$WS" --state-dir "$sd_both" set 777 skip_qa true 2>&1)"
both_set_status=$?
set -e
assert_eq "$both_get_status" "2" "ambiguous numeric get exits 2"
assert_contains "$both_get_out" "ambiguous state key '777'" \
  "ambiguous numeric get names the conflicting key"
assert_eq "$both_set_status" "2" "ambiguous numeric set exits 2"
assert_contains "$both_set_out" "ambiguous state key '777'" \
  "ambiguous numeric set names the conflicting key"
normalized_skip="$("$WS" --state-dir "$sd_both" get issue-777 .skip_qa)"
assert_eq "$normalized_skip" "false" "ambiguous write leaves the issue-N file untouched"

# Test 4: non-numeric keys never alias — a missing Linear-style key errors on
# its own exact file even when a same-suffix issue-N file exists nearby, and
# an existing Linear key resolves normally.
sd_nonnum="$TMP_ROOT/nonnum"
"$WS" --state-dir "$sd_nonnum" init PROJ-123 \
  --worktree "$REPO_ROOT" --branch proj-123 >/dev/null
proj_branch="$("$WS" --state-dir "$sd_nonnum" get PROJ-123 .branch)"
assert_eq "$proj_branch" "proj-123" "non-numeric keys resolve their exact file"

set +e
missing_out="$("$WS" --state-dir "$sd_nonnum" get PROJ-404 .branch 2>&1)"
missing_status=$?
set -e
assert_eq "$([[ "$missing_status" -ne 0 ]] && echo nonzero)" "nonzero" \
  "missing non-numeric key still errors"
assert_contains "$missing_out" "workflow-state-PROJ-404.json" \
  "missing non-numeric key error names the exact file (no alias probe)"

# Test 5: missing numeric key with no normalized file either → standard
# not-found error against the exact bare-number path.
set +e
missing_num_out="$("$WS" --state-dir "$sd_nonnum" get 555 .branch 2>&1)"
missing_num_status=$?
set -e
assert_eq "$([[ "$missing_num_status" -ne 0 ]] && echo nonzero)" "nonzero" \
  "numeric key with no state file at all errors"
assert_contains "$missing_num_out" "workflow-state-555.json" \
  "numeric no-file error names the exact bare-number path"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
