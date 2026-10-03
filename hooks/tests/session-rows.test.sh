#!/usr/bin/env bash
# The session rows the session-start-row, session-end-row and stop-failure-row
# hooks write: each runs the lane-mail-check hook beside it with the argument
# `row`, which appends the payload's event as one JSON row through the orch
# skill's lib/session-rows.sh to the session's file in the overseer mailbox
# directory, and refuses nothing. Every case builds a main checkout under
# TMP_ROOT with the install a kendex project renders, runs a wrapper with a
# payload in the shape Claude Code 2.1.283 emits, and asserts the exit status,
# the keyed first line of stderr and the row. HOOK_UNDER_TEST overrides the
# lane-mail-check copy the control at the end runs against.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$(cd "$TEST_DIR/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOKS/lane-mail-check.sh}"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo "session-rows: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "session-rows: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "session-rows: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
PASS=0
FAIL=0

assert_eq() { # GOT WANT LABEL
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$3" "$2" "$1"
  fi
}

# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# `display-message -p -t <pane> FORMAT`, the two tmux reads a row takes:
# `#{pid}`, the server's pid TMUX_SERVER_ID names, and `#{pane_pid}`, the
# pane's shell, which TMUX_PANE_PID names; and `#{pid} #{start_time}`, the
# server's start the turn-end hook binds the fleet record by, 1790000000.
TMUX_BIN="$TMP_ROOT/tmux-bin"
mkdir -p "$TMUX_BIN"
cat > "$TMUX_BIN/tmux" <<'TMUXSTUB'
#!/bin/sh
[ -n "${TMUX_SERVER_ID:-}" ] || { echo "can't find pane" >&2; exit 1; }
for format in "$@"; do :; done
case "$format" in
  '#{pane_pid}') printf '%s\n' "${TMUX_PANE_PID:-}" ;;
  '#{pid} #{start_time}') printf '%s 1790000000\n' "$TMUX_SERVER_ID" ;;
  *) printf '%s\n' "$TMUX_SERVER_ID" ;;
esac
TMUXSTUB
chmod +x "$TMUX_BIN/tmux"

# A main checkout on `main`, with the orch install and the hooks under
# .claude, and the overseer mailbox directory the fleet makes. CHECKOUT is the
# repository, ROWS the file the session in pane %9 on server 7000 writes.
CHECKOUT=""
ROWS=""
HOOK_HOME=.claude/hooks
new_checkout() { # NAME [HOOK_HOME]
  local wrapper
  HOOK_HOME="${2:-.claude/hooks}"
  CHECKOUT="$TMP_ROOT/$1"
  mkdir -p "$CHECKOUT"
  git -C "$CHECKOUT" init -q
  git -C "$CHECKOUT" checkout -q -b main
  git -C "$CHECKOUT" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
  mkdir -p "$CHECKOUT/.agents/skills/orch" "$CHECKOUT/$HOOK_HOME" "$CHECKOUT/.claude/skills" \
    "$CHECKOUT/tmp/lane-mail/overseer"
  ln -s "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
  ln -s ../../.agents/skills/orch "$CHECKOUT/.claude/skills/orch"
  cp "$HOOK" "$CHECKOUT/$HOOK_HOME/lane-mail-check.sh"
  for wrapper in session-start-row session-end-row stop-failure-row; do
    cp "$HOOKS/$wrapper.sh" "$CHECKOUT/$HOOK_HOME/$wrapper.sh"
  done
  ROWS="$CHECKOUT/tmp/lane-mail/overseer/session-7000-9.jsonl"
}

RC=0
# in_pane COMMAND... — COMMAND as a harness in pane %9 runs its hook: a pane
# shell, whose pid is the pane's, then one process that is no shell, perl
# standing in for the harness, forking COMMAND. NESTED=1 puts a second such
# process between them, a harness another harness started in the same pane.
in_pane() { # COMMAND...
  local harness=(perl -e 'exit(system(@ARGV) >> 8)' --)
  [ "${NESTED:-0}" -eq 0 ] || harness+=(perl -e 'exit(system(@ARGV) >> 8)' --)
  bash -c 'TMUX_PANE_PID=$$ "$@"; exit $?' pane-shell "${harness[@]}" "$@"
}
# run WRAPPER PAYLOAD [ENV=VAL...] — the wrapper as the harness runs it, from
# the checkout, inside pane %9 of server 7000 on the account /accounts/one.
run() { # WRAPPER PAYLOAD [ENV=VAL...]
  local wrapper="$1" payload="$2"
  shift 2
  RC=0
  printf '%s' "$payload" |
    (cd "$CHECKOUT" && env -u CLAUDE_PROJECT_DIR -u CODEX_HOME -u LANE_MAIL_ITEM \
      "PATH=$TMUX_BIN:$PATH" TMUX=fake TMUX_PANE=%9 TMUX_SERVER_ID=7000 \
      CLAUDE_CONFIG_DIR=/accounts/one "$@" bash -c "$(declare -f in_pane); in_pane \"\$@\"" _ \
      bash "$CHECKOUT/$HOOK_HOME/$wrapper.sh") \
    >"$TMP_ROOT/stdout" 2>"$ERR_FILE" || RC=$?
}

# Payloads as Claude Code 2.1.283 builds them: every hook input carries
# session_id, transcript_path, cwd and permission_mode; SessionStart adds
# source and model, SessionEnd reason, StopFailure error, error_details and
# last_assistant_message, and a subagent's turn its agent_id.
BASE='"session_id":"5f0c","transcript_path":"/t/5f0c.jsonl","cwd":"/work","permission_mode":"default"'
START="{\"hook_event_name\":\"SessionStart\",$BASE,\"source\":\"startup\",\"model\":\"claude-fable-5-1\"}"
END="{\"hook_event_name\":\"SessionEnd\",$BASE,\"reason\":\"prompt_input_exit\"}"
WALL="{\"hook_event_name\":\"StopFailure\",$BASE,\"error\":\"rate_limit\",\"last_assistant_message\":\"You've hit your limit · resets 9:50am\"}"
SUB_WALL="{\"hook_event_name\":\"StopFailure\",$BASE,\"agent_id\":\"a1\",\"error\":\"rate_limit\"}"
STOP="{\"hook_event_name\":\"Stop\",$BASE,\"stop_hook_active\":false}"

last_row() { # JQ
  [ -f "$ROWS" ] || { echo absent; return 0; }
  tail -n 1 "$ROWS" | jq -r "$1"
}
row_count() { [ -f "$ROWS" ] && wc -l < "$ROWS" | tr -d ' ' || echo 0; }

echo "=== session rows ==="

# One table: each wrapper and payload, and the row it leaves. `-` is no row.
while IFS='|' read -r label wrapper payload want; do
  new_checkout "$label"
  run "$wrapper" "$payload"
  got="$(last_row '[.event, .harness, .session_id, .transcript_path, .cwd, .account, (.source // .reason // .error // "-")] | join(",")')"
  assert_eq "RC=$RC first=$(first_line) row=$got" "RC=0 first=- row=$want" "$label"
done <<ROWSTABLE
start|session-start-row|$START|SessionStart,claude,5f0c,/t/5f0c.jsonl,/work,/accounts/one,startup
end|session-end-row|$END|SessionEnd,claude,5f0c,/t/5f0c.jsonl,/work,/accounts/one,prompt_input_exit
wall|stop-failure-row|$WALL|StopFailure,claude,5f0c,/t/5f0c.jsonl,/work,/accounts/one,rate_limit
ROWSTABLE

new_checkout wall_message
run stop-failure-row "$WALL"
assert_eq "$(last_row '.message')|$(last_row '.at | type')" "You've hit your limit · resets 9:50am|number" \
  "a StopFailure row keeps the harness's own message, and every row its time"

# What writes nothing, silently: a subagent's failure, a checkout the fleet
# never made a mailbox directory in, a session outside tmux, and a lane's own
# session.
new_checkout subagent
run stop-failure-row "$SUB_WALL"
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=- rows=0" \
  "a subagent's failure is no row of the session's"
# A Stop is written at every turn end, compact, its time, event, harness and
# session alone, so the file takes one per turn; over a standing StopFailure it
# is written whole, and lifts it.
new_checkout stop_alone
run session-start-row "$START"
run session-start-row "$STOP"
assert_eq "RC=$RC rows=$(row_count) row=$(last_row '[keys[]] | join(",")')" "RC=0 rows=2 row=at,event,harness,session_id" \
  "a Stop with no StopFailure standing writes a compact Stop row"
run stop-failure-row "$WALL"
run session-start-row "$STOP"
assert_eq "RC=$RC rows=$(row_count) last=$(last_row .event) path=$(last_row .transcript_path)" "RC=0 rows=4 last=Stop path=/t/5f0c.jsonl" \
  "a Stop over a StopFailure row is written whole and lifts it"
# A start many turns back is still the session's start: its readers look for
# the last row of an event among the rows naming it, not in the last lines.
for _ in $(seq 70); do run session-start-row "$STOP"; done
start_found() { # LIBRARY
  bash -c 'set -euo pipefail; . "$1"; session_rows_start "$2" && printf "%s\n" "$SR_MODEL"' _ "$1" "$ROWS" 2>/dev/null || echo none
}
assert_eq "$(start_found "$REPO_ROOT/skills/orch/scripts/lib/session-rows.sh")" "claude-fable-5-1" \
  "a SessionStart seventy Stop rows back is still read"
new_checkout no_fleet
rm -rf -- "${CHECKOUT:?}/tmp"
run session-start-row "$START"
assert_eq "RC=$RC first=$(first_line) made=$([ -e "$CHECKOUT/tmp" ] && echo yes || echo no)" "RC=0 first=- made=no" \
  "a checkout with no overseer mailbox directory gets no row and no directory"
new_checkout outside_tmux
run session-start-row "$START" TMUX= TMUX_PANE=
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=- rows=0" \
  "a session outside tmux has no pane to key a row by"
new_checkout lane
git -C "$CHECKOUT" checkout -q -b ken-9
mkdir -p "$CHECKOUT/tmp/lane-mail/KEN-9"
run session-start-row "$START"
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=- rows=0" \
  "a lane's session writes no overseer row"

# A harness the overseer started in its own pane, second-opinion's
# `claude -p` or a `codex exec`, inherits TMUX_PANE: its hook is two
# harnesses from the pane shell and writes no row, so no reader meets another
# session's facts in this pane's file.
new_checkout nested
NESTED=1 run session-end-row "$END"
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=- rows=0" \
  "a harness nested in the pane's own harness writes no row"

# The harness a row names is the one the hook's install directory names.
new_checkout codex_install .codex/hooks
run session-start-row "$START"
assert_eq "RC=$RC harness=$(last_row .harness)" "RC=0 harness=codex" \
  "a hook installed under .codex/hooks writes a codex row"

# Copilot, from .github/hooks, with payloads in the camelCase shape Copilot
# CLI 1.0.91 sent tools/harness-smoke's event rows: no hook_event_name, the
# session as sessionId, sessionStart and sessionEnd for the lead alone, and an
# errorOccurred for each try of a failed model call, its error an object.
# The lead's session is recorded where lane-mail-start records it at the
# session's start, under the user's cache; c1 is a session nothing recorded.
COP_HOME_DIR="$TMP_ROOT/cop-home"
mkdir -p "$COP_HOME_DIR/.cache/lane-mail/copilot-leads"
: > "$COP_HOME_DIR/.cache/lane-mail/copilot-leads/l1"
COP_BASE='"sessionId":"l1","timestamp":1790975267602,"cwd":"/work"'
COP_START="{$COP_BASE,\"source\":\"new\",\"initialPrompt\":\"Reply with ok.\"}"
COP_END="{$COP_BASE,\"reason\":\"error\"}"
COP_ERROR='"recoverable":true,"error":{"message":"429 limit reached","name":"Error","stack":"Error: 429"}'
COP_WALL="{$COP_BASE,\"errorContext\":\"model_call\",$COP_ERROR}"
COP_TOOL_FAIL="{$COP_BASE,\"errorContext\":\"tool_execution\",$COP_ERROR}"
COP_SUB_WALL="{\"sessionId\":\"c1\",\"timestamp\":1,\"cwd\":\"/work\",\"errorContext\":\"model_call\",$COP_ERROR}"
COP_ENV=("HOME=$COP_HOME_DIR" COPILOT_HOME=/accounts/cop)
while IFS='|' read -r label wrapper payload want; do
  new_checkout "$label" .github/hooks
  run "$wrapper" "$payload" "${COP_ENV[@]}"
  got="$(last_row '[.event, .harness, .session_id, .cwd, .account, (.source // .reason // .message // "-")] | join(",")')"
  assert_eq "RC=$RC first=$(first_line) row=$got" "RC=0 first=- row=$want" "$label"
done <<ROWSTABLE
copilot start|session-start-row|$COP_START|SessionStart,copilot,l1,/work,/accounts/cop,new
copilot end|session-end-row|$COP_END|SessionEnd,copilot,l1,/work,/accounts/cop,error
copilot model-call failure|stop-failure-row|$COP_WALL|StopFailure,copilot,l1,/work,/accounts/cop,429 limit reached
copilot tool failure|stop-failure-row|$COP_TOOL_FAIL|absent
copilot failure of a session no lead record names|stop-failure-row|$COP_SUB_WALL|absent
ROWSTABLE

# What is reported and passed: an install whose orch scripts lack the row
# library, a key tmux cannot answer, and a wrapper with no judge beside it.
new_checkout no_library
rm -f -- "$CHECKOUT/.agents/skills/orch/scripts"
mkdir -p "$CHECKOUT/.agents/skills/orch/scripts/lib"
ln -s "$REPO_ROOT/skills/orch/scripts/lane-mail" "$CHECKOUT/.agents/skills/orch/scripts/lane-mail"
run session-start-row "$START"
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" \
  "RC=0 first=lane-mail-check: rows-skipped=$CHECKOUT/.claude/skills/orch/scripts/lib/session-rows.sh rows=0" \
  "an install with no row library is reported and the session starts"
new_checkout no_key
run session-start-row "$START" TMUX_SERVER_ID=
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=lane-mail-check: rows-unwritten=$CHECKOUT rows=0" \
  "a pane tmux cannot key is reported and the session starts"
new_checkout no_judge
rm -f -- "$CHECKOUT/.claude/hooks/lane-mail-check.sh"
for wrapper in session-start-row session-end-row stop-failure-row; do
  run "$wrapper" "$START"
  assert_eq "RC=$RC first=$(first_line)" "RC=0 first=$wrapper: judge=$CHECKOUT/.claude/hooks/lane-mail-check.sh" \
    "$wrapper with no judge beside it is reported and passed"
done

# The overseer's own turn end writes the Stop that lifts its wall. The fleet
# state names pane %9 on server 7000 as the overseer, and a judge stub puts it
# under both marks, so the turn ends; what it judges is lane-mail-check.test.sh's.
new_checkout overseer_stop
rm -f -- "$CHECKOUT/.agents/skills/orch/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
printf '#!/bin/sh\necho "oversee-succeed: context-below-mark tokens=1 mark=500000 headroom=80"\n' \
  > "$CHECKOUT/.agents/skills/orch/scripts/oversee-succeed"
(cd "$CHECKOUT" && .agents/skills/orch/scripts/workflow-state init oversee >/dev/null \
  && .agents/skills/orch/scripts/workflow-state set oversee overseer '{"server":"7000","server_start":1790000000,"pane":"%9"}' >/dev/null)
run stop-failure-row "$WALL"
RC=0
printf '%s' '{"session_id":"5f0c","stop_hook_active":false}' |
  (cd "$CHECKOUT" && env -u CLAUDE_PROJECT_DIR -u CODEX_HOME "PATH=$TMUX_BIN:$PATH" TMUX=fake TMUX_PANE=%9 \
    TMUX_SERVER_ID=7000 CLAUDE_CONFIG_DIR=/accounts/one bash -c "$(declare -f in_pane); in_pane \"\$@\"" _ \
    bash "$CHECKOUT/.claude/hooks/lane-mail-check.sh") \
  >"$TMP_ROOT/stdout" 2>"$ERR_FILE" || RC=$?
assert_eq "RC=$RC rows=$(row_count) last=$(last_row .event)" "RC=0 rows=2 last=Stop" \
  "the overseer's turn end, whose payload names no event, writes the Stop over its wall"

# --- control ------------------------------------------------------------------
# The row arm's write removed from a copy of the hook: the start row is gone.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  MUTANT="$TMP_ROOT/mutant-lane-mail-check.sh"
  cp "$HOOK" "$MUTANT"
  ROW_WRITE='  if [ -z "$ITEM" ] && { [ "$HARNESS" != copilot ] || [ "$CALLER" = lead ]; }; then'
  assert_eq "$(grep -c -x -F -- "$ROW_WRITE" "$MUTANT")" "1" "control finds the row arm's write"
  ROW_WRITE="$ROW_WRITE" perl -i -pe 's/^\Q$ENV{ROW_WRITE}\E$/  if false; then/' "$MUTANT"
  assert_eq "$(grep -c -x -F -- "$ROW_WRITE" "$MUTANT")" "0" "control removed it"
  CONTROL_OUT="$(HOOK_UNDER_TEST="$MUTANT" bash "${BASH_SOURCE[0]}" 2>&1 || true)"
  assert_eq "$(grep -c '^  FAIL  start$' <<<"$CONTROL_OUT")" "1" \
    "control: without the row arm's write the start row is not written"
fi
# The library's compact Stop rule removed from a copy of the orch scripts: a
# Stop with no wall standing then lands whole.
new_checkout stop_control
rm -f -- "$CHECKOUT/.agents/skills/orch/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
LIB="$CHECKOUT/.agents/skills/orch/scripts/lib/session-rows.sh"
STOP_RULE='!= StopFailure ]; then'
assert_eq "$(grep -c -F -- "$STOP_RULE" "$LIB")" "1" "control finds the Stop rule"
sed -i.bak 's/!= StopFailure \]; then/= Never ]; then/' "$LIB"
assert_eq "$(grep -c -F -- "$STOP_RULE" "$LIB")" "0" "control removed it"
run session-start-row "$STOP"
assert_eq "path=$(last_row .transcript_path)" "path=/t/5f0c.jsonl" "control: without the compact Stop rule a turn's Stop lands whole"
# Each camelCase read removed from a copy of the orch scripts: a Copilot
# failure's row then lacks what that read carries.
n=0
while IFS='@' read -r old new field label; do
  n=$((n + 1))
  new_checkout "camel_control_$n" .github/hooks
  rm -f -- "${CHECKOUT:?}/.agents/skills/orch/scripts"
  cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
  CAMEL_LIB="$CHECKOUT/.agents/skills/orch/scripts/lib/session-rows.sh"
  assert_eq "$(grep -c -F -- "$old" "$CAMEL_LIB")" "1" "control finds: $old"
  OLD="$old" NEW="$new" perl -i -pe 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$CAMEL_LIB"
  assert_eq "$(grep -c -F -- "$old" "$CAMEL_LIB")" "0" "control removed: $old"
  run stop-failure-row "$COP_WALL" "${COP_ENV[@]}"
  assert_eq "RC=$RC $field=$(last_row ".$field // \"-\"")" "RC=0 $field=-" "control: $label"
done <<'CAMEL'
({session_id: (.session_id // .sessionId), transcript_path@({session_id, transcript_path@session_id@without the sessionId read a Copilot failure's row names no session
elif ($error_message | type) == "string" then@elif false then@message@without the error object's read a Copilot failure's row carries no message
CAMEL
# The event list removed from the reader: a start seventy Stops back is lost.
READ_RULE='    lines="$(grep -F -- "\"event\":\"$2\"" "$1")" || rc=$?'
assert_eq "$(grep -c -F -- "$READ_RULE" "$LIB")" "1" "control finds the event list"
READ_RULE="$READ_RULE" perl -i -pe 's/\Q$ENV{READ_RULE}\E/    lines="\$(cat -- "\$1")" || rc=\$?/' "$LIB"
assert_eq "$(grep -c -F -- "$READ_RULE" "$LIB")" "0" "control removed the event list"
new_checkout start_span_control
run session-start-row "$START"
for _ in $(seq 70); do run session-start-row "$STOP"; done
assert_eq "$(start_found "$LIB")" "none" "control: a reader taking the last lines alone loses a start seventy Stops back"
# The top-level gate removed from the same copy: a nested harness writes.
mutate_lib() { # OLD NEW
  assert_eq "$(grep -c -F -- "$1" "$LIB")" "1" "control finds: $1"
  OLD="$1" NEW="$2" perl -i -pe 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$LIB"
  assert_eq "$(grep -c -F -- "$1" "$LIB")" "0" "control removed: $1"
}
new_checkout nested_control
rm -f -- "$CHECKOUT/.agents/skills/orch/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CHECKOUT/.agents/skills/orch/scripts"
LIB="$CHECKOUT/.agents/skills/orch/scripts/lib/session-rows.sh"
mutate_lib '  session_rows_top_level "$pane_pid" || return 0' '  :'
NESTED=1 run session-end-row "$END"
assert_eq "rows=$(row_count)" "rows=1" "control: without the top-level gate a nested harness writes the pane's row"
# The harness read from the install replaced by a fixed word: a codex install
# writes claude.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  HARNESS_MUTANT="$TMP_ROOT/harness-mutant.sh"
  cp "$HOOK" "$HARNESS_MUTANT"
  assert_eq "$(grep -c -F '    _ "$SCRIPTS" "$ROOT" "$HARNESS" "$ROW_EVENT"' "$HARNESS_MUTANT")" "1" "control finds the row's harness"
  sed -i.bak 's/    _ "\$SCRIPTS" "\$ROOT" "\$HARNESS" "\$ROW_EVENT"/    _ "$SCRIPTS" "$ROOT" claude "$ROW_EVENT"/' "$HARNESS_MUTANT"
  assert_eq "$(grep -c -F '    _ "$SCRIPTS" "$ROOT" "$HARNESS" "$ROW_EVENT"' "$HARNESS_MUTANT")" "0" "control replaced it"
  CONTROL_OUT="$(HOOK_UNDER_TEST="$HARNESS_MUTANT" bash "${BASH_SOURCE[0]}" 2>&1 || true)"
  assert_eq "$(grep -c '^  FAIL  a hook installed under .codex/hooks writes a codex row$' <<<"$CONTROL_OUT")" "1" \
    "control: a row harness fixed at claude fails the codex install row"
fi
# The lead-record rule for a Copilot failure removed from a copy of the hook:
# a failure no lead record names then writes the session's row.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  LEAD_MUTANT="$TMP_ROOT/lead-mutant.sh"
  LEAD_RULE='      [ "$ROW_ARG" != StopFailure ] || { copilot_lead_file && [ -f "$LEAD_FILE" ]; } || CALLER=unknown'
  cp "$HOOK" "$LEAD_MUTANT"
  assert_eq "$(grep -c -x -F -- "$LEAD_RULE" "$LEAD_MUTANT")" "1" "control finds the Copilot lead rule"
  LEAD_RULE="$LEAD_RULE" perl -i -pe 's/^\Q$ENV{LEAD_RULE}\E$/      :/' "$LEAD_MUTANT"
  assert_eq "$(grep -c -x -F -- "$LEAD_RULE" "$LEAD_MUTANT")" "0" "control removed it"
  CONTROL_OUT="$(HOOK_UNDER_TEST="$LEAD_MUTANT" bash "${BASH_SOURCE[0]}" 2>&1 || true)"
  assert_eq "$(grep -c '^  FAIL  copilot failure of a session no lead record names$' <<<"$CONTROL_OUT")" "1" \
    "control: without the lead rule a failure no lead record names writes a row"
fi
# The errorContext filter removed from the checkout's copy of stop-failure-row:
# a tool's failure then writes a StopFailure row.
new_checkout context_control .github/hooks
WRAPPER="$CHECKOUT/.github/hooks/stop-failure-row.sh"
CONTEXT_RULE='  *) exit 0 ;;'
assert_eq "$(grep -c -x -F -- "$CONTEXT_RULE" "$WRAPPER")" "1" "control finds the errorContext filter"
CONTEXT_RULE="$CONTEXT_RULE" perl -i -pe 's/^\Q$ENV{CONTEXT_RULE}\E$/  *) ;;/' "$WRAPPER"
assert_eq "$(grep -c -x -F -- "$CONTEXT_RULE" "$WRAPPER")" "0" "control removed it"
run stop-failure-row "$COP_TOOL_FAIL" "${COP_ENV[@]}"
assert_eq "row=$(last_row .event)" "row=StopFailure" "control: without the errorContext filter a tool's failure writes a StopFailure row"
# The event the wrapper names removed from the checkout's copy of
# session-start-row: a Copilot payload, which spells none, writes no row.
new_checkout event_control .github/hooks
WRAPPER="$CHECKOUT/.github/hooks/session-start-row.sh"
EVENT_RULE='exec "$BASH" "$JUDGE" row SessionStart'
assert_eq "$(grep -c -x -F -- "$EVENT_RULE" "$WRAPPER")" "1" "control finds the wrapper's event"
EVENT_RULE="$EVENT_RULE" perl -i -pe 's/^\Q$ENV{EVENT_RULE}\E$/exec "\$BASH" "\$JUDGE" row/' "$WRAPPER"
assert_eq "$(grep -c -x -F -- "$EVENT_RULE" "$WRAPPER")" "0" "control removed it"
run session-start-row "$COP_START" "${COP_ENV[@]}"
assert_eq "RC=$RC first=$(first_line) rows=$(row_count)" "RC=0 first=lane-mail-check: rows-unwritten=$CHECKOUT rows=0" \
  "control: without the wrapper's event a Copilot start writes no row"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
