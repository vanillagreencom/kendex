#!/usr/bin/env bash
# ---
# name: block-bare-cd
# event: PreToolUse
# matcher: Bash
# description: Refuse a command with a line that is only a `cd`. Where the shell persists across tool calls (Claude Code) a bare cd re-roots every later command and every hook that judges the working directory, while instruction files and hook paths stay with the launch directory; a cd into a worktree inside the repository, Claude Code's default `.claude/worktrees/<name>/`, also loads that tree's instruction files a second time as files there are read. Names the scoped form, `(cd /path && command)`, and, where the harness has one (Claude Code's EnterWorktree), its worktree tool for a move.
# safety: Reads the command text only. On a harness that runs each command in a fresh shell (Codex, the Pi carrier) a bare cd changes nothing and the refusal costs one rewrite; the scoped form is right on every harness. Refusals carry the line `block-bare-cd: <key>=<value>`; a reader matches that prefix, not line 1, because a command this hook runs may write its own diagnostic first.
# ---

set -euo pipefail

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses: the keys and values are the fixed set
# hooks/AGENTS.md names, and the English explanation and the rewrite follow on
# later lines.
# A reader matches `^block-bare-cd: `, not line 1: a command this hook
# runs may write its own diagnostic to the same stream first, and that line
# names a cause the keyed one does not carry.
refuse() { # KEY VALUE
  printf 'block-bare-cd: %s=%s\n' "$1" "$2" >&2
  case "$1=$2" in
    missing-tools=*)
      echo "the commands ${2//,/, } are required to read the hook payload and are not on PATH; refusing rather than skipping the guard" >&2
      ;;
    payload=invalid-json)
      echo "the hook payload is not valid JSON, or names a command that is not a string; refusing rather than skipping the guard" >&2
      ;;
    refused=bare-cd)
      echo "Where the shell persists across tool calls a bare cd re-roots every later command and every hook judging the working directory, while instruction files and hook paths stay with the launch directory." >&2
      echo "  Use a subshell instead: (cd /path && command). To work in a worktree, enter it with the harness's worktree tool where it has one (Claude Code's EnterWorktree) rather than cd." >&2
      ;;
  esac
  exit 2
}

# jq is the only reader of the payload, and grep and sed make every decision
# after it. Without them the command cannot be read, and a command this hook
# has not read cannot be shown to scope its directory change. The value names
# every one of them the PATH is missing, in the order checked.
MISSING=""
for dependency in jq cat grep sed; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

INPUT=$(cat)

# A payload that does not parse, or that names a command which is not a
# string, is refused rather than skipped. An absent command is the empty
# string and passes. The command is read where each harness carries it:
# `tool_input.command` (Claude Code, Codex, Gemini CLI and the Pi carrier), a
# bare `command`, or Copilot's `toolArgs.command`, whose `toolArgs` arrives as
# an object or as one JSON-encoded string. The null tests are spelled out
# because jq's `//` reads `false` as absent, and `false` is not a command
# either.
COMMAND=$(printf '%s' "$INPUT" \
  | jq -r 'def copilot: .toolArgs
             | if . == null then null elif type == "string" then fromjson else . end
             | if . == null then null elif type == "object" then .command else error end;
           if .tool_input.command != null then .tool_input.command
           elif .command != null then .command
           elif copilot != null then copilot
           else "" end
           | if type == "string" then . else error end' 2>/dev/null) ||
  refuse payload invalid-json

# A line that is only a cd, its operand optional on both sides: a bare `cd`
# goes to $HOME, the same move as `cd /tmp`. sed strips the leading whitespace
# of every line so an indented one is read the same; grep reads the whole
# command rather than stopping at the first match, since an early-exiting
# reader turns its producer's SIGPIPE into status 141 under pipefail, read
# here as "no bare cd".
STRIPPED=$(echo "$COMMAND" | sed 's/^[[:space:]]*//')
BARE_STATUS=0
printf '%s\n' "$STRIPPED" | grep -E '^cd([[:space:]]+[^&|;]*)?$' >/dev/null || BARE_STATUS=$?
if [ "$BARE_STATUS" -eq 0 ]; then
  refuse refused bare-cd
fi

exit 0
