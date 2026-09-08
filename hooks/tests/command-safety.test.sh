#!/usr/bin/env bash
# Tests for the command-safety hook. It applies whatever
# COMMAND_SAFETY_DENY_PATTERN the project ships, and every refusal opens with
# `command-safety: <key>=<value>` — the key naming the condition, the value
# naming the state of the policy or the status a check left. `check` asserts
# the exit status of a row; `assert_first` pins the line the refusal opened
# with, which is what a reader parses.
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

settings() { # [SOURCE_FILE]: the file whose one COMMAND_SAFETY_DENY_PATTERN line becomes the policy
  local source="${1:-$ROOT/docs/authoring/command-safety.md}"
  printf '[env]\n' >"$repo/kendex.settings.toml"
  awk '/^COMMAND_SAFETY_DENY_PATTERN = / { print; found++ } END { if (found != 1) { printf "%s: expected one COMMAND_SAFETY_DENY_PATTERN line, found %d\n", FILENAME, found > "/dev/stderr"; exit 1 } }' \
    "$source" >>"$repo/kendex.settings.toml"
}
settings
passed=0
failed=0
# `first` is line 1, the contract: the hook captures what a command it ran
# wrote and replays it under the keyed line, so nothing precedes the key.
# `cause` says whether that captured text is there. The reader is the shared
# one; this suite writes stderr somewhere of its own, so it passes the path.
first=-
# shellcheck source=lib/first-line.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/first-line.sh"
check() { # EXPECTED COMMAND LABEL [CWD] [HOOK]
  local expected="$1" command="$2" label="$3" payload_cwd="${4:-$repo}" payload_hook="${5:-$hook}" payload status=0 output
  payload="$(jq -nc --arg command "$command" --arg cwd "$payload_cwd" '{tool_input:{command:$command},cwd:$cwd}')"
  output="$(printf '%s' "$payload" | bash "$payload_hook" 2>"$scratch/stderr")" || status=$?
  first="$(first_line "$scratch/stderr")"
  cause="$(cause_below "$scratch/stderr")"
  if [ "$status" -eq "$expected" ]; then
    printf 'PASS %s\n' "$label"
    passed=$((passed + 1))
  else
    printf 'FAIL %s: exit %s, expected %s: %s%s\n' "$label" "$status" "$expected" "$output" "$(cat "$scratch/stderr")"
    failed=$((failed + 1))
  fi
}

assert_cause() { # WANT LABEL
  if [ "$cause" = "$1" ]; then
    printf 'PASS %s\n' "$2"
    passed=$((passed + 1))
  else
    printf 'FAIL %s: cause %s, expected %s\n' "$2" "$cause" "$1"
    failed=$((failed + 1))
  fi
}

# What a probe says here is what the hook must have replayed: the row runs
# the same command rather than pinning a wording, so it holds on any platform
# and on any version of the tool. `cause=present` cannot serve this — the
# hook's own English is also a line under line 1.
assert_replays() { # PROBE_OUTPUT LABEL
  if [ -z "$1" ]; then
    printf 'FAIL %s: the probe said nothing, so the row would pass on anything\n' "$2"
    failed=$((failed + 1))
    return
  fi
  case "$(cat "$scratch/stderr")" in
    *"$1"*)
      printf 'PASS %s\n' "$2"
      passed=$((passed + 1))
      ;;
    *)
      printf 'FAIL %s: the cause is not under the keyed line: %s\n' "$2" "$(cat "$scratch/stderr")"
      failed=$((failed + 1))
      ;;
  esac
}

assert_first() { # WANT LABEL
  if [ "$first" = "$1" ]; then
    printf 'PASS %s\n' "$2"
    passed=$((passed + 1))
  else
    printf 'FAIL %s: first line %s, expected %s\n' "$2" "$first" "$1"
    failed=$((failed + 1))
  fi
}
# The two shipped policies, kendex.settings.toml's own value and the example in
# docs/authoring/command-safety.md, are the repository's content rather than
# this hook's behaviour; a tools/guard lane owns them, with its control in
# tools/tests/guard.test.sh. What stays here is that the hook applies whatever
# policy it is given: a project pattern refuses, and a command outside it does
# not, whichever project ships the pattern.
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "^never-matches-anything$"\n' \
  >"$repo/kendex.settings.toml"
check 0 'systemd-run --user --scope -p MemoryMax=64M cargo test -p kendex-core' 'the memory-cap refusal is the project pattern, not the hook'
settings

printf '[env]\n' >"$repo/kendex.settings.toml"
check 0 'git status' 'an unconfigured project leaves the hook inactive'
check 0 'git status' 'a global hook outside Git leaves the hook inactive' /
mkdir -p "$scratch/outside"
printf 'gitdir: /missing\n' >"$scratch/outside/.git"
check 2 'git status' 'an unresolved Git worktree refuses' "$scratch/outside"
assert_first 'command-safety: git=unreadable' 'and the git key names the working directory it could not resolve'
assert_replays "$(git -C "$scratch/outside" rev-parse --show-toplevel 2>&1 || true)" \
  "and git's own words on the entry it could not read stand under it"
mv "$scratch/outside/.git" "$scratch/unresolved-git-marker"
printf '[env\n' >"$repo/kendex.settings.toml"
check 2 'git status' 'malformed project settings refuse'
assert_first 'command-safety: settings=unreadable' 'and the value says the settings could not be read'
assert_cause present "and the loader's own words are replayed under it"
settings

# Every payload shape a shipped harness sends, each counted as a row rather
# than a bare FAIL: the two spellings of the command field, an argument array,
# and Copilot's object and string forms in both directions.
shape() { # EXPECTED FIRST PAYLOAD_JSON LABEL
  local expected="$1" want_first="$2" payload="$3" label="$4" status=0 output
  output="$(printf '%s' "$payload" | bash "$hook" 2>"$scratch/stderr")" || status=$?
  first="$(first_line "$scratch/stderr")"
  cause="$(cause_below "$scratch/stderr")"
  # The status alone cannot tell a refusal for the right reason from one for
  # the wrong reason, and every shape here is meant to reach the policy.
  if [ "$status" -eq "$expected" ] && [ "$first" = "$want_first" ]; then
    printf 'PASS %s\n' "$label"
    passed=$((passed + 1))
  else
    printf 'FAIL %s: exit %s (want %s), first %s (want %s)\n' \
      "$label" "$status" "$expected" "$first" "$want_first"
    failed=$((failed + 1))
  fi
}
# The table counts its own rows: an emptied row list is a refusal, never a
# silently shorter run.
before=$((passed + failed))
while IFS='|' read -r expected want_first filter label; do
  [ -n "$expected" ] || continue
  [ "$want_first" != - ] || want_first='-'
  shape "$expected" "$want_first" "$(jq -nc --arg cwd "$repo" "$filter")" "$label"
done <<'SHAPES'
2|command-safety: refused=policy|{tool_input:{cmd:"qs -c vshell"},cwd:$cwd}|a refused command under the cmd field
2|command-safety: refused=policy|{tool_input:{command:["qs","-c","vshell"]},cwd:$cwd}|a refused command as an argument array
2|command-safety: refused=policy|{toolName:"bash",toolArgs:{command:"qs -c vshell"},cwd:$cwd}|a refused command under a Copilot toolArgs object
0|-|{toolName:"bash",toolArgs:{command:"git status"},cwd:$cwd}|an allowed command under a Copilot toolArgs object
2|command-safety: refused=policy|{toolName:"bash",toolArgs:"{\"command\":\"qs -c vshell\"}",cwd:$cwd}|a refused command under a Copilot toolArgs string
0|-|{toolName:"bash",toolArgs:"{\"command\":\"git status\"}",cwd:$cwd}|an allowed command under a Copilot toolArgs string
SHAPES
[ "$((passed + failed))" -gt "$before" ] || { printf 'FAIL no payload shape was asserted\n'; failed=$((failed + 1)); }

# A cwd the payload names and the hook cannot enter: the value is the path as
# it was requested, not the empty string the failed probe would leave behind.
check 2 'git status' 'a cwd that cannot be entered refuses' "$scratch/gone"
assert_first "command-safety: cwd=$scratch/gone" 'and the value is the path the payload asked for'

# Every external command this hook runs, one world each: without dirname it
# cannot find its own directory, and the refusal must still open with the key.
nodirname="$scratch/nodirname"
mkdir -p "$nodirname"
for tool in jq git grep cat; do
  ln -sf "$(command -v "$tool")" "$nodirname/$tool"
done
# And a world holding none of them: the value is the whole list, in check
# order, which a one-tool world cannot tell from an accumulator that
# overwrites instead of appending.
notools="$scratch/notools"
mkdir -p "$notools"
status=0
out="$(jq -nc --arg cwd "$repo" '{tool_input:{command:"git status"},cwd:$cwd}' \
  | env -i HOME="$HOME" PATH="$notools" "$(command -v bash)" "$hook" 2>&1 >/dev/null)" || status=$?
keyed="${out%%$'\n'*}"
if [ "$status" -eq 2 ] && [ "$keyed" = 'command-safety: missing-tools=jq,git,grep,cat,dirname' ]; then
  printf 'PASS with none of them the value is the whole list, in check order\n'
  passed=$((passed + 1))
else
  printf 'FAIL with none of them the value is the whole list: exit %s, keyed line %s\n' "$status" "$keyed"
  failed=$((failed + 1))
fi

status=0
out="$(jq -nc --arg cwd "$repo" '{tool_input:{command:"git status"},cwd:$cwd}' \
  | env -i HOME="$HOME" PATH="$nodirname" "$(command -v bash)" "$hook" 2>&1 >/dev/null)" || status=$?
keyed="${out%%$'\n'*}"
if [ "$status" -eq 2 ] && [ "$keyed" = 'command-safety: missing-tools=dirname' ]; then
  printf 'PASS without dirname the refusal names it\n'
  passed=$((passed + 1))
else
  printf 'FAIL without dirname the refusal names it: exit %s, keyed line %s\n' "$status" "$keyed"
  failed=$((failed + 1))
fi

printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "^other-command$"\n' >"$repo/kendex.settings.toml"
check 0 'qs -c vshell' 'policy is configured, not tied to Quickshell'
check 2 'other-command' 'a different project policy takes effect'
assert_first 'command-safety: refused=policy' 'a command the policy matches names the policy'
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "BLOCK_THIS"\n' >"$repo/kendex.settings.toml"
check 2 "printf '%s' 'BLOCK_THIS'" 'matching quoted text is still refused'
check 0 'git status' 'a command outside the policy passes'
assert_first - 'a command it allows says nothing at all'

# Every state of the policy the hook can find, each its own value under the
# settings key, so a reader tells a broken pattern from an absent one.
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "["\n' >"$repo/kendex.settings.toml"
check 2 'scripts/validate qml' 'invalid pattern refuses'
assert_first 'command-safety: settings=invalid-pattern' 'and the value says the pattern is unreadable'
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = ""\n' >"$repo/kendex.settings.toml"
check 2 'scripts/validate qml' 'empty pattern refuses'
assert_first 'command-safety: settings=empty' 'and the value says the pattern is empty'
settings
before=$((passed + failed))
while IFS='|' read -r payload label; do
  [ -n "$payload" ] || continue
  shape 2 'command-safety: payload=invalid-json' "$payload" "$label"
done <<'PAYLOADS'
not JSON|a payload that is not JSON is refused unread
{"tool_input":{"command":false}}|a command that is not a string is refused unread
{"tool_input":{}}|a payload naming no command is refused unread
PAYLOADS
[ "$((passed + failed))" -gt "$before" ] || { printf 'FAIL no unreadable payload was asserted\n'; failed=$((failed + 1)); }

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
assert_first 'command-safety: settings=no-loader' 'and the settings key names the missing loader'
[ ! -e "$hostile_marker" ] || { printf 'FAIL missing global support ran the project loader\n'; failed=$((failed + 1)); }

settings
mkdir -p "$repo/.claude/skills/commit-guards/scripts"
mv "$repo/.agents/skills/commit-guards/scripts/lib" "$repo/.claude/skills/commit-guards/scripts/lib"
check 2 'qs -c vshell' 'copy delivery finds the installed dependency'
check 0 'scripts/validate qml' 'copy delivery allows validation'
printf 'return 1\n' >"$repo/.claude/skills/commit-guards/scripts/lib/common.sh"
check 2 'scripts/validate qml' 'a failed settings loader refuses with the blocking exit code'
assert_first 'command-safety: exit=1' 'and the exit key carries the status the check left'
mv "$repo/.claude/skills/commit-guards/scripts/lib" "$scratch/absent-lib"
check 2 'scripts/validate qml' 'missing settings support refuses'
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
