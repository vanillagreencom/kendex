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
# A complete analysis-kind receipt (vstack#952): read-only round, NO commit /
# validate / validate_note keys, recommendation in summary.
valid_analysis='{"schema_version":1,"round_id":"1750000000-4242","kind":"analysis","issue":"issue-770","branch":"issue-770","qa_labels":[],"summary_posted":false,"summary":"Recommend: close with reasoning; premise invalidated by merge X.","bundled":false,"items":[]}'

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

# --- vstack#952: analysis kind — complete-without-code, inverse commit/validate rule ---
printf '%s' "$valid_analysis" > "$artifact"
out="$("$CHECK" --worktree "$worktree" --issue "$issue" --round-id "$R")"
rc=$?
assert_eq "$rc" "0" "valid analysis receipt exits 0"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "valid analysis receipt reports reason=valid"
assert_eq "$(jq -r '.validate' <<<"$out")" "null" "analysis receipt echoes validate=null (no validation ran)"
# The inverse rule: a commit/validate/validate_note key PRESENT on an analysis
# artifact is a fabricated claim about a round that ran none → invalid, even
# when the value looks plausible, and even when it is null.
printf '%s' "$valid_analysis" | jq -c '.commit="abc123f"' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "analysis smuggling a commit reports reason=invalid"
printf '%s' "$valid_analysis" | jq -c '.validate="pass"' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "analysis smuggling validate=pass reports reason=invalid"
printf '%s' "$valid_analysis" | jq -c '.validate_note="looked fine"' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "analysis smuggling a validate_note reports reason=invalid"
printf '%s' "$valid_analysis" | jq -c '.commit=null' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "analysis with a null commit key still reports reason=invalid (presence, not value)"
# The recommendation is the round's deliverable: a missing/empty/wrong-typed
# summary proves the round ended, not what it concluded → incomplete.
printf '%s' "$valid_analysis" | jq -c 'del(.summary)' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "incomplete" "analysis with no summary reports reason=incomplete"
printf '%s' "$valid_analysis" | jq -c '.summary=null' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "incomplete" "analysis with null summary reports reason=incomplete"
printf '%s' "$valid_analysis" | jq -c '.summary=""' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "incomplete" "analysis with empty summary reports reason=incomplete"
# Round-id identity applies to analysis exactly as to the other kinds.
printf '%s' "$valid_analysis" | jq -c '.round_id="OTHER-1"' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "invalid" "analysis with internal round_id mismatch reports reason=invalid"
# An analysis artifact can never satisfy a delegated item set.
printf '%s' "$valid_analysis" > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R" --expect-items 1,2)" "incomplete" "analysis cannot satisfy --expect-items → incomplete"

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
printf 'Recommend: re-scope; seam moved in refactor.\n' > "$rt_wt/analysis.md"
"$WRITE" --worktree "$rt_wt" --kind analysis --issue issue-9 --round-id 9-10 --branch b --summary-file "$rt_wt/analysis.md" --no-summary >/dev/null
assert_eq "$(reason --worktree "$rt_wt" --issue issue-9 --round-id 9-10)" "valid" "writer analysis output round-trips as valid (vstack#952)"

# --- vstack#1230: --expect-items-from-round reads the persisted round record ---
# The delegated item set is persisted at delegation time (dev-round-write →
# tmp/dev-round-ISSUE-RID.json), so the exact-set gate has an on-disk source of
# truth instead of a number list typed from the orchestrator's context.
ROUND_WRITE="$REPO_ROOT/skills/orch/scripts/dev-round-write"
rr_wt="$TMP_ROOT/rr"
mkdir -p "$rr_wt"
"$ROUND_WRITE" --worktree "$rr_wt" --issue issue-9 --round-id 7-8 \
  --item 1 "fix nil deref" --item 2 "cover expiry" >/dev/null
"$WRITE" --worktree "$rr_wt" --kind fix --issue issue-9 --round-id 7-8 --branch b --commit c \
  --validate pass --item 1 Applied a --item 2 Skipped b >/dev/null
assert_eq "$(reason --worktree "$rr_wt" --issue issue-9 --round-id 7-8 --expect-items-from-round)" "valid" \
  "artifact covering the persisted round set → valid (writers round-trip)"
# an artifact missing a delegated item must fail exactly as with explicit numbers
"$WRITE" --worktree "$rr_wt" --kind fix --issue issue-9 --round-id 8-9 --branch b --commit c \
  --validate pass --item 1 Applied a >/dev/null
"$ROUND_WRITE" --worktree "$rr_wt" --issue issue-9 --round-id 8-9 \
  --item 1 "fix nil deref" --item 2 "cover expiry" >/dev/null
assert_eq "$(reason --worktree "$rr_wt" --issue issue-9 --round-id 8-9 --expect-items-from-round)" "incomplete" \
  "artifact missing a persisted delegated item → incomplete"
set +e
# a missing round record means the expected set cannot be established — the
# check refuses to run (exit 2) rather than passing a weaker gate silently
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 9-9 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with no round record exits 2"
# a round record whose internal token differs is not THIS round's record
jq -n '{schema_version:1,round_id:"OTHER-1",issue:"issue-9",items:[{n:1,text:"t"}]}' \
  > "$rr_wt/tmp/dev-round-issue-9-10-10.json"
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 10-10 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with mismatched internal round_id exits 2"
# a malformed round record (empty/ill-typed items) proves nothing about the set
jq -n '{schema_version:1,round_id:"11-11",issue:"issue-9",items:[]}' \
  > "$rr_wt/tmp/dev-round-issue-9-11-11.json"
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 11-11 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with an empty round-record item set exits 2"
# the reader validates the FULL record schema, not just the token
printf 'not json' > "$rr_wt/tmp/dev-round-issue-9-12-12.json"
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 12-12 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with an unparseable round record exits 2"
jq -n '{schema_version:1,round_id:"13-13",issue:"issue-OTHER",items:[{n:1,text:"t"}]}' \
  > "$rr_wt/tmp/dev-round-issue-9-13-13.json"
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 13-13 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with a mismatched internal issue exits 2"
jq -n '{round_id:"14-14",issue:"issue-9",items:[{n:1,text:"t"}]}' \
  > "$rr_wt/tmp/dev-round-issue-9-14-14.json"
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 14-14 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with a record missing schema_version exits 2"
jq -n '{schema_version:1,round_id:"15-15",issue:"issue-9",items:[{n:1,text:""}]}' \
  > "$rr_wt/tmp/dev-round-issue-9-15-15.json"
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 15-15 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with an empty item text exits 2"
set -e
# the count-vs-set hint diagnoses a TYPED --expect-items count; a set read from
# the round record cannot be that misuse, so from-round must not emit the hint
# even when the shapes coincide (control first: the inline form still fires it).
"$WRITE" --worktree "$rr_wt" --kind fix --issue issue-9 --round-id 16-16 --branch b --commit c \
  --validate pass --item 1 Applied a --item 2 Applied b --item 3 Applied c >/dev/null
hint_inline="$("$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 16-16 --expect-items 3 2>/dev/null | jq -r '.hint' || true)"
assert_eq "$([[ "$hint_inline" != "null" ]] && echo fires)" "fires" \
  "control: inline --expect-items 3 against items 1..3 fires the count-vs-set hint"
"$ROUND_WRITE" --worktree "$rr_wt" --issue issue-9 --round-id 16-16 --item 3 "only item three" >/dev/null
hint_round="$("$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 16-16 --expect-items-from-round 2>/dev/null | jq -r '.hint' || true)"
assert_eq "$hint_round" "null" "--expect-items-from-round never emits the count-vs-set hint (reason stays incomplete)"
reason_round="$("$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 16-16 --expect-items-from-round 2>/dev/null | jq -r '.reason' || true)"
assert_eq "$reason_round" "incomplete" "from-round set mismatch still reports incomplete"
set +e
# one expected-set source only
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 7-8 --expect-items 1,2 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items and --expect-items-from-round together exit 2"
# --file mode has no worktree/issue/round to resolve a record from
"$CHECK" --file "$rr_wt/tmp/dev-return-issue-9-7-8.json" --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--file mode rejects --expect-items-from-round"
set -e

# --- vstack#994: the recorded commit must name a real object in the worktree's repo ---
# Case 1 (hyprtrade CC-1006): a dev agent hand-reconstructed a full SHA from the
# short form — same 8-char prefix as HEAD, fabricated tail — and the receipt
# passed every schema gate while naming no object. That must now fail with the
# distinct fatal reason commit_unresolvable. Case 2: a commit orphaned by a
# later rebase still resolves as an object but is no ancestor of HEAD; per the
# issue that is a distinct NON-FATAL signal (warning=commit_unreachable, ok
# stays true) because a legitimate rebase produces it. All the non-git-repo
# worktrees above (plain mktemp dirs) skip these gates entirely.
gitwt="$TMP_ROOT/gitwt"
mkdir -p "$gitwt/tmp"
git -C "$gitwt" init -q -b main
git -C "$gitwt" config user.email test@example.com
git -C "$gitwt" config user.name Test
git -C "$gitwt" config commit.gpgsign false
git -C "$gitwt" commit -q --allow-empty -m base
git -C "$gitwt" commit -q --allow-empty -m orphan-me
orphan_sha="$(git -C "$gitwt" rev-parse HEAD)"
git -C "$gitwt" reset -q --hard HEAD~1   # orphan_sha still resolves, now unreachable
head_sha="$(git -C "$gitwt" rev-parse HEAD)"
fake_sha="${head_sha:0:8}00000000000000000000000000000000"
gartifact="$gitwt/tmp/dev-return-$issue-$R.json"

# valid, reachable commit (HEAD) → valid with no warning
printf '%s' "$valid_impl" | jq -c --arg c "$head_sha" '.commit=$c' > "$gartifact"
out="$("$CHECK" --worktree "$gitwt" --issue "$issue" --round-id "$R")"
rc=$?
assert_eq "$rc" "0" "reachable HEAD commit exits 0"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "reachable HEAD commit reports reason=valid"
assert_eq "$(jq -r '.warning' <<<"$out")" "null" "reachable HEAD commit reports warning=null"

# fabricated SHA (real prefix, invented tail) → ok=false, commit_unresolvable, exit 1
printf '%s' "$valid_impl" | jq -c --arg c "$fake_sha" '.commit=$c' > "$gartifact"
set +e
out="$("$CHECK" --worktree "$gitwt" --issue "$issue" --round-id "$R" 2>/dev/null)"
rc=$?
err="$("$CHECK" --worktree "$gitwt" --issue "$issue" --round-id "$R" 2>&1 >/dev/null)"
set -e
assert_eq "$rc" "1" "fabricated commit SHA exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "fabricated commit SHA reports ok=false"
assert_eq "$(jq -r '.reason' <<<"$out")" "commit_unresolvable" "fabricated commit SHA reports reason=commit_unresolvable"
assert_eq "$(grep -F "$fake_sha" <<<"$err" | grep -cF 'no such object')" "1" "commit_unresolvable stderr names the sha and 'no such object'"

# orphaned-but-real commit → NON-FATAL: ok=true, reason=valid, warning=commit_unreachable
printf '%s' "$valid_impl" | jq -c --arg c "$orphan_sha" '.commit=$c' > "$gartifact"
out="$("$CHECK" --worktree "$gitwt" --issue "$issue" --round-id "$R" 2>/dev/null)"
rc=$?
assert_eq "$rc" "0" "orphaned-but-real commit still exits 0 (non-fatal per vstack#994)"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "orphaned commit reports ok=true"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "orphaned commit reports reason=valid"
assert_eq "$(jq -r '.warning' <<<"$out")" "commit_unreachable" "orphaned commit reports warning=commit_unreachable"

# analysis artifact (no commit key) in a git worktree → unaffected by the commit gates
printf '%s' "$valid_analysis" > "$gartifact"
out="$("$CHECK" --worktree "$gitwt" --issue "$issue" --round-id "$R")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "commit-less analysis artifact in a git worktree stays valid"
assert_eq "$(jq -r '.warning' <<<"$out")" "null" "commit-less analysis artifact reports warning=null"

# gate ordering: scalar invalid beats the commit gates; commit_unresolvable beats incomplete
printf '%s' "$valid_impl" | jq -c 'del(.commit)' > "$gartifact"
assert_eq "$(reason --worktree "$gitwt" --issue "$issue" --round-id "$R")" "invalid" "missing .commit in a git worktree stays reason=invalid (scalar gate first)"
printf '%s' "$valid_fix" | jq -c --arg c "$fake_sha" '.commit=$c | .items=[]' > "$gartifact"
assert_eq "$(reason --worktree "$gitwt" --issue "$issue" --round-id "$R")" "commit_unresolvable" "commit_unresolvable beats incomplete (fake sha + empty items)"

# non-repo worktree keeps today's behavior: commit gates skipped, still valid
printf '%s' "$valid_impl" > "$artifact"
out="$("$CHECK" --worktree "$worktree" --issue "$issue" --round-id "$R")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "non-git worktree skips the commit gates (reason=valid)"
assert_eq "$(jq -r '.warning' <<<"$out")" "null" "non-git worktree reports warning=null"

# --file mode has no repo to check against → fabricated sha still validates
gext="$TMP_ROOT/dev-return-994.json"
printf '%s' "$valid_impl" | jq -c --arg c "$fake_sha" '.commit=$c' > "$gext"
assert_eq "$(reason --file "$gext")" "valid" "--file mode skips the commit gates (no repo)"

# --- doc wiring: ALL FOUR dev/QA paths mint a fresh round id + accept via round mode ---
# dev-start / orch dev-fix / review-pr-comments / ci-fix each mint dev_round_id
# before delegating and accept via dev-artifact-check round mode — one identity
# model, no legacy carve-out. dev-start/dev-fix/review-pr-comments also embed the
# token in the delegation; ci-fix's agent writes no artifact so it does not.
ROUND_STAMP="workflow-state new-round-id [ISSUE_ID] dev_round_id"
ROUND_CHECK="dev-artifact-check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND]"
# Fix rounds must carry the exact-set gate as ONE contiguous command (a regression
# that drops the flag from the command while leaving it in prose would still pass
# two independent substring checks — so assert the full string). Since vstack#1230
# the expected set comes from the persisted round record, not a typed number list.
ROUND_CHECK_EXPECT="$ROUND_CHECK --expect-items-from-round"
ROUND_ITEMS_PERSIST="dev-round-write --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID]"
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
assert_file_contains "$orch_dev_fix" "$ROUND_CHECK_EXPECT" "orch dev-fix accepts via round-mode dev-artifact-check WITH --expect-items-from-round in one command"
assert_file_contains "$orch_dev_fix" "$ROUND_ITEMS_PERSIST" "orch dev-fix persists the delegated item set at stamp time (vstack#1230)"
assert_file_contains "$orch_dev_fix" "Round ID: [DEV_ROUND_ID]" "orch dev-fix delegation carries the Round ID line"
assert_file_contains "$orch_dev_fix" "$ARTIFACT_KEY_LINE" "orch dev-fix delegation carries the Artifact Key line"

review_pr_comments="$REPO_ROOT/skills/orch/workflows/review-pr-comments.md"
assert_file_contains "$review_pr_comments" "$WATCHDOG_STAMP" "review-pr-comments § 6.1 still stamps dev_delegated_at"
assert_file_contains "$review_pr_comments" "$ROUND_STAMP" "review-pr-comments § 6.1 mints dev_round_id before delegation"
assert_file_contains "$review_pr_comments" "$ROUND_CHECK_EXPECT" "review-pr-comments accepts via round-mode dev-artifact-check WITH --expect-items-from-round in one command"
assert_file_contains "$review_pr_comments" "$ROUND_ITEMS_PERSIST" "review-pr-comments persists each group's delegated item set at stamp time (vstack#1230)"
assert_file_contains "$review_pr_comments" "Round ID: [DEV_ROUND_ID]" "review-pr-comments delegation carries the Round ID line"
assert_file_contains "$review_pr_comments" "$ARTIFACT_KEY_LINE" "review-pr-comments delegation carries the Artifact Key line"

# ci-fix: now compliant with the round-id invariant — mints a fresh dev_round_id
# and accepts via round mode; the legacy positional call is gone.
ci_fix="$REPO_ROOT/skills/orch/workflows/ci-fix.md"
assert_file_contains "$ci_fix" "$WATCHDOG_STAMP" "ci-fix § 3.2 re-stamps dev_delegated_at (watchdog deadline)"
assert_file_contains "$ci_fix" "$ROUND_STAMP" "ci-fix § 3.2 mints a fresh dev_round_id before delegating (round-id invariant)"
# ci-fix's agent pushes its fix directly and writes NO artifact, so the fresh
# token alone is the fail-closed guarantee: a prior round's leftover receipt
# carries the previous token and can never be mistaken for this round's.
assert_file_contains "$ci_fix" "writes **no** dev-return artifact" "ci-fix states its agent writes no completion artifact"
assert_file_contains "$ci_fix" "can never be mis-accepted here" "ci-fix states the fresh token is what makes a stale receipt unmatchable"
assert_file_not_contains "$ci_fix" "$LEGACY_CHECK" "ci-fix § 3.2 no longer uses the legacy positional dev-artifact-check call"

# The removed legacy positional call must not survive in any orch workflow.
for wf in dev-start dev-fix review-pr-comments ci-fix; do
  assert_file_not_contains "$REPO_ROOT/skills/orch/workflows/$wf.md" "$LEGACY_CHECK" "$wf.md carries no legacy positional dev-artifact-check call"
done

# --- vstack#803: mechanical per-wake A/B check + single-shot wall-clock watchdog ---
# The stall was an orchestrator that read a `finished` wake's wording and idled
# without running A/B, plus a wait loop with no wall-clock re-entry when wakes
# stopped. SKILL must mandate both, and every delegation point that stamps
# dev_delegated_at must arm the watchdog. vstack#818 re-homed both mandates into
# the numbered "orchestrator owns round closure" list (same requirements, new
# wording) and made that list the primary path rather than a recovery fallback.
orch_skill="$REPO_ROOT/skills/orch/SKILL.md"
assert_file_contains "$orch_skill" "Run A/B on every wake and at the deadline" "SKILL mandates the per-wake and deadline A/B check"
assert_file_contains "$orch_skill" "classifying mechanically rather than from wording or elapsed time" "SKILL forbids classifying a round from wording or elapsed time"
assert_file_contains "$orch_skill" "Arm a single-shot wall-clock watchdog" "SKILL mandates a wall-clock watchdog independent of sub-agent wakes (vstack#803)"
assert_file_contains "$orch_skill" "The orchestrator owns round closure" "SKILL puts round closure on the orchestrator, not on a return arriving"
assert_file_contains "$orch_skill" "the return message is display-only" "SKILL keeps the return message out of the acceptance decision"
for wf in dev-start dev-fix review-pr-comments ci-fix; do
  wf_doc="$REPO_ROOT/skills/orch/workflows/$wf.md"
  assert_file_contains "$wf_doc" "watchdog" "$wf.md arms a watchdog at delegation"
  assert_file_contains "$wf_doc" "SKILL.md#round-closure" "$wf.md routes the watchdog contract to the canonical section"
done

# --- doc wiring: dev workflows write the completion artifact via dev-return-write with --round-id ---
# The dev workflows key the artifact to [ARTIFACT_KEY] (the normalized workflow-state
# key from the delegation's Artifact Key: line), NOT the tracker-native [ISSUE_ID],
# so a GitHub agent writes dev-return-issue-N-RID.json (what orch checks).
dev_implement="$REPO_ROOT/skills/dev/workflows/dev-implement.md"
assert_file_contains "$dev_implement" "dev-return-write --worktree [WORKTREE_PATH] --kind implement --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID]" "dev-implement § 10 keys the artifact to [ARTIFACT_KEY]"
dev_fix="$REPO_ROOT/skills/dev/workflows/dev-fix.md"
assert_file_contains "$dev_fix" "dev-return-write --worktree [WORKTREE_PATH] --kind fix --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID]" "dev-fix § 6 keys the artifact to [ARTIFACT_KEY]"
# vstack#1230: a respawned agent recovers its delegated item set from the
# persisted round record instead of guessing (or depending on the orchestrator's
# context surviving).
assert_file_contains "$dev_fix" "dev-round-[ARTIFACT_KEY]-[DEV_ROUND_ID].json" "dev-fix § 6 points a respawned agent at the persisted round record"

# --- vstack#952 doc wiring: analysis rounds have a truthful spelling everywhere ---
# The dev workflows must offer --kind analysis for read-only rounds (never a
# forced implement/fix, never a skipped artifact), and the orch decision tables
# must say what acceptance of an analysis artifact means (read the
# recommendation and decide; no commit/validate gate for the round).
assert_file_contains "$dev_implement" "--kind analysis" "dev-implement § 10 offers --kind analysis for read-only rounds"
assert_file_contains "$dev_fix" "--kind analysis" "dev-fix § 6 offers --kind analysis for read-only rounds"
assert_file_contains "$dev_start" "Analysis round" "dev-start § 3 carries the analysis acceptance rule"
assert_file_contains "$orch_dev_fix" "Analysis round" "orch dev-fix § 2 carries the analysis acceptance rule"

# --- schema docs carry the round-id / dev_round_id contract ---
dev_return_schema="$REPO_ROOT/skills/orch/schemas/dev-return.md"
assert_file_contains "$dev_return_schema" "dev-return-write" "dev-return schema references the writer"
assert_file_contains "$dev_return_schema" "round_id" "dev-return schema documents round_id identity"
assert_file_contains "$dev_return_schema" "schema_version" "dev-return schema documents schema_version"
# Validation gates have ONE canonical home — the artifact-checks reference —
# so the schema documents the shape and the reference documents the verdicts.
artifact_checks_ref="$REPO_ROOT/skills/orch/references/artifact-checks.md"
assert_file_contains "$artifact_checks_ref" "incomplete" "artifact-checks reference documents the incomplete reason"
assert_file_contains "$artifact_checks_ref" "missing → invalid → incomplete → valid" "artifact-checks reference documents the gate ordering"
assert_file_not_contains "$dev_return_schema" "reason \`incomplete\`" "dev-return schema does not duplicate the verdict vocabulary"
assert_file_contains "$dev_return_schema" "--expect-items" "dev-return schema documents the exact item-set rule"

state_schema="$REPO_ROOT/skills/orch/schemas/workflow-state.md"
assert_file_contains "$state_schema" "dev_delegated_at" "workflow-state schema documents dev_delegated_at"
assert_file_contains "$state_schema" "dev_round_id" "workflow-state schema documents dev_round_id"

# --- vstack#1230 schema doc: the round record has its own contract ---
dev_round_schema="$REPO_ROOT/skills/orch/schemas/dev-round.md"
assert_file_contains "$dev_round_schema" "dev-round-write" "dev-round schema references the writer"
assert_file_contains "$dev_round_schema" "round_id" "dev-round schema documents round_id identity"
assert_file_contains "$dev_round_schema" "--expect-items-from-round" "dev-round schema documents the check-side reader"

# --- vstack#884: the note has to reach the orchestrator, not just the file ---
# This output IS what orch accepts a completion on, so a caveat stored in the
# artifact but never echoed would be as lost as one never recorded.
noted_file="$worktree/tmp/noted.json"
NOTE="80/80 on re-run; first run flaked on Rust Tests (release)"
jq -n --arg note "$NOTE" '{schema_version:1,round_id:"1-1",kind:"implement",issue:"i",branch:"b",
  commit:"c",validate:"pass",validate_note:$note,qa_labels:[],summary_posted:true,summary:null,
  bundled:false,items:[]}' > "$noted_file"
out="$("$CHECK" --file "$noted_file")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "an artifact carrying a validate_note is valid"
assert_eq "$(jq -r '.validate' <<<"$out")" "pass" "the check echoes the enumerated verdict"
assert_eq "$(jq -r '.validate_note' <<<"$out")" "$NOTE" "the check echoes the qualifier to the orchestrator"

# Artifacts written before the field existed must keep validating unchanged.
legacy_file="$worktree/tmp/legacy.json"
jq -n '{schema_version:1,round_id:"1-1",kind:"implement",issue:"i",branch:"b",commit:"c",
  validate:"pass",qa_labels:[],summary_posted:true,summary:null,bundled:false,items:[]}' > "$legacy_file"
out="$("$CHECK" --file "$legacy_file")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "an artifact with no validate_note key is still valid"
assert_eq "$(jq -r '.validate_note' <<<"$out")" "null" "an absent note reports null"

# Wrong-typed or empty notes are malformed receipts, not silently-ignored ones.
for bad in '""' '42' 'true' '[]'; do
  bad_file="$worktree/tmp/badnote.json"
  jq -n --argjson n "$bad" '{schema_version:1,round_id:"1-1",kind:"implement",issue:"i",branch:"b",
    commit:"c",validate:"pass",validate_note:$n,qa_labels:[],summary_posted:true,summary:null,
    bundled:false,items:[]}' > "$bad_file"
  assert_eq "$("$CHECK" --file "$bad_file" 2>/dev/null | jq -r '.reason')" "invalid" \
    "validate_note $bad is rejected as invalid"
done

# A missing artifact still reports the stable shape with null qualifiers.
out="$("$CHECK" --file "$worktree/tmp/nope.json" 2>/dev/null || true)"
assert_eq "$(jq -r '.validate' <<<"$out")" "null" "a missing artifact reports validate=null"
assert_eq "$(jq -r '.validate_note' <<<"$out")" "null" "a missing artifact reports validate_note=null"

assert_file_contains "$dev_return_schema" "validate_note" "dev-return schema documents validate_note"
assert_file_contains "$dev_return_schema" "Analysis rounds" "dev-return schema documents analysis rounds (vstack#952)"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
