#!/usr/bin/env bash
# Pins the documented oversee watch delivery: the harness-neutral rule, the
# per-harness rows and their adapters, the Stop step that ends the watch, and
# the handoff field. Every bg_task parameter the Pi rows name is read from
# those rows and must stand in the package instructions that define it, and the
# numbered follow every harness runs is executed from its fence.
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
rule "a read that fails is never read as no watch" "$WATCH" "$DELIVERY" \
  'failed read' "pgrep's stderr" 'Exit 0 is a live watch'
rule "every delivery and expiry reads the process before the status" \
  "$WATCH" "$DELIVERY" 'run that read first' 'test -s [RUN_DIR]/watch.exit'
rule "a stop signals only the group the read proved" "$WATCH" "$DELIVERY" \
  '`kill -TERM -- -[PID]`' 'the group it proved'
rule "a stop marks the status file before its kill" "$WATCH" "$DELIVERY" \
  'write `stopped` into `[RUN_DIR]/watch.exit`' 'then run the read'
rule "the stop mark ends oversight with no restart" "$WATCH" "$DELIVERY" \
  '`stopped` is the mark' 'no restart'
rule "a fresh run directory restarts the line count" "$WATCH" "$DELIVERY" \
  '`[NEXT_LINE]` starts at 1'
rule "a relaunch moves the follow to the new log" "$WATCH" "$DELIVERY" \
  'end the current follow' 'new `[RUN_DIR]/watch.log` from line 1'
rule "every harness follows through the one saved follow script" "$WATCH" \
  "$DELIVERY" '`[RUN_DIR]/follow.sh`' 'file-write tool'
rule "Stop ends the detached watch before the handoff" "$OVERSEE" "## 5. Stop" \
  'Stop a detached repeat watch first' \
  '[references/watch-delivery.md](../references/watch-delivery.md)'
rule "a stopped watch is never resumed from the handoff" "$WATCH" \
  "$DELIVERY" 'After that Stop' '`stopped`'

# --- One row per harness ----------------------------------------------------
rule "the Claude Code row names Monitor and re-arms on a stop" "$WATCH" \
  "$DELIVERY" '| Claude Code |' '`Monitor`' '`timeout_ms`' 'expiry or stop'
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
  '| Re-arm |' '`running`' '`exit_code`' 'Every poll return'

# --- The Pi adapter ---------------------------------------------------------
rule "Pi arms the numbered follow with output wakes and an expiry" "$PI" \
  "## Standing watch (Pi)" '| Arm |' '`notifyOnOutput: true`' \
  '`notifyMode: "always"`' '`timeoutSeconds: 300`' \
  'numbered follow command of [watch-delivery.md]'
rule "Pi re-arms when the wake budget is spent" "$PI" "## Standing watch (Pi)" \
  '| Re-arm |' '`bg_status action: "stop"`'
rule "Pi spawns on an exit wake only when its follow is not listed running" \
  "$PI" "## Standing watch (Pi)" '| Exit |' '`bg_status action: "list"`'

# --- The Pi adapter's source ------------------------------------------------
rule "the package ends the wake budget with one notice" "$BG_TASKS" \
  "$BG_HEADING" '"wake budget exhausted'

# pi_params FILE — one row per bg_task parameter a code span in FILE's
# § Standing watch (Pi) names, tab-separated: `param NAME VALUE` for a span
# `name` or `name: value` whose name is camelCase or takes a value, VALUE empty
# unless it is a quoted string; `action TOOL ACTION` for a span
# `bg_task|bg_status action: "ACTION"`. A bare lowercase one-word span (`id`)
# is not read as a parameter: that direction stays open.
pi_params() {
  awk '
    /^## / { on = ($0 == "## Standing watch (Pi)"); next }
    !on { next }
    {
      line = $0
      while (match(line, /`[^`]*`/)) {
        span = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        if (span ~ /^bg_(task|status) action: "[a-z]+"$/) {
          tool = span; sub(/ .*/, "", tool)
          act = span; sub(/^[^"]*"/, "", act); sub(/"$/, "", act)
          printf "action\t%s\t%s\n", tool, act
        } else if (span ~ /^[a-z][A-Za-z]*: / || span ~ /^[a-z]+[A-Z][A-Za-z]*$/) {
          name = span; sub(/:.*/, "", name)
          val = ""
          if (span ~ /: "[^"]*"$/) { val = span; sub(/^[^"]*"/, "", val); sub(/"$/, "", val) }
          printf "param\t%s\t%s\n", name, val
        }
      }
    }
  ' "$1"
}

# pi_param_gaps FILE — each row of pi_params FILE that no line of the package
# instructions holds: a param's backticked name, with its quoted value on the
# same line when it has one; an action's tool name with the action backticked
# or quoted on the same line.
pi_param_gaps() {
  local kind a b rows
  rows="$(pi_params "$1")" || { printf 'extractor-failed\n'; return 0; }
  while IFS=$'\t' read -r kind a b; do
    [ -n "$kind" ] || continue
    if [ "$kind" = action ]; then
      awk -v t="$a" -v q="\"$b\"" -v c="\`$b\`" \
        'index($0, t) && (index($0, q) || index($0, c)) { f = 1 } END { exit !f }' \
        "$BG_TASKS" || printf '%s action %s\n' "$a" "$b"
    else
      awk -v n="\`$a" -v v="$b" \
        'index($0, n) && (v == "" || index($0, "\"" v "\"") || index($0, "`" v "`")) { f = 1 } END { exit !f }' \
        "$BG_TASKS" || printf '%s %s\n' "$a" "$b"
    fi
  done <<EOF_ROWS
$rows
EOF_ROWS
}

pi_rows="$(pi_params "$PI")"
case "$pi_rows" in
  *$'param\tnotifyOnOutput\t'*) pass "the Pi parameter extractor reads the Arm row" ;;
  *) fail "the Pi parameter extractor is broken: no notifyOnOutput row in pi-runtime.md" ;;
esac
gaps="$(pi_param_gaps "$PI")"
if [ -z "$gaps" ]; then
  pass "every bg_task parameter the Pi rows name stands in the package instructions"
else
  fail "Pi rows name parameters the package instructions lack: $gaps"
fi
# Control, one row per parameter form: a planted span must be reported.
while IFS='|' read -r span want; do
  cp "$PI" "$MD_TMP/pi-control.md"
  printf '| Plant | `%s` |\n' "$span" >> "$MD_TMP/pi-control.md"
  case "$(pi_param_gaps "$MD_TMP/pi-control.md")" in
    *"$want"*) pass "control: a planted $span is reported" ;;
    *) fail "control: a planted $span went unreported" ;;
  esac
done <<'ROWS'
notifyBogus: true|notifyBogus
bg_status action: "bogus"|bg_status action bogus
ROWS

# --- The numbered follow ----------------------------------------------------
# Runs the fence every harness saves as follow.sh against a log, from a start
# line past 1, and appends a line while it runs: each line must arrive with its
# own number, including the one written after the follow started.
awk '
  /^```sh$/ { active = 1; blocks++; next }
  /^```$/ && active { active = 0; next }
  active { print }
  END { if (blocks != 1 || active) exit 1 }
' "$WATCH" > "$MD_TMP/follow.sh"
printf 'a\nb\nc\n' > "$MD_TMP/watch.log"
# Job control gives the follow its own process group, so one group kill ends
# the tail and the loop together.
set -m
sh "$MD_TMP/follow.sh" "$MD_TMP/watch.log" 2 > "$MD_TMP/follow.out" 2>&1 < /dev/null &
follow_pid=$!
set +m
follow_lines() { awk 'END { print NR }' "$MD_TMP/follow.out"; }
for ((attempt=0; attempt<500; attempt++)); do
  [ "$(follow_lines)" -lt 2 ] || break
  sleep 0.01
done
printf ' d  e\n' >> "$MD_TMP/watch.log"
for ((attempt=0; attempt<500; attempt++)); do
  [ "$(follow_lines)" -lt 3 ] || break
  sleep 0.01
done
kill -TERM -- "-$follow_pid" 2>/dev/null || true
wait "$follow_pid" 2>/dev/null || true
if [ "$(cat "$MD_TMP/follow.out")" = "$(printf '2: b\n3: c\n4:  d  e')" ]; then
  pass "the follow numbers each line from its start line as it arrives"
else
  fail "the follow printed: $(cat "$MD_TMP/follow.out")"
fi

# --- The handoff shape ------------------------------------------------------
rule "the handoff shape carries the watch row" "$MODES" "## Handoff" \
  'Watch: [THE WAKE MECHANISM IN FORCE'

md_report
