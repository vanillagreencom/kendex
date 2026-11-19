#!/usr/bin/env bash
# Surface: op-broker and opq private session, socket, allow-list and request-log contracts.
# Inputs: skills/jarvis/scripts/op-broker, skills/jarvis/scripts/opq,
# skills/jarvis/scripts/lib/op_fifo.py, skills/jarvis/scripts/lib/home.py,
# skills/jarvis/scripts/lib/session-backend.sh, skills/orch/scripts/, skills/mailbox/scripts/,
# skills/jarvis/tests/op_broker_test.py,
# skills/jarvis/tests/desktop_world.py.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
# The session record's process identity comes from session-backend.sh, run by this Bash.
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/tests/op_broker_test.py" "$@"
