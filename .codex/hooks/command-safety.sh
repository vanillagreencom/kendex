#!/usr/bin/env bash
# ---
# name: command-safety
# event: PreToolUse
# matcher: Bash
# description: On harnesses that execute hooks, refuse shell tool command text matching COMMAND_SAFETY_DENY_PATTERN from project settings. An absent policy is inactive. Matching is textual, including quoted text, and does not inspect the desktop or running processes.
# safety: When executed with a configured policy, blocks matching command text before the shell tool runs. Unreadable input, missing settings support, and invalid or explicitly empty patterns refuse execution.
# timeout: 10
# ---

set -euo pipefail

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `command-safety: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, the state of the project policy, or the exit
# status of a check that did not complete. The English explanation follows it.
# The EXIT trap below calls this, so the whole message is one group that
# cannot carry a failure out: a write that fails there would leave with the
# writer's status rather than the refusal's, which the harness runs past.
refuse() { # KEY VALUE
  {
    printf 'command-safety: %s=%s\n' "$1" "$2"
    case "$1=$2" in
      tools=*) echo "$2 is required" ;;
      payload=unreadable) echo "the hook input could not be read" ;;
      payload=invalid-json) echo "the hook input is not valid JSON, or names no command this hook can read" ;;
      payload=invalid-cwd) echo "the payload's working directory is not a string" ;;
      cwd=*) echo "the working directory $2 could not be entered" ;;
      git=unreadable) echo "the Git working directory could not be resolved" ;;
      hook=unlocatable) echo "this hook's own directory could not be read, so its installed dependencies cannot be found" ;;
      settings=no-loader) echo "the command-safety bundle requires the installed commit-guards settings loader" ;;
      settings=unreadable) echo "COMMAND_SAFETY_DENY_PATTERN could not be read" ;;
      settings=empty) echo "COMMAND_SAFETY_DENY_PATTERN must be configured" ;;
      settings=invalid-pattern) echo "COMMAND_SAFETY_DENY_PATTERN is not a readable POSIX ERE" ;;
      refused=policy) echo "the command text matches this project's COMMAND_SAFETY_DENY_PATTERN" ;;
      exit=*) echo "the command safety check could not complete" ;;
    esac
  } >&2 || :
  exit 2
}
# An exit that is neither a verdict (0) nor a refusal (2) is a check that did
# not complete, and it leaves as a refusal. The EXIT trap is what reaches every
# such exit on Bash 3.2 too: an ERR trap inherited through `set -E` fires there
# inside a command substitution even when the substitution stands on the left
# of `||`, which reads the settings loader's guarded probes as failures.
trap 'rc=$?; case $rc in 0 | 2) ;; *) refuse exit "$rc" ;; esac' EXIT
for dependency in jq git grep cat; do
  command -v "$dependency" >/dev/null 2>&1 || refuse tools "$dependency"
done
input="$(cat)" || refuse payload unreadable
command_text="$(jq -r '
  def command_arg:
    if type == "object" then (.command // .cmd)
    elif type == "string" then
      (try fromjson catch null)
      | if type == "object" then (.command // .cmd) else null end
    else null end;
  [.tool_input.command, .tool_input.cmd, (.toolArgs | command_arg), .command, .cmd]
  | map(select(. != null))
  | if length == 0 then error("missing command") else .[0] end
  | if type == "string" then .
    elif type == "array" and all(.[]; type == "string") then join(" ")
    else error("invalid command") end
' <<<"$input" 2>/dev/null)" || refuse payload invalid-json
[ -n "$command_text" ] || exit 0
cwd="$(jq -r 'if .cwd == null then "" elif .cwd | type == "string" then .cwd else error("invalid cwd") end' <<<"$input" 2>/dev/null)" || refuse payload invalid-cwd
[ -n "$cwd" ] || cwd="$PWD"
cwd="$(cd -- "$cwd" && pwd -P)" || refuse cwd "$cwd"
root_status=0
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || root_status=$?
if [ "$root_status" -ne 0 ]; then
  at="$cwd"
  while [ "$at" != / ]; do
    if [ -e "$at/.git" ] || [ -L "$at/.git" ]; then
      refuse git unreadable
    fi
    at="${at%/*}"
    [ -n "$at" ] || at=/
  done
  exit 0
fi

lib=
hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || refuse hook unlocatable
at="$hook_dir"
levels=0
# Registered hook layouts keep the scope's skills one or two directories
# above hooks. A wider walk can reach executable files outside the install.
while [ "$levels" -lt 3 ] && [ "$at" != "$root" ] && [ "$at" != / ]; do
  candidate="$at/skills/commit-guards/scripts/lib"
  if [ -e "$candidate/common.sh" ] || [ -L "$candidate/common.sh" ] \
    || [ -e "$candidate/settings.sh" ] || [ -L "$candidate/settings.sh" ]; then
    lib="$candidate"
    break
  fi
  at="${at%/*}"
  [ -n "$at" ] || at=/
  levels=$((levels + 1))
done
if [ -z "$lib" ]; then
  case "$hook_dir" in
    "$root"/*) lib="$root/.agents/skills/commit-guards/scripts/lib" ;;
  esac
fi
[ -f "$lib/common.sh" ] && [ -f "$lib/settings.sh" ] || refuse settings no-loader
GG_CHECK=command-safety
# shellcheck source=../skills/commit-guards/scripts/lib/common.sh
source "$lib/common.sh"
# shellcheck source=../skills/commit-guards/scripts/lib/settings.sh
source "$lib/settings.sh"
cd -- "$root" || refuse cwd "$root"
# The loader's own diagnostic is dropped so the refusal's keyed line is the
# first line of this hook's stderr; the same settings error reaches the author
# from the commit-guards chain, which reads the file on every commit.
pattern="$(gg_setting COMMAND_SAFETY_DENY_PATTERN "^$" 2>/dev/null)" || refuse settings unreadable
[ -n "$pattern" ] || refuse settings empty
[ "$pattern" != '^$' ] || exit 0
status=0
# grep's own words on a pattern it cannot read are dropped: the status says
# which case it is, and the refusal's keyed line leads instead.
printf '%s\n' "$command_text" | LC_ALL=C grep -E -- "$pattern" >/dev/null 2>&1 || status=$?
case "$status" in
  0) refuse refused policy ;;
  1) exit 0 ;;
  *) refuse settings invalid-pattern ;;
esac
