#!/usr/bin/env bash
# Surface: jarvis-session's must-fail control.
# Inputs: skills/jarvis/scripts/, skills/orch/scripts/, skills/mailbox/scripts/,
# skills/jarvis/tests/.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 "$ROOT/skills/jarvis/tests/session_controls.py"
