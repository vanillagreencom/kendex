#!/usr/bin/env bash
# Tests for dev-artifact-check's additions classifier as the public checker
# runs it over a real linked worktree: helper names by unconditional substring
# and by suffix inside a test path are protected additions a fix round cannot
# add unlisted, product
# and documentation basenames are not, an inert classifier is caught by the
# suite's one control, and round-mode waiting leaves no scratch behind. The writer these rounds are stamped by is
# dev_round_write.sh; the checker's other gates are dev_artifact_check.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
WRITE_BIN="$REPO_ROOT/skills/orch/scripts/dev-round-write"
RETURN_WRITE="$REPO_ROOT/skills/orch/scripts/dev-return-write"
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
# The mode a fix round runs is read from the project's settings, and orch-env
# reads the process environment first: a developer's own range command would
# otherwise decide the fix receipts' acceptance.
unset DEV_VALIDATE_RANGE_CMD
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
jq -r --arg id "issue-$3" '.[] | select(.identifier == $id) | .description' .cache/linear/issues.json
SH
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"
OK_REACH="tools/guard on a staged .agents render"

seed_allowance() {
  local repo="$1"
  mkdir -p "$repo/.cache/linear"
  printf '[{"identifier":"issue-826","description":"**Expected delta**: 1000000 lines, 1000000 test lines"}]\n' \
    > "$repo/.cache/linear/issues.json"
  printf '.cache/\n' >> "$(git -C "$repo" rev-parse --path-format=absolute --git-path info/exclude)"
}

round_write() { growth_round_write "$STATE" "$WRITE_BIN" "$@"; }

# new_repo NAME — a committed git repo; prints its path.
new_repo() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  git -C "$d" config commit.gpgsign false
  git -C "$d" commit -q --allow-empty -m base
  printf '%s' "$d"
}

# run_check CHECKER ARGS... — OUT is the JSON, RC the exit.
run_check() {
  local checker="$1"
  shift
  set +e
  OUT=$("$checker" "$@" 2>/dev/null)
  RC=$?
  set -e
}
json() { jq -r "$1" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE; }
# observe EXPECT — `rc` and JSON fields (`files` compact) in EXPECT's order.
observe() {
  local got="" token name value
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      files) value="$(json '.files | tojson')" ;;
      *) value="$(json "if has(\"$name\") then .$name else \"ABSENT\" end")" ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# commit_files REPO MESSAGE PATH... — writes each PATH with a line and commits.
commit_files() {
  local repo="$1" msg="$2" f
  shift 2
  for f in "$@"; do mkdir -p "$repo/$(dirname "$f")"; printf 'added\n' > "$repo/$f"; git -C "$repo" add "$f"; done
  git -C "$repo" commit -q -m "$msg"
}

echo "=== helper names by unconditional substring and by suffix inside a test path are protected additions ==="
MAIN="$(new_repo linked-main)"
WT="$TMP_ROOT/linked-wt"
git -C "$MAIN" worktree add -q -b linked "$WT"
init_growth_state "$STATE" "$WT" issue-826 seed 1000000 >/dev/null
seed_allowance "$WT"
round_write --worktree "$WT" --issue issue-826 --round-id 30-30 --item 1 linked "$OK_REACH" >/dev/null
commit_files "$WT" helpers existing/workflow_helpers.sh .workflow_helpers.sh adversarial/prefixhelperSuffix.rs \
  adversarial/name_test-helper_more/file.rs adversarial/name_test_helper_more/file.rs \
  adversarial/name_test-util_more/file.rs adversarial/name_test_util_more/file.rs \
  tests/workflow_helpers.sh __tests__/workflow_helpers.sh tests/unit/support/shared.rs __tests__/integration/utils/shared.ts
"$RETURN_WRITE" --worktree "$WT" --kind fix --issue issue-826 --round-id 30-30 --branch linked \
  --commit "$(git -C "$WT" rev-parse HEAD)" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-wt-30-30-1" "$WT" issue-826 30-30)" --item 1 Applied done >/dev/null
run_check "$CHECK" --worktree "$WT" --issue issue-826 --round-id 30-30 --expect-items-from-round
E='rc=1 reason=unapproved_additions files=["__tests__/integration/utils/shared.ts","__tests__/workflow_helpers.sh","adversarial/name_test-helper_more/file.rs","adversarial/name_test-util_more/file.rs","adversarial/name_test_helper_more/file.rs","adversarial/name_test_util_more/file.rs","tests/unit/support/shared.rs","tests/workflow_helpers.sh"]'
assert_eq "$(observe "$E")" "$E" "the public checker refuses the explicit substrings and the test-context helper suffixes, and names each"

# The suite's one must-fail control: an inert classifier accepts the same
# round outright.
INERT="$(mutant_scripts inert-classifier dev-artifact-check)/dev-artifact-check" || exit 1
assert_eq "$(awk '/^is_protected_addition\(\)/,/^}/' "$INERT" | grep -Fc 'return 0')" "4" "control: the classifier has four protected returns to invert"
sed -i.bak '/^is_protected_addition()/,/^}/ s/return 0/return 1/' "$INERT"
assert_eq "$(awk '/^is_protected_addition\(\)/,/^}/' "$INERT" | grep -Fc 'return 0')" "0" "control: every protected return is inverted in the private copy"
run_check "$INERT" --worktree "$WT" --issue issue-826 --round-id 30-30 --expect-items-from-round
E='rc=0 ok=true verdict=accept reason=valid files=[]'
assert_eq "$(observe "$E")" "$E" "control: an inert classifier accepts the round with no file named"


echo "=== product and documentation helper basenames are outside the protected scope ==="
round_write --worktree "$WT" --issue issue-826 --round-id 32-32 --item 1 product "$OK_REACH" >/dev/null
commit_files "$WT" product-helpers docs/render_helpers.md src/ProductHelper.rs src/render.helper.ts .workflow_helpers.md
"$RETURN_WRITE" --worktree "$WT" --kind fix --issue issue-826 --round-id 32-32 --branch linked \
  --commit "$(git -C "$WT" rev-parse HEAD)" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-wt-32-32-2" "$WT" issue-826 32-32)" --item 1 Applied done >/dev/null
run_check "$CHECK" --worktree "$WT" --issue issue-826 --round-id 32-32 --expect-items-from-round
assert_eq "$(observe "rc=0 reason=valid")" "rc=0 reason=valid" "docs, capitalised and dotted helper basenames and a dotfile .md are not protected additions"

echo "=== round-mode waiting leaves no scratch behind ==="
# validate_artifact runs in command substitutions while waiting; each
# invocation owns and removes its probe files before returning.
WR="$(new_repo wait-round)"
init_growth_state "$STATE" "$WR" issue-826 seed 1000000 >/dev/null
seed_allowance "$WR"
round_write --worktree "$WR" --issue issue-826 --round-id 21-21 --item 1 wait "$OK_REACH" >/dev/null
( sleep 2; "$RETURN_WRITE" --worktree "$WR" --kind fix --issue issue-826 --round-id 21-21 --branch main \
    --commit "$(git -C "$WR" rev-parse HEAD)" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-wr-21-21-3" "$WR" issue-826 21-21)" --item 1 Applied done >/dev/null ) &
writer_pid=$!
run_check "$CHECK" --worktree "$WR" --issue issue-826 --round-id 21-21 --expect-items-from-round --wait 20 --interval 1
wait "$writer_pid"
assert_eq "$(observe "verdict=accept") scratch=$(find "$WR/tmp" -maxdepth 1 -name '.dev-artifact-*' | wc -l | tr -d ' ')" "verdict=accept scratch=0" "the wait accepts the landed artifact and leaves no dev-artifact scratch files"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
