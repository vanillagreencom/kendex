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

refuse() { printf 'command-safety: %s\n' "$1" >&2; exit 2; }
# An exit that is neither a verdict (0) nor a refusal (2) is a check that did
# not complete, and it leaves as a refusal. The EXIT trap is what reaches every
# such exit on Bash 3.2 too: an ERR trap inherited through `set -E` fires there
# inside a command substitution even when the substitution stands on the left
# of `||`, which reads the settings loader's guarded probes as failures.
trap 'rc=$?; case $rc in 0 | 2) ;; *) printf "command-safety: the command safety check could not complete (exit %s)\n" "$rc" >&2 || :; exit 2 ;; esac' EXIT
for dependency in jq git grep cat; do
  command -v "$dependency" >/dev/null 2>&1 || refuse "$dependency is required"
done
input="$(cat)" || refuse "could not read the hook input"
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
' <<<"$input" 2>/dev/null)" || refuse "invalid JSON or command input"
[ -n "$command_text" ] || exit 0
cwd="$(jq -r 'if .cwd == null then "" elif .cwd | type == "string" then .cwd else error("invalid cwd") end' <<<"$input" 2>/dev/null)" || refuse "invalid working directory"
[ -n "$cwd" ] || cwd="$PWD"
cwd="$(cd -- "$cwd" && pwd -P)" || refuse "invalid working directory"
root_status=0
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || root_status=$?
if [ "$root_status" -ne 0 ]; then
  at="$cwd"
  while [ "$at" != / ]; do
    if [ -e "$at/.git" ] || [ -L "$at/.git" ]; then
      refuse "could not resolve the Git working directory"
    fi
    at="${at%/*}"
    [ -n "$at" ] || at=/
  done
  exit 0
fi

lib=
hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || refuse "could not locate the hook"
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
[ -f "$lib/common.sh" ] && [ -f "$lib/settings.sh" ] || refuse "the command-safety bundle requires the installed commit-guards settings loader"
GG_CHECK=command-safety
# shellcheck source=../skills/commit-guards/scripts/lib/common.sh
source "$lib/common.sh"
# shellcheck source=../skills/commit-guards/scripts/lib/settings.sh
source "$lib/settings.sh"
cd -- "$root" || refuse "could not read project settings"
pattern="$(gg_setting COMMAND_SAFETY_DENY_PATTERN "^$")" || refuse "could not read COMMAND_SAFETY_DENY_PATTERN"
[ -n "$pattern" ] || refuse "COMMAND_SAFETY_DENY_PATTERN must be configured"
[ "$pattern" != '^$' ] || exit 0
status=0
printf '%s\n' "$command_text" | LC_ALL=C grep -E -- "$pattern" >/dev/null || status=$?
case "$status" in
  0) refuse "command text matches COMMAND_SAFETY_DENY_PATTERN" ;;
  1) exit 0 ;;
  *) refuse "COMMAND_SAFETY_DENY_PATTERN is not a readable POSIX ERE" ;;
esac
