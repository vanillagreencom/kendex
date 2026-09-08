#!/usr/bin/env bash
# Arming and directory notices for pre-commit-check. Word grammar is in the
# sibling suite; these fixtures vary the installed hooks and the directory.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOKS_DIR/pre-commit-check.sh}"
# shellcheck source=lib/pre-commit-world.sh
. "$HOOKS_DIR/tests/lib/pre-commit-world.sh"

UNARMED="$(new_repo unarmed)"
ARMED="$(new_repo armed)"; arm "$ARMED" pre-commit commit-msg
# A hook git will not run: present, execute bit off. Git skips it silently.
DISARMED="$(new_repo disarmed)"; arm "$DISARMED" pre-commit commit-msg
chmod -x "$DISARMED/.git/hooks/pre-commit"
# One lane armed and not the other. Deferring here waives the commit-msg gate.
HALF_ARMED="$(new_repo half-armed)"; arm "$HALF_ARMED" pre-commit
# core.hooksPath set and EMPTY switches hooks off, and git's answer misleads:
# `rev-parse --git-path hooks` reports `./`, so the directory resolves to the
# repository root. This fixture puts an executable pre-commit exactly there.
HOOKS_OFF="$(new_repo hooks-off)"
git -C "$HOOKS_OFF" config core.hooksPath ""
printf '#!/bin/sh\nexit 0\n' >"$HOOKS_OFF/pre-commit"; chmod +x "$HOOKS_OFF/pre-commit"
# Marked and executable, but reached through core.hooksPath: a redirect is not
# armed, whatever it points at.
ARMED_BY_PATH="$(new_repo armed-by-path)"; arm "$ARMED_BY_PATH" pre-commit commit-msg
mkdir -p "$TMP_ROOT/custom-hooks"
cp "$ARMED_BY_PATH/.git/hooks/pre-commit" "$ARMED_BY_PATH/.git/hooks/commit-msg" "$TMP_ROOT/custom-hooks/"
git -C "$ARMED_BY_PATH" config core.hooksPath "$TMP_ROOT/custom-hooks"
NOT_A_REPO="$TMP_ROOT/plain"; mkdir -p "$NOT_A_REPO"

# Each fixture proves once that the hook does not run repository scripts.
arming_table() {
  local rows="$1" row label dir want clause field before=$((PASS + FAIL))
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label dir want clause <<<"$row"
    for field in "$label" "$dir" "$want" "$clause"; do
      [[ "$field" != "" ]] || { echo "arming: a row with an empty field asserts nothing: $row" >&2; exit 1; }
    done
    : >"$RAN_LOG"
    run_hook "$dir" "$(payload 'git commit -m test')"
    if [[ "${PRE_COMMIT_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => rc=%s err=%s log=%s\n' "$label" "$rc" "$err" "$log"
      continue
    fi
    assert_eq "$rc" "$want" "$label"
    if [[ "$clause" != - ]]; then
      assert_contains "$err" "$clause" "and the refusal says so: $label"
    fi
    assert_eq "$log" "" "precondition: nothing of the repository's ran: $label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "arming: no row was asserted" >&2; exit 2; }
}

arming_table "\
an armed .git/hooks pair gates the commit itself|$ARMED|0|-
not armed: disarmed|$DISARMED|2|not armed by kendex
not armed: half-armed|$HALF_ARMED|2|not armed by kendex
not armed: hooks-off|$HOOKS_OFF|2|not armed by kendex
not armed: armed-by-path|$ARMED_BY_PATH|2|not armed by kendex
not armed: unarmed|$UNARMED|2|not armed by kendex
"
assert_contains "$err" "kendex guard install" "the unarmed refusal names the command that fixes it"
assert_contains "$err" "kendex guard check" "and the one that explains it"

echo
echo "the hook gates its working directory only"

run_hook "$ARMED" "$(payload "git -C $UNARMED commit -m x")"
assert_eq "$rc" "0" "an armed cwd defers whatever the commit is aimed at"
run_hook "$UNARMED" "$(payload "git -C $ARMED commit -m x")"
assert_eq "$rc" "2" "an unarmed cwd judges itself whatever the target"
assert_contains "$err" "judged $UNARMED only" "and the notice names the directory it judged"
run_hook "$NOT_A_REPO" "$(payload "git -C $UNARMED commit -m x")"
assert_eq "$rc" "0" "a non-repository cwd gates nothing"
assert_contains "$err" "moves repositories" "and says the target is elsewhere"
run_hook "$UNARMED" "$(payload 'git commit -m x')"
assert_not_contains "$err" "moves repositories" "no notice for a commit in place"
move_table() {
  local rows="$1" row form notice field before=$((PASS + FAIL))
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r form notice <<<"$row"
    for field in "$form" "$notice"; do
      [[ "$field" != "" ]] || { echo "moves: a row with an empty field asserts nothing: $row" >&2; exit 1; }
    done
    run_hook "$UNARMED" "$(payload "$form")"
    if [[ "${PRE_COMMIT_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$form" "$err"
      continue
    fi
    assert_contains "$err" "$notice" "a repository-moving word is named: $form"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "moves: no row was asserted" >&2; exit 2; }
}

move_table 'cd sub && git commit -m x|moves repositories
GIT_DIR=/e/.git git commit -m x|moves repositories
GIT_WORK_TREE=/e git commit -m x|moves repositories
'

echo
echo "the split is not pathname expansion"

# `set -f` around the word split is the only thing keeping the command's text
# from being matched against the working directory. Without it a repository
# holding a file named for the flag turns an ordinary glob into a bypass word,
# which is this hook reading a word no shell handed it.
GLOB="$(new_repo glob)"; arm "$GLOB" pre-commit commit-msg
: >"$GLOB/$NV"
: >"$GLOB/commit"
run_hook "$GLOB" "$(payload 'git commit -m x *')"
assert_eq "$rc" "0" "a glob is not expanded against a decoy named for the flag"
assert_eq "$log" "" "nothing of the repository's ran for the glob"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
