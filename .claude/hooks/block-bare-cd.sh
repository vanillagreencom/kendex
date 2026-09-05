#!/usr/bin/env bash
# ---
# name: block-bare-cd
# event: PreToolUse
# matcher: Bash
# description: Block bare cd commands that permanently change the working directory. Suggests using subshells instead.
# safety: Prevents accidental working directory pollution across tool calls.
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
  echo "Bare 'cd' changes working directory permanently across tool calls." >&2
  echo "Use a subshell instead: (cd /path && command)" >&2
  exit 2
fi

exit 0
