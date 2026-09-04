#!/usr/bin/env bash
# ---
# name: command-safety
# event: PreToolUse
# matcher: Bash
# description: Refuse shell tool command text matching COMMAND_SAFETY_DENY_PATTERN from project settings. Install the command-safety bundle and configure a nonempty POSIX ERE before using the hook. Matching is textual, including quoted text, and does not inspect the desktop or running processes.
# safety: Blocks configured command patterns before the shell tool runs. Unreadable input, missing settings support, and invalid or empty patterns refuse execution.
# timeout: 10
# ---

set -Eeuo pipefail

refuse() { printf 'command-safety: %s\n' "$1" >&2; exit 2; }
trap 'refuse "the command safety check could not complete"' ERR
for dependency in jq git grep cat; do
  command -v "$dependency" >/dev/null 2>&1 || refuse "$dependency is required"
done
input="$(cat)" || refuse "could not read the hook input"
command_text="$(jq -r '
  [.tool_input.command, .tool_input.cmd, .command, .cmd]
  | map(select(. != null))
  | if length == 0 then "" else .[0] end
  | if type == "string" then .
    elif type == "array" and all(.[]; type == "string") then join(" ")
    else error("invalid command") end
' <<<"$input" 2>/dev/null)" || refuse "invalid JSON or command input"
[ -n "$command_text" ] || exit 0
cwd="$(jq -r 'if .cwd == null then "" elif .cwd | type == "string" then .cwd else error("invalid cwd") end' <<<"$input" 2>/dev/null)" || refuse "invalid working directory"
[ -n "$cwd" ] || cwd="$PWD"
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || refuse "project settings require a Git working directory"

lib="$root/.agents/skills/growth-guards/scripts/lib"
if [ ! -f "$lib/settings.sh" ]; then
  # Copy delivery keeps the dependency beside the harness's hook directory.
  at="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || refuse "could not locate the hook"
  while [ "$at" != "$root" ] && [ "$at" != / ]; do
    if [ -f "$at/skills/growth-guards/scripts/lib/settings.sh" ]; then
      lib="$at/skills/growth-guards/scripts/lib"
      break
    fi
    at="${at%/*}"
    [ -n "$at" ] || at=/
  done
fi
[ -f "$lib/common.sh" ] && [ -f "$lib/settings.sh" ] || refuse "the command-safety bundle requires the installed growth-guards settings loader"
GG_CHECK=command-safety
# shellcheck source=../skills/growth-guards/scripts/lib/common.sh
source "$lib/common.sh"
# shellcheck source=../skills/growth-guards/scripts/lib/settings.sh
source "$lib/settings.sh"
cd -- "$root" || refuse "could not read project settings"
pattern="$(gg_setting COMMAND_SAFETY_DENY_PATTERN "")" || refuse "could not read COMMAND_SAFETY_DENY_PATTERN"
[ -n "$pattern" ] || refuse "COMMAND_SAFETY_DENY_PATTERN must be configured"
status=0
printf '%s\n' "$command_text" | LC_ALL=C grep -E -- "$pattern" >/dev/null || status=$?
case "$status" in
  0) refuse "command text matches COMMAND_SAFETY_DENY_PATTERN" ;;
  1) exit 0 ;;
  *) refuse "COMMAND_SAFETY_DENY_PATTERN is not a readable POSIX ERE" ;;
esac
