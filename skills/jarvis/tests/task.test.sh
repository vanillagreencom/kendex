#!/usr/bin/env bash
# bash-runtime: 3.2
# Surface: task launch, completion and cleanup in the managed session.
# Inputs: skills/jarvis/scripts/, skills/jarvis/tests/task_test.py,
# skills/orch/scripts/, skills/mailbox/scripts/,
# skills/orch/tests/fixtures/tier-model/, skills/jarvis/tests/fixtures/.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/skills/jarvis/tests/task_test.py" "$@"
