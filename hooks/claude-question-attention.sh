#!/usr/bin/env bash
# ---
# name: claude-question-attention
# event: PreToolUse
# matcher: AskUserQuestion
# description: Advisory reader forwarding Claude question events to the installed claude-attention sibling, which owns admission, terminalSequence output and cooldown. Requires Claude Code 2.1.246 or newer, Python 3.8+ and tmux. Not run on codex: its question events do not provide Claude terminalSequence output. Not run on opencode: its question events do not provide Claude terminalSequence output. Not run on cursor: its question events do not provide Claude terminalSequence output. Not run on pi: its notification extension owns question delivery. Not run on gemini: its question events do not provide Claude terminalSequence output. Not run on copilot: its question events do not provide Claude terminalSequence output. Not run on antigravity: its question events do not provide Claude terminalSequence output.
# summary: Adds question alerts to claude-attention using the same inactive-pane filter and cooldown. Requires its permission hook beside it.
# safety: Advisory reader. Runs only the installed claude-attention sibling with unchanged stdin and environment. A missing or disabled sibling gives a keyed notice at exit 0. The sibling owns terminal output and the shared cache timestamp.
# timeout: 5
# harnesses: [claude]
# requires: [claude-attention]
# ---
set -euo pipefail

MAIN="${BASH_SOURCE[0]%/*}/claude-attention.sh"
if [ ! -f "$MAIN" ]; then
  printf 'claude-question-attention: companion=missing\n' >&2
  exit 0
fi
exec "$BASH" "$MAIN"
