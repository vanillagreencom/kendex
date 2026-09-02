#!/usr/bin/env bash
# Regression tests for dev-round-write: the orchestrator-side writer that
# persists a fix round's delegated item set to the round-scoped record
# ([WORKTREE]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json) at delegation time
# (kendex#1230). Without it the delegated set exists only in the orchestrator's
# context: a respawned dev agent cannot write a truthful completion artifact,
# and dev-artifact-check --expect-items has no on-disk source of truth. The
# record follows the dev-return round-token discipline (kendex#776): the round
# token in the filename AND as internal "round_id".

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
WRITE_BIN="$REPO_ROOT/skills/orch/scripts/dev-round-write"
WRITE=round_write
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
RETURN_WRITE="$REPO_ROOT/skills/orch/scripts/dev-return-write"
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

fenced_block_with() {
  local file="$1" needle="$2"
  awk -v needle="$needle" '
    /^[[:space:]]*```/ {
      if (!inside) { inside = 1; block = $0 ORS; next }
      block = block $0 ORS
      if (index(block, needle) > 0) { printf "%s", block; exit }
      inside = 0; block = ""; next
    }
    inside { block = block $0 ORS }
  ' "$file"
}

delegation_block() {
  local file="$1" needle="$2"
  awk -v needle="$needle" '
    /<delegation_format>/ { inside = 1; block = "" }
    inside { block = block $0 ORS }
    /<\/delegation_format>/ && inside {
      if (index(block, needle) > 0) { printf "%s", block; exit }
      inside = 0; block = ""
    }
  ' "$file"
}

assert_text_matches() {
  local text="$1" pattern="$2" name="$3"
  if grep -Eq -- "$pattern" <<<"$text"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        missing live pattern: %s\n' "$name" "$pattern"
  fi
}

assert_text_not_matches() {
  local text="$1" pattern="$2" name="$3"
  if grep -Eq -- "$pattern" <<<"$text"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        unexpected live pattern: %s\n' "$name" "$pattern"
  else
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  fi
}

round_write() {
  growth_round_write "$STATE" "$WRITE_BIN" "$@"
}

run_workflow_round_command() {
  local workflow="$1" wt="$2" issue_id="$3" rid="$4" block line
  block="$(fenced_block_with "$workflow" "dev-round-write --worktree")"
  line="$(awk '/dev-round-write --worktree/ { print; exit }' <<<"$block")"
  [[ -n "$line" ]] || return 1
  line="${line//.agents\/skills\/orch\/scripts\/dev-round-write/$WRITE_BIN}"
  line="${line//\[WORKTREE_PATH\]/$wt}"
  line="${line//\[ISSUE_ID\]/$issue_id}"
  line="${line//\[DEV_ROUND_ID\]/$rid}"
  line="${line/\[--adds/--adds}"
  line="${line/\[REPO_RELATIVE_PATHS\]/$ADDS_PATHS}"
  line="${line/\"]/\"}"
  "$STATE" --state-dir "$wt/tmp" set "$issue_id" dev_round_id "$rid" >/dev/null
  env ORCH_STATE_DIR="$wt/tmp" bash -c "$line"
}

# Assert an invocation fails validation with exit code 2.
assert_exit2() {
  local name="$1"; shift
  set +e
  "$WRITE" "$@" >/dev/null 2>&1
  local rc=$?
  set -e
  assert_eq "$rc" "2" "$name"
}

echo "=== dev-round-write ==="

worktree="$TMP_ROOT/wt"
mkdir -p "$worktree"
git -C "$worktree" init -q -b main
git -C "$worktree" config user.email test@example.com
git -C "$worktree" config user.name Test
git -C "$worktree" config commit.gpgsign false
git -C "$worktree" commit -q --allow-empty -m base
base_sha="$(git -C "$worktree" rev-parse HEAD)"
init_growth_state "$STATE" "$worktree" issue-1230 seed 1000000
init_growth_state "$STATE" "$worktree" i seed 1000000
init_growth_state "$STATE" "$worktree" issue-826 seed 1000000
RID="1750000000-77"
# A reach the writer accepts: a command a person runs.
OK_REACH="tools/guard on a staged .agents render"
ADDS="crates/parser/src/lib.rs skills/orch/scripts/new-check"

# --- valid: two-item round record ---
ITEM1='#1 | security-review | src/auth.rs
Description: "token refresh races"
Recommendation: "serialize refresh behind the existing lock"'
ITEM2='#2 | test-review | tests/auth.rs
Description: "no coverage for expired token"
Recommendation: "add expiry regression test"'
# Each item names what reaches it: a user action and a fixture in the tree.
REACH1='a second session refreshing the same account through src/auth.rs'
REACH2='tests/auth.rs expired-token case'
out="$("$WRITE" --worktree "$worktree" --issue issue-1230 --round-id "$RID" \
  --item 1 "$ITEM1" "$REACH1" --item 2 "$ITEM2" "$REACH2" \
  --adds "$ADDS")"
assert_eq "$out" "$worktree/tmp/dev-round-issue-1230-$RID.json" "prints the round-scoped record path"
assert_eq "$([[ -f "$out" ]] && echo yes)" "yes" "wrote the file"
assert_eq "$(jq -r '.schema_version' "$out")" "2" ".schema_version is 2"
assert_eq "$(jq -r '.schema_version | type' "$out")" "number" ".schema_version is a JSON number"
assert_eq "$(jq -r '.round_id' "$out")" "$RID" ".round_id matches --round-id (internal token binding)"
assert_eq "$(jq -r '.issue' "$out")" "issue-1230" ".issue is the normalized state key"
assert_eq "$(jq -r '.base_sha' "$out")" "$base_sha" ".base_sha records HEAD at delegation"
assert_eq "$(jq -c '.adds' "$out")" '["crates/parser/src/lib.rs","skills/orch/scripts/new-check"]' ".adds splits the path list into each allowed new path"
assert_eq "$([[ -e "$worktree/.git/kendex" ]] && echo yes || echo no)" "no" "the record is the whole authorization: nothing is written outside the worktree"
assert_eq "$(jq -r '.items | length' "$out")" "2" ".items carries one entry per --item"
assert_eq "$(jq -r '.items[0].n' "$out")" "1" "first item keeps its delegated number"
assert_eq "$(jq -r '.items[0].n | type' "$out")" "number" ".items[].n is a JSON number"
assert_eq "$(jq -r '.items[1].text' "$out")" "$ITEM2" ".items[].text preserves the formatted block verbatim (multi-line)"

# --- same-round records are IMMUTABLE: the delegated set is stamped once ---
# An identical re-invocation is an idempotent retry → success, same path,
# content untouched. A DIFFERENT set under the same round id would silently
# rewrite the authoritative delegated set (e.g. a retry with a partial list) —
# refused: a changed delegation needs a NEW round id.
out_rerun="$("$WRITE" --worktree "$worktree" --issue issue-1230 --round-id "$RID" \
  --item 1 "$ITEM1" "$REACH1" --item 2 "$ITEM2" "$REACH2" \
  --adds "$ADDS")"
assert_eq "$out_rerun" "$out" "identical re-invocation is idempotent (exit 0, same path)"
assert_eq "$(jq -c '[.items[].n]' "$out")" "[1,2]" "identical re-invocation leaves the record unchanged"
assert_exit2 "a different item set under the same round id exits 2 (immutable round)" \
  --worktree "$worktree" --issue issue-1230 --round-id "$RID" --item 3 "replacement" "$OK_REACH"
assert_eq "$(jq -c '[.items[].n]' "$out")" "[1,2]" "the refused rewrite left the original record intact"

growth_wt="$TMP_ROOT/growth-wt"
growth_remote="$TMP_ROOT/growth-remote.git"
mkdir -p "$growth_wt"
git -C "$growth_wt" init -q -b main
git -C "$growth_wt" config user.email test@example.com
git -C "$growth_wt" config user.name Test
git -C "$growth_wt" config commit.gpgsign false
git -C "$growth_wt" commit -q --allow-empty -m base
git -C "$growth_wt" switch -q -c growth
printf 'one\ntwo\n' > "$growth_wt/change.txt"
git -C "$growth_wt" add change.txt
git -C "$growth_wt" commit -q -m implementation
init_growth_state "$STATE" "$growth_wt" KEN-GROWTH 1-1 2
printf 'three\nfour\n' >> "$growth_wt/change.txt"
git -C "$growth_wt" add change.txt
git -C "$growth_wt" commit -q -m at-limit
"$WRITE" --worktree "$growth_wt" --issue KEN-GROWTH --round-id 2-2 --item 1 at-limit "$OK_REACH" >/dev/null
printf 'five\n' >> "$growth_wt/change.txt"
git -C "$growth_wt" add change.txt
git -C "$growth_wt" commit -q -m over-limit
set +e
growth_error="$("$WRITE" --worktree "$growth_wt" --issue KEN-GROWTH --round-id 3-3 --item 1 over-limit "$OK_REACH" 2>&1)"
growth_rc=$?
set -e
assert_eq "$growth_rc" "3" "a pre-push fix round past twice the baseline is refused"
assert_eq "$([[ "$growth_error" == *"branch diffstat is 5 lines"* && "$growth_error" == *"baseline is 2 lines"* && "$growth_error" == *"2x"* ]] && echo yes)" \
  "yes" "the refusal prints both numbers and the rule"
git init -q --bare "$growth_remote"
git -C "$growth_wt" remote add origin "$growth_remote"
git -C "$growth_wt" push -q origin main growth
set +e
"$WRITE" --worktree "$growth_wt" --issue KEN-GROWTH --round-id 4-4 --item 1 after-push "$OK_REACH" >/dev/null 2>&1
after_push_rc=$?
set -e
assert_eq "$after_push_rc" "3" "the same oversized branch is refused after its first push"

mutant_root="$TMP_ROOT/tripwire-mutant"
mkdir -p "$mutant_root"
cp -R "$REPO_ROOT/skills/orch/scripts" "$mutant_root/"
mutant_write="$mutant_root/scripts/dev-round-write"
mutant_check="$mutant_root/scripts/dev-artifact-check"
assert_eq "$(grep -Fc 'run_size_tripwire "$worktree" "$issue"' "$mutant_write")" "1" \
  "tripwire control finds exactly one live gate call"
assert_eq "$(grep -Fc 'if (.pr.baseline_lines // null) == null' "$mutant_check")" "1" \
  "tripwire control finds exactly one set-once guard"
sed -i.bak 's|^run_size_tripwire "$worktree" "$issue"$|: # tripwire removed by must-fail control|' "$mutant_write"
sed -i.bak 's/if (.pr.baseline_lines \/\/ null) == null/if true/' "$mutant_check"
assert_eq "$([[ "$(grep -Fc 'run_size_tripwire "$worktree" "$issue"' "$mutant_write")" == 0 ]] && ! cmp -s "$mutant_write" "$WRITE_BIN" && echo yes)" \
  "yes" "tripwire control removes the gate only from its private copy"
"$STATE" --state-dir "$growth_wt/tmp" set KEN-GROWTH dev_round_id 5-5 >/dev/null
env ORCH_STATE_DIR="$growth_wt/tmp" "$mutant_write" --worktree "$growth_wt" --issue KEN-GROWTH --round-id 5-5 --item 1 mutant "$OK_REACH" >/dev/null
growth_head="$(git -C "$growth_wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$growth_wt" --kind implement --issue KEN-GROWTH --round-id 6-6 \
  --branch growth --commit "$growth_head" --validate pass >/dev/null
env ORCH_STATE_DIR="$growth_wt/tmp" "$mutant_check" --worktree "$growth_wt" --issue KEN-GROWTH --round-id 6-6 >/dev/null
assert_eq "$([[ -f "$growth_wt/tmp/dev-round-KEN-GROWTH-5-5.json" && "$("$STATE" --state-dir "$growth_wt/tmp" get KEN-GROWTH .pr.baseline_lines)" == 5 ]] && echo yes)" \
  "yes" "must-fail control kills tripwire removal and baseline overwrite"
"$STATE" --state-dir "$growth_wt/tmp" set KEN-GROWTH pr '{"baseline_lines":2}' >/dev/null

# A record is never rewritten after delegation, and a record that cannot supply
# the expected set fails acceptance closed rather than falling back.
"$WRITE" --worktree "$worktree" --issue issue-1230 --round-id 6-6 --item 1 partial "$OK_REACH" >/dev/null
partial_round="$worktree/tmp/dev-round-issue-1230-6-6.json"
rm -f "$partial_round"
set +e
"$CHECK" --worktree "$worktree" --issue issue-1230 --round-id 6-6 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "acceptance fails closed when the round record is missing"
set -e

"$WRITE" --worktree "$worktree" --issue issue-1230 --round-id 8-8 --item 1 schema "$OK_REACH" >/dev/null
round8="$worktree/tmp/dev-round-issue-1230-8-8.json"
jq '.base_sha = 42' "$round8" > "$TMP_ROOT/round8.json"
mv "$TMP_ROOT/round8.json" "$round8"
set +e
"$CHECK" --worktree "$worktree" --issue issue-1230 --round-id 8-8 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a record with a non-string base_sha fails its schema arm"
set -e

"$WRITE" --worktree "$worktree" --issue issue-1230 --round-id 9-9 --item 1 schema "$OK_REACH" >/dev/null
round9="$worktree/tmp/dev-round-issue-1230-9-9.json"
jq '.adds = ["tools/"]' "$round9" > "$TMP_ROOT/round9.json"
mv "$TMP_ROOT/round9.json" "$round9"
set +e
"$CHECK" --worktree "$worktree" --issue issue-1230 --round-id 9-9 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a record with an empty path component fails its adds schema arm"
set -e

"$WRITE" --worktree "$worktree" --issue issue-1230 --round-id 10-10 --item 1 schema "$OK_REACH" >/dev/null
round10="$worktree/tmp/dev-round-issue-1230-10-10.json"
jq '.adds = ["tools/one path"]' "$round10" > "$TMP_ROOT/round10.json"
mv "$TMP_ROOT/round10.json" "$round10"
set +e
"$CHECK" --worktree "$worktree" --issue issue-1230 --round-id 10-10 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a record carrying a whitespace path the delegation cannot express fails closed"
set -e

# --- a fresh round id scopes a distinct file; the prior round's record survives ---
out2="$("$WRITE" --worktree "$worktree" --issue issue-1230 --round-id 2-2 --item 1 "next round" "$OK_REACH")"
assert_eq "$([[ "$out2" != "$out" && -f "$out" && -f "$out2" ]] && echo yes)" "yes" \
  "a new round id writes a distinct record without clobbering the prior round's"

# --- --items-file: the harness-safe route for shell-hostile item text ---
# Real review blocks carry backticks and quotes; Codex rejects a literal
# backtick in a command even single-quoted, so the orchestrator builds the JSON
# with the harness file-write tool and passes one plain --items-file path.
items_file="$TMP_ROOT/items.json"
printf '%s' '[{"n":1,"text":"#1 | fix `parse()` — do not touch '"'"'raw'"'"' mode","reach":"parse() on a config a shipped writer emits"},{"n":4,"text":"#4 | second item","reach":"tools/guard on a staged render"}]' > "$items_file"
outf="$("$WRITE" --worktree "$worktree" --issue issue-1230 --round-id 3-3 --items-file "$items_file")"
assert_eq "$(jq -c '[.items[].n]' "$outf")" "[1,4]" "--items-file records the file's item numbers"
assert_eq "$(jq -r '.items[0].text' "$outf")" '#1 | fix `parse()` — do not touch '"'"'raw'"'"' mode' \
  "--items-file preserves backticks/quotes in item text verbatim"
# extra keys in an element are dropped, not stored (the record schema is {n, text})
printf '%s' '[{"n":1,"text":"t","reach":"tools/guard on a staged render","extra":"x"}]' > "$items_file"
outf="$("$WRITE" --worktree "$worktree" --issue issue-1230 --round-id 4-4 --items-file "$items_file")"
assert_eq "$(jq -c '.items[0] | keys_unsorted' "$outf")" '["n","text","reach"]' "--items-file normalizes elements to {n, text, reach}"

assert_exit2 "--items-file with --item exits 2 (one item source)" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file" --item 1 t "$OK_REACH"
assert_exit2 "--items-file with a nonexistent path exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$TMP_ROOT/nope.json"
printf 'not json' > "$items_file"
assert_exit2 "--items-file with unparseable JSON exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '{"n":1,"text":"t","reach":"tools/guard on a staged render"}' > "$items_file"
assert_exit2 "--items-file with a non-array top level exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '[]' > "$items_file"
assert_exit2 "--items-file with an empty array exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '[{"n":1,"reach":"tools/guard on a staged render"}]' > "$items_file"
assert_exit2 "--items-file element without text exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '[{"n":1.5,"text":"t","reach":"tools/guard on a staged render"}]' > "$items_file"
assert_exit2 "--items-file with a non-integer n exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '[{"n":-1,"text":"t","reach":"tools/guard on a staged render"}]' > "$items_file"
assert_exit2 "--items-file with a negative n exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '[{"n":1,"text":"a","reach":"tools/guard on a staged render"},{"n":1,"text":"b","reach":"tools/guard on a staged render"}]' > "$items_file"
assert_exit2 "--items-file with a duplicate n exits 2 (a set, not a list)" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"
printf '%s' '[{"n":1,"text":"   ","reach":"tools/guard on a staged render"}]' > "$items_file"
assert_exit2 "--items-file with whitespace-only text exits 2" \
  --worktree "$worktree" --issue i --round-id 5-5 --items-file "$items_file"

# --- the reach bar: an item names the producer that reaches the finding ---
# A merged-PR audit found fix rounds answering a review thread rather than a
# producer (KEN-1046), so a shape a bot typed was patched as if a user had
# reached it. The writer refuses an item with no reach and an item whose reach
# is on the refusal list: that item is a `Declined:` reply.
# Each case takes its own round id: sharing one would let the first accepted
# write shadow every later refusal behind the immutability arm.
assert_exit2 "--item with no reach exits 2 (the field is required)" \
  --worktree "$worktree" --issue i --round-id 60-1 --item 1 "text"
assert_exit2 "--item with an empty reach exits 2" \
  --worktree "$worktree" --issue i --round-id 60-2 --item 1 "text" ""
assert_exit2 "--item with a whitespace-only reach exits 2" \
  --worktree "$worktree" --issue i --round-id 60-3 --item 1 "text" "   "
assert_exit2 "reach 'Copilot thread' exits 2 (names only a review thread)" \
  --worktree "$worktree" --issue i --round-id 60-4 --item 1 "text" "Copilot thread"
assert_exit2 "reach naming a review-thread node id exits 2" \
  --worktree "$worktree" --issue i --round-id 60-5 --item 1 "text" "PRRT_kwDOAbc123"
assert_eq "$(find "$worktree/tmp" -maxdepth 1 -name 'dev-round-i-60-*.json' | wc -l | tr -d ' ')" "0" \
  "a refused reach writes no record"

# A reach that names a command a person runs is accepted and stored verbatim.
reach_ok="$("$WRITE" --worktree "$worktree" --issue issue-1230 --round-id 61-61 \
  --item 1 "text" "kendex refresh in a linked worktree")"
assert_eq "$(jq -r '.items[0].reach' "$reach_ok")" "kendex refresh in a linked worktree" \
  "a reach naming a command exits 0 and is recorded verbatim"
assert_eq "$(jq -c '.items[0] | keys_unsorted' "$reach_ok")" '["n","text","reach"]' \
  "an inline item records n, text, and reach"

printf '%s' '[{"n":1,"text":"t"}]' > "$items_file"
assert_exit2 "--items-file element without reach exits 2" \
  --worktree "$worktree" --issue i --round-id 62-1 --items-file "$items_file"
printf '%s' '[{"n":1,"text":"t","reach":"   "}]' > "$items_file"
assert_exit2 "--items-file element with a whitespace-only reach exits 2" \
  --worktree "$worktree" --issue i --round-id 62-2 --items-file "$items_file"
printf '%s' '[{"n":1,"text":"t","reach":"Copilot thread"}]' > "$items_file"
assert_exit2 "--items-file element whose reach is only a review thread exits 2" \
  --worktree "$worktree" --issue i --round-id 62-3 --items-file "$items_file"

# Must-fail control: with check_reach neutered the same values are accepted,
# so the refusals above come from the live check and not from another arm.
#
# Assert the mutation landed before trusting the run that follows it: a pattern
# that stops matching after a reword would otherwise leave the control green
# while testing nothing.
reach_mutant_root="$TMP_ROOT/reach-mutant"
mkdir -p "$reach_mutant_root"
cp -R "$REPO_ROOT/skills/orch/scripts" "$reach_mutant_root/"
reach_mutant="$reach_mutant_root/scripts/dev-round-write"
awk '{ print } /^check_reach\(\) \{$/ { print "  return 0  # MUTATED" }' "$WRITE_BIN" > "$reach_mutant"
chmod +x "$reach_mutant"
assert_eq "$(grep -Fc -- "return 0  # MUTATED" "$reach_mutant")" "1" \
  "reach mutation applied to check_reach"
set +e
growth_round_write "$STATE" "$reach_mutant" --worktree "$worktree" --issue issue-1230 \
  --round-id 63-63 --item 1 "text" "Copilot thread" >/dev/null 2>&1
mutant_rc=$?
set -e
assert_eq "$mutant_rc" "0" "reach control kills a writer whose refusal list never fires"

# --- usage/validation errors: all exit 2, nothing written ---
# Each --adds case takes its own round id: sharing one would let the
# immutable-record collision stand in for the path validation.
assert_exit2 "no --item exits 2 (an empty delegated set is not a fix round)" \
  --worktree "$worktree" --issue i --round-id 1-1
assert_exit2 "missing --worktree exits 2" --issue i --round-id 1-1 --item 1 t "$OK_REACH"
assert_exit2 "nonexistent --worktree exits 2" \
  --worktree "$TMP_ROOT/nope" --issue i --round-id 1-1 --item 1 t "$OK_REACH"
mkdir -p "$TMP_ROOT/no-head"
assert_exit2 "worktree with no HEAD commit exits 2" \
  --worktree "$TMP_ROOT/no-head" --issue i --round-id 1-1 --item 1 t "$OK_REACH"
assert_exit2 "missing --issue exits 2" --worktree "$worktree" --round-id 1-1 --item 1 t "$OK_REACH"
assert_exit2 "missing --round-id exits 2" --worktree "$worktree" --issue i --item 1 t "$OK_REACH"
assert_exit2 "path-unsafe --issue (slash) exits 2" \
  --worktree "$worktree" --issue "a/b" --round-id 1-1 --item 1 t "$OK_REACH"
assert_exit2 "path-traversal --round-id (..) exits 2" \
  --worktree "$worktree" --issue i --round-id ".." --item 1 t "$OK_REACH"
assert_exit2 "non-numeric --item N exits 2" \
  --worktree "$worktree" --issue i --round-id 1-1 --item x t "$OK_REACH"
assert_exit2 "leading-zero --item N exits 2 (not a canonical integer)" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 01 t "$OK_REACH"
assert_exit2 "empty --item TEXT exits 2" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 1 "" "$OK_REACH"
assert_exit2 "whitespace-only --item TEXT exits 2" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 1 "   " "$OK_REACH"
assert_exit2 "--item TEXT that is one of the writer's own flags exits 2 (forgotten value)" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 1 --worktree "$OK_REACH"
assert_exit2 "--item with too few arguments exits 2" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 1
assert_exit2 "duplicate item number exits 2 (a set, not a list)" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 1 a "$OK_REACH" --item 1 b "$OK_REACH"
assert_exit2 "duplicate --issue exits 2 (no silent last-wins)" \
  --worktree "$worktree" --issue i --issue j --round-id 1-1 --item 1 t "$OK_REACH"
assert_exit2 "unknown argument exits 2" \
  --worktree "$worktree" --issue i --round-id 1-1 --item 1 t "$OK_REACH" --bogus
# A real linked worktree keeps its record in its own tmp/, and the public
# checker catches suffix, substring, and dotfile helper names.
linked_main="$TMP_ROOT/linked-main"
linked_wt="$TMP_ROOT/linked-wt"
mkdir -p "$linked_main"
git -C "$linked_main" init -q -b main
git -C "$linked_main" config user.email test@example.com
git -C "$linked_main" config user.name Test
git -C "$linked_main" config commit.gpgsign false
git -C "$linked_main" commit -q --allow-empty -m base
git -C "$linked_main" worktree add -q -b linked "$linked_wt"
init_growth_state "$STATE" "$linked_wt" issue-826 seed 1000000
"$WRITE" --worktree "$linked_wt" --issue issue-826 --round-id 30-30 --item 1 linked "$OK_REACH" >/dev/null
linked_record="$linked_wt/tmp/dev-round-issue-826-30-30.json"
assert_eq "$([[ -f "$linked_record" && ! -e "$linked_main/.git/kendex" ]] && echo yes)" \
  "yes" "a linked worktree keeps its round record in its own tmp/"
mkdir -p "$linked_wt/existing" "$linked_wt/adversarial/name_test-helper_more" \
  "$linked_wt/adversarial/name_test_helper_more" "$linked_wt/adversarial/name_test-util_more" \
  "$linked_wt/adversarial/name_test_util_more" "$linked_wt/tests/unit/support" \
  "$linked_wt/__tests__/integration/utils"
printf 'helper\n' > "$linked_wt/existing/workflow_helpers.sh"
printf 'dot helper\n' > "$linked_wt/.workflow_helpers.sh"
printf 'suffix helper\n' > "$linked_wt/adversarial/prefixhelperSuffix.rs"
printf 'path substring\n' > "$linked_wt/adversarial/name_test-helper_more/file.rs"
printf 'path substring\n' > "$linked_wt/adversarial/name_test_helper_more/file.rs"
printf 'path substring\n' > "$linked_wt/adversarial/name_test-util_more/file.rs"
printf 'path substring\n' > "$linked_wt/adversarial/name_test_util_more/file.rs"
printf 'test helper\n' > "$linked_wt/tests/workflow_helpers.sh"
printf 'js test helper\n' > "$linked_wt/__tests__/workflow_helpers.sh"
printf 'nested support\n' > "$linked_wt/tests/unit/support/shared.rs"
printf 'nested utils\n' > "$linked_wt/__tests__/integration/utils/shared.ts"
git -C "$linked_wt" add existing/workflow_helpers.sh .workflow_helpers.sh \
  adversarial/prefixhelperSuffix.rs adversarial/name_test-helper_more/file.rs \
  adversarial/name_test_helper_more/file.rs adversarial/name_test-util_more/file.rs \
  adversarial/name_test_util_more/file.rs tests/workflow_helpers.sh __tests__/workflow_helpers.sh \
  tests/unit/support/shared.rs __tests__/integration/utils/shared.ts
git -C "$linked_wt" commit -q -m helpers
linked_head="$(git -C "$linked_wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$linked_wt" --kind fix --issue issue-826 --round-id 30-30 \
  --branch linked --commit "$linked_head" --validate pass --item 1 Applied done >/dev/null
set +e
linked_out="$("$CHECK" --worktree "$linked_wt" --issue issue-826 --round-id 30-30 --expect-items-from-round 2>/dev/null)"
linked_rc=$?
set -e
assert_eq "$linked_rc" "1" "linked worktree helper additions refuse acceptance"
assert_eq "$(jq -r '.reason' <<<"$linked_out")" "unapproved_additions" "public checker routes helper suffixes through the additions gate"
assert_eq "$(jq -c '.files' <<<"$linked_out")" \
  '["__tests__/integration/utils/shared.ts","__tests__/workflow_helpers.sh","adversarial/name_test-helper_more/file.rs","adversarial/name_test-util_more/file.rs","adversarial/name_test_helper_more/file.rs","adversarial/name_test_util_more/file.rs","tests/unit/support/shared.rs","tests/workflow_helpers.sh"]' \
  "public checker reports explicit substrings and test-context helper suffixes"

inert_classifier="$TMP_ROOT/inert-classifier"
cp "$CHECK" "$inert_classifier"
sed -i.bak '/^is_protected_addition()/,/^}/ s/return 0/return 1/' "$inert_classifier"
chmod +x "$inert_classifier"
set +e
inert_out="$("$inert_classifier" --worktree "$linked_wt" --issue issue-826 --round-id 30-30 --expect-items-from-round 2>/dev/null)"
inert_rc=$?
set -e
if [[ "$inert_rc" == "0" ]] && jq -e '
  .ok == true and .verdict == "accept" and .reason == "valid" and .files == []
' <<<"$inert_out" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "public checker control kills an inert classifier"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        rc=%s output=%s\n' \
    "public checker control kills an inert classifier" "$inert_rc" "$inert_out"
fi

failed_classifier="$TMP_ROOT/failed-classifier"
cp "$CHECK" "$failed_classifier"
sed -i.bak 's/\[\[ -s "\$result" \]\]/[[ ! -s "$result" ]]/' "$failed_classifier"
chmod +x "$failed_classifier"
set +e
failed_out="$("$failed_classifier" --worktree "$linked_wt" --issue issue-826 --round-id 30-30 --expect-items-from-round 2>/dev/null)"
failed_rc=$?
set -e
assert_eq "$failed_rc" "1" "invalid classifier output fails acceptance"
assert_eq "$(jq -r '.ok' <<<"$failed_out")" "false" "classifier failure reports ok false"
assert_eq "$(jq -r '.verdict' <<<"$failed_out")" "retry" "classifier failure routes to retry"
assert_eq "$(jq -r '.reason' <<<"$failed_out")" "classifier_failed" "classifier failure has a positive routing verdict"

"$WRITE" --worktree "$linked_wt" --issue issue-826 --round-id 32-32 --item 1 product "$OK_REACH" >/dev/null
mkdir -p "$linked_wt/docs" "$linked_wt/src"
printf 'docs helper\n' > "$linked_wt/docs/render_helpers.md"
printf 'capital helper\n' > "$linked_wt/src/ProductHelper.rs"
printf 'dotted helper\n' > "$linked_wt/src/render.helper.ts"
printf 'dotfile helper\n' > "$linked_wt/.workflow_helpers.md"
git -C "$linked_wt" add docs/render_helpers.md src/ProductHelper.rs src/render.helper.ts .workflow_helpers.md
git -C "$linked_wt" commit -q -m product-helpers
product_head="$(git -C "$linked_wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$linked_wt" --kind fix --issue issue-826 --round-id 32-32 \
  --branch linked --commit "$product_head" --validate pass --item 1 Applied done >/dev/null
product_out="$("$CHECK" --worktree "$linked_wt" --issue issue-826 --round-id 32-32 --expect-items-from-round)"
assert_eq "$(jq -r '.reason' <<<"$product_out")" "valid" \
  "product and documentation helper basenames remain outside the protected scope"

# --- the writer refuses to place a record over a symlink -----------------
# The writer half only: dev_round_gate.sh owns the reader's symlink refusal,
# and this is the writer's suite.
"$WRITE" --worktree "$linked_wt" --issue issue-826 --round-id 31-31 --item 1 symlink "$OK_REACH" >/dev/null
symlink_record="$linked_wt/tmp/dev-round-issue-826-31-31.json"
cp "$symlink_record" "$TMP_ROOT/symlink-target.json"
rm -f "$symlink_record"
ln -s "$TMP_ROOT/symlink-target.json" "$symlink_record"
set +e
"$WRITE" --worktree "$linked_wt" --issue issue-826 --round-id 31-31 --item 1 symlink "$OK_REACH" >/dev/null 2>&1
assert_eq "$?" "2" "the writer refuses to place a record over a symlink"
set -e
rm -f "$symlink_record"

# --- the live workflow blocks own the additions transport ----------------
# Live workflow blocks own the additions-file transport. Prose and commented
# decoys outside those blocks cannot satisfy these controls.
for workflow in dev-fix review-pr-comments; do
  workflow_file="$REPO_ROOT/skills/orch/workflows/$workflow.md"
  round_block="$(fenced_block_with "$workflow_file" "dev-round-write --worktree")"
  delegation="$(delegation_block "$workflow_file" "Adds: [REPO_RELATIVE_PATHS]")"
  assert_text_matches "$round_block" '^[[:space:]]*\.agents/.+dev-round-write .+--adds "' "$workflow live command passes the additions path list"
  assert_text_not_matches "$round_block" '(^|[[:space:]])--adds-[a-z]+([[:space:]]|$)' "$workflow live command carries no additions data-file flag"
  assert_text_matches "$delegation" '^[[:space:]]*\[If the round may add files: "Adds: \[REPO_RELATIVE_PATHS\]' "$workflow live delegation carries the Adds path list"
  workflow_text="$(<"$workflow_file")"
done

disposition_text="$(<"$REPO_ROOT/skills/orch/references/finding-disposition.md")"

scope_docs=(
  "$REPO_ROOT/skills/dev/workflows/dev-fix.md"
  "$REPO_ROOT/skills/orch/workflows/dev-fix.md"
  "$REPO_ROOT/skills/orch/workflows/review-pr-comments.md"
  "$WRITE_BIN"
  "$CHECK"
)
for scope_doc in "${scope_docs[@]}"; do
  scope_text="$(<"$scope_doc")"
  assert_text_matches "$scope_text" '^[[:space:]]*[^<[:space:]].*schemas/dev-round\.md.*Protected additions' \
    "$(basename "$scope_doc") points at the canonical protected-additions scope"
  assert_text_not_matches "$scope_text" 'Protected additions are|files? (the )?fix round may add|files? this round may add|Omit it to allow none|none allowed|files the orchestrator authorized.*add' \
    "$(basename "$scope_doc") makes no repository-wide additions claim"
done

scope_mutant="$TMP_ROOT/scope-comment-mutant.md"
cp "$REPO_ROOT/skills/orch/workflows/dev-fix.md" "$scope_mutant"
sed -i.bak '/schemas\/dev-round.md.*Protected additions/ s/^/<!-- /; /<!-- .*Protected additions/ s/$/ -->/' "$scope_mutant"
scope_mutant_text="$(<"$scope_mutant")"
assert_text_not_matches "$scope_mutant_text" '^[[:space:]]*[^<[:space:]].*schemas/dev-round\.md.*Protected additions' \
  "scope reference control rejects an HTML-comment decoy"

ADDS_PATHS="tools/future-helper.sh skills/x/scripts/future-check"
workflow_rid=40
for workflow in dev-fix review-pr-comments; do
  round_token="$workflow_rid-$workflow_rid"
  printf '%s' '[{"n":1,"text":"workflow item","reach":"tools/guard on a staged render"}]' > "$linked_wt/tmp/dev-round-items-$round_token.json"
  run_workflow_round_command "$REPO_ROOT/skills/orch/workflows/$workflow.md" \
    "$linked_wt" issue-826 "$round_token" >/dev/null
  workflow_record="$linked_wt/tmp/dev-round-issue-826-$round_token.json"
  assert_eq "$(jq -c '.adds' "$workflow_record")" '["tools/future-helper.sh","skills/x/scripts/future-check"]' \
    "$workflow live command executes and binds its Adds path list"
  workflow_rid=$((workflow_rid + 1))
done

command_mutant="$TMP_ROOT/dev-fix-command-mutant.md"
cp "$REPO_ROOT/skills/orch/workflows/dev-fix.md" "$command_mutant"
sed -i.bak '/dev-round-write --worktree/ s/^[[:space:]]*/# /' "$command_mutant"
printf '\n--adds "tools/decoy" outside the command block\n' >> "$command_mutant"
mutant_round_block="$(fenced_block_with "$command_mutant" "dev-round-write --worktree")"
assert_text_not_matches "$mutant_round_block" '^[[:space:]]*\.agents/.+dev-round-write .+--adds "' "workflow control rejects a commented live command plus prose decoy"

delegation_mutant="$TMP_ROOT/dev-fix-delegation-mutant.md"
cp "$REPO_ROOT/skills/orch/workflows/dev-fix.md" "$delegation_mutant"
sed -i.bak '/^   \[If the round may add files: "Adds:/ s/^/   <!-- /; /^   <!-- .*Adds:/ s/$/ -->/' "$delegation_mutant"
printf '\nAdds: [REPO_RELATIVE_PATHS] prose decoy\n' >> "$delegation_mutant"
mutant_delegation="$(delegation_block "$delegation_mutant" "Adds: [REPO_RELATIVE_PATHS]")"
assert_text_not_matches "$mutant_delegation" '^[[:space:]]*\[If the round may add files: "Adds: \[REPO_RELATIVE_PATHS\]' "workflow control rejects an inert delegation line plus prose decoy"

inert_workflow="$TMP_ROOT/inert-workflow.md"
cp "$REPO_ROOT/skills/orch/workflows/dev-fix.md" "$inert_workflow"
sed -i.bak '/dev-round-write --worktree/ s|^[[:space:]]*\.agents|true # .agents|' "$inert_workflow"
printf '%s' '[{"n":1,"text":"inert workflow","reach":"tools/guard on a staged render"}]' > "$linked_wt/tmp/dev-round-items-42-42.json"
run_workflow_round_command "$inert_workflow" "$linked_wt" issue-826 42-42 >/dev/null
inert_record="$linked_wt/tmp/dev-round-issue-826-42-42.json"
assert_eq "$([[ -e "$inert_record" ]] && echo yes || echo no)" "no" \
  "executable workflow control kills a satisfied-but-inert command"

if grep -Fq '< <(' "$CHECK" || grep -Fq '$!' "$CHECK"; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "Git probe avoids process-substitution PID behavior"
else
  PASS=$((PASS + 1)); printf '  ok    %s\n' "Git probe avoids process-substitution PID behavior"
fi
# --- round-mode waiting leaves no scratch behind -------------------------
# Round-mode waiting runs validate_artifact in command substitutions. Each
# invocation owns and removes its probe files before returning to the parent.
wait_round="$TMP_ROOT/wait-round"
mkdir -p "$wait_round"
git -C "$wait_round" init -q -b main
git -C "$wait_round" config user.email test@example.com
git -C "$wait_round" config user.name Test
git -C "$wait_round" config commit.gpgsign false
git -C "$wait_round" commit -q --allow-empty -m base
init_growth_state "$STATE" "$wait_round" issue-826 seed 1000000
wait_head="$(git -C "$wait_round" rev-parse HEAD)"
"$WRITE" --worktree "$wait_round" --issue issue-826 --round-id 21-21 --item 1 wait "$OK_REACH" >/dev/null
( sleep 2; "$RETURN_WRITE" --worktree "$wait_round" --kind fix --issue issue-826 --round-id 21-21 \
    --branch main --commit "$wait_head" --validate pass --item 1 Applied done >/dev/null ) &
writer_pid=$!
wait_out="$("$CHECK" --worktree "$wait_round" --issue issue-826 --round-id 21-21 \
  --expect-items-from-round --wait 20 --interval 1 2>/dev/null)"
wait "$writer_pid"
assert_eq "$(jq -r '.verdict' <<<"$wait_out")" "accept" "round-mode wait accepts the landed artifact"
scratch_count="$(find "$wait_round/tmp" -maxdepth 1 -name '.dev-artifact-*' | wc -l | tr -d ' ')"
assert_eq "$scratch_count" "0" "round-mode wait leaves no dev-artifact scratch files"

set +e
"$WRITE" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h prints usage and exits 0"
set -e

# a failed invocation must not leave a partial record behind
bad="$worktree/tmp/dev-round-i-1-1.json"
assert_eq "$([[ -f "$bad" ]] && echo yes || echo no)" "no" "failed invocations write nothing"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
