#!/usr/bin/env bash
# Surface: committed Markdown snapshot report and finite Git object reads.
# Inputs: skills/jarvis/scripts/docs-audit, skills/jarvis/tests/docs_audit_test.py,
# skills/jarvis/tests/desktop_world.py.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/tests/docs_audit_test.py" "$@"
