#!/usr/bin/env bash
# ---
# name: block-argv-kill
# event: PreToolUse
# matcher: Bash
# description: Refuse a command that kills processes by name or by argv pattern (`pkill`, `killall`), whatever flags follow. On a machine where several agents share one checkout and its worktrees, a pattern that matches a tool's name matches every lane running that tool, the caller's own shell included when its command line holds the pattern. Names the accepted forms: `kill <pid>` on a PID the caller recorded when it launched the process, or one whose `/proc/<pid>/cwd` the caller has read and found inside its own worktree.
# summary: Stops executable pkill and killall commands. Ordinary quoted arguments and here-document data pass. Missing tools or unreadable input produce one warning and allow the call.
# safety: Advisory reader: dependency or payload failures warn once and allow the call. Executable command matches retain exit 2. The commit-guards command-position reader selects command words and masks quoted data and data-only here-document bodies. This is a lexical check; assembled command names and unknown launcher option forms are outside its contract. Every diagnostic starts with block-argv-kill: <key>=<value>.
# timeout: 10
# requires-skills: [commit-guards]
# ---

set -euo pipefail
trap 'rc=$?; case $rc in 0 | 2) ;; *) refuse exit "$rc" ;; esac' EXIT

# The command as it was read, empty until the reader has it: the refusal quotes
# it, and a refusal can be reached before it is set.
COMMAND=""
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `block-argv-kill: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, or the verb the command spelled. The English
# explanation and the remedy follow on later lines.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
refuse() { # KEY VALUE [CAUSE]
  printf 'block-argv-kill: %s=%s\n' "$1" "$2" >&2
  case "$1=$2" in
    missing-tools=*)
      echo "the commands ${2//,/, } are required to read the hook payload and are not on PATH; this check is unavailable" >&2
      ;;
    payload=unreadable)
      echo "the hook payload could not be read from stdin; this check is unavailable" >&2
      ;;
    payload=empty)
      echo "the hook payload is empty, which would read as an absent command; this check is unavailable" >&2
      ;;
    payload=invalid-json)
      echo "the hook payload is not valid JSON, or names a command that is not a string; this check is unavailable" >&2
      ;;
    refused=*)
      echo "refusing a kill by process name or argv pattern:" >&2
      echo "  $COMMAND" >&2
      echo "On a shared machine the pattern matches every lane running that tool, and the caller's own shell when its command line holds the pattern." >&2
      echo "Kill one process you can name instead:" >&2
      echo "  kill <pid>                  a PID you recorded when you launched it" >&2
      echo "  readlink /proc/<pid>/cwd    then kill it only if that path is inside your own worktree" >&2
      echo "pgrep and ps are fine for finding a PID; the kill itself takes the PID." >&2
      ;;
  esac
  # The cause a command this hook ran wrote, captured at the site and replayed
  # here: under the keyed line, never ahead of it.
  [ -z "${3:-}" ] || printf '%s\n' "$3" >&2
  case "$1" in
    refused | path) exit 2 ;;
    *)
      echo "Check skipped. Repair the hook installation, tools or payload adapter; retry the command." >&2
      exit 0 ;;
  esac
}

# jq is the only reader of the payload. Without it the command cannot be read,
# and a command this hook has not read cannot be shown to name a PID. The value
# names every one of them the PATH is missing, in the order checked.
MISSING=""
for dependency in jq cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

# cat's words are captured, not left to precede the refusal: on failure the
# substitution holds what it wrote, and the refusal replays it under the keyed
# line. A cat that succeeds is silent, so the payload is not mixed with a
# diagnostic on the passing side.
INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"
# An empty payload is no payload: jq reads nothing from it and says nothing,
# which would pass as an absent command.
case "$INPUT" in
  *[![:space:]]*) ;;
  *) refuse payload empty ;;
esac

# A payload that does not parse, or that names a command which is not a
# string, produces a warning and allows the call. An absent command is the empty
# string and passes. The command is read where each harness carries it:
# `tool_input.command` (Claude Code, Codex, Gemini CLI and the Pi carrier), a
# bare `command`, or Copilot's `toolArgs.command`, whose `toolArgs` arrives as
# an object or as one JSON-encoded string. The null tests are spelled out
# because jq's `//` reads `false` as absent, and `false` is not a command
# either.
COMMAND=$(printf '%s' "$INPUT" \
  | jq -er 'def copilot: .toolArgs
             | if . == null then null elif type == "string" then fromjson else . end
             | if . == null then null elif type == "object" then .command else error end;
           if .tool_input.command != null then .tool_input.command
           elif .command != null then .command
           elif copilot != null then copilot
           else "" end
           | if type == "string" then . else error end' 2>/dev/null) ||
  refuse payload invalid-json

# Resolve only this hook's installed dependency, never a payload-selected path.
reader=""
for candidate in "${BASH_SOURCE[0]%/*}/../skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../.agents/skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../../.agents/skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../../../.agents/skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../../skills/commit-guards/scripts/lib/command-position.sh" \
  "${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib/command-position.sh}"; do
  if [ -f "$candidate" ]; then reader=$candidate; break; fi
done
[ -n "$reader" ] || refuse reader unavailable
# shellcheck source=../skills/commit-guards/scripts/lib/command-position.sh
source "$reader" 2>/dev/null || refuse reader unreadable
KILL_RE='^(pkill|killall)($|[[:space:]])'
command_segments "$COMMAND"
while IFS= read -r segment; do
  command_text "$segment"
  if [[ $COMMAND_TEXTS =~ $KILL_RE ]]; then refuse refused "${BASH_REMATCH[1]}"; fi
done <<<"$SEGMENTS"
exit 0
