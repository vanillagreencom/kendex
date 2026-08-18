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
printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":3,"estimate":2,"category":"issue","impact":"nightly importers hit it on every run"}],"qa_metadata":{}}' > "$glob_item_ok"
touch -d "@$after" "$glob_item_ok"
touch -d "@$later" "$glob_item_bad"
out="$("$CHECK" "$worktree" reviewer-item "$delegated_at")"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "glob falls back past malformed-item to older well-formed artifact"
assert_eq "$(jq -r '.path' <<<"$out")" "$glob_item_ok" "glob fallback selects the well-formed sibling"

# --- zero_sample: a measurement that produced no samples is not a result (vstack#1497) ---
# A stability/mutation run whose pipeline silently selected nothing still emits
# a number, and a zero reads as green. Any artifact citing the reviewer skill's
# fixed format with a zero sample count or zero thread count is rejected, as is
# an empty/all-zero benchmark percentile block. Gated on nothing: the pairing
# binds every reviewer, not only the qa-shaped ones.

zs_mut="$worktree/tmp/review-external-20260815-010101.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"validated: mutation: killed 0/0; stability: 10/10 at 16 threads"}' > "$zs_mut"
set +e
out="$("$CHECK" --file "$zs_mut")"
rc=$?
set -e
assert_eq "$rc" "1" "--file zero-mutant citation exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "--file zero-mutant citation reports ok=false"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file zero-mutant citation reports reason=zero_sample"
assert_substr "$(jq -r '.detail' <<<"$out")" "killed 0/0" "--file zero-mutant detail quotes the offending citation"
assert_substr "$(jq -r '.detail' <<<"$out")" "instrument failure" "--file zero-mutant detail names the rule"

zs_stab="$worktree/tmp/review-external-20260815-020202.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 0/0 at 16 threads"}' > "$zs_stab"
set +e
out="$("$CHECK" --file "$zs_stab")"
rc=$?
set -e
assert_eq "$rc" "1" "--file zero-run stability citation exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file zero-run stability reports reason=zero_sample"
assert_substr "$(jq -r '.detail' <<<"$out")" "stability: 0/0" "--file zero-run detail quotes the stability citation"

# elevated parallelism of zero threads is the same instrument failure
zs_thr="$worktree/tmp/review-external-20260815-030303.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 0 threads"}' > "$zs_thr"
set +e
out="$("$CHECK" --file "$zs_thr")"
rc=$?
set -e
assert_eq "$rc" "1" "--file zero-thread stability citation exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file zero-thread stability reports reason=zero_sample"
assert_substr "$(jq -r '.detail' <<<"$out")" "zero threads" "--file zero-thread detail names the thread count"

# the citation is caught wherever it lives, not only in .summary
zs_deep="$worktree/tmp/review-external-20260815-040404.json"
printf '{"agent":"reviewer-test","verdict":"action_required","summary":"s","blockers":[{"id":1,"title":"t","location":"src/x.rs (`f`)","description":"evidence: mutation: killed 0/0; stability: 10/10 at 16 threads","recommendation":"r","priority":2,"estimate":2}],"suggestions":[],"qa_metadata":{}}' > "$zs_deep"
set +e
out="$("$CHECK" --file "$zs_deep")"
rc=$?
set -e
assert_eq "$rc" "1" "--file zero-sample citation inside a blocker description exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file nested citation reports reason=zero_sample"

# MUST-FAIL CONTROL, other direction: a real two-number citation still validates
zs_ok="$worktree/tmp/review-external-20260815-050505.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}' > "$zs_ok"
out="$("$CHECK" --file "$zs_ok")"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "--file a nonzero mutation/stability citation stays valid"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file nonzero citation reports reason=valid"

# an artifact citing no measurement at all is untouched by the guard
zs_none="$worktree/tmp/review-external-20260815-060606.json"
printf '{"agent":"reviewer-quality","verdict":"pass","summary":"no measurement was needed for this domain"}' > "$zs_none"
out="$("$CHECK" --file "$zs_none")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file artifact with no measurement citation stays valid"

# benchmark percentiles: empty and all-zero blocks are instrument failure
zs_pempty="$worktree/tmp/review-external-20260815-070707.json"
printf '{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":{"percentiles":{},"regression_pct":0,"regressions":[],"platform":"linux","baseline_sha":"abc"}}}' > "$zs_pempty"
set +e
out="$("$CHECK" --file "$zs_pempty")"
rc=$?
set -e
assert_eq "$rc" "1" "--file empty percentile block exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file empty percentile block reports reason=zero_sample"

zs_pzero="$worktree/tmp/review-external-20260815-080808.json"
printf '{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":{"percentiles":{"p50":0,"p99":0},"regression_pct":0,"regressions":[],"platform":"linux","baseline_sha":"abc"}}}' > "$zs_pzero"
set +e
out="$("$CHECK" --file "$zs_pzero")"
rc=$?
set -e
assert_eq "$rc" "1" "--file all-zero percentile block exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file all-zero percentile block reports reason=zero_sample"
assert_substr "$(jq -r '.detail' <<<"$out")" "percentiles" "--file all-zero percentile detail names the block"

# MUST-FAIL CONTROL: one real percentile is enough to make the block a result
zs_pok="$worktree/tmp/review-external-20260815-090909.json"
printf '{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":{"percentiles":{"p50":0,"p99":4.2},"regression_pct":0,"regressions":[],"platform":"linux","baseline_sha":"abc"}}}' > "$zs_pok"
out="$("$CHECK" --file "$zs_pok")"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "--file a percentile block with real numbers stays valid"

# glob mode applies the same guard, and falls back past a zero-sample artifact
zs_glob_bad="$worktree/tmp/review-reviewer-zs-20260815-110000.json"
printf '{"agent":"reviewer-zs","verdict":"pass","summary":"mutation: killed 0/0; stability: 0/0 at 16 threads"}' > "$zs_glob_bad"
touch -d "@$after" "$zs_glob_bad"
set +e
out="$("$CHECK" "$worktree" reviewer-zs "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "glob zero-sample artifact exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "glob zero-sample reports reason=zero_sample"
assert_eq "$(jq -r '.path' <<<"$out")" "$zs_glob_bad" "glob zero-sample report points at the artifact"

zs_glob_ok="$worktree/tmp/review-reviewer-zs-20260815-100000.json"
printf '{"agent":"reviewer-zs","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}' > "$zs_glob_ok"
touch -d "@$after" "$zs_glob_ok"
touch -d "@$later" "$zs_glob_bad"
out="$("$CHECK" "$worktree" reviewer-zs "$delegated_at")"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "glob falls back past a zero-sample artifact to a measured sibling"
assert_eq "$(jq -r '.path' <<<"$out")" "$zs_glob_ok" "glob fallback selects the measured sibling"

# the rejection reason is documented where reviewers read the rules
finding_schema="$REPO_ROOT/skills/reviewer/schemas/review-finding.md"
assert_file_contains "$finding_schema" "zero_sample" "review-finding.md documents the zero_sample rejection"

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
assert_file_contains "$review_pr" "never sufficient" "review-pr states a return message alone cannot complete a reviewer"
assert_file_contains "$review_pr" "exactly one" "review-pr limits incomplete returns to one re-delegation"
assert_file_contains "$review_pr" "using your harness file-write tool" "review-pr re-delegation instructs harness file-write tool"
assert_file_contains "$review_pr" 'review-artifact-check --file "$EXTERNAL_OUTPUT"' "review-pr validates external output via --file mode"
assert_file_not_contains "$review_pr" "if jq -e '.verdict'" "review-pr no longer prescribes inline if/redirection for external verdict check"
assert_file_contains "$review_pr" 'review-artifact-check --file "$EXTERNAL_OUTPUT" [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND]' "review-pr passes review_delegated_at as the --file freshness boundary"
# The reason vocabulary belongs to the script (behaviourally covered above);
# the workflow's obligation is to surface whatever reason it reports, with the
# detail field that pinpoints the offending item, instead of silently passing.
assert_file_contains "$review_pr" 'report the `reason` (and `detail` when present)' "review-pr surfaces the rejection reason and detail"

# --- submit-pr.md wires the --file freshness boundary for the local review ---
submit_pr="$REPO_ROOT/skills/orch/workflows/submit-pr.md"
assert_file_contains "$submit_pr" 'review-artifact-check --file "$LOCAL_OUTPUT" [LOCAL_STARTED_AT]' "submit-pr passes a delegated-at boundary to the --file freshness check"
assert_file_contains "$submit_pr" "git-context timestamp epoch" "submit-pr captures an epoch boundary before running the local review"
assert_file_contains "$submit_pr" 'report the `reason`' "submit-pr surfaces the rejection reason"
assert_file_contains "$submit_pr" "none of those outcomes is a pass" "submit-pr states a rejected local review is not a pass"

# --- vstack#885: the rejection has to teach the schema, not just flag it ---
# Four artifacts were rejected in one session by agents that followed the
# workflow text without opening the schema file. Two reached for `priority: 5`;
# two used plausible-but-wrong field names (`detail`, `remediation`, `file`+
# `line`). The rejection is relayed verbatim to the agent that must redo the
# work, so it names the whole expected item shape.
REQ_SPEC="every blockers[]/suggestions[] item requires: id, title, location (path plus symbol, no line numbers), description, recommendation, priority (integer 1-4), estimate (1-5); suggestions also category (fix|issue), and category:issue also impact (who hits this, on what real path)"

# category:issue items require a non-empty impact line; fix items do not.
impact_wt=$(mktemp -d); mkdir -p "$impact_wt/tmp"
impact_art="$impact_wt/tmp/review-reviewer-impact-20260101-000000.json"
printf '%s' '{"agent":"reviewer-impact","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"s","qa_metadata":{"review_performed":true},"blockers":[],"suggestions":[{"id":1,"title":"t","location":"l (sym)","description":"d","recommendation":"r","priority":3,"estimate":2,"category":"issue"}]}' > "$impact_art"
r=$("$CHECK" "$impact_wt" reviewer-impact 0 || true)
assert_eq "$(jq -r '.ok' <<<"$r")" "false" "category:issue without impact is rejected"
assert_substr "$(jq -r '.detail // ""' <<<"$r")" "impact" "the rejection names the missing impact field"
jq '.suggestions[0].impact = "operators running the nightly import hit it on every run"' "$impact_art" > "$impact_art.n" && mv "$impact_art.n" "$impact_art"
assert_eq "$("$CHECK" "$impact_wt" reviewer-impact 0 | jq -r '.ok')" "true" "category:issue with impact passes"
jq '.suggestions[0].category = "fix" | del(.suggestions[0].impact)' "$impact_art" > "$impact_art.n" && mv "$impact_art.n" "$impact_art"
assert_eq "$("$CHECK" "$impact_wt" reviewer-impact 0 | jq -r '.ok')" "true" "category:fix needs no impact"
rm -rf "$impact_wt"

# The check exits 1 on a rejected artifact, which is the case under test here —
# swallow it so `set -e`/`pipefail` do not abort the suite on an expected failure.
detail_of() { "$CHECK" --file "$1" 2>/dev/null | jq -r '.detail // ""' || true; }

# priority: 5 — the "lower than the lowest" instinct.
p5="$TMP_ROOT/p5.json"
jq -n '{agent:"reviewer-safety",timestamp:"t",verdict:"pass",summary:"s",blockers:[],
  suggestions:[{id:1,title:"t",location:"a.rs (`f`)",description:"d",recommendation:"r",
  priority:5,estimate:2,category:"fix"}],qa_metadata:{safety:{}}}' > "$p5"
d="$(detail_of "$p5")"
assert_substr "$d" "suggestions[0]: missing/invalid priority(not 1..4)" \
  "priority 5 is still reported as out of range"
assert_substr "$d" "$REQ_SPEC" "the priority rejection states the 1-4 range and the full item shape"

# `detail` instead of `description`, with id/estimate/category omitted.
alias1="$TMP_ROOT/alias1.json"
jq -n '{agent:"reviewer-arch",timestamp:"t",verdict:"pass",summary:"s",blockers:[],
  suggestions:[{title:"t",location:"a.rs",detail:"d",recommendation:"r",priority:3}],
  qa_metadata:{arch_review:{}}}' > "$alias1"
d="$(detail_of "$alias1")"
assert_substr "$d" "suggestions[0]: missing/invalid id, description, estimate, category" \
  "a detail/description swap is reported by field name"
assert_substr "$d" "$REQ_SPEC" "the swap rejection names the correct field set"

# file+line instead of location, remediation instead of recommendation.
alias2="$TMP_ROOT/alias2.json"
jq -n '{agent:"reviewer-safety",timestamp:"t",verdict:"pass",summary:"s",blockers:[],
  suggestions:[{title:"t",file:"a.rs",line:12,description:"d",remediation:"r",priority:3}],
  qa_metadata:{safety:{}}}' > "$alias2"
d="$(detail_of "$alias2")"
assert_substr "$d" "suggestions[0]: missing/invalid id, location, recommendation, estimate, category" \
  "file/line and remediation are reported as the missing canonical fields"
assert_substr "$d" "no line numbers" "the rejection states that location carries no line numbers"

# Aliases are NOT accepted — one canonical spelling, taught rather than guessed.
assert_eq "$("$CHECK" --file "$alias1" 2>/dev/null | jq -r '.reason' || true)" "incomplete" \
  "an aliased field name is still rejected, not silently accepted"

# A well-formed item produces no detail at all.
good="$TMP_ROOT/good.json"
jq -n '{agent:"reviewer-safety",timestamp:"t",verdict:"pass",summary:"s",blockers:[],
  suggestions:[{id:1,title:"t",location:"a.rs (`f`)",description:"d",recommendation:"r",
  priority:4,estimate:2,category:"issue",
  impact:"anyone auditing unsafe blocks hits it on the next sweep"}],qa_metadata:{safety:{}}}' > "$good"
assert_eq "$("$CHECK" --file "$good" | jq -r '.reason')" "valid" "a schema-correct artifact is still valid"
assert_eq "$(detail_of "$good")" "" "a valid artifact carries no detail"

# --- The authoring path must carry the requirements, not just the recovery path ---
# vstack#885's defect was an authoring path with strictly less information than
# the rejection it would then receive. The current answer is mechanical, not
# duplicated prose: the schema file is the single field authority, and every
# review workflow + the reviewer SKILL require a pre-return self-check with this
# same validator, so a rejection can never first surface at the orchestrator.
reviewer_skill="$REPO_ROOT/skills/reviewer/SKILL.md"
schema_doc="$REPO_ROOT/skills/reviewer/schemas/review-finding.md"
assert_file_contains "$reviewer_skill" "Output Contract" "reviewer SKILL has an output-contract section"
assert_file_contains "$reviewer_skill" "review-artifact-check" "reviewer SKILL mandates the pre-return self-check"
assert_file_contains "$schema_doc" "1-4" "schema states the priority range"
assert_file_contains "$schema_doc" "no P5" "schema says there is no P5"
assert_file_contains "$schema_doc" "no line numbers" "schema states the location shape"
assert_file_contains "$schema_doc" "recommendation" "schema names the recommendation field"
for wf in review codebase-review qa-review; do
  wf_file="$REPO_ROOT/skills/reviewer/workflows/$wf.md"
  assert_file_contains "$wf_file" "schemas/review-finding.md" "$wf workflow points at the schema authority"
  assert_file_contains "$wf_file" "review-artifact-check" "$wf workflow carries the pre-return self-check"
done

review_pr_recovery="$REPO_ROOT/skills/orch/workflows/review-pr.md"
# The required-field list lives in the schema, so the re-delegation points the
# reviewer there rather than restating a field list that would drift from it.
assert_file_contains "$review_pr_recovery" "every required field of \`review-finding.md\`" \
  "review-pr's re-delegation routes the reviewer to the schema's required fields"

echo "=== --wait blocking mode (glob) ==="

# A reviewer artifact landing mid-wait ends the wait immediately with its
# verdict — valid here; a rejected artifact would return equally fast.
wwt="$TMP_ROOT/waitwt"
mkdir -p "$wwt/tmp"
start_epoch="$(date +%s)"
( sleep 2; printf '{"agent":"waitrev","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"questions":[]}' \
    > "$wwt/tmp/review-waitrev-20260101-000001.json" ) &
writer_pid=$!
rc=0
wait_out="$("$CHECK" "$wwt" waitrev 0 --wait 20 --interval 1 2>/dev/null)" || rc=$?
wait "$writer_pid" 2>/dev/null || true
elapsed=$(( $(date +%s) - start_epoch ))
assert_eq "$(jq -r '.ok' <<<"$wait_out")" "true" "--wait returns the landed artifact as ok"
assert_eq "$rc" "0" "--wait exit 0 on a valid landing"
if (( elapsed < 15 )); then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "--wait returned on the landing, not the deadline (${elapsed}s)"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "--wait burned toward its deadline (${elapsed}s)"
fi

# Deadline with nothing landed: reason missing, exit 1.
rc=0
wait_out="$("$CHECK" "$wwt" ghostrev 0 --wait 2 --interval 1 2>/dev/null)" || rc=$?
assert_eq "$(jq -r '.reason' <<<"$wait_out")" "missing" "--wait deadline reports missing"
assert_eq "$rc" "1" "--wait deadline exits 1"

# The production shape from cycle 2 onward: a STALE prior-round artifact on
# disk must keep the wait polling for the fresh one, not end it instantly.
swt="$TMP_ROOT/stalewt"
mkdir -p "$swt/tmp"
printf '{"agent":"cyc","verdict":"pass","summary":"old","blockers":[],"suggestions":[],"questions":[]}' \
  > "$swt/tmp/review-cyc-20200101-000000.json"
touch -t 202001010000 "$swt/tmp/review-cyc-20200101-000000.json"
now_epoch="$(date +%s)"
start_epoch="$now_epoch"
( sleep 2; printf '{"agent":"cyc","verdict":"pass","summary":"fresh","blockers":[],"suggestions":[],"questions":[]}' \
    > "$swt/tmp/review-cyc-20990101-000000.json" ) &
writer_pid=$!
rc=0
wait_out="$("$CHECK" "$swt" cyc "$now_epoch" --wait 20 --interval 1 2>/dev/null)" || rc=$?
wait "$writer_pid" 2>/dev/null || true
elapsed=$(( $(date +%s) - start_epoch ))
assert_eq "$(jq -r '.ok' <<<"$wait_out")" "true" "--wait polls past a stale prior-round artifact to the fresh one"
if (( elapsed >= 1 && elapsed < 15 )); then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "--wait neither returned instantly on stale nor burned the deadline (${elapsed}s)"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "--wait stale handling wrong (${elapsed}s: 0s = instant-stale regression, >=15s = deadline burn)"
fi

# Flag validation is a usage error; the frozen 3-positional call is untouched.
rc=0; "$CHECK" "$wwt" waitrev 0 --wait nope >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "a non-integer --wait is a usage error"
rc=0; "$CHECK" "$wwt" waitrev 0 >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "the bare three-positional contract still validates"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
