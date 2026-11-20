#!/usr/bin/env bash
# Surface: independent rules in the packaged browser, password and input tools.
# Inputs: skills/jarvis/scripts/, skills/jarvis/SKILL.md, skills/jarvis/tests/,
# skills/orch/scripts/, skills/orch/runtime/, skills/agent-runtime/scripts/, skills/agent-runtime/runtime/.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
exec python3 -B "$ROOT/tests/desktop_controls.py" "$@"
