#!/usr/bin/env bash
# Surface: human-input pointer, keyboard and protected capture operations.
# Inputs: skills/jarvis/scripts/human-input, skills/jarvis/tests/human_input_test.py,
# skills/jarvis/tests/desktop_world.py.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
exec python3 -B "$ROOT/tests/human_input_test.py" "$@"
