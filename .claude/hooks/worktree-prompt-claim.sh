#!/usr/bin/env bash
# ---
# name: worktree-prompt-claim
# event: UserPromptSubmit
# matcher:
# description: Uses the worktree-session-claim hook's decision before each Claude prompt. In required-claim mode its keyed claim failure on stderr and exit 2 block the prompt before the model processes it. Without that mode it passes silently. The SessionStart hook requires this companion on Claude. Not run on codex: SessionStart already supports the required claim refusal. Not run on copilot: its UserPromptSubmit output does not provide this Claude blocking contract. Not run on pi: its prompt hook does not provide this Claude blocking contract. Not run on gemini: its prompt hook does not provide this Claude blocking contract. Not run on antigravity: it has no UserPromptSubmit event. Not run on opencode: it runs no hooks. Not run on cursor: kendex delivers hooks there as advisory rule prose.
# summary: Blocks Claude prompts when a required worktree claim fails.
# safety: Runs the companion worktree-session-claim hook from the same install. Its claim reads Git metadata and writes the worktree lease through the worktree skill. Loads no project settings or .env.local.
# timeout: 75
# harnesses: [claude]
# requires: [worktree-session-claim]
# ---

set -euo pipefail

JUDGE="${BASH_SOURCE[0]%/*}/worktree-session-claim.sh"
if [ ! -f "$JUDGE" ]; then
  printf 'worktree-prompt-claim: judge=%s\nInstall worktree-session-claim in the same scope before submitting a prompt.\n' "$JUDGE" >&2
  exit 2
fi
exec "$BASH" "$JUDGE" prompt
