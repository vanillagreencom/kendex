#!/usr/bin/env bash
# ---
# name: session-drift-check
# event: SessionStart
# description: On a fresh session start (not resume or compact), runs `vstack check --quiet` and surfaces vstack drift to the agent — outdated items (`vstack refresh`), items removed upstream (`vstack remove <name>`), unreachable sources — plus, alongside drift, items available in the source but not installed (`vstack add --<kind> <name>`, pending user approval). Prints nothing when the install is current. VSTACK_DRIFT_HOOK=off disables it; VSTACK_DRIFT_HOOK_AVAILABLE=off hides the available-but-not-installed suggestions.
# safety: Informational only — never installs or removes anything and never touches the project's git state. The only write is vstack's own rate-limited refresh (git fetch + reset, at most once per TTL) of its source-cache repositories under ~/.vstack/cache. Every suggestion requires user approval before acting.
# timeout: 30
# harnesses: [claude-code, codex]
# ---

# No `set -e`: a session must start no matter what this hook hits.
set -uo pipefail

INPUT=$(cat)

if [ "${VSTACK_DRIFT_HOOK:-}" = "off" ]; then
  exit 0
fi

# Fresh starts only. Claude Code sends source startup|resume|clear|compact;
# a resumed or compacted session already carries the report, and a per-compact
# rerun is the wallpaper this hook must not become.
SOURCE=$(printf '%s' "$INPUT" | grep -o '"source"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"source"[[:space:]]*:[[:space:]]*"//;s/"$//' 2>/dev/null || true)
case "$SOURCE" in
  resume|compact)
    exit 0
    ;;
esac

# The hook only exists because vstack installed it, so a missing binary is
# almost always a PATH gap worth one line — never a blocker.
if ! command -v vstack >/dev/null 2>&1; then
  echo "vstack drift check skipped: vstack is not on PATH"
  exit 0
fi

ARGS=(check --quiet)
if [ "${VSTACK_DRIFT_HOOK_AVAILABLE:-}" = "off" ]; then
  ARGS+=(--no-available)
fi

# Claude Code exports the project root; other harnesses launch the hook in it.
# Enter it separately so only vstack's own exit code drives classification.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if ! cd "$PROJECT_DIR" 2>/dev/null; then
  exit 0
fi

OUTPUT=$(vstack "${ARGS[@]}" 2>&1)
RC=$?

case "$RC" in
  0)
    exit 0
    ;;
  1)
    # Drift found: stdout is the session-start context channel.
    printf '%s\n' "$OUTPUT"
    ;;
  *)
    printf 'vstack check could not run (exit %s); drift status unknown:\n%s\n' "$RC" "$OUTPUT"
    ;;
esac

exit 0
