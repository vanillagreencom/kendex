#!/usr/bin/env bash
# Pins the documented oversee watch delivery: the harness-neutral rule, the
# per-harness rows and their adapters, the Stop step that ends the watch, and
# the handoff field. Where an adapter copies a parameter from the package that
# defines it, the source line is pinned as well, so the two fail together.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

OVERSEE="$SKILL_DIR/workflows/oversee.md"
WATCH="$SKILL_DIR/references/watch-delivery.md"
CODEX="$SKILL_DIR/references/codex-runtime.md"
PI="$SKILL_DIR/references/pi-runtime.md"
MODES="$SKILL_DIR/references/communication-modes.md"
BG_TASKS="$REPO_ROOT/pi-extensions/pi-background-tasks/instructions.md"
BG_HEADING='## pi-background-tasks — `bg_task` and `bg_status`'
DELIVERY="# Watch delivery"

echo "=== orch oversee wake lint ==="

# --- The harness-neutral rule -----------------------------------------------
rule "the overseer workflow points at the watch delivery reference" \
  "$OVERSEE" "### Watch delivery" \
  '[references/watch-delivery.md](../references/watch-delivery.md)'
rule "a turn without an asynchronous wake holds while a lane runs" "$WATCH" \
  "$DELIVERY" 'blocking follow' '`running`'
rule "the repeat watch runs detached through the waiter launch" "$WATCH" \
  "$DELIVERY" '[Waiter launch](waiter-launch.md)' '`[RUN_DIR]/watch.log`'
rule "every delivery and expiry reads the watch's exit" "$WATCH" \
  "$DELIVERY" 'test -s [RUN_DIR]/watch.exit'
rule "a watch with no exit status is judged by its pid and its log's age" \
  "$WATCH" "$DELIVERY" '`kill -0 [PID]`' '`[RUN_DIR]/watch.pid`' \
  '`find [RUN_DIR]/watch.log -mmin +[MINUTES]`' '`--max-loops`'
rule "every harness follows through the one saved follow script" "$WATCH" \
  "$DELIVERY" '`[RUN_DIR]/follow.sh`' 'file-write tool'
rule "Stop ends the detached watch before the handoff" "$OVERSEE" "## 5. Stop" \
  '`kill -TERM -- -[PID]`' '`[RUN_DIR]/watch.pid`' '`kill -0 [PID]`'
rule "a stopped watch is never resumed from the handoff" "$WATCH" \
  "$DELIVERY" 'After that Stop' '`stopped`'

# --- One row per harness ----------------------------------------------------
rule "the Claude Code row names Monitor and re-arms on a stop" "$WATCH" \
  "$DELIVERY" '| Claude Code |' '`Monitor`' '`timeout_ms`' 'expiry or stop'
rule_fenced "the follow numbers each log line as it arrives" "$WATCH" \
  "$DELIVERY" 'tail -n "+$n" -F "$1"' 'while IFS= read -r line'
rule "the Codex row names write_stdin polls" "$WATCH" "$DELIVERY" \
  '| Codex |' '`write_stdin`' 'codex-runtime.md § Standing watch'
rule "the Pi row names bg_task output wakes" "$WATCH" "$DELIVERY" \
  '| Pi |' '`bg_task`' 'pi-runtime.md § Standing watch (Pi)'
rule "an exit-only harness runs single passes" "$WATCH" "$DELIVERY" \
  'Single passes' '`--repeat`' '`overseer-dead`'
rule "the handoff names the wake in force" "$WATCH" "$DELIVERY" \
  'handoff names the mechanism in force'

# --- The Codex adapter ------------------------------------------------------
rule "Codex arms the numbered follow with exec_command" "$CODEX" \
  "## Standing watch" '| Arm |' '`exec_command`' '`yield_time_ms` 30000' \
  'numbered follow command of [watch-delivery.md]'
rule "Codex waits in write_stdin empty polls" "$CODEX" "## Standing watch" \
  '| Wait |' '`write_stdin`' '`background_terminal_max_timeout`'
rule "Codex re-arms inside the same turn" "$CODEX" "## Standing watch" \
  '| Re-arm |' '`running`' '`exit_code`'

# --- The Pi adapter ---------------------------------------------------------
rule "Pi arms the numbered follow with output wakes and an expiry" "$PI" \
  "## Standing watch (Pi)" '| Arm |' '`notifyOnOutput: true`' \
  '`notifyMode: "always"`' '`timeoutSeconds: 300`' \
  'numbered follow command of [watch-delivery.md]'
rule "Pi re-arms when the wake budget is spent" "$PI" "## Standing watch (Pi)" \
  '| Re-arm |' '`bg_status action: "stop"`'
rule "Pi re-arms on an exit wake only for a follow it did not stop" "$PI" \
  "## Standing watch (Pi)" '| Exit |' '`timed_out`' '`stopped`'

# --- The Pi adapter's source ------------------------------------------------
rule "the package names every-output wakes" "$BG_TASKS" "$BG_HEADING" \
  'Pass `notifyMode: "always"`'
rule "the package caps the inline tail" "$BG_TASKS" "$BG_HEADING" \
  '`outputAlertMaxChars`'
rule "the package ends the wake budget with one notice" "$BG_TASKS" \
  "$BG_HEADING" '"wake budget exhausted'
rule "the package takes a spawn timeout" "$BG_TASKS" "$BG_HEADING" \
  '`timeoutSeconds`'

# --- The handoff shape ------------------------------------------------------
rule "the handoff shape carries the watch row" "$MODES" "## Handoff" \
  'Watch: [THE WAKE MECHANISM IN FORCE'

md_report
