#!/usr/bin/env bash
# Surface: owner-unanswered, the owner messages no reply or record covers.
# Inputs: skills/jarvis/scripts/owner-unanswered, skills/jarvis/scripts/lib/owner_unanswered.py,
# skills/jarvis/scripts/lib/progress.py, skills/jarvis/scripts/lib/watch.py,
# skills/jarvis/tests/owner_unanswered_test.py, skills/jarvis/tests/mail_world.py,
# skills/mailbox/scripts/, skills/orch/scripts/.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/skills/jarvis/tests/owner_unanswered_test.py" "$@"
