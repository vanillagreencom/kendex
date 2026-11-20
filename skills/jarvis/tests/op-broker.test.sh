#!/usr/bin/env bash
# Surface: op-broker and opq private session, socket, allow-list and request-log contracts.
# Inputs: skills/jarvis/scripts/op-broker, skills/jarvis/scripts/opq,
# skills/jarvis/scripts/lib/op_fifo.py, skills/orch/scripts/, skills/orch/runtime/,
# skills/agent-runtime/scripts/, skills/agent-runtime/runtime/, skills/mailbox/scripts/,
# skills/jarvis/tests/op_broker_test.py, skills/jarvis/tests/fixtures/fifo_broker/,
# skills/jarvis/tests/desktop_world.py.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
exec python3 -B "$ROOT/tests/op_broker_test.py" "$@"
