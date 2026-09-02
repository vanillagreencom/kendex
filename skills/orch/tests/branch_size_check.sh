#!/usr/bin/env bash
# Regression tests for branch-size-check: the submit-time size check that
# scores the branch's whole diffstat against the issue it implements, before
# the push (kendex KEN-1185). The fix-round tripwire runs at round mint against
# the branch's own first commit, so a branch that was already grown when the PR
# opened never met it.

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
git -C "$WT" commit -q --allow-empty -m base
git -C "$WT" switch -q -c size

# The issue the branch is scored against. Two Done-when surfaces, an estimate,
# and a stated expected delta the later cases switch on.
write_issue() {
  local delta_line="$1" estimate="$2"
  mkdir -p "$WT/.cache/linear"
  jq -n --arg delta "$delta_line" --argjson est "$estimate" '[{
    identifier: "KEN-SIZE",
    estimate: $est,
    description: ($delta + "\n\n## Done-when\n\n- [ ] the check refuses a branch past its production allowance\n- [ ] the check refuses a branch past its test allowance\n")
  }]' > "$WT/.cache/linear/issues.json"
}

lines() { seq 1 "$1"; }

commit_files() {
  git -C "$WT" add -A
  git -C "$WT" commit -q -m "$1"
}

run_check() {
  env ORCH_STATE_DIR="$WT/tmp" ORCH_SIZE_TEST_LINES_PER_CONTROL=5 "$@" \
    --worktree "$WT" --issue KEN-SIZE
}

# --- Within both allowances --------------------------------------------------
write_issue "**Expected delta**: 40 lines" 2
init_growth_state "$STATE" "$WT" KEN-SIZE 1-1 12
# The fixture's own issue cache is not part of the branch being measured.
printf '.cache/\n' >> "$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)"
mkdir -p "$WT/src" "$WT/tests"
lines 10 > "$WT/src/impl.txt"
lines 8 > "$WT/tests/impl.test.txt"
commit_files implementation

set +e
pass_json="$(run_check "$CHECK_BIN" --json 2>/dev/null)"
pass_rc=$?
set -e
assert_eq "$pass_rc" "0" "a branch inside both allowances passes"
assert_eq "$(jq -r '.production_lines' <<<"$pass_json")" "10" "production lines are scored on their own"
assert_eq "$(jq -r '.test_lines' <<<"$pass_json")" "8" "test lines are scored on their own line"
assert_eq "$(jq -r '.production_allowance, .allowance_source' <<<"$pass_json" | paste -sd,)" \
  "40,stated-delta" "a stated expected delta is the production allowance"
assert_eq "$(jq -r '.surfaces, .test_allowance' <<<"$pass_json" | paste -sd,)" "2,20" \
  "the test allowance is one control per Done-when surface plus its must-fail control"
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-SIZE '.pr.size_check.verdict')" "pass" \
  "the verdict is recorded beside pr.baseline_lines, in no new state file"

# --- A mandated render mirror is counted once, at its source -----------------
mkdir -p "$WT/skills/orch" "$WT/.agents/skills/orch"
lines 6 > "$WT/skills/orch/SKILL.md"
lines 6 > "$WT/.agents/skills/orch/SKILL.md"
commit_files render-mirror
mirror_json="$(run_check "$CHECK_BIN" --json 2>/dev/null)"
assert_eq "$(jq -r '.production_lines' <<<"$mirror_json")" "16" \
  "the render mirror is not billed a second time to production"
assert_eq "$(jq -r '.mirror_lines' <<<"$mirror_json")" "6" "the excluded mirror lines are reported"

# --- Past the production allowance ------------------------------------------
lines 60 > "$WT/src/impl.txt"
commit_files production-growth
set +e
prod_error="$(run_check "$CHECK_BIN" 2>&1 >/dev/null)"
prod_rc=$?
set -e
assert_eq "$prod_rc" "3" "a branch past its production allowance is refused before the push"
assert_eq "$([[ "$prod_error" == *"production diffstat is 66 lines"* \
  && "$prod_error" == *"allowance is 40 lines"* \
  && "$prod_error" == *"stated-delta"* ]] && echo yes)" "yes" \
  "the production refusal prints both counts and where the allowance came from"
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-SIZE '.pr.size_check.verdict')" "production_over" \
  "the refusal is recorded with its reason"

MUTANT_SCRIPTS="$(copy_scripts size-mutant)"
MUTANT="$MUTANT_SCRIPTS/branch-size-check"
assert_eq "$(grep -Fc 'if (( production_lines > allowance )); then' "$MUTANT")" "1" \
  "production control finds exactly one live comparison"
sed -i.bak 's/^if (( production_lines > allowance )); then$/if false; then/' "$MUTANT"
assert_eq "$([[ "$(grep -Fc 'if (( production_lines > allowance )); then' "$MUTANT")" == 0 ]] \
  && ! cmp -s "$MUTANT" "$CHECK_BIN" && echo yes)" "yes" \
  "production control neuters the comparison only in its private copy"
set +e
run_check "$MUTANT" >/dev/null 2>&1
mutant_prod_rc=$?
set -e
assert_eq "$mutant_prod_rc" "0" \
  "must-fail control: without that comparison the oversized branch is not refused"

# --- Past the test allowance -------------------------------------------------
lines 10 > "$WT/src/impl.txt"
lines 40 > "$WT/tests/impl.test.txt"
commit_files test-growth
set +e
test_error="$(run_check "$CHECK_BIN" 2>&1 >/dev/null)"
test_rc=$?
set -e
assert_eq "$test_rc" "3" "a branch past its test allowance is refused before the push"
assert_eq "$([[ "$test_error" == *"test diffstat is 40 lines"* \
  && "$test_error" == *"allowance is 20 lines"* \
  && "$test_error" == *"2 Done-when surfaces"* ]] && echo yes)" "yes" \
  "the test refusal prints the count and the surface arithmetic"
assert_eq "$([[ "$test_error" == *"refuses a branch past its test allowance"* ]] && echo yes)" "yes" \
  "the test refusal lists the Done-when surfaces themselves"

assert_eq "$(grep -Fc 'elif [[ -n "$test_allowance" ]] && (( test_lines > test_allowance )); then' "$MUTANT")" "1" \
  "test control finds exactly one live comparison"
sed -i.bak 's/^elif \[\[ -n "\$test_allowance" \]\] \&\& (( test_lines > test_allowance )); then$/elif false; then/' "$MUTANT"
set +e
run_check "$MUTANT" >/dev/null 2>&1
mutant_test_rc=$?
set -e
assert_eq "$mutant_test_rc" "0" \
  "must-fail control: without that comparison the oversized test diff is not refused"

# --- An issue with no Done-when surfaces ------------------------------------
# There is no allowance to build, so the test lines are scored where they were
# before this check existed: inside the production total.
jq -n '[{identifier: "KEN-SIZE", estimate: 2, description: "no surfaces here"}]' \
  > "$WT/.cache/linear/issues.json"
no_surface_json="$(run_check "$CHECK_BIN" --json 2>/dev/null)"
assert_eq "$(jq -r '.surfaces, .test_lines, .production_lines' <<<"$no_surface_json" | paste -sd,)" \
  "0,0,56" "with no Done-when surfaces the test lines fall back into the production total"
assert_eq "$(jq -r '.allowance_source' <<<"$no_surface_json")" "est-2" \
  "with no stated delta the estimate supplies the production allowance"

# --- A GitHub-tracked issue reads its surfaces from the issue body ----------
GH_STUB="$TMP_ROOT/bin"
mkdir -p "$GH_STUB"
cat > "$GH_STUB/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "**Expected delta**: 40 lines

## Done-when

- [ ] the check reads a GitHub issue body
"
STUB
chmod +x "$GH_STUB/gh"
"$STATE" --state-dir "$WT/tmp" init issue-77 --worktree "$WT" --branch size >/dev/null
gh_json="$(env PATH="$GH_STUB:$PATH" ORCH_STATE_DIR="$WT/tmp" ORCH_SIZE_TEST_LINES_PER_CONTROL=5 \
  "$CHECK_BIN" --worktree "$WT" --issue issue-77 --json 2>/dev/null || true)"
assert_eq "$(jq -r '.surfaces, .test_allowance, .allowance_source' <<<"$gh_json" | paste -sd,)" \
  "1,10,stated-delta" "a GitHub issue body supplies the same allowance and surfaces"

# --- No allowance at all -----------------------------------------------------
rm -f "$WT/.cache/linear/issues.json"
"$STATE" --state-dir "$WT/tmp" set KEN-SIZE pr '{"baseline_lines":null}' >/dev/null
set +e
none_error="$(run_check "$CHECK_BIN" 2>&1 >/dev/null)"
none_rc=$?
set -e
assert_eq "$none_rc" "2" "an unreadable issue with no recorded baseline is an environment failure, not a verdict"
assert_eq "$([[ "$none_error" == *"linear_cache_absent"* ]] && echo yes)" "yes" \
  "the environment failure names why the issue could not be read"
"$STATE" --state-dir "$WT/tmp" set KEN-SIZE pr '{"baseline_lines":12}' >/dev/null
set +e
run_check "$CHECK_BIN" >/dev/null 2>&1
fallback_rc=$?
set -e
assert_eq "$fallback_rc" "3" \
  "must-fail control: with the baseline restored the same branch is scored, not refused as unmeasurable"
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-SIZE '.pr.size_check.allowance_source')" "baseline-lines" \
  "the recorded baseline is the fallback allowance, at twice the recorded count"

printf '\npass: %d  fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
