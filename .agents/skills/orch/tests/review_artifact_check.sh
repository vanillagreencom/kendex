#!/usr/bin/env bash
# Regression tests for review-artifact-check: deterministic on-disk acceptance
# of reviewer JSON artifacts in the orch review-pr workflow.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

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

# expect_valid <artifact-path> <desc> — accepting-direction assertion that
# survives a mutant. A bare `out="$("$CHECK" ...)"` aborts the whole run under
# set -e the moment a guard starts over-rejecting, which truncates the suite
# instead of naming what broke; the accepting direction is exactly where that
# matters, because it is what pins WHICH number a guard reads.
expect_valid() {
  local path="$1" desc="$2" out rc=0
  set +e
  out="$("$CHECK" --file "$path")"
  rc=$?
  set -e
  assert_eq "$rc" "0" "$desc (exits 0)"
  assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "$desc"
}

# expect_glob_valid <worktree> <agent> <boundary> <expected-path> <desc>
expect_glob_valid() {
  local wt="$1" ag="$2" bound="$3" want="$4" desc="$5" out rc=0
  set +e
  out="$("$CHECK" "$wt" "$ag" "$bound")"
  rc=$?
  set -e
  assert_eq "$rc" "0" "$desc (exits 0)"
  assert_eq "$(jq -r '.path' <<<"$out")" "$want" "$desc"
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

# --- no_review: self-reported no-review artifacts are rejected (kendex#652) ---
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
# arrays validates — declaring qa_metadata requires the arrays (kendex#678)
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

# ...and it is TERMINAL: an older fresh sibling does NOT rescue it. no_review is
# the reviewer's self-report about the RUN, and the prescribed self-check
# boundary of 0 makes every prior artifact fresh, so falling back would answer
# "did some earlier round leave a file?" instead of "did this review happen?"
glob_valid="$worktree/tmp/review-reviewer-ext-20260718-000000.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{}}' > "$glob_valid"
touch -d "@$after" "$glob_valid"
touch -d "@$later" "$glob_noreview"
set +e
out="$("$CHECK" "$worktree" reviewer-ext "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "glob no-review is terminal, not rescued by an older sibling"
assert_eq "$(jq -r '.reason' <<<"$out")" "no_review" "glob terminal no-review keeps reason=no_review"
assert_eq "$(jq -r '.path' <<<"$out")" "$glob_noreview" "glob terminal no-review points at the rejected artifact"

# MUST-FAIL CONTROL for the terminal rule: with the no-review artifact STALE
# (not fresh), the older-but-fresh valid sibling is still the answer — terminal
# means "this run is refused", not "this agent is refused forever".
touch -d "@$before" "$glob_noreview"
expect_glob_valid "$worktree" reviewer-ext "$delegated_at" "$glob_valid" "a STALE no-review artifact does not block a fresh valid one"
touch -d "@$later" "$glob_noreview"

# --- incomplete: qa-shaped artifacts must carry the finding arrays (kendex#678) ---
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

# ...and it is TERMINAL. This gate was filed as the truncated-write shape until
# the argument was checked: a truncated JSON object is not a JSON object, so
# every torn or partial write fails the `.verdict` parse before any content gate
# runs. What reaches this gate is well-formed JSON the writer produced, which no
# older artifact answers for.
glob_inc_valid="$worktree/tmp/review-reviewer-inc-20260718-000000.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{}}' > "$glob_inc_valid"
touch -d "@$after" "$glob_inc_valid"
touch -d "@$later" "$glob_inc"
set +e
out="$("$CHECK" "$worktree" reviewer-inc "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "glob qa-shape incomplete is terminal, not rescued by an older sibling"
assert_eq "$(jq -r '.path' <<<"$out")" "$glob_inc" "glob terminal qa-shape points at the rejected artifact"

# MUST-FAIL CONTROL: stale, and the fresh complete one is the answer again.
touch -d "@$before" "$glob_inc"
expect_glob_valid "$worktree" reviewer-inc "$delegated_at" "$glob_inc_valid" "a STALE qa-shape artifact does not block a fresh complete one"
touch -d "@$later" "$glob_inc"

# THE PREMISE, ASSERTED: no prefix truncation of a review artifact ever reaches
# a content gate, because it is not parseable JSON. If this ever stopped
# holding, the disposition above would be wrong.
trunc_src='{"agent":"r","verdict":"pass","summary":"s","blockers":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":1,"estimate":1}],"suggestions":[],"qa_metadata":{"x":1}}'
trunc_bad=""
for pct in 20 40 60 80 90 95 99; do
  trunc_path="$worktree/tmp/review-external-20260813-0000$pct.json"
  printf '%s' "${trunc_src:0:$(( ${#trunc_src} * pct / 100 ))}" > "$trunc_path"
  set +e
  trunc_out="$("$CHECK" --file "$trunc_path")"
  set -e
  trunc_reason="$(jq -r '.reason' <<<"$trunc_out" 2>/dev/null || printf 'unparseable')"
  [[ "$trunc_reason" == "invalid" ]] || trunc_bad="$trunc_bad ${pct}%:$trunc_reason"
done
assert_eq "$trunc_bad" "" "every prefix truncation is rejected as invalid before any content gate"

# --- incomplete: qa-shaped artifacts must carry USABLE finding items (kendex#810) ---
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
# 1..5, kendex#810): a present-but-out-of-range or non-numeric value is unusable
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
# arrays are entirely missing is reason=incomplete, and it names WHICH arrays.
# This was the chain's one detail-free rejection, so an artifact that adopted
# qa_metadata to reach the measurement declaration got a second, unexplained
# refusal after doing exactly what the first rejection instructed — and § 3.1
# permits one re-delegation before `unresponsive`.
arrays_lost="$worktree/tmp/review-external-20260810-090909.json"
printf '{"verdict":"pass","summary":"truncated","qa_metadata":{}}' > "$arrays_lost"
set +e
out="$("$CHECK" --file "$arrays_lost")"
rc=$?
set -e
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "--file arrays-lost still reason=incomplete"
assert_substr "$(jq -r '.detail' <<<"$out")" "blockers[] is absent" "--file arrays-lost detail names the first missing array and what it was"
assert_substr "$(jq -r '.detail' <<<"$out")" "suggestions[] is absent" "--file arrays-lost detail names the second"
assert_substr "$(jq -r '.detail' <<<"$out")" "no qa_metadata" "--file arrays-lost detail says the tolerant shape is exempt"

# A key that is missing and a key written as null are different things an agent
# did; `has()` is what tells them apart, and the remedy reads better for both
# when the report says which one it saw. Kept BELOW the arrays-lost assertions:
# each of these reassigns `out`, so sitting above them made the last one read
# this fixture while claiming to describe $arrays_lost.
qa_absent_vs_null="$worktree/tmp/review-external-20260812-950001.json"
printf '{"verdict":"pass","blockers":null,"suggestions":[],"qa_metadata":{}}' > "$qa_absent_vs_null"
set +e
out="$("$CHECK" --file "$qa_absent_vs_null")"
set -e
assert_substr "$(jq -r '.detail' <<<"$out")" "blockers[] is null" "--file a null array is reported as null, not as absent"
printf '{"verdict":"pass","suggestions":[],"qa_metadata":{}}' > "$qa_absent_vs_null"
set +e
out="$("$CHECK" --file "$qa_absent_vs_null")"
set -e
assert_substr "$(jq -r '.detail' <<<"$out")" "blockers[] is absent" "--file a missing key is reported as absent, not as null"

# A field PRESENT with the wrong type is this run's output shape, not a damaged
# write, and the detail has to say which it was — an agent that wrote `null`
# meaning "no findings" needs to be told to write [].
qa_shape_case() {
  local name="$1" literal="$2" want_detail="$3" path out
  path="$worktree/tmp/review-external-20260812-$(printf '%06d' "$SHAPE_N").json"
  SHAPE_N=$((SHAPE_N + 1))
  printf '{"verdict":"pass","blockers":%s,"suggestions":[],"qa_metadata":{}}' "$literal" > "$path"
  set +e
  out="$("$CHECK" --file "$path")"
  rc=$?
  set -e
  assert_eq "$rc" "1" "--file blockers:$name exits 1"
  assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "--file blockers:$name reports reason=incomplete"
  assert_substr "$(jq -r '.detail' <<<"$out")" "$want_detail" "--file blockers:$name detail names what it found"
  assert_substr "$(jq -r '.detail' <<<"$out")" "writes []" "--file blockers:$name detail says what an empty review writes"
}
SHAPE_N=1
qa_shape_case "null"    'null'     "blockers[] is null"
qa_shape_case "object"  '{}'       "blockers[] is object, not an array"
qa_shape_case "string"  '"none"'   "blockers[] is string, not an array"
qa_shape_case "number"  '3'        "blockers[] is number, not an array"
# the same shapes on the OTHER array, so neither is checked by accident
sugg_shape="$worktree/tmp/review-external-20260812-900001.json"
printf '{"verdict":"pass","blockers":[],"suggestions":null,"qa_metadata":{}}' > "$sugg_shape"
set +e
out="$("$CHECK" --file "$sugg_shape")"
set -e
assert_substr "$(jq -r '.detail' <<<"$out")" "suggestions[] is null" "--file suggestions:null is reported on its own"
printf '{"verdict":"pass","blockers":[],"suggestions":"x","qa_metadata":{}}' > "$sugg_shape"
set +e
out="$("$CHECK" --file "$sugg_shape")"
set -e
assert_substr "$(jq -r '.detail' <<<"$out")" "suggestions[] is string, not an array" "--file suggestions with a wrong type is reported on its own"

# EVERY rejection in the chain names its cause. A reason with no detail is a
# dead end for the agent that has to fix it.
chain_no_detail=""
chain_case() {
  local body="$1" label="$2" path out
  path="$worktree/tmp/review-external-20260811-$(printf '%06d' "$CHAIN_N").json"
  CHAIN_N=$((CHAIN_N + 1))
  printf '%s' "$body" > "$path"
  set +e
  out="$("$CHECK" --file "$path")"
  set -e
  if [[ "$(jq -r '.ok' <<<"$out")" == "false" ]] && [[ "$(jq -r '.detail // ""' <<<"$out")" == "" ]]; then
    chain_no_detail="$chain_no_detail $label($(jq -r '.reason' <<<"$out"))"
  fi
}
CHAIN_N=1
chain_case '{"agent":"r","summary":"no verdict field"}' missing-verdict
chain_case '{"verdict":"pass","qa_metadata":{"review_performed":false}}' no-review
chain_case '{"verdict":"pass","summary":"s","qa_metadata":{}}' qa-shape
chain_case '{"verdict":"pass","blockers":[],"suggestions":[{"title":"t"}],"qa_metadata":{}}' finding-item
chain_case '{"verdict":"pass","blockers":[],"suggestions":[],"measurement_failed":"n/a"}' bad-declaration
chain_case '{"verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"qa_metadata":{}}' zero-sample
assert_eq "$chain_no_detail" "" "every content-gate rejection names its cause in detail"

# ...and the two reasons an agent reads BEFORE it knows what it did wrong. The
# --help claim is unconditional, and these were the two carrying nothing.
detail_of() {
  set +e
  local out
  out="$("$CHECK" "$@")"
  set -e
  jq -r '.detail // ""' <<<"$out"
}
empty_wt="$TMP_ROOT/emptywt"
mkdir -p "$empty_wt/tmp"
assert_substr "$(detail_of "$empty_wt" ghost-agent 0)" "review-ghost-agent-" "glob missing names the glob that matched nothing"
stale_only="$empty_wt/tmp/review-staleonly-20200101-000000.json"
printf '{"verdict":"pass"}' > "$stale_only"
touch -d "@$before" "$stale_only"
assert_substr "$(detail_of "$empty_wt" staleonly "$delegated_at")" "predates the boundary" "glob stale names the mtime against the boundary"
assert_substr "$(detail_of --file "$TMP_ROOT/definitely-not-here.json")" "no file at" "--file missing names the path"
assert_substr "$(detail_of --file "$stale_only" "$delegated_at")" "predates the boundary" "--file stale names the mtime against the boundary"

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

# ...and it is TERMINAL, not answered by an older sibling. Items carrying wrong
# field names are what THIS run produced — a truncated write does not rename
# fields — so the disposition rule puts this on the self-report side. Falling
# back here told a reviewer whose items were unroutable that someone else's
# artifact was valid, and it never saw a reason at all.
glob_item_ok="$worktree/tmp/review-reviewer-item-20260810-000000.json"
printf '{"verdict":"pass","blockers":[],"suggestions":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":3,"estimate":2,"category":"issue","impact":"nightly importers hit it on every run"}],"qa_metadata":{}}' > "$glob_item_ok"
touch -d "@$after" "$glob_item_ok"
touch -d "@$later" "$glob_item_bad"
set +e
out="$("$CHECK" "$worktree" reviewer-item "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "glob malformed-item is terminal, not rescued by an older sibling"
assert_eq "$(jq -r '.reason' <<<"$out")" "incomplete" "glob terminal malformed-item keeps reason=incomplete"
assert_eq "$(jq -r '.path' <<<"$out")" "$glob_item_bad" "glob terminal malformed-item points at the rejected artifact"

# MUST-FAIL CONTROL: with the malformed artifact STALE, the fresh well-formed
# one is the answer — terminal refuses THIS run, not the agent forever.
touch -d "@$before" "$glob_item_bad"
expect_glob_valid "$worktree" reviewer-item "$delegated_at" "$glob_item_ok" "a STALE malformed-item artifact does not block a fresh well-formed one"
touch -d "@$later" "$glob_item_bad"

# THE OTHER SIDE OF THE RULE now has exactly one member — a gate that could not
# run — and it is pinned in review_artifact_check_measurement.sh, where the
# selective jq shim lives.

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

echo "=== -h/--help answers before any temp-file initialization (KEN-556) ==="

# Token pins per KEN-555: the heredoc is the contract's sole home.
set +e
help_out="$("$CHECK" --help 2>"$TMP_ROOT/help.err")"
rc=$?
set -e
assert_eq "$rc" "0" "--help exits 0"
assert_substr "$help_out" "Usage:" "--help prints usage on stdout"
assert_eq "$(cat "$TMP_ROOT/help.err")" "" "--help writes nothing to stderr"
assert_substr "$help_out" "zero_sample" "--help carries the reason vocabulary"
assert_substr "$help_out" "measurement_failed" "--help carries the declaration contract"

set +e
help_out="$("$CHECK" -h 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" "0" "-h exits 0"
assert_substr "$help_out" "Usage:" "-h prints usage"

# The dispatch runs BEFORE the gates lib is sourced: its source-time mktemp
# fails under an unusable TMPDIR, and --help must still print the contract.
set +e
help_out="$(TMPDIR="$TMP_ROOT/does-not-exist/nope" "$CHECK" --help 2>"$TMP_ROOT/help2.err")"
rc=$?
set -e
assert_eq "$rc" "0" "--help exits 0 with an unusable TMPDIR"
assert_substr "$help_out" "Usage:" "--help still prints the contract under it"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
