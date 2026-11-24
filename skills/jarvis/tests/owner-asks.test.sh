#!/usr/bin/env bash
# bash-runtime: 4
# Surface: jarvis-session owner-asks and its main-owned pages/actions.
# Inputs: skills/jarvis/scripts/, skills/jarvis/tests/owner_asks_test.py,
# skills/jarvis/tests/mail_world.py, skills/jarvis/tests/fixtures/runtime_cache.py,
# skills/mailbox/scripts/, skills/orch/scripts/,
# skills/orch/runtime/, skills/agent-runtime/scripts/, skills/agent-runtime/runtime/,
# skills/linear/scripts/, skills/slack/scripts/.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/skills/jarvis/tests/owner_asks_test.py" "$@"
