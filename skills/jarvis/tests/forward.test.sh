#!/usr/bin/env bash
# Surface: jarvis-session forward, forward-drain and status --main, a satellite's
# confirmed forwards to the main home.
# Inputs: skills/jarvis/scripts/jarvis-session, skills/jarvis/scripts/lib/forward.py,
# skills/jarvis/scripts/lib/session.py, skills/jarvis/scripts/lib/owner_note.py,
# skills/jarvis/scripts/lib/watch.py, skills/jarvis/scripts/lib/jarvis-env.sh,
# skills/jarvis/tests/forward_test.py, skills/jarvis/tests/mail_world.py,
# skills/mailbox/scripts/, skills/orch/scripts/.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/skills/jarvis/tests/forward_test.py" "$@"
