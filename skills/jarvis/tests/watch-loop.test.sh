#!/usr/bin/env bash
# Surface: Jarvis event acquisition, batching, retry and settings.
# Inputs: skills/jarvis/scripts/, skills/jarvis/tests/watch_test.py, skills/jarvis/tests/mail_world.py,
# skills/jarvis/tests/fixtures/runtime_cache.py,
# skills/mailbox/scripts/, skills/orch/scripts/, skills/slack/scripts/,
# skills/orch/runtime/, skills/agent-runtime/scripts/,
# skills/agent-runtime/tests/rust/fixtures/.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/skills/jarvis/tests/watch_test.py" "$@"
