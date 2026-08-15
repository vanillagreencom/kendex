#!/usr/bin/env bash
# ---
# name: session-drift-check
# event: SessionStart
# description: Runs `vstack check --quiet` at session start and surfaces vstack drift to the agent — outdated items (`vstack refresh`), items removed upstream (`vstack remove <name>`), and items available in the source but not installed (`vstack add --<kind> <name>`, pending user approval). Prints nothing when the install is current. VSTACK_DRIFT_HOOK=off disables it; VSTACK_DRIFT_HOOK_AVAILABLE=off hides the available-but-not-installed suggestions.
# safety: Informational only — never installs, removes, fetches over the network beyond vstack's own rate-limited source cache refresh, or touches git. Every suggestion requires user approval before acting.
# timeout: 30
# harnesses: [claude-code, codex]
# ---

# No `set -e`: a session must start no matter what this hook hits.
set -uo pipefail

# Drain the event payload; the report keys off the working directory, not it.
cat >/dev/null

if [ "${VSTACK_DRIFT_HOOK:-}" = "off" ]; then
  exit 0
fi

# No vstack binary means nothing to compare against — stay silent.
if ! command -v vstack >/dev/null 2>&1; then
  exit 0
fi

ARGS=(check --quiet)
if [ "${VSTACK_DRIFT_HOOK_AVAILABLE:-}" = "off" ]; then
  ARGS+=(--no-available)
fi

# Claude Code exports the project root; other harnesses launch the hook in it.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

OUTPUT=$(cd "$PROJECT_DIR" && vstack "${ARGS[@]}" 2>&1)
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
