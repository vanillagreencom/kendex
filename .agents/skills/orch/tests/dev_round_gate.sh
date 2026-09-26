#!/usr/bin/env bash
# Tests for the one thing that authorizes a fix round: the round
# record dev-round-write stamps at delegation time. dev-artifact-check reads it
# for both the delegated item set and the protected additions the round may
# make, so anything that lets a check run WITHOUT that record, or lets a record
# reach the additions probe carrying a base_sha or an adds path the reader's
# own rules forbid, is a bypass of the whole gate rather than one weak
# assertion.
#
# Each case here pairs a control that must pass with a mutation of exactly one
# input that must refuse, so a refusal cannot be credited to the wrong arm.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
ROUND_WRITE=round_write
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
# The mode a fix round runs is read from the project's settings, and orch-env
# reads the process environment first: a developer's own range command would
# otherwise decide the fix receipts' acceptance.
unset DEV_VALIDATE_RANGE_CMD
VRUN="$(validate_run_dir "$TMP_ROOT/validate-run" full)"
mkdir -p "$TMP_ROOT/linear/scripts" "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
jq -r --arg id "issue-$3" '.[] | select(.identifier == $id) | .description' .cache/linear/issues.json
SH
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"
LIVE_SCRIPTS="$(copy_scripts live)"
CHECK="$LIVE_SCRIPTS/dev-artifact-check"
ROUND_WRITE_BIN="$LIVE_SCRIPTS/dev-round-write"
RETURN_WRITE="$LIVE_SCRIPTS/dev-return-write"

write_allowance() {
  local repo="$1" issue="$2" line="$3"
  mkdir -p "$repo/.cache/linear"
  jq -n --arg id "$issue" --arg body "$line" \
    '[{identifier: $id, description: $body}]' > "$repo/.cache/linear/issues.json"
  printf '.cache/\n' >> "$(git -C "$repo" rev-parse --path-format=absolute --git-path info/exclude)"
}

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

round_write() {
  growth_round_write "$STATE" "$ROUND_WRITE_BIN" "$@"
}

reason() {
  "$CHECK" "$@" 2>/dev/null | jq -r '.reason'
}

echo "=== dev round gate ==="

wt="$TMP_ROOT/wt"
mkdir -p "$wt"
git -C "$wt" init -q -b main
git -C "$wt" config user.email test@example.com
git -C "$wt" config user.name Test
git -C "$wt" config commit.gpgsign false
git -C "$wt" commit -q --allow-empty -m base
init_growth_state "$STATE" "$wt" issue-826 seed 1000000
write_allowance "$wt" issue-826 '**Expected delta**: 1000000 lines, 1000000 test lines'

# A round whose diff adds a protected file it was never authorized to add. Every
# case below asks whether some other spelling of the check lets it through.
"$ROUND_WRITE" --worktree "$wt" --issue issue-826 --round-id 1-1 --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
mkdir -p "$wt/tools"
printf 'sneaky\n' > "$wt/tools/sneaky-check"
git -C "$wt" add tools/sneaky-check
git -C "$wt" commit -q -m sneaky
head_sha="$(git -C "$wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$wt" --kind fix --issue issue-826 --round-id 1-1 --branch b \
  --commit "$head_sha" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-wt-1-1-1" "$wt" issue-826 1-1)" --item 1 Applied done >/dev/null

assert_eq "$(reason --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round)" \
  "unapproved_additions" "control: the bound check refuses the unlisted addition"

# --- omitting the flag is not a way past the gate ---------------------------
# Without --expect-items-from-round there is no delegated set and no authorized
# additions list, so validate_artifact would fall back to the weak
# non-empty-items rule and never run the additions probe at all.
set +e
flagless_out="$("$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 2>/dev/null)"
flagless_rc=$?
set -e
assert_eq "$flagless_rc" "2" "a flagless fix receipt over an unlisted addition refuses with exit 2"
assert_eq "$([[ -z "$flagless_out" ]] && echo silent || jq -r '.ok' <<<"$flagless_out")" "silent" \
  "the flagless refusal reports no verdict at all, never ok=true"

# An implement round writes no round record, so it stays flagless.
"$RETURN_WRITE" --worktree "$wt" --kind implement --issue issue-826 --round-id 2-2 --branch b \
  --commit "$head_sha" --validate pass --validate-run-dir "$VRUN" >/dev/null
assert_eq "$(env ORCH_STATE_DIR="$wt/tmp" "$CHECK" --worktree "$wt" --issue issue-826 \
  --round-id 2-2 | jq -r '.reason')" "valid" \
  "a flagless implement receipt is unaffected by the fix-round requirement"

# --- the record's base_sha is a git revision, not a free string -------------
# It reaches `git diff` as an argument. A value git parses as an OPTION never
# reaches revision parsing: git exits 0 over an empty probe, the additions list
# comes back empty, and the gate reports valid over a round that adds anything
# it likes. A `--` separator cannot stand in for the grammar: git does stop
# option parsing there, but everything after it is a pathspec, so the revision
# pair could not be passed at all.
record="$wt/tmp/dev-round-issue-826-1-1.json"
cp "$record" "$TMP_ROOT/record-honest.json"
for bad_base in "--output=$TMP_ROOT/sink" "HEAD" "0123456789abcdef0123456789abcdef0123456Z" ""; do
  jq --arg base "$bad_base" '.base_sha = $base' "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/bad.json"
  cp "$TMP_ROOT/bad.json" "$record"
  set +e
  "$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round >/dev/null 2>&1
  bad_rc=$?
  set -e
  assert_eq "$bad_rc" "2" "a base_sha outside 40 hex ('$bad_base') refuses before the additions probe"
done
assert_eq "$([[ -e "$TMP_ROOT/sink" ]] && echo wrote || echo no)" "no" \
  "the refused base_sha never reached git as an option"
cp "$TMP_ROOT/record-honest.json" "$record"
assert_eq "$(reason --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round)" \
  "unapproved_additions" "restoring the honest base_sha restores the refusal"

# 40 hex naming no object answers no to every git question, "is it an ancestor
# of HEAD" included — which is the orphaned-base stop, where the gate does not
# run. A base this repository cannot answer for is a failed comparison.
jq --arg base "0123456789abcdef0123456789abcdef01234567" '.base_sha = $base' \
  "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/ghost.json"
cp "$TMP_ROOT/ghost.json" "$record"
assert_eq "$(reason --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round)" \
  "comparison_failed" "a base_sha naming no object refuses rather than skipping the gate"
cp "$TMP_ROOT/record-honest.json" "$record"

# A trailing newline is the same anchoring in the opposite direction:
# Oniguruma's `$` matches before a string-final newline, so an unanchored form
# accepts a path the writer cannot produce. `$'...'` holds the newline that a
# command substitution would strip.
jq --arg add $'tools/a\n' '.adds = [$add]' "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/adds.json"
cp "$TMP_ROOT/adds.json" "$record"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a record whose adds path ends in a newline fails closed"
set -e

# The same anchoring on base_sha: 40 hex plus a trailing newline.
jq --arg base $'0123456789abcdef0123456789abcdef01234567\n' '.base_sha = $base' \
  "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/base.json"
cp "$TMP_ROOT/base.json" "$record"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a base_sha of 40 hex plus a trailing newline fails closed"
set -e
cp "$TMP_ROOT/record-honest.json" "$record"

# --- the record must be a regular file at its own path ----------------------
# Only the symlink changes between the two halves: same bytes, same token, same
# schema. A refusal here can come from nothing but the symlink.
"$ROUND_WRITE" --worktree "$wt" --issue issue-826 --round-id 4-4 --item 1 "later round" "tools/guard on a staged render" >/dev/null
linked_record="$wt/tmp/dev-round-issue-826-4-4.json"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 4-4 --expect-items-from-round >/dev/null 2>&1
control_rc=$?
set -e
assert_eq "$([[ "$control_rc" == "2" ]] && echo refused || echo read)" "read" \
  "control: the same record as a regular file passes the record gates"
cp "$linked_record" "$TMP_ROOT/link-target.json"
rm -f "$linked_record"
ln -s "$TMP_ROOT/link-target.json" "$linked_record"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 4-4 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a symlinked round record fails closed"
set -e

# --- A chosen cut uses its recorded comparison ----------------------------
cut_wt="$TMP_ROOT/cut-wt"
mkdir -p "$cut_wt"
git -C "$cut_wt" init -q -b main
git -C "$cut_wt" config user.email test@example.com
git -C "$cut_wt" config user.name Test
git -C "$cut_wt" config commit.gpgsign false
git -C "$cut_wt" commit -q --allow-empty -m base
git -C "$cut_wt" switch -q -c cut
printf 'one\ntwo\n' > "$cut_wt/change.txt"
git -C "$cut_wt" add change.txt
git -C "$cut_wt" commit -q -m implementation
# The branch grows past its issue allowance.
init_growth_state "$STATE" "$cut_wt" issue-1165 1-1 1
write_allowance "$cut_wt" issue-1165 '**Expected delta**: 4 lines, 2 test lines'
printf 'three\nfour\nfive\n' >> "$cut_wt/change.txt"
git -C "$cut_wt" add change.txt
git -C "$cut_wt" commit -q -m over-limit

cut_reason() {
  env ORCH_STATE_DIR="$cut_wt/tmp" "$CHECK" "$@" 2>/dev/null | jq -r '.reason'
}

for row in 'over|**Expected delta**: 4 lines, 2 test lines|0|over' \
  'unsized|No allowance.|0|allowance_missing' 'malformed|**Expected delta**: about 4 lines|3|'; do
  IFS='|' read -r label line want_rc verdict <<<"$row"
  write_allowance "$cut_wt" issue-1165 "$line"
  round_rc=0
  "$ROUND_WRITE" --worktree "$cut_wt" --issue issue-1165 --round-id "$label" \
    --item 1 "fix the branch" "the branch this round shrinks" >/dev/null 2>&1 || round_rc=$?
  assert_eq "$round_rc" "$want_rc" "$label round reports size or malformed text"
  [[ "$want_rc" != 0 ]] || assert_eq \
    "$(jq -r '[.size_check.verdict, .size_check.production_lines, .size_check.test_lines] | join(",")' "$cut_wt/tmp/dev-round-issue-1165-$label.json")" \
    "$verdict,5,0" "$label round records its verdict and counts"
done
write_allowance "$cut_wt" issue-1165 '**Expected delta**: 4 lines, 2 test lines'
"$ROUND_WRITE" --worktree "$cut_wt" --issue issue-1165 --round-id 1-1 --cut \
  --item 1 "cut the branch back to the Done-when" "the branch this round shrinks" >/dev/null
assert_eq "$(jq -r '.cut' "$cut_wt/tmp/dev-round-issue-1165-1-1.json")" "true" \
  "the declared cut is recorded, so its item set is still checked at acceptance"

# The cut lands: the branch comes back under the cap and the receipt is accepted.
printf 'one\ntwo\n' > "$cut_wt/change.txt"
git -C "$cut_wt" add change.txt
git -C "$cut_wt" commit -q -m cut
cut_head="$(git -C "$cut_wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$cut_wt" --kind fix --issue issue-1165 --round-id 1-1 --branch cut \
  --commit "$cut_head" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-cutwt-1-1-2" "$cut_wt" issue-1165 1-1)" --item 1 Applied "cut to the Done-when" >/dev/null
assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id 1-1 --expect-items-from-round)" \
  "valid" "a cut that brought the branch back to the cap is accepted"

# Must-fail: the same declaration over a round that grew the branch instead.
# Only the round's effect on the branch differs from the arm above.
"$ROUND_WRITE" --worktree "$cut_wt" --issue issue-1165 --round-id 2-2 --cut \
  --item 1 "cut the branch back to the Done-when" "the branch this round shrinks" >/dev/null
printf 'three\nfour\nfive\nsix\n' >> "$cut_wt/change.txt"
git -C "$cut_wt" add change.txt
git -C "$cut_wt" commit -q -m grew
grew_head="$(git -C "$cut_wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$cut_wt" --kind fix --issue issue-1165 --round-id 2-2 --branch cut \
  --commit "$grew_head" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-cutwt-2-2-3" "$cut_wt" issue-1165 2-2)" --item 1 Applied "cut to the Done-when" >/dev/null
assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id 2-2 --expect-items-from-round)" \
  "cut_not_shrunk" "a round declared a cut that grew the branch is refused"

# Tracker edits cannot change an already delegated cut's comparison.
for line in 'No allowance.' '**Expected delta**: 100 lines' '**Expected delta**: about 4 lines'; do
  write_allowance "$cut_wt" issue-1165 "$line"
  assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id 2-2 --expect-items-from-round)" \
    "cut_not_shrunk" "the recorded cut comparison survives: $line"
done

MUTANT_SCRIPTS="$(copy_scripts cut-comparison-mutant)"
MUTANT_LIB="$MUTANT_SCRIPTS/lib/branch-growth.sh"
assert_eq "$(grep -Fc 'cut_args=(--cut-from-round "$4")' "$MUTANT_LIB")" "1" "control finds the recorded comparison"
sed -i.bak 's/cut_args=(--cut-from-round "$4")/cut_args=()/' "$MUTANT_LIB"
assert_eq "$([[ ! -L "$MUTANT_LIB" ]] && ! cmp -s "$MUTANT_LIB" "$LIVE_SCRIPTS/lib/branch-growth.sh" && echo changed)" "changed" "control changes the private comparison"
write_allowance "$cut_wt" issue-1165 '**Expected delta**: 100 lines'
LIVE_CHECK="$CHECK"
CHECK="$MUTANT_SCRIPTS/dev-artifact-check"
assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id 2-2 --expect-items-from-round)" \
  "valid" "control: reading the edited allowance accepts the unfinished cut"
CHECK="$LIVE_CHECK"

write_allowance "$cut_wt" issue-1165 'No allowance.'
"$ROUND_WRITE" --worktree "$cut_wt" --issue issue-1165 --round-id 3-3 --cut \
  --item 1 "cut the branch back to the Done-when" "the branch this round shrinks" >/dev/null
assert_eq "$(jq -r '[.size_check.verdict, .size_check.production_lines] | join(",")' "$cut_wt/tmp/dev-round-issue-1165-3-3.json")" \
  "allowance_missing,6" "an unsized cut records its starting count"
printf 'one\ntwo\n' > "$cut_wt/change.txt"
git -C "$cut_wt" add change.txt
git -C "$cut_wt" commit -q -m unsized-cut
cut_head="$(git -C "$cut_wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$cut_wt" --kind fix --issue issue-1165 --round-id 3-3 --branch cut \
  --commit "$cut_head" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-cutwt-3-3-4" "$cut_wt" issue-1165 3-3)" --item 1 Applied "cut to the Done-when" >/dev/null
assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id 3-3 --expect-items-from-round)" \
  "valid" "an unsized cut can finish below its recorded counts"
assert_eq "$("$STATE" --state-dir "$cut_wt/tmp" get issue-1165 '.pr.size_check.verdict, .pr.size_check.production_allowance, .pr.size_check.test_allowance' | paste -sd, -)" \
  "allowance_missing,null,null" "cut acceptance keeps the unsized PR report without invented allowances"

STATE_SCRIPTS="$(copy_scripts cut-state-mutant)"
STATE_CHECKER="$STATE_SCRIPTS/branch-size-check"
assert_eq "$(grep -Fc 'if [[ -z "$cut_from_round" ]]; then' "$STATE_CHECKER")" "1" "control finds the report write guard"
sed -i.bak 's/if \[\[ -z "$cut_from_round" \]\]; then/if :; then # [[ -z "$cut_from_round" ]]/' "$STATE_CHECKER"
assert_eq "$([[ ! -L "$STATE_CHECKER" ]] && ! cmp -s "$STATE_CHECKER" "$LIVE_SCRIPTS/branch-size-check" && echo changed)" "changed" "control changes the private report writer"
CHECK="$STATE_SCRIPTS/dev-artifact-check"
assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id 3-3 --expect-items-from-round)" \
  "valid" "control: the cut still succeeds when its comparison overwrites state"
assert_eq "$("$STATE" --state-dir "$cut_wt/tmp" get issue-1165 '.pr.size_check.verdict, .pr.size_check.production_allowance, .pr.size_check.test_allowance' | paste -sd, -)" \
  "pass,6,0" "control: the state write invents allowances for the unsized report"
CHECK="$LIVE_CHECK"
mkdir -p "$cut_wt/tests"
printf 'test\n' > "$cut_wt/tests/new.sh"
git -C "$cut_wt" add tests/new.sh
git -C "$cut_wt" commit -q -m test-growth
cut_head="$(git -C "$cut_wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$cut_wt" --kind fix --issue issue-1165 --round-id 3-3 --branch cut \
  --commit "$cut_head" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-cutwt-3-3-5" "$cut_wt" issue-1165 3-3)" --item 1 Applied "cut to the Done-when" >/dev/null
assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id 3-3 --expect-items-from-round)" \
  "cut_not_shrunk" "an unsized cut cannot grow tests above their recorded count"
unsized_record="$cut_wt/tmp/dev-round-issue-1165-3-3.json"

"$ROUND_WRITE" --worktree "$cut_wt" --issue issue-1165 --round-id retry \
  --cut-from-round "$unsized_record" --item 1 "finish the cut" "the branch this round shrinks" >/dev/null
retry_record="$cut_wt/tmp/dev-round-issue-1165-retry.json"
assert_eq "$(jq -r '[.size_check.verdict, .size_check.production_lines, .size_check.test_lines, .cut_comparison.production_allowance, .cut_comparison.test_allowance] | join(",")' "$retry_record")" \
  "allowance_missing,2,1,6,0" "a cut retry records current counts and preserves the earlier comparison"
"$RETURN_WRITE" --worktree "$cut_wt" --kind fix --issue issue-1165 --round-id retry --branch cut \
  --commit "$cut_head" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-cutwt-retry-6" "$cut_wt" issue-1165 retry)" --item 1 Applied "cut to the Done-when" >/dev/null
assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id retry --expect-items-from-round)" \
  "cut_not_shrunk" "a fresh cut retry cannot accept the same uncut growth"

RETRY_SCRIPTS="$(copy_scripts cut-retry-mutant)"
RETRY_WRITER="$RETRY_SCRIPTS/dev-round-write"
assert_eq "$(grep -Fc '  cut_comparison="$BRANCH_ALLOWANCE_RECORD"' "$RETRY_WRITER")" "1" "control finds the preserved cut comparison"
sed -i.bak 's/  cut_comparison="$BRANCH_ALLOWANCE_RECORD"/  cut_comparison="$size_check" # $BRANCH_ALLOWANCE_RECORD/' "$RETRY_WRITER"
assert_eq "$([[ ! -L "$RETRY_WRITER" ]] && ! cmp -s "$RETRY_WRITER" "$LIVE_SCRIPTS/dev-round-write" && echo changed)" "changed" "control changes the private retry writer"
ROUND_WRITE_BIN="$RETRY_WRITER"
"$ROUND_WRITE" --worktree "$cut_wt" --issue issue-1165 --round-id retry-mutant \
  --cut-from-round "$unsized_record" --item 1 "finish the cut" "the branch this round shrinks" >/dev/null
ROUND_WRITE_BIN="$LIVE_SCRIPTS/dev-round-write"
"$RETURN_WRITE" --worktree "$cut_wt" --kind fix --issue issue-1165 --round-id retry-mutant --branch cut \
  --commit "$cut_head" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-cutwt-retry-mutant-7" "$cut_wt" issue-1165 retry-mutant)" --item 1 Applied "cut to the Done-when" >/dev/null
assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id retry-mutant --expect-items-from-round)" \
  "valid" "control: resetting the comparison accepts the unchanged growth"

jq 'del(.cut_comparison)' "$unsized_record" > "$TMP_ROOT/cut-unmeasurable.json"
cp "$TMP_ROOT/cut-unmeasurable.json" "$unsized_record"
assert_eq "$(cut_reason --worktree "$cut_wt" --issue issue-1165 --round-id 3-3 --expect-items-from-round)" \
  "cut_unmeasurable" "a cut without its recorded comparison fails closed"
retry_rc=0
"$ROUND_WRITE" --worktree "$cut_wt" --issue issue-1165 --round-id retry-unmeasurable \
  --cut-from-round "$unsized_record" --item 1 "finish the cut" "the branch this round shrinks" >/dev/null 2>&1 || retry_rc=$?
assert_eq "$retry_rc" "2" "a cut retry without its recorded comparison fails closed"

# Must-fail: the record's cut is a boolean, and a hand-edited string is not it.
# Only the field's type differs from the arm above — same token, same items,
# same base_sha — so a refusal here can come from nothing else.
cut_record="$cut_wt/tmp/dev-round-issue-1165-2-2.json"
jq '.cut = "true"' "$cut_record" > "$TMP_ROOT/cut-string.json"
cp "$TMP_ROOT/cut-string.json" "$cut_record"
set +e
env ORCH_STATE_DIR="$cut_wt/tmp" "$CHECK" --worktree "$cut_wt" --issue issue-1165 \
  --round-id 2-2 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a round record whose cut is a non-boolean fails closed"
set -e

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
