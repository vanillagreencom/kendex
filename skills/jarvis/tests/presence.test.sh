#!/usr/bin/env bash
# Surface: bound-session hook activity renews local and host Jarvis holds.
# Inputs: skills/jarvis/scripts/, skills/jarvis/tests/presence_test.py,
# hooks/lane-mail-check.sh, hooks/lane-mail-deliver.sh, hooks/session-start-row.sh,
# hooks/tests/lib/, skills/orch/scripts/, skills/mailbox/scripts/.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
source "$ROOT/hooks/tests/lib/lane-mail-world.sh"
overseer_transcript
new_overseer jarvis_presence
install_arms
install_hook "$ROOT/hooks/session-start-row.sh" "$LANE/.claude/hooks/session-start-row.sh"
mkdir -p "$LANE/tmp/lane-mail/overseer"
write_transcript "$TRANSCRIPT" 100000
judge_says "$BELOW_MARK_LINE"
wake_row_process_table
env "PATH=$TMUX_BIN:$PATH" TMUX=fake "TMUX_PANE=$OVERSEER_PANE" \
  "TMUX_SERVER_ID=$OVERSEER_SERVER" "TMUX_SERVER_START=$OVERSEER_SERVER_START" \
  "TMUX_PANE_PID=$OVERSEER_SERVER" "CLAUDE_CONFIG_DIR=$OVERSEER_HOME_DIR" \
  "JARVIS_TEST_BASH=$BASH" "PRESENCE_ROOT=$LANE" "PRESENCE_TRANSCRIPT=$TRANSCRIPT" \
  python3 -B "$ROOT/skills/jarvis/tests/presence_test.py"
