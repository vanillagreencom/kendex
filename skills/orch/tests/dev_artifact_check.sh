#!/usr/bin/env bash
# Regression tests for dev-artifact-check: deterministic on-disk acceptance of a
# dev agent's completion JSON artifact in the orch dev-start / dev-fix /
# review-pr-comments workflows. Identity is by per-delegation ROUND ID, not mtime
# (kendex#776): the check resolves WT/tmp/dev-return-ISSUE-RID.json and requires
# the internal .round_id to match. The mtime freshness gate is gone.

#
# The markdown checks pin COMMAND and delegation-line shapes. review-bots.md:
# a token pin establishes that a structural element is present, never that a
# behavioral claim written in prose is true. So ci-fix's two rules have no
# lint: that its agent writes no dev-return artifact, and that the round is
# accepted on the return message plus the pushed fix commit rather than on a
# stale artifact.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
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

assert_file_matches() {
  local file="$1" pattern="$2" name="$3"
  if grep -Eq -- "$pattern" "$file"; then
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

round_write() {
  growth_round_write "$STATE" "$ROUND_WRITE_BIN" "$@"
}

echo "=== dev-artifact-check ==="

worktree="$TMP_ROOT/wt"
mkdir -p "$worktree/tmp"
issue="issue-770"
R="1750000000-4242"
artifact="$worktree/tmp/dev-return-$issue-$R.json"
"$STATE" --state-dir "$worktree/tmp" init "$issue" --worktree "$worktree" --branch test >/dev/null
export ORCH_STATE_DIR="$worktree/tmp"

# A complete implement-kind receipt (round-scoped, all required fields present).
valid_impl='{"schema_version":1,"round_id":"1750000000-4242","kind":"implement","issue":"issue-770","branch":"issue-770","commit":"abc123f","baseline_lines":1,"validate":"pass","qa_labels":["needs-review"],"summary_posted":true,"summary":null,"bundled":false,"items":[]}'
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
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "flagless implement receipt reports reason=valid"

# Without --expect-items-from-round there is no delegated set and no authorized
# additions list, so the check refuses rather than falling back to the weak
# non-empty-items rule.
printf '%s' "$valid_fix" > "$artifact"
set +e
"$CHECK" --worktree "$worktree" --issue "$issue" --round-id "$R" >/dev/null 2>&1
assert_eq "$?" "2" "flagless round-mode fix receipt refuses instead of falling back"
set -e

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
assert_eq "$(reason --file "$artifact")" "incomplete" "file-mode fix with items missing reports reason=incomplete"
printf '%s' "$valid_fix" | jq -c '.items=[]' > "$artifact"
assert_eq "$(reason --file "$artifact")" "incomplete" "file-mode fix with empty items reports reason=incomplete"
printf '%s' "$valid_fix" | jq -c '.items="nope"' > "$artifact"
assert_eq "$(reason --file "$artifact")" "incomplete" "file-mode fix with non-array items reports reason=incomplete"
printf '%s' "$valid_fix" | jq -c '.items=[{"n":1,"decision":"Applied"}]' > "$artifact"
assert_eq "$(reason --file "$artifact")" "incomplete" "file-mode fix with item missing reasoning reports reason=incomplete"
printf '%s' "$valid_fix" | jq -c '.items=[{"n":1,"decision":"Applied","reasoning":""}]' > "$artifact"
assert_eq "$(reason --file "$artifact")" "incomplete" "file-mode fix with empty reasoning reports reason=incomplete"
printf '%s' "$valid_fix" | jq -c '.items=[{"n":1,"decision":"Nope","reasoning":"x"}]' > "$artifact"
assert_eq "$(reason --file "$artifact")" "incomplete" "file-mode fix with out-of-enum decision reports reason=incomplete"
printf '%s' "$valid_fix" | jq -c '.items=[{"n":"1","decision":"Applied","reasoning":"x"}]' > "$artifact"
assert_eq "$(reason --file "$artifact")" "incomplete" "file-mode fix with non-numeric item .n reports reason=incomplete"

# bundled implement with empty items → incomplete
printf '%s' "$valid_impl" | jq -c '.bundled=true' > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "incomplete" "bundled implement with empty items reports reason=incomplete"

# single implement with items:[] → valid (implement without bundled tolerates empty items)
printf '%s' "$valid_impl" > "$artifact"
assert_eq "$(reason --worktree "$worktree" --issue "$issue" --round-id "$R")" "valid" "single implement with items:[] stays valid"

# --- gate ordering: invalid (scalars/round) beats incomplete (items) ---
printf '%s' "$valid_fix" | jq -c 'del(.commit) | .items=[]' > "$artifact"
assert_eq "$(reason --file "$artifact")" "invalid" "file-mode invalid scalar beats incomplete"

# --- --expect-items: exact set coverage for fix rounds ---
printf '%s' "$valid_fix" > "$artifact"   # items n = [1,2]
assert_eq "$(reason --file "$artifact" --expect-items 1,2)" "valid" "file-mode expect 1,2 exact match → valid"
assert_eq "$(reason --file "$artifact" --expect-items 2,1)" "valid" "file-mode expect 2,1 order-independent → valid"
assert_eq "$(reason --file "$artifact" --expect-items 1,2,3)" "incomplete" "file-mode expect 1,2,3 with 3 missing → incomplete"
assert_eq "$(reason --file "$artifact" --expect-items 1)" "incomplete" "file-mode expect 1 with extra 2 present → incomplete"
# duplicate item number in the artifact must not satisfy a distinct expected set
printf '%s' "$valid_fix" | jq -c '.items=[{"n":1,"decision":"Applied","reasoning":"a"},{"n":1,"decision":"Skipped","reasoning":"b"}]' > "$artifact"
assert_eq "$(reason --file "$artifact" --expect-items 1,2)" "incomplete" "file-mode duplicate item n=1 does not cover {1,2} → incomplete"
# expect-items applies its own enum/reasoning rules even when the item set matches exactly
printf '%s' "$valid_fix" | jq -c '.items=[{"n":1,"decision":"Applied","reasoning":""},{"n":2,"decision":"Skipped","reasoning":"b"}]' > "$artifact"
assert_eq "$(reason --file "$artifact" --expect-items 1,2)" "incomplete" "file-mode expect-items rejects empty reasoning → incomplete"
printf '%s' "$valid_fix" | jq -c '.items=[{"n":1,"decision":"Nope","reasoning":"a"},{"n":2,"decision":"Skipped","reasoning":"b"}]' > "$artifact"
assert_eq "$(reason --file "$artifact" --expect-items 1,2)" "incomplete" "file-mode expect-items rejects out-of-enum decision → incomplete"
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
"$CHECK" --file "$artifact" --expect-items "1,x" >/dev/null 2>&1
assert_eq "$?" "2" "file mode with malformed --expect-items exits 2"
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
git -C "$rt_wt" init -q -b main
git -C "$rt_wt" config user.email test@example.com
git -C "$rt_wt" config user.name Test
git -C "$rt_wt" config commit.gpgsign false
git -C "$rt_wt" commit -q --allow-empty -m base
init_growth_state "$STATE" "$rt_wt" issue-9 5-6
rt_head="$(git -C "$rt_wt" rev-parse HEAD)"
rt_impl="$("$WRITE" --worktree "$rt_wt" --kind implement --issue issue-9 --round-id 5-6 --branch b --commit "$rt_head" --validate pass)"
assert_eq "$([[ -f "$rt_impl" ]] && echo yes)" "yes" "writer produced the round-scoped implement artifact"
assert_eq "$(env ORCH_STATE_DIR="$rt_wt/tmp" "$CHECK" --worktree "$rt_wt" --issue issue-9 --round-id 5-6 | jq -r '.reason')" "valid" "writer implement output round-trips as valid"
assert_eq "$("$STATE" --state-dir "$rt_wt/tmp" get issue-9 .pr.baseline_lines)" "1" \
  "the baseline has one authoritative workflow-state value"
"$WRITE" --worktree "$rt_wt" --kind fix --issue issue-9 --round-id 7-8 --branch b --commit c --validate pass --item 1 Applied a --item 2 Skipped b >/dev/null
assert_eq "$(reason --file "$rt_wt/tmp/dev-return-issue-9-7-8.json" --expect-items 1,2)" "valid" "writer fix output round-trips through file-mode --expect-items"

# --- kendex#1230: --expect-items-from-round reads the persisted round record ---
# The delegated item set is persisted at delegation time (dev-round-write →
# tmp/dev-round-ISSUE-RID.json), so the exact-set gate has an on-disk source of
# truth instead of a number list typed from the orchestrator's context.
ROUND_WRITE_BIN="$REPO_ROOT/skills/orch/scripts/dev-round-write"
ROUND_WRITE=round_write
rr_wt="$TMP_ROOT/rr"
mkdir -p "$rr_wt"
git -C "$rr_wt" init -q -b main
git -C "$rr_wt" config user.email test@example.com
git -C "$rr_wt" config user.name Test
git -C "$rr_wt" config commit.gpgsign false
git -C "$rr_wt" commit -q --allow-empty -m base
init_growth_state "$STATE" "$rr_wt" issue-9 seed 1000000
rr_head="$(git -C "$rr_wt" rev-parse HEAD)"
"$ROUND_WRITE" --worktree "$rr_wt" --issue issue-9 --round-id 7-8 \
  --item 1 "fix nil deref" "src/parse.rs on a config a shipped writer emits" --item 2 "cover expiry" "tests/auth.rs expiry case" >/dev/null
"$WRITE" --worktree "$rr_wt" --kind fix --issue issue-9 --round-id 7-8 --branch b --commit "$rr_head" \
  --validate pass --item 1 Applied a --item 2 Skipped b >/dev/null
assert_eq "$(reason --worktree "$rr_wt" --issue issue-9 --round-id 7-8 --expect-items-from-round)" "valid" \
  "artifact covering the persisted round set → valid (writers round-trip)"
assert_eq "$(reason --worktree "$rr_wt" --issue issue-9 --round-id 7-8 --expect-items-from-round)" "valid" \
  "the record is not consumed: a repeat check of the accepted round stays valid"
# an artifact missing a delegated item must fail exactly as with explicit numbers
"$WRITE" --worktree "$rr_wt" --kind fix --issue issue-9 --round-id 8-9 --branch b --commit "$rr_head" \
  --validate pass --item 1 Applied a >/dev/null
"$ROUND_WRITE" --worktree "$rr_wt" --issue issue-9 --round-id 8-9 \
  --item 1 "fix nil deref" "src/parse.rs on a config a shipped writer emits" --item 2 "cover expiry" "tests/auth.rs expiry case" >/dev/null
assert_eq "$(reason --worktree "$rr_wt" --issue issue-9 --round-id 8-9 --expect-items-from-round)" "incomplete" \
  "artifact missing a persisted delegated item → incomplete"
set +e
# a missing round record means the expected set cannot be established — the
# check refuses to run (exit 2) rather than passing a weaker gate silently
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 9-9 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with no round record exits 2"
# a round record whose internal token differs is not THIS round's record
jq -n --arg base "$rr_head" '{schema_version:2,round_id:"OTHER-1",issue:"issue-9",base_sha:$base,adds:[],items:[{n:1,text:"t"}]}' \
  > "$rr_wt/tmp/dev-round-issue-9-10-10.json"
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 10-10 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with mismatched internal round_id exits 2"
# a malformed round record (empty/ill-typed items) proves nothing about the set
jq -n --arg base "$rr_head" '{schema_version:2,round_id:"11-11",issue:"issue-9",base_sha:$base,adds:[],items:[]}' \
  > "$rr_wt/tmp/dev-round-issue-9-11-11.json"
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 11-11 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with an empty round-record item set exits 2"
# the reader validates the FULL record schema, not just the token
printf 'not json' > "$rr_wt/tmp/dev-round-issue-9-12-12.json"
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 12-12 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with an unparseable round record exits 2"
jq -n --arg base "$rr_head" '{schema_version:2,round_id:"13-13",issue:"issue-OTHER",base_sha:$base,adds:[],items:[{n:1,text:"t"}]}' \
  > "$rr_wt/tmp/dev-round-issue-9-13-13.json"
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 13-13 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with a mismatched internal issue exits 2"
jq -n --arg base "$rr_head" '{round_id:"14-14",issue:"issue-9",base_sha:$base,adds:[],items:[{n:1,text:"t"}]}' \
  > "$rr_wt/tmp/dev-round-issue-9-14-14.json"
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 14-14 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with a record missing schema_version exits 2"
jq -n --arg base "$rr_head" '{schema_version:2,round_id:"15-15",issue:"issue-9",base_sha:$base,adds:[],items:[{n:1,text:""}]}' \
  > "$rr_wt/tmp/dev-round-issue-9-15-15.json"
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 15-15 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--expect-items-from-round with an empty item text exits 2"
set -e
# the count-vs-set hint diagnoses a TYPED --expect-items count; a set read from
# the round record cannot be that misuse, so from-round must not emit the hint
# even when the shapes coincide (control first: the inline form still fires it).
"$WRITE" --worktree "$rr_wt" --kind fix --issue issue-9 --round-id 16-16 --branch b --commit "$rr_head" \
  --validate pass --item 1 Applied a --item 2 Applied b --item 3 Applied c >/dev/null
hint_inline="$("$CHECK" --file "$rr_wt/tmp/dev-return-issue-9-16-16.json" --expect-items 3 2>/dev/null | jq -r '.hint' || true)"
assert_eq "$([[ "$hint_inline" != "null" ]] && echo fires)" "fires" \
  "control: file-mode --expect-items 3 against items 1..3 fires the count-vs-set hint"
"$ROUND_WRITE" --worktree "$rr_wt" --issue issue-9 --round-id 16-16 --item 3 "only item three" "tools/guard on a staged render" >/dev/null
hint_round="$("$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 16-16 --expect-items-from-round 2>/dev/null | jq -r '.hint' || true)"
assert_eq "$hint_round" "null" "--expect-items-from-round never emits the count-vs-set hint (reason stays incomplete)"
reason_round="$("$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 16-16 --expect-items-from-round 2>/dev/null | jq -r '.reason' || true)"
assert_eq "$reason_round" "incomplete" "from-round set mismatch still reports incomplete"
set +e
# The weaker item-list flag cannot accept a round-mode artifact that the
# from-round path accepts.
"$CHECK" --worktree "$rr_wt" --issue issue-9 --round-id 7-8 --expect-items 1,2 >/dev/null 2>&1
assert_eq "$?" "2" "round mode rejects --expect-items authorization bypass"
# --file mode has no worktree/issue/round to resolve a record from
"$CHECK" --file "$rr_wt/tmp/dev-return-issue-9-7-8.json" --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "--file mode rejects --expect-items-from-round"
set -e

# --- KEN-826: a fix round cannot add unlisted machinery ---
adds_wt="$TMP_ROOT/adds"
mkdir -p "$adds_wt"
git -C "$adds_wt" init -q -b main
git -C "$adds_wt" config user.email test@example.com
git -C "$adds_wt" config user.name Test
git -C "$adds_wt" config commit.gpgsign false
git -C "$adds_wt" commit -q --allow-empty -m base
init_growth_state "$STATE" "$adds_wt" issue-826 seed 1000000

"$ROUND_WRITE" --worktree "$adds_wt" --issue issue-826 --round-id 1-1 --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
mkdir -p "$adds_wt/.agents/skills/orch/scripts" "$adds_wt/crates/new-parser" "$adds_wt/helpers" \
  "$adds_wt/pkg/test_helpers" "$adds_wt/skills/orch/scripts" "$adds_wt/src" \
  "$adds_wt/test/support" "$adds_wt/tools" "$adds_wt/ui/src/test"
printf 'installed\n' > "$adds_wt/.agents/skills/orch/scripts/installed-check"
printf 'crate\n' > "$adds_wt/crates/new-parser/lib.rs"
printf 'root helper\n' > "$adds_wt/helpers/root-helper.ts"
printf 'nested helper\n' > "$adds_wt/pkg/test_helpers/nested.ts"
printf 'script\n' > "$adds_wt/skills/orch/scripts/new-check"
printf 'basename helper\n' > "$adds_wt/src/test_utils.rs"
printf 'root test support\n' > "$adds_wt/test/support/root-support.sh"
printf 'tool\n' > "$adds_wt/tools/new-tool"
newline_path=$'tools/new\nline'
printf 'odd path\n' > "$adds_wt/$newline_path"
printf 'helper\n' > "$adds_wt/ui/src/test/round-helper.ts"
git -C "$adds_wt" add .agents/skills/orch/scripts/installed-check crates/new-parser/lib.rs \
  helpers/root-helper.ts pkg/test_helpers/nested.ts skills/orch/scripts/new-check \
  src/test_utils.rs test/support/root-support.sh tools/new-tool "$newline_path" ui/src/test/round-helper.ts
git -C "$adds_wt" commit -q -m additions
adds_head="$(git -C "$adds_wt" rev-parse HEAD)"
"$WRITE" --worktree "$adds_wt" --kind fix --issue issue-826 --round-id 1-1 --branch b --commit "$adds_head" \
  --validate pass --item 1 Applied done >/dev/null
set +e
adds_out="$("$CHECK" --worktree "$adds_wt" --issue issue-826 --round-id 1-1 --expect-items-from-round 2>/dev/null)"
adds_rc=$?
set -e
assert_eq "$adds_rc" "1" "an unlisted sensitive addition refuses acceptance"
assert_eq "$(jq -r '.ok' <<<"$adds_out")" "false" "the refusal reports ok false"
assert_eq "$(jq -r '.verdict' <<<"$adds_out")" "retry" "the refusal routes to retry"
assert_eq "$(jq -r '.path' <<<"$adds_out")" "$adds_wt/tmp/dev-return-issue-826-1-1.json" "the refusal binds the artifact path"
assert_eq "$(jq -r '.reason' <<<"$adds_out")" "unapproved_additions" "the refusal has a distinct reason"
assert_eq "$(jq -c '.files' <<<"$adds_out")" \
  '[".agents/skills/orch/scripts/installed-check","crates/new-parser/lib.rs","helpers/root-helper.ts","pkg/test_helpers/nested.ts","skills/orch/scripts/new-check","src/test_utils.rs","test/support/root-support.sh","tools/new\nline","tools/new-tool","ui/src/test/round-helper.ts"]' \
  "the refusal names every unlisted addition"

"$ROUND_WRITE" --worktree "$adds_wt" --issue issue-826 --round-id 2-2 --item 1 "fix finding" "tools/guard on a staged render" \
  --adds "crates/allowed/lib.rs skills/orch/scripts/allowed-check tools/allowed;still-data ui/src/test/allowed-helper.ts" >/dev/null
mkdir -p "$adds_wt/crates/allowed"
printf 'crate\n' > "$adds_wt/crates/allowed/lib.rs"
printf 'script\n' > "$adds_wt/skills/orch/scripts/allowed-check"
printf 'tool\n' > "$adds_wt/tools/allowed;still-data"
printf 'helper\n' > "$adds_wt/ui/src/test/allowed-helper.ts"
git -C "$adds_wt" add crates/allowed/lib.rs skills/orch/scripts/allowed-check \
  "tools/allowed;still-data" ui/src/test/allowed-helper.ts
git -C "$adds_wt" commit -q -m allowed-additions
allowed_head="$(git -C "$adds_wt" rev-parse HEAD)"
"$WRITE" --worktree "$adds_wt" --kind fix --issue issue-826 --round-id 2-2 --branch b --commit "$allowed_head" \
  --validate pass --item 1 Applied done >/dev/null
assert_eq "$(reason --worktree "$adds_wt" --issue issue-826 --round-id 2-2 --expect-items-from-round)" "valid" \
  "each addition named by the round is accepted"

printf 'move me\n' > "$adds_wt/ordinary.txt"
git -C "$adds_wt" add ordinary.txt
git -C "$adds_wt" commit -q -m pre-move
"$ROUND_WRITE" --worktree "$adds_wt" --issue issue-826 --round-id 3-3 --item 1 "move existing file" "tools/guard on a staged render" >/dev/null
git -C "$adds_wt" mv ordinary.txt tools/moved.txt
git -C "$adds_wt" commit -q -m move
move_head="$(git -C "$adds_wt" rev-parse HEAD)"
"$WRITE" --worktree "$adds_wt" --kind fix --issue issue-826 --round-id 3-3 --branch b --commit "$move_head" \
  --validate pass --item 1 Applied done >/dev/null
assert_eq "$(reason --worktree "$adds_wt" --issue issue-826 --round-id 3-3 --expect-items-from-round)" "valid" \
  "a moved file is not treated as an addition"
diverge_wt="$TMP_ROOT/diverge"
mkdir -p "$diverge_wt"
git -C "$diverge_wt" init -q -b main
git -C "$diverge_wt" config user.email test@example.com
git -C "$diverge_wt" config user.name Test
git -C "$diverge_wt" config commit.gpgsign false
git -C "$diverge_wt" commit -q --allow-empty -m base
init_growth_state "$STATE" "$diverge_wt" issue-826 seed 1000000
"$ROUND_WRITE" --worktree "$diverge_wt" --issue issue-826 --round-id 4-4 --item 1 compare "tools/guard on a staged render" >/dev/null
git -C "$diverge_wt" checkout -q --orphan divergent
git -C "$diverge_wt" commit -q --allow-empty -m divergent
diverge_head="$(git -C "$diverge_wt" rev-parse HEAD)"
"$WRITE" --worktree "$diverge_wt" --kind fix --issue issue-826 --round-id 4-4 --branch divergent \
  --commit "$diverge_head" --validate pass --item 1 Applied done >/dev/null
diverge_out="$("$CHECK" --worktree "$diverge_wt" --issue issue-826 --round-id 4-4 --expect-items-from-round)"
assert_eq "$(jq -r '.reason' <<<"$diverge_out")" "valid" \
  "direct snapshot comparison accepts histories with no merge base"
git_shim_dir="$TMP_ROOT/git-shim"
mkdir -p "$git_shim_dir"
cat > "$git_shim_dir/git" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == "diff" ]] && exit 42
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$git_shim_dir/git"
real_git="$(command -v git)"
set +e
comparison_out="$(REAL_GIT="$real_git" PATH="$git_shim_dir:$PATH" "$CHECK" \
  --worktree "$diverge_wt" --issue issue-826 --round-id 4-4 --expect-items-from-round 2>/dev/null)"
comparison_rc=$?
set -e
assert_eq "$comparison_rc" "1" "a failed direct snapshot probe refuses acceptance"
assert_eq "$(jq -r '.reason' <<<"$comparison_out")" "comparison_failed" \
  "failed direct snapshot probe keeps the distinct reason"
routing_mutant="$(copy_scripts routing-mutant)/dev-artifact-check"
sed -i.bak 's/emit false "$file" "comparison_failed"/emit false "$file" "unapproved_additions"/' "$routing_mutant"
chmod +x "$routing_mutant"
set +e
routing_mutant_out="$(REAL_GIT="$real_git" PATH="$git_shim_dir:$PATH" "$routing_mutant" \
  --worktree "$diverge_wt" --issue issue-826 --round-id 4-4 --expect-items-from-round 2>/dev/null)"
set -e
# The misroute must show as the reason the mutation names. Asserting only
# "not comparison_failed" would also pass for a mutant that never ran.
assert_eq "$(jq -r '.reason' <<<"$routing_mutant_out")" "unapproved_additions" \
  "routing control detects a comparison-failure misroute"
# --- kendex#994: the recorded commit must name a real object in the worktree's repo ---
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
assert_eq "$rc" "0" "orphaned-but-real commit still exits 0 (non-fatal per kendex#994)"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "orphaned commit reports ok=true"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "orphaned commit reports reason=valid"
assert_eq "$(jq -r '.warning' <<<"$out")" "commit_unreachable" "orphaned commit reports warning=commit_unreachable"

# gate ordering: scalar invalid beats the commit gates; commit_unresolvable beats incomplete
printf '%s' "$valid_impl" | jq -c 'del(.commit)' > "$gartifact"
assert_eq "$(reason --worktree "$gitwt" --issue "$issue" --round-id "$R")" "invalid" "missing .commit in a git worktree stays reason=invalid (scalar gate first)"
printf '%s' "$valid_impl" | jq -c --arg c "$fake_sha" '.commit=$c | .bundled=true | .items=[]' > "$gartifact"
assert_eq "$(reason --worktree "$gitwt" --issue "$issue" --round-id "$R")" "commit_unresolvable" "commit_unresolvable beats bundled-item incompleteness"

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
# two independent substring checks — so assert the full string). Since kendex#1230
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
assert_file_contains "$orch_dev_fix" "$ROUND_ITEMS_PERSIST" "orch dev-fix persists the delegated item set at stamp time (kendex#1230)"
assert_file_not_contains "$orch_dev_fix" "write the record now" "orch dev-fix never recreates missing round state after delegation"
assert_file_not_contains "$orch_dev_fix" "only if that context is also gone, fall back" "orch dev-fix never bypasses authorization with a typed item set"
assert_file_contains "$orch_dev_fix" "Round ID: [DEV_ROUND_ID]" "orch dev-fix delegation carries the Round ID line"
assert_file_contains "$orch_dev_fix" "$ARTIFACT_KEY_LINE" "orch dev-fix delegation carries the Artifact Key line"

review_pr_comments="$REPO_ROOT/skills/orch/workflows/review-pr-comments.md"
assert_file_contains "$review_pr_comments" "$WATCHDOG_STAMP" "review-pr-comments § 6.1 still stamps dev_delegated_at"
assert_file_contains "$review_pr_comments" "$ROUND_STAMP" "review-pr-comments § 6.1 mints dev_round_id before delegation"
assert_file_contains "$review_pr_comments" "$ROUND_CHECK_EXPECT" "review-pr-comments accepts via round-mode dev-artifact-check WITH --expect-items-from-round in one command"
assert_file_contains "$review_pr_comments" "$ROUND_ITEMS_PERSIST" "review-pr-comments persists each group's delegated item set at stamp time (kendex#1230)"
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
assert_file_not_contains "$ci_fix" "$LEGACY_CHECK" "ci-fix § 3.2 no longer uses the legacy positional dev-artifact-check call"

# The removed legacy positional call must not survive in any orch workflow.
for wf in dev-start dev-fix review-pr-comments ci-fix; do
  assert_file_not_contains "$REPO_ROOT/skills/orch/workflows/$wf.md" "$LEGACY_CHECK" "$wf.md carries no legacy positional dev-artifact-check call"
done

# --- kendex#803: mechanical per-wake A/B check + single-shot wall-clock watchdog ---
# The stall was an orchestrator that read a `finished` wake's wording and idled
# without running A/B, plus a wait loop with no wall-clock re-entry when wakes
# stopped. SKILL must mandate both, and every delegation point that stamps
# dev_delegated_at must arm the watchdog. kendex#818 re-homed both mandates into
# the numbered "orchestrator owns round closure" list (same requirements, new
# wording) and made that list the primary path rather than a recovery fallback.
# The two bolded list items are the anchors.
orch_skill="$REPO_ROOT/skills/orch/SKILL.md"
assert_file_contains "$orch_skill" "Run the check on every wake and at the deadline" "SKILL mandates the per-wake and deadline check"
assert_file_contains "$orch_skill" '`verdict`' "SKILL names the one-word verdict acceptance reads"
assert_file_contains "$orch_skill" "Arm a single-shot wall-clock watchdog" "SKILL mandates a wall-clock watchdog independent of sub-agent wakes (kendex#803)"
for wf in dev-start dev-fix review-pr-comments ci-fix; do
  wf_doc="$REPO_ROOT/skills/orch/workflows/$wf.md"
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
# kendex#1230: a respawned agent recovers its delegated item set from the
# persisted round record instead of guessing (or depending on the orchestrator's
# context surviving).
assert_file_contains "$dev_fix" "dev-round-[ARTIFACT_KEY]-[DEV_ROUND_ID].json" "dev-fix § 6 points a respawned agent at the persisted round record"

# --- schema docs carry the round-id / dev_round_id contract ---
dev_return_schema="$REPO_ROOT/skills/orch/schemas/dev-return.md"
assert_file_contains "$dev_return_schema" "dev-return-write" "dev-return schema references the writer"
assert_file_contains "$dev_return_schema" "round_id" "dev-return schema documents round_id identity"
assert_file_contains "$dev_return_schema" "schema_version" "dev-return schema documents schema_version"
# Validation gates have ONE canonical home — dev-artifact-check --help —
# and the artifact-checks reference only routes to it (KEN-556). Pin the
# gate-ordering and reason vocabulary in the canonical copy.
check_help="$("$CHECK" --help)"
assert_contains_str() {
  local haystack="$1" needle="$2" name="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s (missing: %s)\n' "$name" "$needle"
  fi
}
assert_contains_str "$check_help" "Gates ordered:" "--help documents the gate ordering"
assert_contains_str "$check_help" "commit_unresolvable" "--help documents the commit gate"
assert_contains_str "$check_help" "unapproved_additions" "--help documents the additions gate"
assert_contains_str "$check_help" "comparison_failed" "--help documents Git comparison failures"
assert_contains_str "$check_help" "classifier_failed" "--help documents classifier failures"
assert_contains_str "$check_help" "--expect-items (--file mode only)" "--help confines the weaker item-list flag to file mode"
assert_contains_str "$check_help" "incomplete" "--help documents the incomplete reason"
artifact_checks_ref="$REPO_ROOT/skills/orch/references/artifact-checks.md"
assert_file_contains "$artifact_checks_ref" "--help" "artifact-checks reference routes to the help contracts"
assert_file_not_contains "$dev_return_schema" "reason \`incomplete\`" "dev-return schema does not duplicate the verdict vocabulary"
assert_file_contains "$dev_return_schema" "--expect-items" "dev-return schema documents the exact item-set rule"

state_schema="$REPO_ROOT/skills/orch/schemas/workflow-state.md"
assert_file_contains "$state_schema" "dev_delegated_at" "workflow-state schema documents dev_delegated_at"
assert_file_contains "$state_schema" "dev_round_id" "workflow-state schema documents dev_round_id"

# --- kendex#1230 schema doc: the round record has its own contract ---
dev_round_schema="$REPO_ROOT/skills/orch/schemas/dev-round.md"
assert_file_contains "$dev_round_schema" "dev-round-write" "dev-round schema references the writer"
assert_file_contains "$dev_round_schema" "round_id" "dev-round schema documents round_id identity"
assert_file_contains "$dev_round_schema" "base_sha" "dev-round schema documents the fix round base"
assert_file_contains "$dev_round_schema" "adds" "dev-round schema documents allowed additions"
assert_file_contains "$dev_round_schema" "tmp/dev-round-" "dev-round schema documents where the record lives"
assert_file_not_contains "$dev_round_schema" "git-common-dir" "dev-round schema keeps no external authorization store"
assert_file_contains "$dev_round_schema" "never fall back" "dev-round schema forbids post-delegation recovery bypass"
assert_file_contains "$dev_round_schema" "--expect-items-from-round" "dev-round schema documents the check-side reader"

# --- kendex#884: the note has to reach the orchestrator, not just the file ---
# This output IS what orch accepts a completion on, so a caveat stored in the
# artifact but never echoed would be as lost as one never recorded.
noted_file="$worktree/tmp/noted.json"
NOTE="80/80 on re-run; first run flaked on Rust Tests (release)"
jq -n --arg note "$NOTE" '{schema_version:1,round_id:"1-1",kind:"implement",issue:"i",branch:"b",
  commit:"c",baseline_lines:1,validate:"pass",validate_note:$note,qa_labels:[],summary_posted:true,summary:null,
  bundled:false,items:[]}' > "$noted_file"
out="$("$CHECK" --file "$noted_file")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "an artifact carrying a validate_note is valid"
assert_eq "$(jq -r '.validate' <<<"$out")" "pass" "the check echoes the enumerated verdict"
assert_eq "$(jq -r '.validate_note' <<<"$out")" "$NOTE" "the check echoes the qualifier to the orchestrator"

# The validation note remains optional beside the required baseline measurement.
legacy_file="$worktree/tmp/legacy.json"
jq -n '{schema_version:1,round_id:"1-1",kind:"implement",issue:"i",branch:"b",commit:"c",
  baseline_lines:1,validate:"pass",qa_labels:[],summary_posted:true,summary:null,bundled:false,items:[]}' > "$legacy_file"
out="$("$CHECK" --file "$legacy_file")"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "an artifact with no validate_note key is still valid"
assert_eq "$(jq -r '.validate_note' <<<"$out")" "null" "an absent note reports null"

# Wrong-typed or empty notes are malformed receipts, not silently-ignored ones.
for bad in '""' '42' 'true' '[]'; do
  bad_file="$worktree/tmp/badnote.json"
  jq -n --argjson n "$bad" '{schema_version:1,round_id:"1-1",kind:"implement",issue:"i",branch:"b",
    commit:"c",baseline_lines:1,validate:"pass",validate_note:$n,qa_labels:[],summary_posted:true,summary:null,
    bundled:false,items:[]}' > "$bad_file"
  assert_eq "$("$CHECK" --file "$bad_file" 2>/dev/null | jq -r '.reason')" "invalid" \
    "validate_note $bad is rejected as invalid"
done

# A missing artifact still reports the stable shape with null qualifiers.
out="$("$CHECK" --file "$worktree/tmp/nope.json" 2>/dev/null || true)"
assert_eq "$(jq -r '.validate' <<<"$out")" "null" "a missing artifact reports validate=null"
assert_eq "$(jq -r '.validate_note' <<<"$out")" "null" "a missing artifact reports validate_note=null"

assert_file_contains "$dev_return_schema" "validate_note" "dev-return schema documents validate_note"

echo "=== --wait blocking mode ==="

# An artifact landing mid-wait ends the wait immediately: the writer lands an
# (invalid) receipt after ~2s; --wait 20 must return well before its deadline
# with the artifact's verdict, proving closure does not depend on any message.
wait_dir="$TMP_ROOT/waitwt"
mkdir -p "$wait_dir"
start_epoch="$(date +%s)"
( sleep 2; printf '{"bad":true}' > "$wait_dir/landing.json" ) &
writer_pid=$!
wait_out="$("$CHECK" --file "$wait_dir/landing.json" --wait 20 --interval 1 2>/dev/null || true)"
wait "$writer_pid" 2>/dev/null || true
elapsed=$(( $(date +%s) - start_epoch ))
assert_eq "$(jq -r '.verdict' <<<"$wait_out")" "retry" "--wait returns the landed artifact's verdict"
if (( elapsed < 15 )); then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "--wait returned on the landing, not the deadline (${elapsed}s)"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "--wait burned toward its deadline (${elapsed}s) instead of returning on the landing"
fi

# No artifact at the deadline: verdict wait, exit 1, and the deadline was honored.
start_epoch="$(date +%s)"
rc=0
wait_out="$("$CHECK" --file "$wait_dir/never.json" --wait 2 --interval 1 2>/dev/null)" || rc=$?
elapsed=$(( $(date +%s) - start_epoch ))
assert_eq "$(jq -r '.verdict' <<<"$wait_out")" "wait" "--wait deadline returns verdict wait"
assert_eq "$rc" "1" "--wait deadline exits 1"
if (( elapsed >= 2 )); then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "--wait held until its deadline (${elapsed}s)"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "--wait gave up before its deadline (${elapsed}s)"
fi

# Flag validation fails closed as usage errors.
rc=0; "$CHECK" --file "$wait_dir/never.json" --wait nope >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "a non-integer --wait is a usage error"
rc=0; "$CHECK" --file "$wait_dir/never.json" --wait 5 --interval 0 >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "a zero --interval is a usage error"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
