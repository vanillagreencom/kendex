#!/usr/bin/env bash
# ---
# name: docs-writing-bash-note
# event: PostToolUse
# matcher: Bash
# description: After a successful Claude Code Bash call, runs the docs-writing-note advisory reader beside this hook to route the first changed tracked Markdown file once per session. Not run on codex: its apply_patch payload is read by docs-writing-note before the edit. Not run on pi: its edit payload is read by docs-writing-note before the edit. Not run on copilot: its postToolUse Bash payload is not read here. Not run on gemini: its AfterTool payload is not read here. Not run on opencode: it executes no hook commands. Not run on cursor: it executes no tool event. Not run on antigravity: its toolCall.args payload is not read here.
# summary: Reminds Claude Code of the docs-writing rules when it changes tracked Markdown through Bash. Every call remains allowed.
# safety: Advisory reader. Passes the payload to the docs-writing-note installed beside this hook. Missing or failed readers produce a keyed context notice at exit 0.
# timeout: 10
# harnesses: [claude]
# requires: [docs-writing-note]
# ---
set -euo pipefail
trap 'exit 0' EXIT
READER="${BASH_SOURCE[0]%/*}/docs-writing-note.sh"
if [ -f "$READER" ]; then
  "$BASH" "$READER" post-bash && exit 0
  REASON=failed
else
  REASON=missing
fi
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"docs-writing-note: reader=%s"}}\n' "$REASON"
