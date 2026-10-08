#!/usr/bin/env bash
# Surface: pre-commit-check arming notices and setup ownership.
# Inputs: hooks/pre-commit-check.sh and hooks/tests/lib/*.sh.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOKS_DIR/pre-commit-check.sh}"
# shellcheck source=lib/pre-commit-world.sh
. "$HOOKS_DIR/tests/lib/pre-commit-world.sh"
# shellcheck source=lib/assert.sh
. "$HOOKS_DIR/tests/lib/assert.sh"
UNARMED="$(new_repo unarmed)"
SUBDIR="$UNARMED/src"; mkdir -p "$SUBDIR"
ARMED="$(new_repo armed)"; arm "$ARMED" pre-commit commit-msg
DISARMED="$(new_repo disarmed)"; arm "$DISARMED" pre-commit commit-msg
chmod -x "$DISARMED/.git/hooks/pre-commit"
HALF_ARMED="$(new_repo half-armed)"; arm "$HALF_ARMED" pre-commit
HOOKS_OFF="$(new_repo hooks-off)"
git -C "$HOOKS_OFF" config core.hooksPath ""
ARMED_BY_PATH="$(new_repo armed-by-path)"; arm "$ARMED_BY_PATH" pre-commit commit-msg
git -C "$ARMED_BY_PATH" config core.hooksPath "$ARMED_BY_PATH/.git/hooks"
NOT_A_REPO="$TMP_ROOT/plain"; mkdir -p "$NOT_A_REPO"

arming_rows() {
  local row directory want
  while IFS='|' read -r directory want; do
    [ -n "$directory" ] || continue
    run_hook "$directory" "$(payload 'git commit -m test')"
    assert_eq "rc=$rc first=$(first_line)" "rc=0 first=$want" "arming: $directory"
    assert_eq "$log" "" "repository scripts do not run: $directory"
    if [ "$directory" != "$ARMED" ]; then
      assert_eq "$(grep -Fxc 'pre-commit-check: setup=consent' <<<"$err" || :)" 1 "setup requires consent: $directory"
      assert_eq "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")" "$err" "setup notice reaches context: $directory"
    fi
  done <<ROWS
$ARMED|-
$DISARMED|pre-commit-check: unarmed=$DISARMED
$HALF_ARMED|pre-commit-check: unarmed=$HALF_ARMED
$HOOKS_OFF|pre-commit-check: unarmed=$HOOKS_OFF
$ARMED_BY_PATH|pre-commit-check: unarmed=$ARMED_BY_PATH
$UNARMED|pre-commit-check: unarmed=$UNARMED
$SUBDIR|pre-commit-check: unarmed=$SUBDIR
ROWS
}
arming_rows

# Linked worktrees share hook files. The item lane must not arm them itself.
git -C "$UNARMED" -c user.name=fixture -c user.email=fixture@example.test -c commit.gpgSign=false commit -q --allow-empty -m fixture
WORKTREE="$TMP_ROOT/linked"
git -C "$UNARMED" worktree add -q -b linked "$WORKTREE"
owner_row() {
  run_hook "$WORKTREE" "$(payload 'git commit -m test')"
  assert_eq "rc=$rc first=$(first_line)" "rc=0 first=pre-commit-check: unarmed=$WORKTREE" "a worktree is allowed with a setup notice"
  assert_eq "$(grep -Fxc "pre-commit-check: setup=$UNARMED" <<<"$err" || :)" 1 "setup goes to the main checkout owner"
  assert_eq "$log" "" "the item lane runs no shared setup script"
  assert_eq "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")" "$err" "main-owner setup reaches context"
}
owner_row

run_hook "$NOT_A_REPO" "$(payload 'git -C /elsewhere commit -m x')"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=pre-commit-check: judged=$NOT_A_REPO" "the notice names the directory actually inspected"
run_hook "$NOT_A_REPO" "$(payload 'git commit -m x')"
assert_eq "rc=$rc first=$(first_line)" 'rc=0 first=-' "a non-repository with no move has no verdict"

if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  skill_load_control no-consent "$HOOK" 'message unarmed "$PWD"' 'exit 2' HOOK arming_rows \
    "arming: $UNARMED"
  skill_load_control relative-owner "$HOOK" 'COMMON=$(cd -- "$COMMON" && pwd -P) || { message setup consent; exit 0; }' 'COMMON=$(git rev-parse --git-common-dir)' HOOK arming_rows \
    "setup requires consent: $SUBDIR"
  skill_load_control wrong-owner "$HOOK" 'MAIN=$(cd -- "$COMMON/.." && pwd -P) || { message setup consent; exit 0; }' 'MAIN=consent' HOOK owner_row \
    'setup goes to the main checkout owner'
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
