#!/usr/bin/env bash
# ---
# name: block-bare-cd
# event: PreToolUse
# matcher: Bash
# description: Refuse a command with a line that is only a `cd`. Where the shell persists across tool calls (Claude Code) a bare cd re-roots every later command and every hook that judges the working directory, while instruction files and hook paths stay with the launch directory; a cd into a worktree inside the repository, Claude Code's default `.claude/worktrees/<name>/`, also loads that tree's instruction files a second time as files there are read. Names the scoped form, `(cd /path && command)`, and, where the harness has one (Claude Code's EnterWorktree), its worktree tool for a move.
# safety: Reads the command text only. On a harness that runs each command in a fresh shell (Codex, the Pi carrier) a bare cd changes nothing and the refusal costs one rewrite; the scoped form is right on every harness.
# ---

set -euo pipefail

# jq is the only reader of the payload, and grep and sed make every decision
# after it. Without them the command cannot be read, and a command this hook
# has not read cannot be shown to scope its directory change.
if ! command -v jq >/dev/null 2>&1 || ! command -v cat >/dev/null 2>&1 \
  || ! command -v grep >/dev/null 2>&1 || ! command -v sed >/dev/null 2>&1; then
  echo "block-bare-cd: jq, cat, grep and sed are required to read the hook payload; refusing rather than skipping the guard" >&2
  exit 2
fi

INPUT=$(cat)

# A payload that does not parse, or that names a command which is not a
# string, is refused rather than skipped. An absent command is the empty
# string and passes. The command is read where each harness carries it:
# `tool_input.command` (Claude Code, Codex, Gemini CLI and the Pi carrier), a
# bare `command`, or Copilot's `toolArgs.command`, whose `toolArgs` arrives as
# an object or as one JSON-encoded string. The null tests are spelled out
# because jq's `//` reads `false` as absent, and `false` is not a command
# either.
if ! COMMAND=$(printf '%s' "$INPUT" \
  | jq -r 'def copilot: .toolArgs
             | if . == null then null elif type == "string" then fromjson else . end
             | if . == null then null elif type == "object" then .command else error end;
           if .tool_input.command != null then .tool_input.command
           elif .command != null then .command
           elif copilot != null then copilot
           else "" end
           | if type == "string" then . else error end' 2>/dev/null); then
  echo "block-bare-cd: hook payload is not valid JSON, or names a command that is not a string; refusing rather than skipping the guard" >&2
  exit 2
fi

# Fast exit if no cd in command. A bare `cd` goes to $HOME, the change this
# hook exists to stop, so end of line counts the same as a following space.
if ! echo "$COMMAND" | grep -qE 'cd([[:space:]]|$)'; then
  exit 0
fi

# Check for bare top-level cd (not in subshell or &&-chained with other work)
# Simple heuristic: if the command is just "cd /path" with nothing else meaningful
STRIPPED=$(echo "$COMMAND" | sed 's/^[[:space:]]*//')
if echo "$STRIPPED" | grep -qE '^cd([[:space:]]+[^&|;]*)?$'; then
  echo "block-bare-cd: refusing a bare 'cd'. Where the shell persists across tool calls it re-roots every later command and every hook judging the working directory, while instruction files and hook paths stay with the launch directory." >&2
  echo "  Use a subshell instead: (cd /path && command). To work in a worktree, enter it with the harness's worktree tool where it has one (Claude Code's EnterWorktree) rather than cd." >&2
  exit 2
fi

exit 0
