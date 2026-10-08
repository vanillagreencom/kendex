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
RESTORED="$(new_repo restored)"; arm "$RESTORED" pre-commit commit-msg
git -C "$RESTORED" config core.hooksPath /dev/null
for lane in pre-commit commit-msg; do
  printf '#!/bin/sh\n%s\nprintf "%%s\\n" %s >>"%s"\nexit 1\n' "$GG_MARK" "$lane" "$TMP_ROOT/reset-check.log" >"$RESTORED/.git/hooks/$lane"
done
SCOPED="$(new_repo scoped)"; arm "$SCOPED" pre-commit commit-msg
git -C "$SCOPED" config extensions.worktreeConfig true
git -C "$SCOPED" config --local core.hooksPath /dev/null
git -C "$SCOPED" config --worktree core.hooksPath /dev/null
INCLUDED="$(new_repo included)"; arm "$INCLUDED" pre-commit commit-msg
git -C "$INCLUDED" config core.hooksPath /dev/null
git -C "$INCLUDED" config include.path "$TMP_ROOT/include.gitconfig"
git config --file "$TMP_ROOT/include.gitconfig" core.hooksPath /dev/null
NOT_A_REPO="$TMP_ROOT/plain"; mkdir -p "$NOT_A_REPO"

arming_rows() {
  local row directory want status form name
  while IFS='|' read -r directory want status form; do
    [ -n "$directory" ] || continue
    name="arming: $directory${form:+: $form}"
    [ "${status:-0}" != 2 ] || name="defensive guard refusal: $directory: $form"
    form=${form:-git commit -m test}
    run_hook "$directory" "$(jq -nc --arg c "$form" '{tool_input:{command:$c}}')"
    assert_eq "rc=$rc first=$(first_line)" "rc=${status:-0} first=$want" "$name"
    assert_eq "$log" "" "repository scripts do not run: $directory"
    if [ "$want" = "pre-commit-check: unarmed=$directory" ]; then
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
$RESTORED|pre-commit-check: bypass=-n|2|git config --unset core.hooksPath && git commit -n --allow-empty -m fixture
$RESTORED|pre-commit-check: bypass=-n|2|git config --local --unset-all core.hooksPath; git commit -n -m fixture
$RESTORED|pre-commit-check: bypass=-n|2|git config unset --local --all core.hooksPath; git commit -n -m fixture
$RESTORED|pre-commit-check: bypass=-n|2|git config --unset core.hooksPath; git config core.hooksPath "\$HOOKS"; git commit -n -m fixture
$RESTORED|pre-commit-check: bypass=-n|2|git config --unset core.hooksPath; git commit -n -m fixture; echo {a,b}
$RESTORED|-|0|git config --unset core.hooksPath; git commit -m '-n'
$RESTORED|-|0|git config --unset core.hooksPath; git commit -F -n
$RESTORED|-|0|git config --unset core.hooksPath; git commit -- -n
$RESTORED|-|0|git config --unset core.hooksPath; git commit -n --verify -m fixture
$RESTORED|pre-commit-check: unarmed=$RESTORED|0|git commit -n -m fixture; git config --unset core.hooksPath
$RESTORED|pre-commit-check: unarmed=$RESTORED|0|git config --get core.hooksPath; git commit -n -m fixture
$RESTORED|pre-commit-check: unarmed=$RESTORED|0|git config --global --unset core.hooksPath; git commit -n -m fixture
$SCOPED|pre-commit-check: unarmed=$SCOPED|0|git config --local --unset core.hooksPath; git commit -n -m fixture
$INCLUDED|pre-commit-check: unarmed=$INCLUDED|0|git config --local --unset core.hooksPath; git commit -n -m fixture
$RESTORED|pre-commit-check: command=unresolved|0|git config core.hooksPath "\$HOOKS"; git config --unset core.hooksPath; git commit -n -m fixture
$RESTORED|pre-commit-check: unarmed=$RESTORED|0|git config --unset core.hooksPath /another/path; git commit -n -m fixture
$RESTORED|pre-commit-check: unarmed=$RESTORED|0|git config --type=path core.hooksPath /dev/null; git commit -m fixture
$UNARMED|pre-commit-check: unarmed=$UNARMED|0|git config --unset core.hooksPath; git commit -n -m fixture
$DISARMED|pre-commit-check: unarmed=$DISARMED|0|git config --unset core.hooksPath; git commit -n -m fixture
$HALF_ARMED|pre-commit-check: unarmed=$HALF_ARMED|0|git config --unset core.hooksPath; git commit -n -m fixture
$ARMED|pre-commit-check: command=unresolved|0|git config core.hooksPath /dev/null; git config --unset core.hooksPath; git commit -m fixture
ROWS
}
arming_rows

# Real Git is the control: restored marked hooks refuse an ordinary commit,
# while the actual bypass can create it if the tool guard loses its refusal.
status=0
(cd -- "$RESTORED" && git config --unset core.hooksPath && git -c user.name=fixture -c user.email=fixture@example.test -c commit.gpgSign=false commit -q --allow-empty -m fixture) >"$OUT_FILE" 2>"$ERR_FILE" || status=$?
assert_eq "$status" 1 'real restored hook refuses an ordinary commit'
assert_eq "$(cat "$TMP_ROOT/reset-check.log")" pre-commit 'the restored refusing hook runs'
git -C "$RESTORED" config core.hooksPath /dev/null
run_hook "$RESTORED" "$(payload 'git config --unset core.hooksPath && git commit -n --allow-empty -m fixture')"
assert_eq "rc=$rc first=$(first_line)" 'rc=2 first=pre-commit-check: bypass=-n' 'defensive guard refusal after a known reset'
status=0
(cd -- "$RESTORED" && git config --unset core.hooksPath && git -c user.name=fixture -c user.email=fixture@example.test -c commit.gpgSign=false commit -q -n --allow-empty -m fixture) >"$OUT_FILE" 2>"$ERR_FILE" || status=$?
assert_eq "$status" 0 'real bypass creates a commit without the refusing hook'
assert_eq "$(cat "$TMP_ROOT/reset-check.log")" pre-commit 'the actual bypass skips the restored refusing hook'
git -C "$RESTORED" config core.hooksPath /dev/null

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
  skill_load_control reset-loses-consent "$HOOK" '[ -n "$CONFIG_ENTRIES" ] || CONFIG_ARMED=$RESET_ARMED' \
    'CONFIG_ARMED=$ARMED' HOOK arming_rows \
    "defensive guard refusal: $RESTORED: git config --unset core.hooksPath && git commit -n --allow-empty -m fixture"
  skill_load_control reset-ignores-survivors "$HOOK" 'CONFIG_ENTRIES=$SURVIVING_ENTRIES' \
    'CONFIG_ENTRIES=""' HOOK arming_rows \
    "arming: $SCOPED: git config --local --unset core.hooksPath; git commit -n -m fixture" \
    "arming: $INCLUDED: git config --local --unset core.hooksPath; git commit -n -m fixture"
  skill_load_control no-consent "$HOOK" 'message unarmed "$PWD"' 'exit 2' HOOK arming_rows \
    "arming: $UNARMED"
  skill_load_control relative-owner "$HOOK" 'COMMON=$(cd -- "$COMMON" && pwd -P) || { message setup consent; exit 0; }' 'COMMON=$(git rev-parse --git-common-dir)' HOOK arming_rows \
    "setup requires consent: $SUBDIR"
  skill_load_control wrong-owner "$HOOK" 'MAIN=$(cd -- "$COMMON/.." && pwd -P) || { message setup consent; exit 0; }' 'MAIN=consent' HOOK owner_row \
    'setup goes to the main checkout owner'
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
