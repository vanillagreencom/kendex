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

# --- no_review: self-reported no-review artifacts are rejected (vstack#652) ---
# A schema-valid pass verdict whose qa_metadata admits no review happened must
# never validate, regardless of verdict.
noreview="$worktree/tmp/review-external-20260718-010101.json"
printf '{"verdict":"pass","summary":"No review was actually performed","qa_metadata":{"review_performed":false,"reason":"no_scope_provided"}}' > "$noreview"
touch -d "@$after" "$noreview"
set +e
out="$("$CHECK" --file "$noreview")"
rc=$?
set -e
assert_eq "$rc" "1" "--file review_performed=false exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "--file review_performed=false reports ok=false"
assert_eq "$(jq -r '.path' <<<"$out")" "$noreview" "--file review_performed=false reports its path"
assert_eq "$(jq -r '.reason' <<<"$out")" "no_review" "--file review_performed=false reports reason=no_review"

# a no-review reason alone (without review_performed) is also an admission
noreview_reason="$worktree/tmp/review-external-20260718-020202.json"
printf '{"verdict":"pass","qa_metadata":{"reason":"no_scope_provided"}}' > "$noreview_reason"
set +e
out="$("$CHECK" --file "$noreview_reason")"
rc=$?
set -e
assert_eq "$rc" "1" "--file no-scope reason alone exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "no_review" "--file no-scope reason alone reports reason=no_review"

# backward compat: no qa_metadata at all still validates on existence + verdict
no_qa="$worktree/tmp/review-external-20260718-030303.json"
printf '{"verdict":"pass","items":[]}' > "$no_qa"
out="$("$CHECK" --file "$no_qa")"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "--file artifact without qa_metadata still validates"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file artifact without qa_metadata reports reason=valid"

# empty qa_metadata (the schema's performed-review shape) with the finding
# arrays validates — declaring qa_metadata requires the arrays (vstack#678)
empty_qa="$worktree/tmp/review-external-20260718-040404.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}' > "$empty_qa"
out="$("$CHECK" --file "$empty_qa")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file empty qa_metadata with arrays reports reason=valid"

# explicit review_performed=true validates
performed="$worktree/tmp/review-external-20260718-050505.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{"review_performed":true}}' > "$performed"
out="$("$CHECK" --file "$performed")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file review_performed=true reports reason=valid"

# glob mode applies the same gate: a fresh no-review artifact is rejected...
glob_noreview="$worktree/tmp/review-reviewer-ext-20260718-060606.json"
printf '{"verdict":"pass","qa_metadata":{"review_performed":false,"reason":"no_scope_provided"}}' > "$glob_noreview"
touch -d "@$after" "$glob_noreview"
set +e
out="$("$CHECK" "$worktree" reviewer-ext "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "glob no-review artifact exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "no_review" "glob no-review artifact reports reason=no_review"
assert_eq "$(jq -r '.path' <<<"$out")" "$glob_noreview" "glob no-review report points at the artifact"

# ...and an older fresh valid sibling still wins over a newer no-review one
glob_valid="$worktree/tmp/review-reviewer-ext-20260718-000000.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{}}' > "$glob_valid"
touch -d "@$after" "$glob_valid"
touch -d "@$later" "$glob_noreview"
out="$("$CHECK" "$worktree" reviewer-ext "$delegated_at")"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "glob falls back past no-review to older valid artifact"
assert_eq "$(jq -r '.path' <<<"$out")" "$glob_valid" "glob fallback selects the valid sibling"

# --- incomplete: qa-shaped artifacts must carry the finding arrays (vstack#678) ---
# A truncated write can keep verdict/summary while losing blockers/suggestions —
# schema-valid on the `.verdict` gate, but the findings are gone. An artifact
# that declares qa_metadata without the arrays is rejected reason=incomplete;
# artifacts without qa_metadata keep the pre-existing tolerance (see no_qa above).
inc="$worktree/tmp/review-external-20260718-070707.json"
printf '{"agent":"external-codex","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"looks fine","qa_metadata":{}}' > "$inc"
set +e
out="$("$CHECK" --file "$inc")"
rc=$?
set -e
assert_eq "$rc" "1" "--file qa-shaped artifact without arrays exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "--file qa-shaped without arrays reports ok=false"
assert_eq "$(jq -r '.path' <<<"$out")" "$inc" "--file qa-shaped without arrays reports its path"
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "--file qa-shaped without arrays reports reason=incomplete"

# a mistyped array is as lost as a missing one
inc_type="$worktree/tmp/review-external-20260718-080808.json"
printf '{"verdict":"pass","blockers":"none","suggestions":[],"qa_metadata":{}}' > "$inc_type"
set +e
out="$("$CHECK" --file "$inc_type")"
rc=$?
set -e
assert_eq "$rc" "1" "--file non-array blockers exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "--file non-array blockers reports reason=incomplete"

# missing suggestions alone is incomplete too
inc_sugg="$worktree/tmp/review-external-20260718-090909.json"
printf '{"verdict":"pass","blockers":[],"qa_metadata":{}}' > "$inc_sugg"
set +e
out="$("$CHECK" --file "$inc_sugg")"
rc=$?
set -e
assert_eq "$rc" "1" "--file missing suggestions exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "--file missing suggestions reports reason=incomplete"

# questions[] is NOT required (PR-comment-triage-only; the QA standard fields omit it)
no_questions="$worktree/tmp/review-external-20260718-101010.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{}}' > "$no_questions"
out="$("$CHECK" --file "$no_questions")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file qa-shaped without questions still validates"

# glob mode applies the same gate: a fresh qa-shaped incomplete artifact is rejected...
glob_inc="$worktree/tmp/review-reviewer-inc-20260718-111111.json"
printf '{"verdict":"pass","summary":"truncated","qa_metadata":{}}' > "$glob_inc"
touch -d "@$after" "$glob_inc"
set +e
out="$("$CHECK" "$worktree" reviewer-inc "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "glob qa-shaped artifact without arrays exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "glob qa-shaped without arrays reports reason=incomplete"
assert_eq "$(jq -r '.path' <<<"$out")" "$glob_inc" "glob incomplete report points at the artifact"

# ...and an older fresh complete sibling still wins over a newer incomplete one
glob_inc_valid="$worktree/tmp/review-reviewer-inc-20260718-000000.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{}}' > "$glob_inc_valid"
touch -d "@$after" "$glob_inc_valid"
touch -d "@$later" "$glob_inc"
out="$("$CHECK" "$worktree" reviewer-inc "$delegated_at")"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "glob falls back past incomplete to older complete artifact"
assert_eq "$(jq -r '.path' <<<"$out")" "$glob_inc_valid" "glob fallback selects the complete sibling"

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
assert_file_contains "$review_pr" 'reason `incomplete`' "review-pr documents the incomplete-artifact rejection (vstack#678)"

# --- submit-pr.md wires the --file freshness boundary for the local review ---
submit_pr="$REPO_ROOT/skills/orch/workflows/submit-pr.md"
assert_file_contains "$submit_pr" 'review-artifact-check --file "$LOCAL_OUTPUT" [LOCAL_STARTED_AT]' "submit-pr passes a delegated-at boundary to the --file freshness check"
assert_file_contains "$submit_pr" "git-context timestamp epoch" "submit-pr captures an epoch boundary before running the local review"
assert_file_contains "$submit_pr" 'reason `incomplete`' "submit-pr documents the incomplete-artifact rejection (vstack#678)"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
