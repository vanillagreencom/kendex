#!/usr/bin/env bash
# Regression tests for review-artifact-check: deterministic on-disk acceptance
# of reviewer JSON artifacts in the orch review-pr workflow.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/review-artifact-check"
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

echo "=== review-artifact-check ==="

worktree="$TMP_ROOT/wt"
mkdir -p "$worktree/tmp"
delegated_at=1750000000
before=$((delegated_at - 100))
after=$((delegated_at + 100))
later=$((delegated_at + 200))

# --- missing: no artifacts at all ---
set +e
out="$("$CHECK" "$worktree" reviewer-quality "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "missing artifact exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "missing artifact reports ok=false"
assert_eq "$(jq -r '.path' <<<"$out")" "null" "missing artifact reports null path"
assert_eq "$(jq -r '.reason' <<<"$out")" "missing" "missing artifact reports reason=missing"

# --- other agent's artifact does not count ---
other="$worktree/tmp/review-reviewer-arch-20260709-010101.json"
printf '{"verdict":"pass","items":[]}' > "$other"
touch -d "@$after" "$other"
set +e
out="$("$CHECK" "$worktree" reviewer-quality "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "other agent's artifact exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "missing" "other agent's artifact still reason=missing"

# --- stale: artifact predates delegation ---
stale="$worktree/tmp/review-reviewer-quality-20260709-010101.json"
printf '{"verdict":"pass","items":[]}' > "$stale"
touch -d "@$before" "$stale"
set +e
out="$("$CHECK" "$worktree" reviewer-quality "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "stale artifact exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "stale artifact reports ok=false"
assert_eq "$(jq -r '.path' <<<"$out")" "$stale" "stale artifact reports its path"
assert_eq "$(jq -r '.reason' <<<"$out")" "stale" "stale artifact reports reason=stale"

# --- invalid: fresh artifact without verdict field ---
invalid="$worktree/tmp/review-reviewer-quality-20260709-020202.json"
printf '{"items":[]}' > "$invalid"
touch -d "@$after" "$invalid"
set +e
out="$("$CHECK" "$worktree" reviewer-quality "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "fresh artifact missing verdict exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "fresh artifact missing verdict reports reason=invalid"
assert_eq "$(jq -r '.path' <<<"$out")" "$invalid" "invalid report points at newest fresh artifact"

# --- valid: fresh artifact with verdict wins over stale/invalid siblings ---
valid="$worktree/tmp/review-reviewer-quality-20260709-030303.json"
printf '{"verdict":"action_required","items":[{"category":"fix"}]}' > "$valid"
touch -d "@$later" "$valid"
out="$("$CHECK" "$worktree" reviewer-quality "$delegated_at")"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "valid fresh artifact reports ok=true"
assert_eq "$(jq -r '.path' <<<"$out")" "$valid" "valid fresh artifact reports its path"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "valid fresh artifact reports reason=valid"

# --- newest artifact invalid: falls back to older fresh valid artifact ---
newest_invalid="$worktree/tmp/review-reviewer-quality-20260709-040404.json"
printf 'not json' > "$newest_invalid"
touch -d "@$((later + 100))" "$newest_invalid"
out="$("$CHECK" "$worktree" reviewer-quality "$delegated_at")"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "newest-invalid falls back to older valid artifact"
assert_eq "$(jq -r '.path' <<<"$out")" "$valid" "fallback selects the older fresh valid artifact"

# --- --file mode: explicit path validation (external review output) ---
ext_valid="$worktree/tmp/review-external-20260709-050505.json"
printf '{"verdict":"pass","items":[]}' > "$ext_valid"
out="$("$CHECK" --file "$ext_valid")"
rc=$?
assert_eq "$rc" "0" "--file valid artifact exits 0"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "--file valid reports ok=true"
assert_eq "$(jq -r '.path' <<<"$out")" "$ext_valid" "--file valid reports its path"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file valid reports reason=valid"

# --file with NO boundary does not apply the staleness gate — an old mtime still validates
touch -d "@$before" "$ext_valid"
out="$("$CHECK" --file "$ext_valid")"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "--file without boundary ignores mtime (existence+verdict only)"

# --- --file mode: OPTIONAL delegated_at boundary applies glob mode's freshness gate ---
# older-than-boundary mtime → stale
touch -d "@$before" "$ext_valid"
set +e
out="$("$CHECK" --file "$ext_valid" "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "--file with boundary, older mtime exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "--file stale reports ok=false"
assert_eq "$(jq -r '.path' <<<"$out")" "$ext_valid" "--file stale reports its path"
assert_eq "$(jq -r '.reason' <<<"$out")" "stale" "--file older-than-boundary reports reason=stale"

# newer-than-boundary mtime → valid
touch -d "@$after" "$ext_valid"
out="$("$CHECK" --file "$ext_valid" "$delegated_at")"
rc=$?
assert_eq "$rc" "0" "--file with boundary, newer mtime exits 0"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "--file fresh (mtime >= boundary) reports ok=true"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file newer-than-boundary reports reason=valid"

# mtime exactly equal to boundary is fresh (not stale) — matches glob mode's >= semantics
touch -d "@$delegated_at" "$ext_valid"
out="$("$CHECK" --file "$ext_valid" "$delegated_at")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file mtime == boundary is fresh"

# fresh mtime but missing verdict → invalid (freshness passes, verdict gate fails)
ext_fresh_noverdict="$worktree/tmp/review-external-20260709-070707.json"
printf '{"items":[]}' > "$ext_fresh_noverdict"
touch -d "@$after" "$ext_fresh_noverdict"
set +e
out="$("$CHECK" --file "$ext_fresh_noverdict" "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "--file fresh-but-no-verdict with boundary exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "--file fresh-but-no-verdict with boundary reports reason=invalid"

# missing file with a boundary still reports missing (existence checked before freshness)
set +e
out="$("$CHECK" --file "$worktree/tmp/review-external-nope.json" "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "--file missing with boundary exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "missing" "--file missing with boundary reports reason=missing"

# --file: missing file
set +e
out="$("$CHECK" --file "$worktree/tmp/review-external-does-not-exist.json")"
rc=$?
set -e
assert_eq "$rc" "1" "--file missing artifact exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "--file missing reports ok=false"
assert_eq "$(jq -r '.path' <<<"$out")" "null" "--file missing reports null path"
assert_eq "$(jq -r '.reason' <<<"$out")" "missing" "--file missing reports reason=missing"

# --file: exists but no verdict field
ext_invalid="$worktree/tmp/review-external-20260709-060606.json"
printf '{"items":[]}' > "$ext_invalid"
set +e
out="$("$CHECK" --file "$ext_invalid")"
rc=$?
set -e
assert_eq "$rc" "1" "--file missing verdict exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "--file missing verdict reports reason=invalid"
assert_eq "$(jq -r '.path' <<<"$out")" "$ext_invalid" "--file invalid reports the file path"

# --- usage errors ---
set +e
"$CHECK" "$worktree" reviewer-quality >/dev/null 2>&1
assert_eq "$?" "2" "missing arguments exit 2"
"$CHECK" "$worktree" reviewer-quality not-a-number >/dev/null 2>&1
assert_eq "$?" "2" "non-numeric delegated_at exits 2"
"$CHECK" "$TMP_ROOT/does-not-exist" reviewer-quality "$delegated_at" >/dev/null 2>&1
assert_eq "$?" "2" "nonexistent worktree exits 2"
"$CHECK" --file >/dev/null 2>&1
assert_eq "$?" "2" "--file with no path exits 2"
"$CHECK" --file "$ext_valid" not-a-number >/dev/null 2>&1
assert_eq "$?" "2" "--file non-numeric boundary exits 2"
"$CHECK" --file "$ext_valid" "$delegated_at" extra-arg >/dev/null 2>&1
assert_eq "$?" "2" "--file with too many args exits 2"
set -e

# --- review-pr.md wires the deterministic acceptance ---
review_pr="$REPO_ROOT/skills/orch/workflows/review-pr.md"
assert_file_contains "$review_pr" ".agents/skills/orch/scripts/review-artifact-check [WORKTREE_PATH] [AGENT]" "review-pr acceptance runs review-artifact-check"
assert_file_not_contains "$review_pr" 'A return message arrives with `Verdict:` and `File:` lines, *or*' "review-pr no longer accepts return-message-only completion"
assert_file_contains "$review_pr" "a return message with \`Verdict:\`/\`File:\` lines is never sufficient by itself" "review-pr states artifact is the only acceptance condition"
assert_file_contains "$review_pr" "exactly one" "review-pr limits incomplete returns to one re-delegation"
assert_file_contains "$review_pr" "using your harness file-write tool" "review-pr re-delegation instructs harness file-write tool"
assert_file_contains "$review_pr" 'review-artifact-check --file "$EXTERNAL_OUTPUT"' "review-pr validates external output via --file mode"
assert_file_not_contains "$review_pr" "if jq -e '.verdict'" "review-pr no longer prescribes inline if/redirection for external verdict check"
assert_file_contains "$review_pr" 'review-artifact-check --file "$EXTERNAL_OUTPUT" [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND]' "review-pr passes review_delegated_at as the --file freshness boundary"

# --- submit-pr.md wires the --file freshness boundary for the local review ---
submit_pr="$REPO_ROOT/skills/orch/workflows/submit-pr.md"
assert_file_contains "$submit_pr" 'review-artifact-check --file "$LOCAL_OUTPUT" [LOCAL_STARTED_AT]' "submit-pr passes a delegated-at boundary to the --file freshness check"
assert_file_contains "$submit_pr" "git-context timestamp epoch" "submit-pr captures an epoch boundary before running the local review"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
