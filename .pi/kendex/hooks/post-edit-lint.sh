#!/usr/bin/env bash
# ---
# name: post-edit-lint
# event: PostToolUse
# matcher: Edit|Write
# description: Run workspace linter after editing source files. Currently supports Rust (cargo clippy).
# safety: Catches lint errors immediately after edits rather than waiting for commit time.
# timeout: 30
# ---

set -euo pipefail

INPUT=$(cat)

# Claude Code surfaces the file as tool_input.file_path / filePath.
FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || true)
if [ -z "$FILE_PATH" ]; then
  FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"filePath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || true)
fi

# Codex routes Edit|Write through apply_patch and reports tool_input.command
# (the patch text). Scrape the first .rs path from the input as a fallback.
if [ -z "$FILE_PATH" ]; then
  FILE_PATH=$(echo "$INPUT" | grep -oE '[A-Za-z0-9_./@-]+\.rs' | head -1 || true)
fi

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only lint Rust files (extend this for other languages)
case "$FILE_PATH" in
  *.rs) ;;
  *) exit 0 ;;
esac

# Find the workspace root
WORKSPACE_ROOT=$(cargo metadata --format-version 1 --no-deps 2>/dev/null | sed -n 's/.*"workspace_root"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)
if [ -z "$WORKSPACE_ROOT" ]; then
  exit 0
fi

# Run clippy on the workspace
OUTPUT=$(cargo clippy --workspace --all-targets -- -D warnings 2>&1 || true)

# Filter to issues in the edited file (limit output). `grep` exits 1 on no
# match — `pipefail` would otherwise abort the script, so swallow it.
ISSUES=$(echo "$OUTPUT" | grep -F "$FILE_PATH" | head -10 || true)

if [ -n "$ISSUES" ]; then
  COUNT=$(echo "$ISSUES" | wc -l)
  ESCAPED=$(echo "$ISSUES" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '|' | sed 's/|/\\n/g')
  # Nested hookSpecificOutput is the shape codex requires for PostToolUse and
  # Claude Code also accepts it.
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"Clippy found ${COUNT} issue(s) in ${FILE_PATH}:\\n${ESCAPED}\"}}"
fi
