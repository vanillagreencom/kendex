#!/usr/bin/env bash
# Surface: jarvis-browser URL opening and assistant profile selection.
# Inputs: skills/jarvis/scripts/jarvis-browser, skills/jarvis/tests/browser_test.py,
# skills/jarvis/tests/desktop_world.py.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
exec python3 -B "$ROOT/tests/browser_test.py" "$@"
