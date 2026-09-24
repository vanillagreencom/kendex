#!/usr/bin/env bash
# Every line the oversee watch prints reaches the overseer session on every
# harness: one harness-neutral rule, one row per harness naming its own wake
# and re-arm, and the handoff carrying the mechanism in force to a successor.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

OVERSEE="$SKILL_DIR/workflows/oversee.md"
CODEX="$SKILL_DIR/references/codex-runtime.md"
PI="$SKILL_DIR/references/pi-runtime.md"
MODES="$SKILL_DIR/references/communication-modes.md"
DELIVERY="### Watch delivery"

echo "=== orch oversee wake lint ==="

# --- The harness-neutral rule -----------------------------------------------
rule "a turn without an asynchronous wake holds while a lane runs" "$OVERSEE" \
  "$DELIVERY" 'blocking follow' '`running`'
rule "the repeat watch runs detached through the waiter launch" "$OVERSEE" \
  "$DELIVERY" '[Waiter launch](../references/waiter-launch.md)' '`[RUN_DIR]/watch.log`'
rule "every delivery and expiry reads the watch's exit" "$OVERSEE" \
  "$DELIVERY" 'test -s [RUN_DIR]/watch.exit'

# --- One row per harness ----------------------------------------------------
rule "the Claude Code row names Monitor" "$OVERSEE" "$DELIVERY" \
  '| Claude Code |' '`Monitor`' '`timeout_ms`'
rule_fenced "the Claude Code follow numbers the log lines it delivers" "$OVERSEE" \
  "$DELIVERY" 'tail -n +[NEXT_LINE] -F [RUN_DIR]/watch.log' 'awk -v n=[NEXT_LINE]'
rule "the Codex row names write_stdin polls" "$OVERSEE" "$DELIVERY" \
  '| Codex |' '`write_stdin`' 'codex-runtime.md § Standing watch'
rule "the Pi row names bg_task output wakes" "$OVERSEE" "$DELIVERY" \
  '| Pi |' '`bg_task`' 'pi-runtime.md § Standing watch (Pi)'
rule "an exit-only harness runs single passes" "$OVERSEE" "$DELIVERY" \
  'Single passes' '`--repeat`' '`overseer-dead`'
rule "the handoff names the wake in force" "$OVERSEE" "$DELIVERY" \
  'The § 5 handoff names the mechanism in force'

# --- The Codex adapter ------------------------------------------------------
rule "Codex arms the follow with exec_command" "$CODEX" "## Standing watch" \
  '| Arm |' '`exec_command`' '`yield_time_ms` 30000'
rule "Codex waits in write_stdin empty polls" "$CODEX" "## Standing watch" \
  '| Wait |' '`write_stdin`' '`background_terminal_max_timeout`'
rule "Codex re-arms inside the same turn" "$CODEX" "## Standing watch" \
  '| Re-arm |' '`running`' '`exit_code`'

# --- The Pi adapter ---------------------------------------------------------
rule "Pi arms the follow with output wakes" "$PI" "## Standing watch (Pi)" \
  '| Arm |' '`notifyOnOutput: true`' '`notifyMode: "always"`'
rule "Pi re-arms when the wake budget is spent" "$PI" "## Standing watch (Pi)" \
  '| Re-arm |' '`bg_status action: "stop"`'

# --- The handoff shape ------------------------------------------------------
rule "the handoff shape carries the watch row" "$MODES" "## Handoff" \
  'Watch: [THE WAKE MECHANISM IN FORCE'

md_report
