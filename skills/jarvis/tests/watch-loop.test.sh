#!/usr/bin/env bash
# Surface: Jarvis event acquisition, batching, retry and settings.
# Inputs: skills/jarvis/scripts/, skills/jarvis/tests/watch_test.py,
# skills/mailbox/scripts/, skills/orch/scripts/, skills/slack/scripts/.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/skills/jarvis/tests/watch_test.py" "$@"
