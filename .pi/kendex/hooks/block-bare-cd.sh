#!/usr/bin/env bash
# ---
# name: block-bare-cd
# event: PreToolUse
# matcher: Bash
# description: Block bare cd commands that permanently change the working directory. Suggests using subshells instead.
# safety: Prevents accidental working directory pollution across tool calls.
# ---

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"command"[[:space:]]*:[[:space:]]*"//;s/"$//' 2>/dev/null || true)

# Fast exit if no cd in command
if ! echo "$COMMAND" | grep -q 'cd '; then
  exit 0
fi

# Check for bare top-level cd (not in subshell or &&-chained with other work)
# Simple heuristic: if the command is just "cd /path" with nothing else meaningful
STRIPPED=$(echo "$COMMAND" | sed 's/^[[:space:]]*//')
if echo "$STRIPPED" | grep -qE '^cd[[:space:]]+[^&|;]+$'; then
  echo "Bare 'cd' changes working directory permanently across tool calls." >&2
  echo "Use a subshell instead: (cd /path && command)" >&2
  exit 2
fi

exit 0
