#!/usr/bin/env bash
# Surface: Jarvis cold Start and hand-over recovery in a consumer home.
# Inputs: skills/jarvis/scripts/progress-log, skills/jarvis/scripts/lib/progress.py,
# skills/jarvis/scripts/lib/sections.py, skills/jarvis/scripts/lib/watch.py,
# skills/jarvis/tests/progress_log_test.py,
# skills/jarvis/tests/mail_world.py, skills/jarvis/tests/fixtures/runtime_cache.py,
# skills/agent-runtime/scripts/lib/key.sh, skills/linear/scripts/lib/common.sh,
# skills/linear/scripts/lib/formatters.sh, skills/linear/scripts/commands/comments.sh.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/skills/jarvis/tests/progress_log_test.py" ConsumerRecovery "$@"
