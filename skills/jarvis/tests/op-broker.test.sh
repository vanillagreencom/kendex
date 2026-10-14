#!/usr/bin/env bash
# Surface: op-broker and opq private session and FIFO contracts.
# Inputs: skills/jarvis/scripts/op-broker, skills/jarvis/scripts/opq,
# skills/jarvis/scripts/lib/op_fifo.py, skills/jarvis/tests/op_broker_test.py,
# skills/jarvis/tests/desktop_world.py.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
exec python3 -B "$ROOT/tests/op_broker_test.py" "$@"
