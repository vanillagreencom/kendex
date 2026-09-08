#!/usr/bin/env bash
# Arming and directory notices for pre-commit-check. Word grammar is in the
# sibling suite; these fixtures vary the installed hooks and the directory.
#
# Every refusal and notice opens with `pre-commit-check: <key>=<value>`, and
# that line is what a row pins. An unarmed repository refuses with `armed=no`
# whatever the command said; the directory notice is `judged=<directory>`, and
# it follows the verdict rather than leading it, so it is read out of the whole
# stderr rather than off the first line.
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
# A row is `label|directory|status|first line`.
arming_table() {
  local rows="$1" row label dir want first field before=$((PASS + FAIL))
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label dir want first <<<"$row"
    for field in "$label" "$dir" "$want" "$first"; do
      [[ "$field" != "" ]] || { echo "arming: a row with an empty field asserts nothing: $row" >&2; exit 1; }
    done
    : >"$RAN_LOG"
    run_hook "$dir" "$(payload 'git commit -m test')"
    if [[ "${PRE_COMMIT_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => rc=%s first=%s log=%s\n' "$label" "$rc" "$(first_line)" "$log"
      continue
    fi
    assert_eq "rc=$rc first=$(first_line)" "rc=$want first=$first" "$label"
    assert_eq "$log" "" "nothing of the repository's own scripts ran: $label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "arming: no row was asserted" >&2; exit 2; }
}

arming_table "\
an armed .git/hooks pair gates the commit itself|$ARMED|0|-
not armed: disarmed|$DISARMED|2|pre-commit-check: armed=no
not armed: half-armed|$HALF_ARMED|2|pre-commit-check: armed=no
not armed: hooks-off|$HOOKS_OFF|2|pre-commit-check: armed=no
not armed: armed-by-path|$ARMED_BY_PATH|2|pre-commit-check: armed=no
not armed: unarmed|$UNARMED|2|pre-commit-check: armed=no
"
assert_contains "$err" "kendex guard install" "the unarmed refusal names the command that fixes it"
assert_contains "$err" "kendex guard check" "and the one that explains it"

echo
echo "the hook gates its working directory only"

run_hook "$ARMED" "$(payload "git -C $UNARMED commit -m x")"
assert_eq "$rc" "0" "an armed cwd defers whatever the commit is aimed at"
run_hook "$UNARMED" "$(payload "git -C $ARMED commit -m x")"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=pre-commit-check: armed=no" \
  "an unarmed cwd judges itself whatever the target"
assert_contains "$err" "pre-commit-check: judged=$UNARMED" "and the notice names the directory it judged"
run_hook "$NOT_A_REPO" "$(payload "git -C $UNARMED commit -m x")"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=pre-commit-check: judged=$NOT_A_REPO" \
  "a non-repository cwd gates nothing and says the target is elsewhere"
run_hook "$UNARMED" "$(payload 'git commit -m x')"
assert_not_contains "$err" "pre-commit-check: judged=" "no notice for a commit in place"
# Every word that moves the repository, each named by the same notice.
move_table() {
  local rows="$1" row form before=$((PASS + FAIL))
  while IFS= read -r row; do
    # A row is the form and nothing else, so an empty one is an empty field.
    [[ "$row" != "" ]] || continue
    form="$row"
    run_hook "$UNARMED" "$(payload "$form")"
    if [[ "${PRE_COMMIT_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$form" "$err"
      continue
    fi
    assert_contains "$err" "pre-commit-check: judged=$UNARMED" "a repository-moving word is named: $form"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "moves: no row was asserted" >&2; exit 2; }
}

move_table 'cd sub && git commit -m x
GIT_DIR=/e/.git git commit -m x
GIT_WORK_TREE=/e git commit -m x
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
