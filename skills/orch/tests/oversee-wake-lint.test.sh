#!/usr/bin/env bash
# Pins the machine-read half of the oversee watch delivery: the commands and
# status file the watch rules run and read, and the tool and parameter names
# each harness row hands its harness. Every bg_task parameter the Pi rows name
# is read from those rows and must stand in the package instructions that
# define it, and the numbered follow every harness runs is executed from its
# fence.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

WATCH="$SKILL_DIR/references/watch-delivery.md"
CODEX="$SKILL_DIR/references/codex-runtime.md"
PI="$SKILL_DIR/references/pi-runtime.md"
# The render copy sits under .agents/, where md.sh's REPO_ROOT is .agents/
# itself; the package lives at the work tree's top level in both copies.
PKG_DIR="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)/pi-extensions/pi-background-tasks"
BG_TASKS="$PKG_DIR/instructions.md"
BG_TOOLS="$PKG_DIR/extensions/registrations.ts"
REPEAT="## Repeat watch"

echo "=== orch oversee wake lint ==="

# --- The watch's commands and status file -----------------------------------
rule "a stop runs stop-job on the runner the launch recorded" "$WATCH" "$REPEAT" \
  'job-unit.sh stop-job "[RUN_DIR]/watch.runner" [PID]'
rule "every delivery and expiry reads the waiter's status file" "$WATCH" \
  "$REPEAT" 'test -s "[RUN_DIR]/watch.exit"'

# --- One row per harness, by the tool and parameter names it takes ----------
rule "the Claude Code row names Monitor and its timeout" "$WATCH" \
  "$REPEAT" '| Claude Code |' '`Monitor`' '`timeout_ms`'
rule "the Codex row names write_stdin" "$WATCH" "$REPEAT" \
  '| Codex |' '`write_stdin`'
rule "the Pi row names bg_task" "$WATCH" "$REPEAT" '| Pi |' '`bg_task`'

# --- The Codex adapter ------------------------------------------------------
rule "Codex arms the follow with exec_command" "$CODEX" \
  "## Standing watch" '| Arm |' '`exec_command`' '`yield_time_ms` 30000'
rule "Codex waits in write_stdin polls" "$CODEX" "## Standing watch" \
  '| Wait |' '`write_stdin`' '`background_terminal_max_timeout`'
rule "Codex re-arms on the poll's running and exit_code fields" "$CODEX" \
  "## Standing watch" '| Re-arm |' '`running`' '`exit_code`'

# --- The Pi adapter ---------------------------------------------------------
rule "Pi arms the follow with output wakes and an expiry" "$PI" \
  "## Standing watch (Pi)" '| Arm |' '`notifyOnOutput: true`' \
  '`notifyMode: "always"`' '`timeoutSeconds: 300`'
rule "Pi re-arms with a bg_status stop" "$PI" "## Standing watch (Pi)" \
  '| Re-arm |' '`bg_status action: "stop"`'
rule "Pi keeps the pid the spawn result prints" "$PI" "## Standing watch (Pi)" \
  '`Started [ID] (pid [PID])`'
rule "Pi lists its follow on an exit wake" \
  "$PI" "## Standing watch (Pi)" '| Exit |' '`bg_status action: "list"`'

# --- The Pi adapter's source ------------------------------------------------

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

# The Pi rows stop a follow by the pid they kept. instructions.md does not say
# which identifier bg_status takes, so the tool's own schema is the source: the
# bg_status registration must take `pid` for its stop, and the spawn result must
# print the pid beside the id.
bg_status_schema="$(awk '/name: "bg_status"/ { on = 1 } on && /name: "bg_task"/ { exit } on' "$BG_TOOLS")"
case "$bg_status_schema" in
  *'pid: Type.Optional'*'stop=terminate by pid'*|*'stop=terminate by pid'*'pid: Type.Optional'*)
    pass "bg_status stops by pid in the package's tool schema" ;;
  *) fail "bg_status no longer stops by pid in ${BG_TOOLS##*/}: the Pi rows keep the wrong identifier" ;;
esac
if grep -qF 'Started ${task.id} (pid ${task.pid})' "$BG_TOOLS"; then
  pass "the bg_task spawn result prints the pid the Pi rows keep"
else
  fail "the bg_task spawn result in ${BG_TOOLS##*/} no longer prints the pid"
fi

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
# The extractor's one control: a planted parameter span must be reported.
cp "$PI" "$MD_TMP/pi-control.md"
printf '| Plant | `notifyBogus: true` |\n' >> "$MD_TMP/pi-control.md"
case "$(pi_param_gaps "$MD_TMP/pi-control.md")" in
  *notifyBogus*) pass "control: a planted notifyBogus: true is reported" ;;
  *) fail "control: a planted notifyBogus: true went unreported" ;;
esac

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
# Job control gives the follow its own process group, so one group kill ends
# the tail and the loop together. The kill waits for the lines it expects: a
# job forked but not yet exec'd still runs this suite's EXIT trap on a TERM,
# which removes MD_TMP. A follow.out not opened yet holds 0 lines, not an error.
follow_lines() {
  if [ -f "$MD_TMP/follow.out" ]; then awk 'END { print NR }' "$MD_TMP/follow.out"; else echo 0; fi
}
# One follow, its lines counted by COUNTER. With DELAY, follow.out appears only
# DELAY seconds after the job starts, as when a slow fork opens it late; that
# job is `sh` from the start, so a kill never lands on a forked copy of this one.
follow_run() { # COUNTER [DELAY]
  local attempt
  rm -f -- "${MD_TMP:?}/follow.out" "${MD_TMP:?}/follow.out.part"
  printf 'a\nb\nc\n' > "$MD_TMP/watch.log"
  set -m
  if [ -z "${2:-}" ]; then
    sh "$MD_TMP/follow.sh" "$MD_TMP/watch.log" 2 > "$MD_TMP/follow.out" 2>&1 < /dev/null &
  else
    sh -c 'sleep "$1"; ln -- "$2.part" "$2"; exec sh "$3" "$4" 2' _ "$2" "$MD_TMP/follow.out" \
      "$MD_TMP/follow.sh" "$MD_TMP/watch.log" > "$MD_TMP/follow.out.part" 2>&1 < /dev/null &
  fi
  follow_pid=$!
  set +m
  for ((attempt=0; attempt<500; attempt++)); do
    [ "$("$1")" -lt 2 ] || break
    sleep 0.01
  done
  printf ' d  e\n' >> "$MD_TMP/watch.log"
  for ((attempt=0; attempt<500; attempt++)); do
    [ "$("$1")" -lt 3 ] || break
    sleep 0.01
  done
  kill -TERM -- "-$follow_pid" 2>/dev/null || true
  wait "$follow_pid" 2>/dev/null || true
  FOLLOW_OUT="$(cat "$MD_TMP/follow.out" 2>/dev/null)" || FOLLOW_OUT=""
}
FOLLOW_WANT="$(printf '2: b\n3: c\n4:  d  e')"
follow_run follow_lines
if [ "$FOLLOW_OUT" = "$FOLLOW_WANT" ]; then
  pass "the follow numbers each line from its start line as it arrives"
else
  fail "the follow printed: $FOLLOW_OUT"
fi
follow_run follow_lines 0.3
if [ "$FOLLOW_OUT" = "$FOLLOW_WANT" ]; then
  pass "the follow row waits for a follow.out opened late"
else
  fail "with follow.out opened late the follow printed: $FOLLOW_OUT"
fi

md_report
