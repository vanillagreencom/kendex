#!/usr/bin/env bash
# Regression tests for dev-artifact-check: deterministic on-disk acceptance of a
# dev agent's completion JSON artifact in the orch dev-start / dev-fix workflows.
# The artifact makes a dev completion recoverable when the live return message is
# lost to a harness tool timeout mid-tail (vstack#770), mirroring the reviewer
# completion-artifact gate.

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

echo "=== dev-artifact-check ==="

worktree="$TMP_ROOT/wt"
mkdir -p "$worktree/tmp"
issue="issue-770"
artifact="$worktree/tmp/dev-return-$issue.json"
delegated_at=1750000000
before=$((delegated_at - 100))
after=$((delegated_at + 100))

# A complete implement-kind receipt (all five required fields present).
implement_json='{"kind":"implement","issue":"issue-770","branch":"issue-770","commit":"abc123f","validate":"pass","qa_labels":["needs-review"],"summary_posted":true,"bundled":false,"items":[]}'
# A complete fix-kind receipt with items[].
fix_json='{"kind":"fix","issue":"issue-770","branch":"issue-770","commit":"def456a","validate":"FAILING: lint","summary_posted":true,"bundled":false,"items":[{"n":1,"decision":"Applied","reasoning":"fixed nil deref"}]}'

# --- missing: no artifact at all ---
set +e
out="$("$CHECK" "$worktree" "$issue" "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "missing artifact exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "missing artifact reports ok=false"
assert_eq "$(jq -r '.path' <<<"$out")" "null" "missing artifact reports null path"
assert_eq "$(jq -r '.reason' <<<"$out")" "missing" "missing artifact reports reason=missing"

# --- stale: artifact predates delegation ---
printf '%s' "$implement_json" > "$artifact"
touch -d "@$before" "$artifact"
set +e
out="$("$CHECK" "$worktree" "$issue" "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "stale artifact exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "stale artifact reports ok=false"
assert_eq "$(jq -r '.path' <<<"$out")" "$artifact" "stale artifact reports its path"
assert_eq "$(jq -r '.reason' <<<"$out")" "stale" "stale artifact reports reason=stale"

# --- valid: fresh implement receipt ---
touch -d "@$after" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at")"
rc=$?
assert_eq "$rc" "0" "valid implement receipt exits 0"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "valid implement receipt reports ok=true"
assert_eq "$(jq -r '.path' <<<"$out")" "$artifact" "valid implement receipt reports its path"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "valid implement receipt reports reason=valid"

# --- valid: fresh fix receipt (kind: fix, populated items[]) ---
printf '%s' "$fix_json" > "$artifact"
touch -d "@$after" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "valid fix receipt reports reason=valid"

# mtime exactly equal to the boundary is fresh (>= semantics, not stale)
touch -d "@$delegated_at" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "mtime == boundary is fresh"

# --- invalid: each required field missing → invalid (fresh, so freshness passes first) ---
# not JSON at all
printf 'not json' > "$artifact"
touch -d "@$after" "$artifact"
set +e
out="$("$CHECK" "$worktree" "$issue" "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "non-JSON artifact exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "non-JSON artifact reports reason=invalid"
assert_eq "$(jq -r '.path' <<<"$out")" "$artifact" "invalid artifact reports its path"

# .kind missing
printf '{"issue":"issue-770","branch":"b","commit":"c","validate":"pass"}' > "$artifact"
touch -d "@$after" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at" 2>/dev/null || true)"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "missing .kind reports reason=invalid"

# .kind present but not implement|fix
printf '{"kind":"review","issue":"issue-770","branch":"b","commit":"c","validate":"pass"}' > "$artifact"
touch -d "@$after" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at" 2>/dev/null || true)"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "out-of-domain .kind reports reason=invalid"

# .issue missing
printf '{"kind":"implement","branch":"b","commit":"c","validate":"pass"}' > "$artifact"
touch -d "@$after" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at" 2>/dev/null || true)"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "missing .issue reports reason=invalid"

# .branch missing
printf '{"kind":"implement","issue":"issue-770","commit":"c","validate":"pass"}' > "$artifact"
touch -d "@$after" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at" 2>/dev/null || true)"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "missing .branch reports reason=invalid"

# .commit missing
printf '{"kind":"implement","issue":"issue-770","branch":"b","validate":"pass"}' > "$artifact"
touch -d "@$after" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at" 2>/dev/null || true)"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "missing .commit reports reason=invalid"

# .validate missing
printf '{"kind":"implement","issue":"issue-770","branch":"b","commit":"c"}' > "$artifact"
touch -d "@$after" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at" 2>/dev/null || true)"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "missing .validate reports reason=invalid"

# empty-string required field is as lost as a missing one — each field, symmetrically
printf '{"kind":"implement","issue":"issue-770","branch":"","commit":"c","validate":"pass"}' > "$artifact"
touch -d "@$after" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at" 2>/dev/null || true)"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "empty .branch reports reason=invalid"

printf '{"kind":"implement","issue":"","branch":"b","commit":"c","validate":"pass"}' > "$artifact"
touch -d "@$after" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at" 2>/dev/null || true)"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "empty .issue reports reason=invalid"

printf '{"kind":"implement","issue":"issue-770","branch":"b","commit":"","validate":"pass"}' > "$artifact"
touch -d "@$after" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at" 2>/dev/null || true)"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "empty .commit reports reason=invalid"

printf '{"kind":"implement","issue":"issue-770","branch":"b","commit":"c","validate":""}' > "$artifact"
touch -d "@$after" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at" 2>/dev/null || true)"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "empty .validate reports reason=invalid"

# freshness is checked before field validation: a stale artifact with missing
# fields still reports stale, not invalid
printf '{"kind":"implement"}' > "$artifact"
touch -d "@$before" "$artifact"
out="$("$CHECK" "$worktree" "$issue" "$delegated_at" 2>/dev/null || true)"
assert_eq "$(jq -r '.reason' <<<"$out")" "stale" "stale-and-incomplete artifact reports reason=stale (freshness first)"

# --- --file mode: explicit path validation ---
ext="$worktree/tmp/dev-return-explicit.json"
printf '%s' "$implement_json" > "$ext"
out="$("$CHECK" --file "$ext")"
rc=$?
assert_eq "$rc" "0" "--file valid artifact exits 0"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "--file valid reports ok=true"
assert_eq "$(jq -r '.path' <<<"$out")" "$ext" "--file valid reports its path"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file valid reports reason=valid"

# --file with NO boundary ignores mtime — an old mtime still validates
touch -d "@$before" "$ext"
out="$("$CHECK" --file "$ext")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file without boundary ignores mtime (existence+fields only)"

# --file with OPTIONAL boundary applies the freshness gate: older mtime → stale
touch -d "@$before" "$ext"
set +e
out="$("$CHECK" --file "$ext" "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "--file with boundary, older mtime exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "stale" "--file older-than-boundary reports reason=stale"

# --file with boundary: newer mtime → valid
touch -d "@$after" "$ext"
out="$("$CHECK" --file "$ext" "$delegated_at")"
rc=$?
assert_eq "$rc" "0" "--file with boundary, newer mtime exits 0"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file newer-than-boundary reports reason=valid"

# --file: mtime exactly equal to boundary is fresh
touch -d "@$delegated_at" "$ext"
out="$("$CHECK" --file "$ext" "$delegated_at")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file mtime == boundary is fresh"

# --file: fresh mtime but a required field missing → invalid (freshness passes, fields fail)
printf '{"kind":"fix","issue":"i","branch":"b","commit":"c"}' > "$ext"
touch -d "@$after" "$ext"
set +e
out="$("$CHECK" --file "$ext" "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "--file fresh-but-incomplete with boundary exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "--file fresh-but-incomplete with boundary reports reason=invalid"

# --file: missing file (existence checked before freshness)
set +e
out="$("$CHECK" --file "$worktree/tmp/dev-return-nope.json" "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "--file missing with boundary exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "--file missing reports ok=false"
assert_eq "$(jq -r '.path' <<<"$out")" "null" "--file missing reports null path"
assert_eq "$(jq -r '.reason' <<<"$out")" "missing" "--file missing reports reason=missing"

# --- usage errors ---
set +e
"$CHECK" "$worktree" "$issue" >/dev/null 2>&1
assert_eq "$?" "2" "missing arguments exit 2"
"$CHECK" "$worktree" "$issue" not-a-number >/dev/null 2>&1
assert_eq "$?" "2" "non-numeric delegated_at exits 2"
"$CHECK" "$TMP_ROOT/does-not-exist" "$issue" "$delegated_at" >/dev/null 2>&1
assert_eq "$?" "2" "nonexistent worktree exits 2"
"$CHECK" "$worktree" "" "$delegated_at" >/dev/null 2>&1
assert_eq "$?" "2" "empty issue_id exits 2"
"$CHECK" "$worktree" "$issue" "$delegated_at" extra-arg >/dev/null 2>&1
assert_eq "$?" "2" "primary mode with too many args (4 positional) exits 2"
"$CHECK" --file >/dev/null 2>&1
assert_eq "$?" "2" "--file with no path exits 2"
"$CHECK" --file "$ext" not-a-number >/dev/null 2>&1
assert_eq "$?" "2" "--file non-numeric boundary exits 2"
"$CHECK" --file "$ext" "$delegated_at" extra-arg >/dev/null 2>&1
assert_eq "$?" "2" "--file with too many args exits 2"
set -e

# --- doc wiring: the workflows record dev_delegated_at and gate on the artifact ---
# The dev-artifact-check assertions pin the third arg [DEV_DELEGATED_AT...]: dropping
# the freshness boundary disables the stale-artifact guard, so the boundary must stay
# wired on every path (vstack#770 B1). Mirrors review_artifact_check.sh pinning
# [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND].
DA_BOUNDARY="dev-artifact-check [WORKTREE_PATH] [ISSUE_ID] [DEV_DELEGATED_AT_FROM_PREVIOUS_COMMAND]"

dev_start="$REPO_ROOT/skills/orch/workflows/dev-start.md"
assert_file_contains "$dev_start" "workflow-state set-now [ISSUE_ID] dev_delegated_at" "dev-start records dev_delegated_at before delegation"
assert_file_contains "$dev_start" "$DA_BOUNDARY" "dev-start § 3 runs dev-artifact-check with the freshness boundary"

orch_dev_fix="$REPO_ROOT/skills/orch/workflows/dev-fix.md"
assert_file_contains "$orch_dev_fix" "workflow-state set-now [ISSUE_ID] dev_delegated_at" "orch dev-fix records dev_delegated_at before delegation"
assert_file_contains "$orch_dev_fix" "$DA_BOUNDARY" "orch dev-fix accepts via dev-artifact-check with the freshness boundary"

# Newly-wired fix paths (vstack#770 B1): both MUST re-stamp dev_delegated_at so a stale
# receipt at the one reused path can never be mis-accepted on an idle stall.
review_pr_comments="$REPO_ROOT/skills/orch/workflows/review-pr-comments.md"
assert_file_contains "$review_pr_comments" "workflow-state set-now [ISSUE_ID] dev_delegated_at" "review-pr-comments § 6.1 records dev_delegated_at before delegation"
assert_file_contains "$review_pr_comments" "$DA_BOUNDARY" "review-pr-comments § 6.1 accepts via dev-artifact-check with the freshness boundary"

ci_fix="$REPO_ROOT/skills/orch/workflows/ci-fix.md"
assert_file_contains "$ci_fix" "workflow-state set-now [ISSUE_ID] dev_delegated_at" "ci-fix § 3.2 re-stamps dev_delegated_at (stale-guard; its agent writes no artifact)"
assert_file_contains "$ci_fix" "$DA_BOUNDARY" "ci-fix § 3.2 stale-guard runs dev-artifact-check with the freshness boundary"

# --- doc wiring: dev workflows write the completion artifact before the return ---
dev_implement="$REPO_ROOT/skills/dev/workflows/dev-implement.md"
assert_file_contains "$dev_implement" "tmp/dev-return-[ISSUE_ID].json" "dev-implement § 10 writes the completion artifact"
dev_fix="$REPO_ROOT/skills/dev/workflows/dev-fix.md"
assert_file_contains "$dev_fix" "tmp/dev-return-[ISSUE_ID].json" "dev-fix § 6 writes the completion artifact"

# --- schema doc carries the dev_delegated_at field ---
state_schema="$REPO_ROOT/skills/orch/schemas/workflow-state.md"
assert_file_contains "$state_schema" "dev_delegated_at" "workflow-state schema documents dev_delegated_at"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
