#!/usr/bin/env bash
# Surface: owner-note, the owner's directive to an overseer on the host or here.
# Inputs: skills/jarvis/scripts/owner-note, skills/jarvis/scripts/lib/owner_note.py,
# skills/jarvis/scripts/lib/watch.py, skills/jarvis/scripts/lib/jarvis-env.sh,
# skills/jarvis/tests/owner_note_test.py, skills/jarvis/tests/mail_world.py,
# skills/mailbox/scripts/, skills/orch/scripts/.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/skills/jarvis/tests/owner_note_test.py" "$@"
