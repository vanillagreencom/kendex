#!/usr/bin/env bash
# ---
# name: block-bare-cd
# event: PreToolUse
# matcher: Bash
# description: Not run on codex: each shell call starts a fresh process. Not run on pi: each shell call starts a fresh process. Not run on antigravity: its toolCall.args payload is not read. Refuse a command with a line that is only a `cd`. A here-document body read by a proven simple data command is not judged. Here-documents with groups, control operators or substitutions can warn or refuse when their bodies hold guarded text. Where the shell persists across tool calls (Claude Code) a bare cd re-roots every later command and every hook that judges the working directory, while instruction files and hook paths stay with the launch directory; a cd into a worktree inside the repository, Claude Code's default `.claude/worktrees/<name>/`, also loads that tree's instruction files a second time as files there are read. Names the scoped form, `(cd /path && command)`, and, where the harness has one (Claude Code's EnterWorktree), its worktree tool for a move.
# summary: Stops a standalone cd on a shell that persists across calls. Ordinary quoted arguments and proven simple data-reader here-documents pass; here-documents with groups, control operators or substitutions can warn or refuse on guarded text.
# safety: Advisory reader: dependency or payload failures warn once and allow the call. Executable command matches retain exit 2. The commit-guards command-position reader selects command words and masks quoted data and proven simple data-reader here-document bodies. Here-documents with groups, control operators or substitutions can warn or refuse when their bodies hold guarded text. This is a lexical check; assembled command names and unknown launcher option forms are outside its contract. Every diagnostic starts with block-bare-cd: <key>=<value>.
# harnesses: [claude, copilot, gemini, cursor, opencode]
# requires-skills: [commit-guards]
# ---

set -euo pipefail
trap 'rc=$?; case $rc in 0 | 2) ;; *) refuse exit "$rc" ;; esac' EXIT

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses: the keys and values are the fixed set
# hooks/AGENTS.md names, and the English explanation and the rewrite follow on
# later lines.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
refuse() { # KEY VALUE [CAUSE]
  printf 'block-bare-cd: %s=%s\n' "$1" "$2" >&2
  case "$1=$2" in
    missing-tools=*)
      echo "the commands ${2//,/, } are required to read the hook payload and are not on PATH; this check is unavailable" >&2
      ;;
    payload=invalid-json)
      echo "the hook payload is not valid JSON, or names a command that is not a string; this check is unavailable" >&2
      ;;
    refused=bare-cd)
      echo "Where the shell persists across tool calls a bare cd re-roots every later command and every hook judging the working directory, while instruction files and hook paths stay with the launch directory." >&2
      echo "  Use a subshell instead: (cd /path && command). To work in a worktree, enter it with the harness's worktree tool where it has one (Claude Code's EnterWorktree) rather than cd." >&2
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

# jq is the only reader of the payload, and grep and sed make every decision
# after it. Without them the command cannot be read, and a command this hook
# has not read cannot be shown to scope its directory change. The value names
# every one of them the PATH is missing, in the order checked.
MISSING=""
for dependency in jq cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"

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
command_segments "$COMMAND" lines
while IFS= read -r segment; do
  command_text "$segment"
  selected=${COMMAND_TEXTS%"$NL"}
  if [[ $selected =~ ^cd([[:space:]]+[^\&\|\;\(\)]*)?$ ]]; then
    refuse refused bare-cd
  fi
done <<<"$SEGMENTS"
exit 0
