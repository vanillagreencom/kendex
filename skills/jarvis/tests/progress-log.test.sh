#!/usr/bin/env bash
# Surface: progress-log, the handoff's progress record writer.
# Inputs: skills/jarvis/scripts/progress-log, skills/jarvis/scripts/lib/progress.py,
# skills/jarvis/scripts/lib/sections.py, skills/jarvis/scripts/lib/watch.py,
# skills/jarvis/tests/progress_log_test.py, skills/jarvis/tests/mail_world.py.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/skills/jarvis/tests/progress_log_test.py" "$@"
