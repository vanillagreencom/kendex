#!/usr/bin/env bash
# Surface: independent rules in the packaged browser, password and input tools.
# Inputs: skills/jarvis/scripts/, skills/jarvis/SKILL.md, skills/jarvis/tests/.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
# The op-broker cases record their session process with session-backend.sh, run by this Bash.
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/tests/desktop_controls.py" "$@"
