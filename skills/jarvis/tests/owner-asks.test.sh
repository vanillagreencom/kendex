#!/usr/bin/env bash
# Surface: jarvis-session owner-asks and its main-owned pages/actions.
# Inputs: skills/jarvis/scripts/, skills/jarvis/tests/owner_asks_test.py,
# skills/jarvis/tests/mail_world.py, skills/mailbox/scripts/, skills/orch/scripts/,
# skills/linear/scripts/, skills/slack/scripts/, skills/slack/tests/lib/fake_slack.py.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 -B "$ROOT/skills/jarvis/tests/owner_asks_test.py" "$@"
