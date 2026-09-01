#!/usr/bin/env bash
# ---
# name: session-drift-check
# event: SessionStart
# description: On a fresh session start (not resume or compact), runs `kendex check --quiet` and surfaces kendex drift to the agent — outdated items (`kendex refresh`), items removed upstream (`kendex remove <name>`, `-g` in a global section), unreachable sources, and packages not yet evaluated against their sources (a background refresh settles them). Prints nothing when the install is current. KENDEX_DRIFT_HOOK=off disables it.
# safety: Informational only — never installs or removes anything and never touches the project's git state. The check never waits on the network; the only thing it may write is kendex's own cache bookkeeping under ~/.kendex/cache (fetch stamps), and when a source cache there is older than its TTL, a detached background process refreshes it (git fetch + reset, confined to that cache) and this hook does not wait for it. Every suggestion requires user approval before acting.
# timeout: 30
# harnesses: [claude-code, codex]
# ---

# Strict, and a session must still start no matter what this hook hits: every
# command that can legitimately fail is guarded so this always reaches exit 0.
set -euo pipefail

# Reaching this trap means an UNGUARDED command failed. Say so: an unexpected
# failure that printed nothing would read as a clean install.
trap 'rc=$?; echo "kendex check could not run: drift hook failed at line $LINENO (exit $rc); drift status unknown"; exit 0' ERR

INPUT=$(cat || true)

if [ "${KENDEX_DRIFT_HOOK:-}" = "off" ]; then
  exit 0
fi

# Fresh starts only. Claude Code sends source startup|resume|clear|compact;
# a resumed or compacted session already carries the report, and a per-compact
# rerun is the wallpaper this hook must not become.
#
# The payload is JSON and jq is the only thing that reads it: the key is the
# TOP-LEVEL `source`, and a text scan for it finds the same key nested in any
# other object, or the same characters inside an unrelated string value — a
# transcript path or a cwd is enough. Without jq the payload is unread, and an
# unread payload cannot be shown to be a fresh start, so the report is skipped
# rather than repeated on every compact.
if ! command -v jq >/dev/null 2>&1; then
  echo "kendex drift check skipped: jq is not on PATH to read the session payload"
  exit 0
fi
if ! SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // ""' 2>/dev/null); then
  echo "kendex drift check skipped: the session payload is not valid JSON"
  exit 0
fi
case "$SOURCE" in
  resume|compact)
    exit 0
    ;;
esac

# The hook only exists because kendex installed it, so a missing binary is
# almost always a PATH gap worth one line — never a blocker.
if ! command -v kendex >/dev/null 2>&1; then
  echo "kendex drift check skipped: kendex is not on PATH"
  exit 0
fi

# Claude Code exports the project root; other harnesses launch the hook in it.
# Enter it separately so only kendex's own exit code drives classification.
# `--` so a directory whose name starts with a dash is a path, not an option.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if ! cd -- "$PROJECT_DIR" 2>/dev/null; then
  echo "kendex check could not run: project directory $PROJECT_DIR is not accessible; drift status unknown"
  exit 0
fi

# kendex's exit code IS the classification; under errexit a bare failing
# assignment would abort before `RC=$?` could run.
RC=0
OUTPUT=$(kendex check --quiet 2>&1) || RC=$?

case "$RC" in
  0)
    exit 0
    ;;
  1)
    # Drift found, or packages awaiting evaluation: stdout is the
    # session-start context channel.
    printf '%s\n' "$OUTPUT"
    ;;
  2)
    # kendex could not check, in part or at all. A report carrying a
    # "could not check" section checked everything else and says what it
    # could not; it is printed as incomplete, never as a crash. Output
    # that opens with kendex's own Error: line or clap's usage error:
    # comes from before the check read anything, so nothing was checked
    # and it reads as could-not-run.
    case "$OUTPUT" in
      "")
        echo "kendex check could not run (exit 2); drift status unknown"
        ;;
      Error:* | error:*)
        printf 'kendex check could not run (exit 2); drift status unknown:\n%s\n' "$OUTPUT"
        ;;
      *)
        printf 'kendex check incomplete (exit 2); some drift status unknown:\n%s\n' "$OUTPUT"
        ;;
    esac
    ;;
  *)
    # Anything else is not a kendex verdict: a signal, a timeout, a
    # binary that could not start.
    printf 'kendex check could not run (exit %s); drift status unknown:\n%s\n' "$RC" "$OUTPUT"
    ;;
esac

exit 0
