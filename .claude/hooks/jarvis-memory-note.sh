#!/usr/bin/env bash
# ---
# name: jarvis-memory-note
# event: PreToolUse
# matcher: Edit|MultiEdit|NotebookEdit|Write
# description: Before an edit under a Jarvis home's memory directory, hands the session the edited path and the Notes reading route in the installed Jarvis memory guide. The home's installed jarvis/SKILL.md identifies the home. The guide alone owns the note rule. Not run on codex: apply_patch has no tool_input.file_path to identify the edited note. Not run on copilot: preToolUse has no measured additionalContext delivery to the model. Not run on gemini: the BeforeTool edit payload and context delivery are unmeasured. Not run on opencode: it executes no hook commands. Not run on cursor: it reads hooks as advisory prose and executes no edit event. Not run on antigravity: its toolCall.args payload has no tool_input.file_path reader here.
# summary: Reminds the assistant to read the note guidance when it edits memory. Every edit remains allowed.
# safety: Advisory reader. Reads the tool payload, resolves the edited path's existing parent directories and checks the installed Jarvis guide. Writes no file. Missing tools, an unreadable payload, an unknown tool or a missing guide produce a keyed notice at exit 0. Other edits are silent. Uses additionalContext on stdout because successful stderr does not reach the Claude Code model. Shell commands that write files are outside this edit-tool matcher.
# timeout: 10
# harnesses: [claude, pi]
# requires-skills: [jarvis]
# ---

set -euo pipefail

# A reader failure must never refuse the edit, including an unexpected status.
trap 'status=$?; trap - EXIT; if [ "$status" -ne 0 ]; then notice payload reader-failed; fi; exit 0' EXIT

notice() { # KEY VALUE [INSTRUCTION]
  local text encoded bs=\\ q='"' octal char escaped
  printf -v text 'jarvis-memory-note: %s=%s' "$1" "$2"
  [ -z "${3:-}" ] || text="$text"$'\n'"$3"
  # Builtins keep the advisory context available when jq is missing or broken.
  encoded=${text//"$bs"/"$bs$bs"}
  encoded=${encoded//"$q"/"$bs$q"}
  for octal in 001 002 003 004 005 006 007 010 011 012 013 014 015 016 017 \
      020 021 022 023 024 025 026 027 030 031 032 033 034 035 036 037; do
    printf -v char '%b' "\\0$octal"
    printf -v escaped '\\u%04x' "0$octal"
    encoded=${encoded//"$char"/$escaped}
  done
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$encoded"
}

MISSING=""
for dependency in jq cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || { notice missing-tools "${MISSING#,}"; exit 0; }
INPUT=$(cat 2>/dev/null) || { notice payload unreadable; exit 0; }
TOOL=$(jq -er '.tool_name | strings | select(length > 0)' 2>/dev/null <<<"$INPUT") ||
  { notice payload invalid-json; exit 0; }
case "$TOOL" in
  Edit | MultiEdit | NotebookEdit | Write) ;;
  *) notice payload unknown-tool; exit 0 ;;
esac
TARGET=$(jq -er '.tool_input.file_path | strings | select(length > 0)' 2>/dev/null <<<"$INPUT") ||
  { notice payload no-file-path; exit 0; }
case "$TARGET" in /*) ;; *) TARGET="$PWD/$TARGET" ;; esac

# Write can create parent directories. Resolve the existing ancestor before
# checking memory membership, so an existing ../ or symlink cannot misroute it.
PARENT=${TARGET%/*}
TAIL=""
while [ ! -d "$PARENT" ]; do
  case "${PARENT##*/}" in
    . | ..) notice payload unresolved-path; exit 0 ;;
  esac
  TAIL="/${PARENT##*/}$TAIL"
  PARENT=${PARENT%/*}
  [ -n "$PARENT" ] || PARENT=/
done
PARENT=$(cd -- "$PARENT" 2>/dev/null && pwd -P) || { notice payload unresolved-path; exit 0; }
DIRECTORY="$PARENT$TAIL"
while [ "$DIRECTORY" != / ] && [ -n "$DIRECTORY" ]; do
  if [ "${DIRECTORY##*/}" = memory ]; then
    ROOT=${DIRECTORY%/*}
    for SKILL in "$ROOT/.agents/skills/jarvis" "$ROOT/.claude/skills/jarvis"; do
      [ -f "$SKILL/SKILL.md" ] || continue
      GUIDE="$SKILL/references/memory.md"
      [ -r "$GUIDE" ] || { notice payload memory-guide-missing; exit 0; }
      notice path "$TARGET" "Read ## Notes in $GUIDE before finishing this edit."
      exit 0
    done
  fi
  DIRECTORY=${DIRECTORY%/*}
done
exit 0
