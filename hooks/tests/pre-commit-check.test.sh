#!/usr/bin/env bash
# Surface: pre-commit-check literal command and option boundaries.
# Inputs: hooks/pre-commit-check.sh, hooks/tests/lib/*.sh, .claude/settings.json,
# .codex/hooks.json, .github/hooks/pre-commit-check.json, .pi/kendex/hooks.json,
# and the pre-commit-check.sh renders under each registry’s hook directory.
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
2|pre-commit-check: bypass=-n|git commit file -n -m x
2|pre-commit-check: bypass=-n|git commit file >log -n -m x
2|pre-commit-check: bypass=-n|git commit -F "$FILE" -n
2|pre-commit-check: bypass=-n|git commit -m"$TEXT" -n
2|pre-commit-check: bypass=-nm"$TEXT"|git commit -nm"$TEXT"
2|pre-commit-check: bypass=-n|git commit --author="$AUTHOR" -n -m x
0|pre-commit-check: command=unresolved|git commit "-n$OPTION" -m x
2|pre-commit-check: bypass=-n|git commit --message="$TEXT" -n
2|pre-commit-check: bypass=-n|git commit -m "$(cat message)" -n
2|pre-commit-check: bypass=-n|git commit -m "`cat message`" -n
0|-|git commit -m "$TEXT"
0|-|git commit -m "$(echo -n)"
0|-|echo "$HOME"
0|-|ls *.rs
0|-|echo "$HOME git"
0|-|printf "%s" "git"; ls *.rs
0|-|echo "$HOME"; git status
0|-|echo $(date); git status
2|pre-commit-check: bypass=-n|echo $(date); git commit -n -m x
2|pre-commit-check: bypass=-n|echo "$HOME"; git commit -n -m x
2|pre-commit-check: bypass=-n|ls *.rs; git commit -n -m x
0|-|"g"'i'\t "comm"'it' -m x
2|pre-commit-check: bypass=-n|"g"'i'\t "comm"'it' -n -m x
2|pre-commit-check: bypass=-n|g\it comm""it -n -m x
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
2|pre-commit-check: bypass=-n|git commit -m "$TEXT" -n
0|-|cat <<EOF\ngit commit -n\nEOF
0|pre-commit-check: command=unresolved|git commit -m $(cat message) -n
0|pre-commit-check: command=unresolved|git commit -m $TEXT -n
0|pre-commit-check: command=unresolved|git commit -m "$@" -n
0|pre-commit-check: command=unresolved|git commit -m "$(cat message" -n
0|pre-commit-check: command=unresolved|git commit -m x *
ROWS
}
command_rows

quoted_message_rows() {
  local flag command
  for flag in '' -n; do
    command='git commit -m "$(cat <<'"'"'EOF'"'"'
fix: text with ) " $ and -n
EOF
)"'" $flag"
    run_hook "$ARMED" "$(jq -nc --arg c "$command" '{tool_input:{command:$c}}')"
    if [ -n "$flag" ]; then
      assert_eq "rc=$rc first=$(first_line)" 'rc=2 first=pre-commit-check: bypass=-n' 'Claude quoted heredoc preserves a separate option'
    else
      assert_eq "rc=$rc first=$(first_line)" 'rc=0 first=-' 'Claude quoted heredoc stays message data'
    fi
  done
}
quoted_message_rows

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

# The registered commands are the consumers of stdout JSON. Failure worlds
# keep the reader absent or broken while jq in the parent parses that JSON.
context_rows() {
  local harness registry registered install row world form key path status context selected expected
  local repo="$UNARMED" root="${HOOKS_DIR%/hooks}" tool real
  for harness in claude codex copilot pi; do
    case "$harness" in
      claude)
        registry="$root/.claude/settings.json"; install=.claude/hooks/pre-commit-check.sh
        registered=$(jq -er '.hooks[][].hooks[] | select(.command | contains("/pre-commit-check.sh")) | .command' "$registry") ;;
      codex | pi)
        if [ "$harness" = codex ]; then
          registry="$root/.codex/hooks.json"; install=.codex/hooks/pre-commit-check.sh
        else
          registry="$root/.pi/kendex/hooks.json"; install=.pi/kendex/hooks/pre-commit-check.sh
        fi
        registered=$(jq -er '.hooks[][].hooks[] | select(.command | contains("/pre-commit-check.sh")) | .command' "$registry") ;;
      copilot)
        registry="$root/.github/hooks/pre-commit-check.json"; install=.github/hooks/pre-commit-check.sh
        registered=$(jq -er '.hooks.preToolUse[].bash' "$registry") ;;
    esac
    mkdir -p "$repo/${install%/*}"
    if [ "$HOOK" != "$HOOKS_DIR/pre-commit-check.sh" ]; then
      cp "$HOOK" "$repo/$install"
    else
      cp "$root/$install" "$repo/$install"
    fi
    while IFS='|' read -r world form key; do
      [ -n "$world" ] || continue
      path="$TMP_ROOT/context-$world"
      mkdir -p "$path"
      for tool in git grep jq bash cat env printf awk; do
        [ "$world" != "no-$tool" ] || continue
        case "$world:$tool" in broken-jq:jq | broken-cat:cat) continue ;; esac
        real=$(type -P "$tool"); ln -sf "$real" "$path/$tool"
      done
      case "$world" in
        broken-jq | broken-cat)
          tool=${world#broken-}
          printf '#!%s\nprintf '\''reader: cause="\\\\\\""\\t\\001\\n'\'' >&2\nexit 1\n' "$BASH" >"$path/$tool"
          chmod +x "$path/$tool" ;;
      esac
      case "$form" in
        invalid) form='{"tool_input":' ;;
        *) form=$(jq -nc --arg c "$form" '{tool_input:{command:$c}}') ;;
      esac
      status=0
      (cd -- "$repo" && env -i HOME="$TMP_ROOT" PATH="$path" CLAUDE_PROJECT_DIR="$repo" "$BASH" -c "$registered" <<<"$form") >"$OUT_FILE" 2>"$ERR_FILE" || status=$?
      out=$(cat "$OUT_FILE"); err=$(cat "$ERR_FILE")
      if [ "$harness" = copilot ]; then
        selected='.additionalContext'
      else
        selected='if .hookSpecificOutput.hookEventName == "PreToolUse" then .hookSpecificOutput.additionalContext else error end'
      fi
      context=$(jq -er "$selected | select(type == \"string\")" "$OUT_FILE") || context=invalid
      expected="pre-commit-check: $key"
      expected=${expected//REPO/$repo}
      assert_eq "rc=$status first=${err%%$'\n'*}" "rc=0 first=$expected" "registered $harness $world $key notice status"
      assert_eq "$context" "$err" "registered $harness $world $key context equals the keyed diagnostic"
    done <<'ROWS'
tools|git commit -m test|unarmed=REPO
tools|git commit -m $TEXT -n|command=unresolved
tools|invalid|payload=invalid-json
no-jq|git commit -m test|missing-tools=jq
no-cat|git commit -m test|missing-tools=cat
no-grep|git commit -m test|missing-tools=grep
broken-jq|git commit -m test|payload=invalid-json
broken-cat|git commit -m test|payload=read-failed
ROWS
  done
}
context_rows

if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  skill_load_control no-short-flag "$HOOK" 'letter=${rest:0:1}; rest=${rest:1}' 'letter=x' HOOK command_rows \
    'git commit -n -m test'
  skill_load_control no-hook-override "$HOOK" 'CALL_COMMIT=1; CALL_BYPASS=$env_config' 'CALL_BYPASS=""' HOOK command_rows \
    'git -c core.hooksPath=/dev/null commit -m x'
  skill_load_control message-is-option "$HOOK" '      --message | --file | --reuse-message | --reedit-message | --template | --author | --date | --cleanup | --fixup | --squash | --trailer | --pathspec-from-file)' 'i=$((i - 1))' HOOK command_rows \
    "git commit --message $NV"
  skill_load_control ordinary-notice "$HOOK" 'TOKEN_ERROR=""' 'message command unresolved' HOOK command_rows \
    'echo "$HOME git"'
  skill_load_control no-notice-context "$HOOK" '  local text=$NOTICE' 'return 0' HOOK context_rows \
    'registered claude tools unarmed=REPO context equals the keyed diagnostic'
  skill_load_control stop-at-path "$HOOK" '      *) continue ;;' 'break' HOOK command_rows \
    'git commit file -n -m x'
  skill_load_control lose-quoted-option "$HOOK" '  [ -n "$closed" ] || return 1' 'return 1' HOOK quoted_message_rows \
    'Claude quoted heredoc preserves a separate option'
  skill_load_control reader-block "$HOOK" "printf 'pre-commit-check: %s=%s\\n' \"\$1\" \"\$2\"" \
    'case "$1" in missing-tools | payload) exit 2 ;; esac' HOOK payload_rows \
    'without jq the refusing command is refused unread rather than guessed at'
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
