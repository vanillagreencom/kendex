#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$ROOT/tmp"
scratch="$(mktemp -d "$ROOT/tmp/command-safety.XXXXXX")" || exit 1
trap 'rm -rf -- "$scratch"' EXIT
repo="$scratch/project"
mkdir -p "$repo/.claude/hooks" "$repo/.agents/skills/commit-guards/scripts"
git -C "$repo" init -q
cp "$ROOT/hooks/command-safety.sh" "$repo/.claude/hooks/command-safety.sh"
cp -R "$ROOT/skills/commit-guards/scripts/lib" "$repo/.agents/skills/commit-guards/scripts/lib"
hook="$repo/.claude/hooks/command-safety.sh"
unset COMMAND_SAFETY_DENY_PATTERN COMMIT_GUARDS_SETTINGS_FILE

settings() {
  printf '[env]\n' >"$repo/kendex.settings.toml"
  awk '/^COMMAND_SAFETY_DENY_PATTERN = / { print; found++ } END { if (found != 1) exit 1 }' \
    "$ROOT/docs/authoring/command-safety.md" >>"$repo/kendex.settings.toml"
}
settings
passed=0
failed=0
check() { # EXPECTED COMMAND LABEL
  local expected="$1" command="$2" label="$3" payload_cwd="${4:-$repo}" payload_hook="${5:-$hook}" payload status=0 output
  payload="$(jq -nc --arg command "$command" --arg cwd "$payload_cwd" '{tool_input:{command:$command},cwd:$cwd}')"
  output="$(printf '%s' "$payload" | bash "$payload_hook" 2>&1)" || status=$?
  if [ "$status" -eq "$expected" ]; then
    printf 'PASS %s\n' "$label"
    passed=$((passed + 1))
  else
    printf 'FAIL %s: exit %s, expected %s: %s\n' "$label" "$status" "$expected" "$output"
    failed=$((failed + 1))
  fi
}
check 2 'qs -c vshell' 'live config launch'
check 2 'qs -p quickshell/vshell' 'live path launch'
check 2 'pkill quickshell' 'broad process-name kill'
check 2 'pkill -f quickshell' 'process kill with flags'
check 2 'git status && qs -c vshell' 'launch in a compound command'
check 0 'scripts/validate qml' 'isolated validation'
check 0 'git status' 'unrelated shell command'
check 0 'qs -c test-fixture' 'a different configured shell'

printf '[env]\n' >"$repo/kendex.settings.toml"
check 0 'git status' 'an unconfigured project leaves the hook inactive'
check 0 'git status' 'a global hook outside Git leaves the hook inactive' /
mkdir -p "$scratch/outside"
printf 'gitdir: /missing\n' >"$scratch/outside/.git"
check 2 'git status' 'an unresolved Git worktree refuses' "$scratch/outside"
mv "$scratch/outside/.git" "$scratch/unresolved-git-marker"
printf '[env\n' >"$repo/kendex.settings.toml"
check 2 'git status' 'malformed project settings refuse'
settings

status=0
jq -nc --arg cwd "$repo" '{tool_input:{cmd:"qs -c vshell"},cwd:$cwd}' | bash "$hook" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || { printf 'FAIL cmd input\n'; failed=$((failed + 1)); }
status=0
jq -nc --arg cwd "$repo" '{tool_input:{command:["qs","-c","vshell"]},cwd:$cwd}' | bash "$hook" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || { printf 'FAIL argument-array input\n'; failed=$((failed + 1)); }
status=0
jq -nc --arg cwd "$repo" '{toolName:"bash",toolArgs:{command:"qs -c vshell"},cwd:$cwd}' | bash "$hook" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || { printf 'FAIL Copilot object input\n'; failed=$((failed + 1)); }
status=0
jq -nc --arg cwd "$repo" '{toolName:"bash",toolArgs:{command:"git status"},cwd:$cwd}' | bash "$hook" >/dev/null 2>&1 || status=$?
[ "$status" -eq 0 ] || { printf 'FAIL allowed Copilot object input\n'; failed=$((failed + 1)); }
status=0
jq -nc --arg cwd "$repo" '{toolName:"bash",toolArgs:"{\"command\":\"qs -c vshell\"}",cwd:$cwd}' | bash "$hook" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || { printf 'FAIL Copilot string input\n'; failed=$((failed + 1)); }
status=0
jq -nc --arg cwd "$repo" '{toolName:"bash",toolArgs:"{\"command\":\"git status\"}",cwd:$cwd}' | bash "$hook" >/dev/null 2>&1 || status=$?
[ "$status" -eq 0 ] || { printf 'FAIL allowed Copilot string input\n'; failed=$((failed + 1)); }

printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "^other-command$"\n' >"$repo/kendex.settings.toml"
check 0 'qs -c vshell' 'policy is configured, not tied to Quickshell'
check 2 'other-command' 'a different project policy takes effect'
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "BLOCK_THIS"\n' >"$repo/kendex.settings.toml"
check 2 "printf '%s' 'BLOCK_THIS'" 'matching quoted text is still refused'

printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "["\n' >"$repo/kendex.settings.toml"
check 2 'scripts/validate qml' 'invalid pattern refuses'
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = ""\n' >"$repo/kendex.settings.toml"
check 2 'scripts/validate qml' 'empty pattern refuses'
for payload in 'not JSON' '{"tool_input":{"command":false}}' '{"tool_input":{}}'; do
  status=0
  printf '%s' "$payload" | bash "$hook" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || { printf 'FAIL invalid input\n'; failed=$((failed + 1)); }
done

global="$scratch/global/.claude"
hostile="$scratch/hostile"
mkdir -p "$global/hooks" "$global/skills/commit-guards/scripts" "$hostile/.agents/skills/commit-guards/scripts/lib"
git -C "$hostile" init -q
cp "$ROOT/hooks/command-safety.sh" "$global/hooks/command-safety.sh"
cp -R "$ROOT/skills/commit-guards/scripts/lib" "$global/skills/commit-guards/scripts/lib"
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "BLOCK_THIS"\n' >"$hostile/kendex.settings.toml"
hostile_marker="$scratch/hostile-loader-ran"
printf 'printf ran >"%s"\nreturn 1\n' "$hostile_marker" >"$hostile/.agents/skills/commit-guards/scripts/lib/common.sh"
cp "$ROOT/skills/commit-guards/scripts/lib/settings.sh" "$hostile/.agents/skills/commit-guards/scripts/lib/settings.sh"
check 0 'git status' 'global delivery prefers its installed loader' "$hostile" "$global/hooks/command-safety.sh"
[ ! -e "$hostile_marker" ] || { printf 'FAIL global delivery ran the project loader\n'; failed=$((failed + 1)); }
mv "$global/skills/commit-guards/scripts/lib" "$scratch/absent-global-lib"
check 2 'git status' 'missing global support refuses without a project fallback' "$hostile" "$global/hooks/command-safety.sh"
[ ! -e "$hostile_marker" ] || { printf 'FAIL missing global support ran the project loader\n'; failed=$((failed + 1)); }

settings
mkdir -p "$repo/.claude/skills/commit-guards/scripts"
mv "$repo/.agents/skills/commit-guards/scripts/lib" "$repo/.claude/skills/commit-guards/scripts/lib"
check 2 'qs -c vshell' 'copy delivery finds the installed dependency'
check 0 'scripts/validate qml' 'copy delivery allows validation'
printf 'return 1\n' >"$repo/.claude/skills/commit-guards/scripts/lib/common.sh"
check 2 'scripts/validate qml' 'a failed settings loader refuses with the blocking exit code'
mv "$repo/.claude/skills/commit-guards/scripts/lib" "$scratch/absent-lib"
check 2 'scripts/validate qml' 'missing settings support refuses'
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
