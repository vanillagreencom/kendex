#!/usr/bin/env bash
# Regression tests for branch-size-check, the submit-time size check that
# measures a branch's added lines against the allowance its issue states:
# the classification of every added line, the one allowance grammar, the
# binding of the record to base and head, and both refusals with a must-fail
# control each.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK_BIN="$REPO_ROOT/skills/orch/scripts/branch-size-check"
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

WT="$TMP_ROOT/wt"
mkdir -p "$WT"
git -C "$WT" init -q -b main
git -C "$WT" config user.email test@example.com
git -C "$WT" config user.name Test
git -C "$WT" config commit.gpgsign false
# Rename detection off in the fixture: the check passes --find-renames itself,
# and a control run under a runner that already enables it proves nothing.
git -C "$WT" config diff.renames false
# On the base branch, so a move of them on the branch is a rename in the
# comparison the check makes, and a rewrite of them has deletions to ignore.
mkdir -p "$WT/src" "$WT/tests"
seq 1 120 > "$WT/src/legacy.txt"
seq 1 30 > "$WT/tests/legacy.sh"
seq 1 50 > "$WT/src/rewritten.txt"
git -C "$WT" add -A
git -C "$WT" commit -q -m base
git -C "$WT" switch -q -c size

# The Linear cache the check reads through the linear CLI, which needs a
# meta.json beside the rows before it will answer at all.
write_issue() {
  mkdir -p "$WT/.cache/linear"
  jq -n --arg body "$1" '[{identifier: "KEN-SIZE", description: $body}]' \
    > "$WT/.cache/linear/issues.json"
  jq -n '{synced_at: "2026-09-02T00:00:00Z"}' > "$WT/.cache/linear/meta.json"
}

mk() { mkdir -p "$(dirname "$WT/$2")"; seq 1 "$1" > "$WT/$2"; }
commit_files() { git -C "$WT" add -A; git -C "$WT" commit -q -m "$1"; }

# The one setting the check reads is pinned here: a value exported by whoever
# runs the suite would otherwise decide its assertions.
run_check() {
  env -u ORCH_SIZE_RENDER_ROOTS ORCH_STATE_DIR="$WT/tmp" "$@" --worktree "$WT" --issue KEN-SIZE
}
# Every capture is guarded: a bare command substitution under errexit ends the
# suite at that line, with no tally and every later assertion unrun.
capture() { local __v="$1"; shift; set +e; printf -v "$__v" '%s' "$("$@" 2>/dev/null)"; set -e; }
rc_of() { local __v="$1"; shift; set +e; "$@" >/dev/null 2>&1; printf -v "$__v" '%s' "$?"; set -e; }
# copy_scripts copies scripts/ alone, so a mutant resolves its sibling skills
# one level above the copy. Without this every mutant dies reading the issue,
# and a control whose mutant never runs credits a pass to nothing.
mutant_scripts() {
  mkdir -p "$TMP_ROOT/linear"
  [[ -e "$TMP_ROOT/linear/scripts" ]] \
    || ln -s "$REPO_ROOT/skills/linear/scripts" "$TMP_ROOT/linear/scripts"
  copy_scripts "$1"
}

# --- Every classification rule, one file per rule, additions alone ----------
write_issue "**Expected delta**: 40 lines, 20 test lines"
init_growth_state "$STATE" "$WT" KEN-SIZE 1-1 12
printf '.cache/\n' >> "$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)"
mk 10 src/impl.txt                  # production
mk 4  src/testing.rs                # production: a name containing 'test' is not a test
mk 2  crates/core/src/tests.rs      # test by basename only
mk 3  crates/core/src/test_util.rs  # test by basename only
mk 4  tests/plain.sh                # test by directory only
mk 5  ui/src/thing.test.ts          # test by .test. infix only
printf 'x\ny\n' > "$WT/src/rewritten.txt"   # 50 deleted, 2 added: bills 2
commit_files implementation

capture split_json run_check "$CHECK_BIN" --json
assert_eq "$(jq -r '.production_lines, .test_lines' <<<"$split_json" | paste -sd,)" "16,14" \
  "each is_test rule classifies alone, a name containing 'test' does not, and a rewrite bills only its additions"
assert_eq "$(jq -r '.production_allowance, .test_allowance, .verdict' <<<"$split_json" | paste -sd,)" \
  "40,20,pass" "the stated line is the production and test allowance"
assert_eq "$(jq -r '.base_sha, .head_sha' <<<"$split_json" | paste -sd,)" \
  "$(git -C "$WT" rev-parse main HEAD | paste -sd,)" \
  "the record is bound to the base and head it measured"
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-SIZE '.pr.size_check.verdict')" "pass" \
  "the verdict is recorded beside pr.baseline_lines, in no new state file"

# --- A render pairs with the source it renders, and only with that source ---
mk 6 skills/orch/SKILL.md
mk 6 .agents/skills/orch/SKILL.md          # same path under the render root
mk 3 agents/gen.md
mk 3 .codex/agents/gen.toml                # same stem, different extension
mk 2 hooks/h.sh
mk 2 .pi/kendex/hooks/h.sh                 # nested render root
mk 9 .claude/settings.json                 # renders nothing this diff changed
mk 2 ui/src/stores/settings.ts             # same basename, not its source
mk 2 README.md                             # a root source has no directory to pair on
mk 7 .agents/skills/other/README.md        # so this same-basename render is counted
commit_files renders
capture mirror_json run_check "$CHECK_BIN" --json
assert_eq "$(jq -r '.mirror_lines' <<<"$mirror_json")" "11" \
  "a render pairs with its own source across a changed extension and a nested root, never by basename alone"
assert_eq "$(jq -r '.production_lines' <<<"$mirror_json")" "47" \
  "a render whose source did not change stays in production beside a same-basename source"

PAIR_SCRIPTS="$(mutant_scripts pairing-mutant)"
PAIR_LIB="$PAIR_SCRIPTS/lib/branch-growth.sh"
assert_eq "$(grep -Fc 'if (rest_stem == s) return 1' "$PAIR_LIB")" "1" \
  "pairing control finds exactly one live match"
sed -i.bak 's/^      rest_stem = stem_path(rest)$/      rest_stem = stem_path(rest); return 1/' "$PAIR_LIB"
capture pair_mutant_json run_check "$PAIR_SCRIPTS/branch-size-check" --json
assert_eq "$(jq -r '.mirror_lines' <<<"$pair_mutant_json")" "27" \
  "must-fail control: without the pairing every render-root path drops out"

# --- A move a size ratchet forced is a rename, not growth -------------------
git -C "$WT" mv src/legacy.txt src/relocated.txt
git -C "$WT" mv tests/legacy.sh src/moved-out.sh
printf 'a\nb\nc\n' >> "$WT/src/moved-out.sh"
commit_files ratchet-move
capture rename_json run_check "$CHECK_BIN" --json
assert_eq "$(jq -r '.production_lines' <<<"$rename_json")" "50" \
  "a pure rename bills no lines, and an edited move bills only its additions"
assert_eq "$(jq -r '.test_lines' <<<"$rename_json")" "14" \
  "a move out of a test directory is classified by the path it landed on"

# --- The one allowance grammar, and what falls outside it -------------------
# Row: the header line as the issue states it | allowance,test allowance,verdict | exit
while IFS='|' read -r line want_fields want_rc; do
  write_issue "$line"
  set +e
  row_json="$(run_check "$CHECK_BIN" --json 2>/dev/null)"
  row_rc=$?
  set -e
  assert_eq "$row_rc" "$want_rc" "exit for: $line"
  [[ "$want_rc" != 0 ]] || assert_eq \
    "$(jq -r '.production_allowance, .test_allowance, .verdict' <<<"$row_json" | paste -sd,)" \
    "$want_fields" "record for: $line"
done <<'ROWS'
**Expected delta**: 250 lines|250,null,pass|0
**Expected delta**: 250 lines, 120 test lines|250,120,pass|0
**Expected delta**: about 250 lines||2
**Expected delta**: 200-300 lines||2
**Expected delta**: -250 lines||2
A sentence about an expected delta of 9 lines somewhere.|null,null,allowance_missing|0
ROWS

write_issue "no header line at all"
set +e
missing_error="$(run_check "$CHECK_BIN" 2>&1 >/dev/null)"
missing_rc=$?
set -e
assert_eq "$missing_rc" "0" "an issue stating no allowance is reported, not refused and not defaulted"
assert_eq "$([[ "$missing_error" == *"no allowance to judge by"* && "$missing_error" == *"50 production, 14 test"* ]] && echo yes)" \
  "yes" "the report names the missing line and the counts measured"
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-SIZE '.pr.size_check.verdict, .pr.size_check.production_allowance' | paste -sd,)" \
  "allowance_missing,null" "the record says nothing was judged and invents no allowance"

# --- Past the production allowance ------------------------------------------
write_issue "**Expected delta**: 40 lines, 20 test lines"
mk 60 src/impl.txt
commit_files production-growth
set +e
prod_error="$(run_check "$CHECK_BIN" 2>&1 >/dev/null)"
prod_rc=$?
set -e
assert_eq "$prod_rc" "3" "a branch past its production allowance is refused before the push"
assert_eq "$([[ "$prod_error" == *"100 production lines added"* && "$prod_error" == *"allows 40"* ]] && echo yes)" \
  "yes" "the production refusal prints the count and the allowance"
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-SIZE '.pr.size_check.verdict')" "production_over" \
  "the refusal is recorded with its reason"

PROD_SCRIPTS="$(mutant_scripts production-mutant)"
PROD_MUTANT="$PROD_SCRIPTS/branch-size-check"
assert_eq "$(grep -Fc 'elif (( production_lines > allowance )); then' "$PROD_MUTANT")" "1" \
  "production control finds exactly one live comparison"
sed -i.bak 's/^elif (( production_lines > allowance )); then$/elif false; then/' "$PROD_MUTANT"
assert_eq "$([[ "$(grep -Fc 'elif (( production_lines > allowance )); then' "$PROD_MUTANT")" == 0 ]] \
  && ! cmp -s "$PROD_MUTANT" "$CHECK_BIN" && echo yes)" "yes" \
  "production control neuters the comparison only in its private copy"
rc_of mutant_prod_rc run_check "$PROD_MUTANT"
assert_eq "$mutant_prod_rc" "0" \
  "must-fail control: without that comparison the oversized branch is not refused"

# --- Past the test allowance -------------------------------------------------
write_issue "**Expected delta**: 50 lines, 20 test lines"
mk 10 src/impl.txt
mk 40 tests/plain.sh
commit_files test-growth
set +e
test_error="$(run_check "$CHECK_BIN" 2>&1 >/dev/null)"
test_rc=$?
set -e
assert_eq "$test_rc" "3" "a branch past its test allowance is refused before the push"
assert_eq "$([[ "$test_error" == *"50 test lines added"* && "$test_error" == *"allows 20"* ]] && echo yes)" \
  "yes" "the test refusal prints the count and the allowance"

# A private copy of its own: a mutant already carrying the production mutation
# would prove nothing about this comparison.
TEST_SCRIPTS="$(mutant_scripts test-mutant)"
TEST_MUTANT="$TEST_SCRIPTS/branch-size-check"
assert_eq "$(grep -Fc 'elif [[ -n "$test_allowance" ]] && (( test_lines > test_allowance )); then' "$TEST_MUTANT")" "1" \
  "test control finds exactly one live comparison"
sed -i.bak 's/^elif \[\[ -n "\$test_allowance" \]\] \&\& (( test_lines > test_allowance )); then$/elif false; then/' "$TEST_MUTANT"
rc_of mutant_test_rc run_check "$TEST_MUTANT"
assert_eq "$mutant_test_rc" "0" \
  "must-fail control: without that comparison the oversized test diff is not refused"

write_issue "**Expected delta**: 50 lines"
rc_of unjudged_rc run_check "$CHECK_BIN"
assert_eq "$unjudged_rc" "0" "with no test count the test lines are shown and not judged"

# --- A GitHub-tracked issue reads the same line from its body ---------------
GH_STUB="$TMP_ROOT/bin"
mkdir -p "$GH_STUB"
printf '#!/usr/bin/env bash\nprintf "%%s" "**Expected delta**: 50 lines, 60 test lines"\n' > "$GH_STUB/gh"
chmod +x "$GH_STUB/gh"
"$STATE" --state-dir "$WT/tmp" init issue-77 --worktree "$WT" --branch size >/dev/null
capture gh_json env PATH="$GH_STUB:$PATH" ORCH_STATE_DIR="$WT/tmp" \
  "$CHECK_BIN" --worktree "$WT" --issue issue-77 --json
assert_eq "$(jq -r '.production_allowance, .test_allowance, .verdict' <<<"$gh_json" | paste -sd,)" \
  "50,60,pass" "a GitHub issue body supplies the same allowance"

# --- An issue the tracker cannot give is an environment failure -------------
jq -n '[{identifier: "KEN-OTHER", description: "another issue"}]' > "$WT/.cache/linear/issues.json"
rc_of unread_rc run_check "$CHECK_BIN"
assert_eq "$unread_rc" "2" "an issue absent from the cache exits 2 rather than judging by nothing"

# --- The state file is the one named, not the one the caller stands in ------
write_issue "**Expected delta**: 50 lines"
STATE_DIR="$TMP_ROOT/elsewhere"
mkdir -p "$STATE_DIR"
"$STATE" --state-dir "$STATE_DIR" init KEN-SIZE --worktree "$WT" --branch size >/dev/null
set +e
(cd "$TMP_ROOT" && env -u ORCH_STATE_DIR "$CHECK_BIN" --worktree "$WT" --issue KEN-SIZE --state-dir "$STATE_DIR" >/dev/null 2>&1)
set -e
assert_eq "$("$STATE" --state-dir "$STATE_DIR" get KEN-SIZE '.pr.size_check.verdict')" "pass" \
  "--state-dir decides which state is read and written, not the caller's directory"

printf '\npass: %d  fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
