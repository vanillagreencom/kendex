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

assert_substr() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected substring: %s\n        in:                 %s\n' "$name" "$needle" "$haystack"
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

# --- incomplete: qa-shaped artifacts must carry USABLE finding items (vstack#810) ---
# qa_shaped_incomplete only catches arrays lost wholesale. An artifact can carry
# present, non-empty blockers[]/suggestions[] whose ITEMS omit the required
# review-finding fields — present in prose but unroutable, because the
# orchestrator routes suggestions on `category`. Required item set (from
# reviewer/schemas/review-finding.md § Item Fields): id, title, location,
# description, recommendation, priority, estimate — plus category (∈ fix|issue)
# for suggestions. Reason reuses `incomplete`; a `detail` field names the first
# offending item and field.

# the exact malformed shape from the issue: {title, location, detail, severity}
issue_bad="$worktree/tmp/review-external-20260810-010101.json"
printf '{"agent":"reviewer-arch","verdict":"pass","blockers":[],"suggestions":[{"title":"Two resolvers coexist","location":"/abs/instrument_link.rs (instrument_name)","detail":"...","severity":"low"}],"qa_metadata":{"arch_review":{"overall_score":8.4,"pass":true}}}' > "$issue_bad"
set +e
out="$("$CHECK" --file "$issue_bad")"
rc=$?
set -e
assert_eq "$rc" "1" "--file issue malformed suggestion exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "--file issue malformed suggestion reports ok=false"
assert_eq "$(jq -r '.path' <<<"$out")" "$issue_bad" "--file issue malformed suggestion reports its path"
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "--file issue malformed suggestion reports reason=incomplete"
assert_substr "$(jq -r '.detail' <<<"$out")" "suggestions[0]" "--file issue malformed detail names the offending item"
assert_substr "$(jq -r '.detail' <<<"$out")" "category" "--file issue malformed detail names the missing category field"

# a fully schema-compliant artifact with populated items still validates
compliant="$worktree/tmp/review-external-20260810-020202.json"
printf '{"verdict":"action_required","blockers":[{"id":1,"title":"t","location":"src/x.rs (`f`)","description":"d","recommendation":"r","priority":1,"estimate":2}],"suggestions":[{"id":1,"title":"t","location":"src/y.rs (`g`)","description":"d","recommendation":"r","priority":3,"estimate":2,"category":"fix"}],"qa_metadata":{}}' > "$compliant"
out="$("$CHECK" --file "$compliant")"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "--file fully compliant items reports ok=true"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file fully compliant items reports reason=valid"
assert_eq "$(jq -r '.detail' <<<"$out")" "null" "--file valid artifact carries no detail field"

# empty blockers[]/suggestions[] carry no items and stay valid (do not regress)
empty_items="$worktree/tmp/review-external-20260810-030303.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{}}' > "$empty_items"
out="$("$CHECK" --file "$empty_items")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file empty arrays stay valid under item check"

# an item missing ONLY category (routing-critical) is rejected
nocat="$worktree/tmp/review-external-20260810-040404.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":3,"estimate":2}],"qa_metadata":{}}' > "$nocat"
set +e
out="$("$CHECK" --file "$nocat")"
rc=$?
set -e
assert_eq "$rc" "1" "--file suggestion missing only category exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "--file suggestion missing only category reports reason=incomplete"
assert_substr "$(jq -r '.detail' <<<"$out")" "category" "--file missing-category detail names category"

# category present but not in {fix,issue} is rejected (routing keys on the value)
badcatval="$worktree/tmp/review-external-20260810-050505.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":3,"estimate":2,"category":"low"}],"qa_metadata":{}}' > "$badcatval"
set +e
out="$("$CHECK" --file "$badcatval")"
rc=$?
set -e
assert_eq "$rc" "1" "--file suggestion category not in {fix,issue} exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "--file bad category value reports reason=incomplete"

# blockers require the base fields but NOT category — a blocker missing a base
# field is rejected, a blocker without category is fine
badblk="$worktree/tmp/review-external-20260810-060606.json"
printf '{"verdict":"action_required","blockers":[{"id":1,"title":"t","location":"l","recommendation":"r","priority":1,"estimate":2}],"suggestions":[],"qa_metadata":{}}' > "$badblk"
set +e
out="$("$CHECK" --file "$badblk")"
rc=$?
set -e
assert_eq "$rc" "1" "--file blocker missing description exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "--file blocker missing base field reports reason=incomplete"
assert_substr "$(jq -r '.detail' <<<"$out")" "blockers[0]" "--file blocker detail names the blockers array"
assert_substr "$(jq -r '.detail' <<<"$out")" "description" "--file blocker detail names the missing field"

okblk="$worktree/tmp/review-external-20260810-070707.json"
printf '{"verdict":"action_required","blockers":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":1,"estimate":2}],"suggestions":[],"qa_metadata":{}}' > "$okblk"
out="$("$CHECK" --file "$okblk")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file blocker without category is valid (category is suggestions-only)"

# priority/estimate range + type per review-finding.md (priority 1..4, estimate
# 1..5, vstack#810): a present-but-out-of-range or non-numeric value is unusable
badpri="$worktree/tmp/review-external-20260810-090909.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":5,"estimate":2,"category":"fix"}],"qa_metadata":{}}' > "$badpri"
set +e; out="$("$CHECK" --file "$badpri")"; rc=$?; set -e
assert_eq "$rc" "1" "--file priority out of 1..4 exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "--file out-of-range priority reports reason=incomplete"
assert_substr "$(jq -r '.detail' <<<"$out")" "priority" "--file out-of-range priority detail names priority"

badest="$worktree/tmp/review-external-20260810-101010.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":2,"estimate":"2","category":"issue"}],"qa_metadata":{}}' > "$badest"
set +e; out="$("$CHECK" --file "$badest")"; rc=$?; set -e
assert_eq "$rc" "1" "--file non-numeric estimate exits 1"
assert_substr "$(jq -r '.detail' <<<"$out")" "estimate" "--file string estimate detail names estimate"

# blockers carry the same numeric constraint (priority 0 is below range)
badblkpri="$worktree/tmp/review-external-20260810-111111.json"
printf '{"verdict":"action_required","blockers":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":0,"estimate":3}],"suggestions":[],"qa_metadata":{}}' > "$badblkpri"
set +e; out="$("$CHECK" --file "$badblkpri")"; rc=$?; set -e
assert_eq "$rc" "1" "--file blocker priority below 1..4 exits 1"
assert_substr "$(jq -r '.detail' <<<"$out")" "blockers[0]" "--file blocker out-of-range detail names the blockers array"

# boundary values (priority 1 and 4, estimate 1 and 5) are valid — not off-by-one rejected
okbound="$worktree/tmp/review-external-20260810-121212.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":4,"estimate":5,"category":"fix"}],"qa_metadata":{}}' > "$okbound"
out="$("$CHECK" --file "$okbound")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file priority=4 estimate=5 boundary values are valid"

# artifacts WITHOUT qa_metadata keep the pre-existing tolerance — malformed items
# do NOT trip the check (parity with qa_shaped_incomplete's gating)
noqa_bad="$worktree/tmp/review-external-20260810-080808.json"
printf '{"verdict":"pass","suggestions":[{"title":"t","location":"l"}]}' > "$noqa_bad"
out="$("$CHECK" --file "$noqa_bad")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file malformed items without qa_metadata stay tolerant (valid)"

# array-lost incomplete still precedes the item check: a qa-shaped artifact whose
# arrays are entirely missing is reason=incomplete with no item detail
arrays_lost="$worktree/tmp/review-external-20260810-090909.json"
printf '{"verdict":"pass","summary":"truncated","qa_metadata":{}}' > "$arrays_lost"
set +e
out="$("$CHECK" --file "$arrays_lost")"
rc=$?
set -e
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "--file arrays-lost still reason=incomplete"
assert_eq "$(jq -r '.detail' <<<"$out")" "null" "--file arrays-lost incomplete carries no item detail"

# glob mode applies the same item gate: a fresh malformed-item artifact is rejected...
glob_item_bad="$worktree/tmp/review-reviewer-item-20260810-111111.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[{"title":"t","location":"l","detail":"x","severity":"low"}],"qa_metadata":{}}' > "$glob_item_bad"
touch -d "@$after" "$glob_item_bad"
set +e
out="$("$CHECK" "$worktree" reviewer-item "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "glob malformed-item artifact exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "glob malformed-item reports reason=incomplete"
assert_eq "$(jq -r '.path' <<<"$out")" "$glob_item_bad" "glob malformed-item report points at the artifact"
assert_substr "$(jq -r '.detail' <<<"$out")" "suggestions[0]" "glob malformed-item detail names the item"

# ...and an older fresh well-formed sibling still wins over a newer malformed one
glob_item_ok="$worktree/tmp/review-reviewer-item-20260810-000000.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":3,"estimate":2,"category":"issue"}],"qa_metadata":{}}' > "$glob_item_ok"
touch -d "@$after" "$glob_item_ok"
touch -d "@$later" "$glob_item_bad"
out="$("$CHECK" "$worktree" reviewer-item "$delegated_at")"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "glob falls back past malformed-item to older well-formed artifact"
assert_eq "$(jq -r '.path' <<<"$out")" "$glob_item_ok" "glob fallback selects the well-formed sibling"

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
