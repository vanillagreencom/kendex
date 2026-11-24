#!/usr/bin/env bash
# Surface: jarvis-session forward, forward-drain, forward-wait and status --main,
# a satellite's forwards to the main home and its standing watch service.
# Inputs: skills/jarvis/scripts/jarvis-session, skills/jarvis/scripts/lib/forward.py,
# skills/jarvis/scripts/lib/session.py, skills/jarvis/scripts/lib/owner_note.py,
# skills/jarvis/scripts/lib/watch.py, skills/jarvis/scripts/lib/jarvis-env.sh,
# skills/jarvis/scripts/watch-loop, skills/jarvis/scripts/lib/home.py,
# skills/jarvis/systemd/jarvis-watch.service,
# skills/jarvis/tests/forward_test.py, skills/jarvis/tests/mail_world.py,
# skills/jarvis/tests/fixtures/runtime_cache.py,
# skills/mailbox/scripts/, skills/orch/scripts/, skills/orch/runtime/,
# skills/agent-runtime/scripts/, skills/agent-runtime/runtime/.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/skills/jarvis/tests/forward_test.py" "$@"
