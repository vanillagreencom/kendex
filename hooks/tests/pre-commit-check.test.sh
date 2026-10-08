#!/usr/bin/env bash
# Surface: pre-commit-check literal command and option boundaries.
# Inputs: hooks/pre-commit-check.sh and hooks/tests/lib/*.sh.
# HOOK_UNDER_TEST lets the same rows reject a planted production defect.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOKS_DIR/pre-commit-check.sh}"
# shellcheck source=lib/pre-commit-world.sh
. "$HOOKS_DIR/tests/lib/pre-commit-world.sh"
# shellcheck source=lib/assert.sh
. "$HOOKS_DIR/tests/lib/assert.sh"
# shellcheck source=lib/payload-rows.sh
. "$HOOKS_DIR/tests/lib/payload-rows.sh"
PAYLOAD_TOOLS=jq,cat,grep
PAYLOAD_NAME=pre-commit-check
ARMED="$(new_repo armed)"; arm "$ARMED" pre-commit commit-msg
UNARMED="$(new_repo unarmed)"

command_rows() {
  local row status key form
  while IFS='|' read -r status key form; do
    [ -n "$status" ] || continue
    form=${form//NOVERIFY/$NV}; key=${key//NOVERIFY/$NV}
    run_hook "$ARMED" "$(jq -nc --arg c "$form" '{tool_input:{command:$c}}')"
    assert_eq "rc=$rc first=$(first_line)" "rc=$status first=$key" "$form"
  done <<'ROWS'
0|-|git commit -m test
2|pre-commit-check: bypass=NOVERIFY|git commit NOVERIFY -m test
2|pre-commit-check: bypass=-n|git commit -n -m test
2|pre-commit-check: bypass=-anm|git commit -anm test
2|pre-commit-check: bypass=--no-veri|git commit --no-veri -m test
2|pre-commit-check: bypass="-n"|git commit "-n" -m test
2|pre-commit-check: bypass=NOVERIFY|true;git commit NOVERIFY -m test
2|pre-commit-check: bypass=-n|if true; then git commit -n -m test; fi
2|pre-commit-check: bypass=-n|X=1 git commit -n -m test
2|pre-commit-check: bypass=-n|env X=1 git commit -n -m test
2|pre-commit-check: bypass=-n|command /usr/bin/git commit -n -m test
2|pre-commit-check: bypass=-n|git commit -m "fix: a; b" -n
2|pre-commit-check: bypass=-n|git commit -m x 2>&1 -n
2|pre-commit-check: bypass=-n|2>/dev/null git commit -m x -n
2|pre-commit-check: bypass=-n|git commit -m x >>log -n
0|-|2 >log git commit -n
0|-|"2">log git commit -n
2|pre-commit-check: bypass=NOVERIFY|git commit -m 'explain NOVERIFY' NOVERIFY
0|-|git commit -m "explain why NOVERIFY is banned"
0|-|git commit --message NOVERIFY
0|-|git commit --message=NOVERIFY
0|-|git commit -mNOVERIFY
0|-|git commit -Cnote
0|-|git commit -F NOVERIFY
0|-|git commit --file NOVERIFY
0|-|git commit --author NOVERIFY
0|-|git commit --trailer NOVERIFY
0|-|git commit -- NOVERIFY
0|-|git commit -- core.hooksPath
0|-|git commit -m 'core.hooksPath=/dev/null GIT_CONFIG_COUNT=1'
0|-|git commit -m x # NOVERIFY
0|-|printf %s "git commit NOVERIFY"
0|-|echo "done; git commit NOVERIFY"
0|-|notify -m "run git commit NOVERIFY after the fix"
0|-|git log -n 3; git commit -m "x"
0|-|git commit -m "x"; tail -n 5 log
0|-|git commit -m "x" | tail -n 5
0|-|git commit --dry-run -n
0|-|git commit --short -n
0|-|git commit --help -n
0|-|git commit -n --verify -m x
2|pre-commit-check: bypass=-n|git commit --verify -n -m x
0|-|git log --grep 'git commit NOVERIFY'
0|-|git config --get core.hooksPath; git commit -m x
0|-|GIT_CONFIG_COUNT=1 git commit -m x
0|-|GIT_CONFIG_KEY_0=user.name git commit -m x
0|-|GIT_CONFIG_COUNT=0 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x
0|-|GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x
0|-|git -c user.name=NOVERIFY commit -m x
0|-|git -C commit status -n
0|-|git status commit -n
2|pre-commit-check: bypass=core.hooksPath=/dev/null|git -c core.hooksPath=/dev/null commit -m x
2|pre-commit-check: bypass=-ccore.hooksPath=/dev/null|git -ccore.hooksPath=/dev/null commit -m x
2|pre-commit-check: bypass=--config-env=core.hooksPath=HP|git --config-env=core.hooksPath=HP commit -m x
2|pre-commit-check: bypass=GIT_CONFIG_KEY_0=Core.HooksPath|GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=Core.HooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x
2|pre-commit-check: bypass=core.hooksPath|git config --local core.hooksPath /dev/null; git commit -m x
0|-|git commit -m x; git config --local core.hooksPath /dev/null
0|pre-commit-check: command=unresolved|git commit -m "$TEXT" -n
0|pre-commit-check: command=unresolved|cat <<EOF\ngit commit -n\nEOF
0|pre-commit-check: command=unresolved|git commit -m $(cat message) -n
0|pre-commit-check: command=unresolved|git commit -m x *
ROWS
}
command_rows

# This hook's unavailable-reader contract differs from the other hooks that
# share these payload shapes. Keep their expectations private to this suite.
PAYLOAD_ROWS=${PAYLOAD_ROWS//|2|payload=/|0|payload=}
PAYLOAD_ROWS=${PAYLOAD_ROWS//|2|missing-tools=/|0|missing-tools=}
payload_rows() {
  payload_table "$HOOK" "git commit $NV -m x" 'git commit -m x' "$ARMED"
}
payload_rows

run_hook "$UNARMED" "$(payload 'git commit -m x')"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=pre-commit-check: unarmed=$UNARMED" "unarmed checks do not hold the committer"
assert_eq "$log" "" "the hook never executes repository checks"

if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  skill_load_control no-short-flag "$HOOK" 'letter=${rest:0:1}; rest=${rest:1}' 'letter=x' HOOK command_rows \
    'git commit -n -m test'
  skill_load_control no-hook-override "$HOOK" 'CALL_COMMIT=1; CALL_BYPASS=$env_config' 'CALL_BYPASS=""' HOOK command_rows \
    'git -c core.hooksPath=/dev/null commit -m x'
  skill_load_control message-is-option "$HOOK" '      --message | --file | --reuse-message | --reedit-message | --template | --author | --date | --cleanup | --fixup | --squash | --trailer | --pathspec-from-file)' 'i=$((i - 1))' HOOK command_rows \
    "git commit --message $NV"
  skill_load_control reader-block "$HOOK" "printf 'pre-commit-check: %s=%s\\n' \"\$1\" \"\$2\" >&2" \
    'case "$1" in missing-tools | payload) exit 2 ;; esac' HOOK payload_rows \
    'without jq the refusing command is refused unread rather than guessed at'
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
