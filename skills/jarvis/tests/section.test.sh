#!/usr/bin/env bash
# bash-runtime: 3.2
# Surface: heading-selected rule and memory section reads.
# Inputs: skills/jarvis/scripts/jarvis-section, skills/jarvis/tests/section_test.py,
# skills/jarvis/tests/desktop_world.py.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
exec python3 -B "$ROOT/tests/section_test.py" "$@"
