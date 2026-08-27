#!/usr/bin/env bash
# ---
# name: block-bare-cd
# event: PreToolUse
# matcher: Bash
# description: Block bare cd commands that permanently change the working directory. Suggests using subshells instead.
# safety: Prevents accidental working directory pollution across tool calls.
# ---

set -euo pipefail

# Every decision below is made by these tools, so a PATH without them would
# no-op each check in turn and exit clean. Refuse before reading anything.
if ! command -v cat >/dev/null 2>&1 || ! command -v grep >/dev/null 2>&1 \
  || ! command -v sed >/dev/null 2>&1 || ! command -v head >/dev/null 2>&1; then
  echo "block-bare-cd: text tools (cat/grep/sed/head) unavailable to read the payload; refusing rather than skipping the guard" >&2
  exit 2
fi

INPUT=$(cat)

# Decode the command the way the sibling guards do. The value carries JSON
# escapes, and a parser that stops at the first quote truncates
# `cd "$repo" && ls` to `cd \`, which the heuristic below then reads as a
# bare cd and refuses — the opposite of what this hook is for.
if command -v jq >/dev/null 2>&1; then
  # A payload that does not parse is refused, not skipped: an unreadable
  # command cannot be proven scoped, and this guard is fail-closed by design.
  if ! COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // empty' 2>/dev/null); then
    echo "block-bare-cd: hook payload is not valid JSON; refusing rather than skipping the guard" >&2
    exit 2
  fi
else
  # Escape-aware fallback: the value may carry \" and \\ inside it.
  RAW=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"\([^"\\]\|\\.\)*"' | head -1 \
    | sed 's/^"command"[[:space:]]*:[[:space:]]*"//;s/"$//' 2>/dev/null || true)
  # Only \" and \\ are decoded here. A \t, \n, or \u escape would have to be
  # interpreted before the command can be classified, and reading one wrong
  # is a bare cd that passes, so such a payload is refused instead. jq, when
  # it is there, decodes them all and never reaches this.
  if printf '%s' "$RAW" | grep -q '\\[^"\\]'; then
    echo "block-bare-cd: hook payload carries a JSON escape this fallback does not decode; refusing rather than skipping the guard" >&2
    exit 2
  fi
  COMMAND=$(printf '%s' "$RAW" | sed 's/\\"/"/g;s/\\\\/\\/g')
  # Same fail-closed contract as the jq branch: a payload that names a
  # command the fallback could not decode is refused, not skipped. A
  # decoded-empty command ("command":"") still passes.
  if [ -z "$COMMAND" ] \
    && printf '%s' "$INPUT" | grep -q '"command"' \
    && ! printf '%s' "$INPUT" | grep -Eq '"command"[[:space:]]*:[[:space:]]*""'; then
    echo "block-bare-cd: could not decode the command from the hook payload; refusing rather than skipping the guard" >&2
    exit 2
  fi
fi

# Fast exit if no cd in command. A bare `cd` goes to $HOME, the change this
# hook exists to stop, so end of line counts the same as a following space.
if ! echo "$COMMAND" | grep -qE 'cd([[:space:]]|$)'; then
  exit 0
fi

# Check for bare top-level cd (not in subshell or &&-chained with other work)
# Simple heuristic: if the command is just "cd /path" with nothing else
# meaningful. Quoted text is an operand, not structure, so it is blanked
# first — the `;` in `cd "a;b"` separates nothing.
STRIPPED=$(echo "$COMMAND" | sed 's/^[[:space:]]*//')
MASKED=$(printf '%s' "$STRIPPED" | sed 's/"[^"]*"/Q/g' | sed "s/'[^']*'/Q/g")
if echo "$MASKED" | grep -qE '^cd([[:space:]]+[^&|;]*)?$'; then
  echo "Bare 'cd' changes working directory permanently across tool calls." >&2
  echo "Use a subshell instead: (cd /path && command)" >&2
  exit 2
fi

exit 0
