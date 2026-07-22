#!/usr/bin/env bash
# Regression tests for dev-artifact-check: deterministic on-disk acceptance of a
# dev agent's completion JSON artifact in the orch dev-start / dev-fix /
# review-pr-comments workflows. Identity is by per-delegation ROUND ID, not mtime
# (vstack#776): the check resolves WT/tmp/dev-return-ISSUE-RID.json and requires
# the internal .round_id to match. The mtime freshness gate is gone.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
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

assert_file_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  fi
}

# Run the check and print just the reason (swallowing exit code).
reason() {
  "$CHECK" "$@" 2>/dev/null | jq -r '.reason' || true
}

echo "=== dev-artifact-check ==="

worktree="$TMP_ROOT/wt"
mkdir -p "$worktree/tmp"
issue="issue-770"
R="1750000000-4242"
artifact="$worktree/tmp/dev-return-$issue-$R.json"

# A complete implement-kind receipt (round-scoped, all required fields present).
valid_impl='{"schema_version":1,"round_id":"1750000000-4242","kind":"implement","issue":"issue-770","branch":"issue-770","commit":"abc123f","validate":"pass","qa_labels":["needs-review"],"summary_posted":true,"summary":null,"bundled":false,"items":[]}'
# A complete fix-kind receipt with items[] (n = 1,2).
valid_fix='{"schema_version":1,"round_id":"1750000000-4242","kind":"fix","issue":"issue-770","branch":"issue-770","commit":"def456a","validate":"FAILING: lint","summary_posted":true,"summary":null,"bundled":false,"items":[{"n":1,"decision":"Applied","reasoning":"fixed nil deref"},{"n":2,"decision":"Skipped","reasoning":"contradicts D010"}]}'

# --- missing: no artifact at the round-scoped path ---
set +e
out="$("$CHECK" --worktree "$worktree" --issue "$issue" --round-id "$R")"
rc=$?
set -e
assert_eq "$rc" "1" "missing artifact exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "missing artifact reports ok=false"
assert_eq "$(jq -r '.path' <<<"$out")" "null" "missing artifact reports null path"
assert_eq "$(jq -r '.reason' <<<"$out")" "missing" "missing artifact reports reason=missing"

# --- valid: fresh implement receipt at the round path ---
printf '%s' "$valid_impl" > "$artifact"
out="$("$CHECK" --worktree "$worktree" --issue "$issue" --round-id "$R")"
rc=$?
assert_eq "$rc" "0" "valid implement receipt exits 0"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "valid implement receipt reports ok=true"
assert_eq "$(jq -r '.path' <<<"$out")" "$artifact" "valid implement receipt reports its path"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "valid implement receipt reports reason=valid"

# --- valid: fix receipt (fallback items rule, no --expect-items) ---
printf '%s' "$valid_fix" > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "valid" "valid fix receipt reports reason=valid"

# --- round-id identity: a DIFFERENT requested round resolves a different path → missing ---
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id 9999-0)" "missing" "wrong round id resolves a different path → missing"

# --- round-id identity: internal round_id != expected (copied/renamed file) → invalid ---
printf '%s' "$valid_impl" | jq -c '.round_id="OTHER-1"' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "internal round_id mismatch reports reason=invalid"
printf '%s' "$valid_impl" > "$artifact"   # restore

# --- invalid: not JSON, and each required field wrong-typed/empty ---
printf 'not json' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "non-JSON artifact reports reason=invalid"

# missing / out-of-domain kind
printf '%s' "$valid_impl" | jq -c 'del(.kind)' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "missing .kind reports reason=invalid"
printf '%s' "$valid_impl" | jq -c '.kind="review"' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "out-of-domain .kind reports reason=invalid"

# type-strict scalars: a non-string issue/branch/commit/validate fails (not just "")
printf '%s' "$valid_impl" | jq -c '.issue=123' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "numeric .issue reports reason=invalid (type-strict)"
printf '%s' "$valid_impl" | jq -c '.branch=""' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "empty .branch reports reason=invalid"
printf '%s' "$valid_impl" | jq -c '.commit=["x"]' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "array .commit reports reason=invalid (type-strict)"
printf '%s' "$valid_impl" | jq -c '.validate=true' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "boolean .validate reports reason=invalid (type-strict)"

# round_id / schema_version required and typed
printf '%s' "$valid_impl" | jq -c 'del(.round_id)' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "missing .round_id reports reason=invalid"
printf '%s' "$valid_impl" | jq -c 'del(.schema_version)' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "missing .schema_version reports reason=invalid"
printf '%s' "$valid_impl" | jq -c '.schema_version="1"' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "string .schema_version reports reason=invalid (type-strict)"

# --- incomplete: kind fix OR bundled requires a non-empty, well-formed items[] ---
printf '%s' "$valid_fix" | jq -c 'del(.items)' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "incomplete" "fix with items missing reports reason=incomplete"
printf '%s' "$valid_fix" | jq -c '.items=[]' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "incomplete" "fix with empty items reports reason=incomplete"
printf '%s' "$valid_fix" | jq -c '.items="nope"' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "incomplete" "fix with non-array items reports reason=incomplete"
printf '%s' "$valid_fix" | jq -c '.items=[{"n":1,"decision":"Applied"}]' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "incomplete" "fix with item missing reasoning reports reason=incomplete"
printf '%s' "$valid_fix" | jq -c '.items=[{"n":1,"decision":"Applied","reasoning":""}]' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "incomplete" "fix with empty reasoning reports reason=incomplete"
printf '%s' "$valid_fix" | jq -c '.items=[{"n":1,"decision":"Nope","reasoning":"x"}]' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "incomplete" "fix with out-of-enum decision reports reason=incomplete"
printf '%s' "$valid_fix" | jq -c '.items=[{"n":"1","decision":"Applied","reasoning":"x"}]' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "incomplete" "fix with non-numeric item .n reports reason=incomplete"

# bundled implement with empty items → incomplete
printf '%s' "$valid_impl" | jq -c '.bundled=true' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "incomplete" "bundled implement with empty items reports reason=incomplete"

# single implement with items:[] → valid (implement without bundled tolerates empty items)
printf '%s' "$valid_impl" > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "valid" "single implement with items:[] stays valid"

# --- gate ordering: invalid (scalars/round) beats incomplete (items) ---
printf '%s' "$valid_fix" | jq -c 'del(.commit) | .items=[]' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "invalid scalar beats incomplete (fix missing .commit + empty items)"

# --- --expect-items: exact set coverage for fix rounds ---
printf '%s' "$valid_fix" > "$artifact"   # items n = [1,2]
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R" --expect-items 1,2)" "valid" "expect 1,2 exact match → valid"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R" --expect-items 2,1)" "valid" "expect 2,1 order-independent → valid"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R" --expect-items 1,2,3)" "incomplete" "expect 1,2,3 with 3 missing → incomplete"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R" --expect-items 1)" "incomplete" "expect 1 with extra 2 present → incomplete"
# duplicate item number in the artifact must not satisfy a distinct expected set
printf '%s' "$valid_fix" | jq -c '.items=[{"n":1,"decision":"Applied","reasoning":"a"},{"n":1,"decision":"Skipped","reasoning":"b"}]' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R" --expect-items 1,2)" "incomplete" "duplicate item n=1 does not cover {1,2} → incomplete"
# expect-items applies its own enum/reasoning rules even when the item set matches exactly
printf '%s' "$valid_fix" | jq -c '.items=[{"n":1,"decision":"Applied","reasoning":""},{"n":2,"decision":"Skipped","reasoning":"b"}]' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R" --expect-items 1,2)" "incomplete" "expect-items rejects empty reasoning → incomplete"
printf '%s' "$valid_fix" | jq -c '.items=[{"n":1,"decision":"Nope","reasoning":"a"},{"n":2,"decision":"Skipped","reasoning":"b"}]' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R" --expect-items 1,2)" "incomplete" "expect-items rejects out-of-enum decision (set matches) → incomplete"
printf '%s' "$valid_fix" > "$artifact"   # restore

# --- --file mode: explicit path validation ---
ext="$worktree/tmp/dev-return-explicit.json"
printf '%s' "$valid_impl" > "$ext"
out="$("$CHECK" --file "$ext")"
rc=$?
assert_eq "$rc" "0" "--file valid artifact exits 0"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file valid reports reason=valid"
# --file with a matching --round-id → valid; mismatch → invalid
assert_eq "$(reason --file "$ext" --round-id "$R")" "valid" "--file with matching --round-id → valid"
assert_eq "$(reason --file "$ext" --round-id NOPE-1)" "invalid" "--file with mismatched --round-id → invalid"
# --file with --expect-items
printf '%s' "$valid_fix" > "$ext"
assert_eq "$(reason --file "$ext" --expect-items 1,2)" "valid" "--file fix with matching --expect-items → valid"
assert_eq "$(reason --file "$ext" --expect-items 1)" "incomplete" "--file fix with wrong --expect-items → incomplete"
# --file missing
set +e
out="$("$CHECK" --file "$worktree/tmp/nope.json")"
rc=$?
set -e
assert_eq "$rc" "1" "--file missing exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "missing" "--file missing reports reason=missing"

# --- legacy positional mode REMOVED: a bare positional call is a usage error ---
# There is one identity model (round id); the pre-round positional stale-guard
# mode (and its only caller, ci-fix) is gone.
set +e
"$CHECK" "$worktree" "$issue" 1750000000 >/dev/null 2>&1
assert_eq "$?" "2" "removed legacy positional mode now exits 2 (usage error)"
set -e

# --- usage errors ---
set +e
"$CHECK" --worktree "$worktree" --issue "$issue" >/dev/null 2>&1
assert_eq "$?" "2" "round mode without --round-id exits 2"
"$CHECK" --issue "$issue" --round-id "$R" >/dev/null 2>&1
assert_eq "$?" "2" "round mode without --worktree exits 2"
"$CHECK" --worktree "$worktree" --issue "a/b" --round-id "$R" >/dev/null 2>&1
assert_eq "$?" "2" "round mode with path-unsafe --issue (slash) exits 2"
"$CHECK" --worktree "$worktree" --issue ".." --round-id "$R" >/dev/null 2>&1
assert_eq "$?" "2" "round mode with path-traversal --issue (..) exits 2"
"$CHECK" --worktree "$worktree" --issue "$issue" --round-id ".." >/dev/null 2>&1
assert_eq "$?" "2" "round mode with path-traversal --round-id (..) exits 2"
"$CHECK" --worktree "$worktree" --issue "$issue" --round-id "$R" --expect-items "1,x" >/dev/null 2>&1
assert_eq "$?" "2" "round mode with malformed --expect-items exits 2"
"$CHECK" --worktree "$TMP_ROOT/does-not-exist" --issue "$issue" --round-id "$R" >/dev/null 2>&1
assert_eq "$?" "2" "round mode with nonexistent worktree exits 2"
"$CHECK" --file >/dev/null 2>&1
assert_eq "$?" "2" "--file with no path exits 2"
"$CHECK" --worktree "$worktree" --issue "$issue" --round-id "$R" --bogus >/dev/null 2>&1
assert_eq "$?" "2" "unknown argument exits 2"
"$CHECK" >/dev/null 2>&1
assert_eq "$?" "2" "no mode (bare invocation) exits 2"
"$CHECK" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h prints usage and exits 0"
"$CHECK" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help prints usage and exits 0"
set -e

# --- round-trip: dev-return-write output validates in round mode ---
WRITE="$REPO_ROOT/skills/orch/scripts/dev-return-write"
rt_wt="$TMP_ROOT/rt"
mkdir -p "$rt_wt"
rt_impl="$("$WRITE" --worktree "$rt_wt" --kind implement --issue issue-9 --round-id 5-6 --branch b --commit c --validate pass)"
assert_eq "$([[ -f "$rt_impl" ]] && echo yes)" "yes" "writer produced the round-scoped implement artifact"
assert_eq "$(reason --worktree "$rt_wt" --issue issue-9 --round-id 5-6)" "valid" "writer implement output round-trips as valid"
"$WRITE" --worktree "$rt_wt" --kind fix --issue issue-9 --round-id 7-8 --branch b --commit c --validate pass --item 1 Applied a --item 2 Skipped b >/dev/null
assert_eq "$(reason --worktree "$rt_wt" --issue issue-9 --round-id 7-8 --expect-items 1,2)" "valid" "writer fix output round-trips with matching --expect-items"

# --- doc wiring: ALL FOUR dev/QA paths mint a fresh round id + accept via round mode ---
# dev-start / orch dev-fix / review-pr-comments / ci-fix each mint dev_round_id
# before delegating and accept via dev-artifact-check round mode — one identity
# model, no legacy carve-out. dev-start/dev-fix/review-pr-comments also embed the
# token in the delegation; ci-fix's agent writes no artifact so it does not.
ROUND_STAMP="workflow-state new-round-id [ISSUE_ID] dev_round_id"
ROUND_CHECK="dev-artifact-check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND]"
# Fix rounds must carry --expect-items as ONE contiguous command (a regression that
# drops the flag from the command while leaving it in prose would still pass two
# independent substring checks — so assert the full string).
ROUND_CHECK_EXPECT="$ROUND_CHECK --expect-items [ITEM_NUMBERS]"
WATCHDOG_STAMP="workflow-state set-now [ISSUE_ID] dev_delegated_at"
ARTIFACT_KEY_LINE="Artifact Key: [ISSUE_ID]"
LEGACY_CHECK="dev-artifact-check [WORKTREE_PATH] [ISSUE_ID] [DEV_DELEGATED_AT_FROM_PREVIOUS_COMMAND]"

assert_file_not_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

dev_start="$REPO_ROOT/skills/orch/workflows/dev-start.md"
assert_file_contains "$dev_start" "$WATCHDOG_STAMP" "dev-start still stamps dev_delegated_at (watchdog deadline)"
assert_file_contains "$dev_start" "$ROUND_STAMP" "dev-start mints dev_round_id before delegation"
assert_file_contains "$dev_start" "$ROUND_CHECK" "dev-start § 3 accepts via dev-artifact-check round mode"
assert_file_contains "$dev_start" "Round ID: [DEV_ROUND_ID]" "dev-start delegation carries the Round ID line"
assert_file_contains "$dev_start" "$ARTIFACT_KEY_LINE" "dev-start delegation carries the Artifact Key line (normalized state key)"

orch_dev_fix="$REPO_ROOT/skills/orch/workflows/dev-fix.md"
assert_file_contains "$orch_dev_fix" "$WATCHDOG_STAMP" "orch dev-fix still stamps dev_delegated_at"
assert_file_contains "$orch_dev_fix" "$ROUND_STAMP" "orch dev-fix mints dev_round_id before delegation"
assert_file_contains "$orch_dev_fix" "$ROUND_CHECK_EXPECT" "orch dev-fix accepts via round-mode dev-artifact-check WITH --expect-items in one command"
assert_file_contains "$orch_dev_fix" "Round ID: [DEV_ROUND_ID]" "orch dev-fix delegation carries the Round ID line"
assert_file_contains "$orch_dev_fix" "$ARTIFACT_KEY_LINE" "orch dev-fix delegation carries the Artifact Key line"

review_pr_comments="$REPO_ROOT/skills/orch/workflows/review-pr-comments.md"
assert_file_contains "$review_pr_comments" "$WATCHDOG_STAMP" "review-pr-comments § 6.1 still stamps dev_delegated_at"
assert_file_contains "$review_pr_comments" "$ROUND_STAMP" "review-pr-comments § 6.1 mints dev_round_id before delegation"
assert_file_contains "$review_pr_comments" "$ROUND_CHECK_EXPECT" "review-pr-comments accepts via round-mode dev-artifact-check WITH --expect-items in one command"
assert_file_contains "$review_pr_comments" "Round ID: [DEV_ROUND_ID]" "review-pr-comments delegation carries the Round ID line"
assert_file_contains "$review_pr_comments" "$ARTIFACT_KEY_LINE" "review-pr-comments delegation carries the Artifact Key line"

# ci-fix: now compliant with the round-id invariant — mints a fresh dev_round_id
# and accepts via round mode; the legacy positional call is gone.
ci_fix="$REPO_ROOT/skills/orch/workflows/ci-fix.md"
assert_file_contains "$ci_fix" "$WATCHDOG_STAMP" "ci-fix § 3.2 re-stamps dev_delegated_at (watchdog deadline)"
assert_file_contains "$ci_fix" "$ROUND_STAMP" "ci-fix § 3.2 mints a fresh dev_round_id before delegating (round-id invariant)"
assert_file_contains "$ci_fix" "$ROUND_CHECK" "ci-fix § 3.2 accepts via dev-artifact-check round mode"
assert_file_not_contains "$ci_fix" "$LEGACY_CHECK" "ci-fix § 3.2 no longer uses the legacy positional dev-artifact-check call"

# The removed legacy positional call must not survive in any orch workflow.
for wf in dev-start dev-fix review-pr-comments ci-fix; do
  assert_file_not_contains "$REPO_ROOT/skills/orch/workflows/$wf.md" "$LEGACY_CHECK" "$wf.md carries no legacy positional dev-artifact-check call"
done

# --- doc wiring: dev workflows write the completion artifact via dev-return-write with --round-id ---
# The dev workflows key the artifact to [ARTIFACT_KEY] (the normalized workflow-state
# key from the delegation's Artifact Key: line), NOT the tracker-native [ISSUE_ID],
# so a GitHub agent writes dev-return-issue-N-RID.json (what orch checks).
dev_implement="$REPO_ROOT/skills/dev/workflows/dev-implement.md"
assert_file_contains "$dev_implement" "dev-return-write --worktree [WORKTREE_PATH] --kind implement --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID]" "dev-implement § 10 keys the artifact to [ARTIFACT_KEY]"
dev_fix="$REPO_ROOT/skills/dev/workflows/dev-fix.md"
assert_file_contains "$dev_fix" "dev-return-write --worktree [WORKTREE_PATH] --kind fix --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID]" "dev-fix § 6 keys the artifact to [ARTIFACT_KEY]"

# --- schema docs carry the round-id / dev_round_id contract ---
dev_return_schema="$REPO_ROOT/skills/orch/schemas/dev-return.md"
assert_file_contains "$dev_return_schema" "dev-return-write" "dev-return schema references the writer"
assert_file_contains "$dev_return_schema" "round_id" "dev-return schema documents round_id identity"
assert_file_contains "$dev_return_schema" "schema_version" "dev-return schema documents schema_version"
assert_file_contains "$dev_return_schema" "incomplete" "dev-return schema documents the incomplete reason"
assert_file_contains "$dev_return_schema" "--expect-items" "dev-return schema documents the exact item-set rule"

state_schema="$REPO_ROOT/skills/orch/schemas/workflow-state.md"
assert_file_contains "$state_schema" "dev_delegated_at" "workflow-state schema documents dev_delegated_at"
assert_file_contains "$state_schema" "dev_round_id" "workflow-state schema documents dev_round_id"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
