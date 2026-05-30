#!/bin/bash
# Best-effort Flightdeck activity emitter for Linear wrappers.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Nothing should be emitted outside Flightdeck-managed contexts. Return before
# touching the shared helper so a missing/unreadable Flightdeck install never
# affects standalone Linear wrapper usage.
if [ "${FLIGHTDECK_MANAGED:-}" != "1" ] && [ -z "${FLIGHTDECK_ACTIVITY_FILE:-}" ]; then
    exit 0
fi

ACTIVITY_EMIT_SH="$SCRIPT_DIR/../../flightdeck/scripts/_activity-emit.sh"

warn_activity_unavailable() {
    printf 'Warning: Flightdeck activity emit unavailable; continuing without activity: %s\n' "$ACTIVITY_EMIT_SH" >&2
}

# shellcheck source=/dev/null
if ! source "$ACTIVITY_EMIT_SH" >/dev/null 2>&1; then
    warn_activity_unavailable
    exit 0
fi

if ! declare -F flightdeck_activity_emit >/dev/null 2>&1; then
    warn_activity_unavailable
    exit 0
fi

flightdeck_activity_emit linear "$@" >/dev/null 2>&1 || true
exit 0
