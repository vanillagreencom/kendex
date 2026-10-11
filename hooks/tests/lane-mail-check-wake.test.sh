#!/usr/bin/env bash
# The registered session's wake, over real processes with the follow and
# single-pass argv watch-delivery produces. The harness rows drive the hook's
# existing lead identity and refusal formats, not a second wake implementation.
# HOOK_UNDER_TEST selects the planted copy for each must-fail control.
set -euo pipefail
export MSYS=winsymlinks:nativestrict

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

SELECTED=""
if [ "${1:-}" = --wake-row ]; then SELECTED=$2; fi
REARM='sh "[RUN_DIR]/follow.sh" "[RUN_DIR]/watch.log" [NEXT_LINE]'
JARVIS_START='run-jarvis-wake --resume'

# CASE|HARNESS|EXIT|STDERR-KEY|DECISION|CONTEXT-KEY|COMMAND-COUNT[|WAKE-NOTICE]
# Stop, Codex Stop and Copilot agentStop are held. Pi's carrier can make only
# one further model request, so these are hook-format tests, not proof of an
# indefinitely held Pi turn. Unsupported harnesses dispatch no hook at all.
while IFS='|' read -r scenario harness want_rc first decision context commands wake_notice; do
  [ -z "$SELECTED" ] || [ "$scenario:$harness" = "$SELECTED" ] || continue
  stop_wake_processes
  wake_overseer "wake-$scenario-$harness" "$harness"
  command=$REARM
  payload='{"session_id":"s1","stop_hook_active":false}'
  if [ "$harness" = copilot ]; then
    payload=$(jq -nc --arg p "$COP_HOME/session-state/s1/events.jsonl" '{sessionId:"s1",transcriptPath:$p,timestamp:1}') || exit 1
  fi
  case "$scenario" in
    armed) start_wake_watch repeat; start_follow ;;
    succession-stale | succession-armed)
      # watch-handover writes the live stdout log beside the fleet state.
      # An idle linked reader cannot arm a follow running on an old log.
      start_wake_watch repeat
      printf 'pid=%s\nstate=%s\npane=none\norigin=succession\ncwd=%s\n' "$WAKE_PID" "$WAKE_STATE" "$LANE" \
        > "${WAKE_STATE%/*}/oversee-watch.pid"
      live_log="${WAKE_STATE%/*}/oversee-watch.log"
      : > "$live_log"
      : > "$LANE/tmp/old-watch.log"
      mkdir -p "$LANE/tmp/waiter.fixture" "$LANE/tmp/waiter.linked"
      ln -s "$LANE/tmp/old-watch.log" "$LANE/tmp/waiter.fixture/watch.log"
      ln -s "$live_log" "$LANE/tmp/waiter.linked/watch.log"
      [ -L "$LANE/tmp/waiter.fixture/watch.log" ] && [ -L "$LANE/tmp/waiter.linked/watch.log" ]
      start_follow
      if [ "$scenario" = succession-armed ]; then
        wake_process "$LANE/tmp/waiter.linked/follow.sh" "$LANE/tmp/waiter.linked/watch.log" 1
      fi
      ;;
    no-follow | continuation | continuation-mark | agent-id | agent-type | subagent-stop | other-session | no-pgrep | probe-error | probe-error-mark | watch-probe-error | record-cwd | record-armed | missing-cwd | unreadable-record)
      start_wake_watch repeat
      ;;
    single) start_wake_watch single ;;
    jarvis-live | jarvis-dead | jarvis-continuation | incomplete-jarvis)
      command=$JARVIS_START
      if [ "$scenario" = jarvis-live ]; then
        wake_process "$TMP_ROOT/jarvis-wake" --fleet "$LANE"
        CALL_ENV+=("ORCH_WAKE_PROCESS=jarvis-wake --fleet $LANE")
      else
        CALL_ENV+=("ORCH_WAKE_PROCESS=jarvis-wake --fleet $LANE")
      fi
      CALL_ENV+=("ORCH_WAKE_START=$JARVIS_START")
      ;;
    empty-keys | absent-keys) command="" ;;
    no-record)
      command=""
      (cd -- "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set oversee overseer null >/dev/null)
      CALL_ENV+=(ORCH_WAKE_PROCESS=never-matched "ORCH_WAKE_START=$JARVIS_START")
      ;;
    *) echo "wake-suite: case=unknown value=$scenario" >&2; exit 1 ;;
  esac
  case "$scenario" in
    no-follow)
      # A matched Jarvis session setting cannot replace a repeat follow. The live
      # watch is also deliberately left running throughout the refusal.
      CALL_ENV+=("ORCH_WAKE_PROCESS=oversee-watc[h]" "ORCH_WAKE_START=$JARVIS_START")
      ;;
    continuation | continuation-mark | jarvis-continuation) payload=$(jq -c '. + {stop_hook_active:true}' <<< "$payload") || exit 1 ;;
    agent-id) payload=$(jq -c '. + {agent_id:"child"}' <<< "$payload") || exit 1 ;;
    agent-type) payload=$(jq -c '. + {agent_type:"worker"}' <<< "$payload") || exit 1 ;;
    subagent-stop) payload=$(jq -c '. + {hook_event_name:"SubagentStop"}' <<< "$payload") || exit 1 ;;
    other-session) CALL_ENV+=(TMUX_PANE=%3) ;;
    no-pgrep) wake_without_pgrep ;;
    probe-error | probe-error-mark)
      printf '#!/bin/sh\necho "probe failed" >&2\nexit 2\n' > "$TMUX_BIN/pgrep"
      chmod +x "$TMUX_BIN/pgrep"
      ;;
    watch-probe-error)
      executable=$(command -v ps) || exit 1
      {
        printf '#!/bin/sh\n'
        printf 'if [ "$2" = stat= ]; then echo "watch-query-failed" >&2; exit 1; fi\n'
        printf 'exec %q "$@"\n' "$executable"
      } > "$TMUX_BIN/ps"
      chmod +x "$TMUX_BIN/ps"
      ;;
    record-cwd | record-armed)
      # A follow on the session root does not arm a watch whose claim names
      # another cwd. The path includes regex characters and a space.
      stop_wake_processes
      start_wake_watch repeat "$TMP_ROOT/watch [cwd].root"
      if [ "$scenario" = record-armed ]; then start_follow "$TMP_ROOT/watch [cwd].root"; else start_follow; fi
      ;;
    missing-cwd)
      sed '/^cwd=/d' "${WAKE_STATE%/*}/oversee-watch.pid" > "$TMP_ROOT/claim"
      mv -- "$TMP_ROOT/claim" "${WAKE_STATE%/*}/oversee-watch.pid"
      ;;
    unreadable-record)
      rm -- "${WAKE_STATE%/*}/oversee-watch.pid"
      mkdir -- "${WAKE_STATE%/*}/oversee-watch.pid"
      ;;
    empty-keys) CALL_ENV+=(ORCH_WAKE_PROCESS= ORCH_WAKE_START=) ;;
    incomplete-jarvis) CALL_ENV+=(ORCH_WAKE_START=); command="" ;;
  esac
  if [ -n "$wake_notice" ]; then
    # An unarmed continuation or failed wake probe coincides with a handoff
    # mark. Its Stop row and context record must still land.
    judge_says "$CONTEXT_MARK_LINE"
    wake_row_process_table
    mkdir -p "$LANE/tmp/lane-mail/overseer"
  fi
  record_key="wake-record=${WAKE_STATE%/*}/oversee-watch.pid"
  process_key="wake-process=follow[.]sh ${LANE//./\\.}/tmp/waiter[.][^/]*/watch[.]log"
  case "$context" in record) context=$record_key ;; process) context=$process_key ;; esac
  case "$first" in record) first=$record_key ;; process) first=$process_key ;; esac
  [ "$first" = - ] || first="lane-mail-check: $first"
  [ "$context" = - ] || context="lane-mail-check: $context"
  run_payload "$payload"
  got=$(wake_observation "$command") || exit 1
  want="RC=$want_rc first=$first decision=$decision context=$context command=$commands"
  # Exit 0 alone does not end Claude Stop: additionalContext requests a turn.
  # Pin the whole output count.
  objects=$(jq -s 'length' "$TMP_ROOT/stdout") || exit 1
  event=$(jq -rs '.[0].hookSpecificOutput.hookEventName // "-"' "$TMP_ROOT/stdout") || exit 1
  want_objects=0 want_event=-
  if [ "$decision" = block ]; then want_objects=1; fi
  got="$got replies=$objects event=$event"
  want="$want replies=$want_objects event=$want_event"
  case "$scenario" in
    succession-stale | succession-armed)
      # The re-arm instruction carries the log path the caller must link.
      log_paths=$(grep -Fc -- "$live_log" "$ERR_FILE" || :)
      want_paths=0
      [ "$scenario" != succession-stale ] || want_paths=1
      got="$got log=$log_paths"
      want="$want log=$want_paths"
      ;;
  esac
  if [ -n "$wake_notice" ]; then
    row=$(jq -rs 'map([.event, .harness] | join(":")) | join(",")' \
      "$LANE/tmp/lane-mail/overseer/session-$OVERSEER_SERVER-${OVERSEER_PANE#%}.jsonl") || exit 1
    record=$(jq -r '[.harness, .session_id, .pane_key, (.tokens | tostring)] | join(":")' \
      "$LANE/tmp/lane-mail/overseer/context.json") || exit 1
    notices=$(grep -c "^lane-mail-check: $wake_notice" "$ERR_FILE") || exit 1
    objects=$(jq -s 'length' "$TMP_ROOT/stdout") || exit 1
    case "$harness" in
      copilot)
        # The wake warning joins the block reason, never a second JSON reply.
        reason=$(jq -r '.reason | split("\n") | map(select(startswith("lane-mail-check: wake"))) | length' "$TMP_ROOT/stdout") || exit 1
        output="objects=1 reason=1"
        tokens=100000
        ;;
      *) reason=-; output="objects=0 reason=-"; tokens=null ;;
    esac
    got="$got row=$row record=$record notices=$notices objects=$objects reason=$reason"
    want="$want row=Stop:$harness record=$harness:s1:$OVERSEER_SERVER $OVERSEER_PANE:$tokens notices=1 $output"
  fi
  assert_eq "$got" "$want" "$scenario:$harness"
  rm -f -- "$TMUX_BIN/pgrep" "$TMUX_BIN/ps"
done <<'ROWS'
armed|claude|0|-|-|-|0
armed|codex|0|-|-|-|0
armed|copilot|0|-|-|-|0
armed|pi|0|-|-|-|0
succession-stale|claude|2|wake=unarmed|-|-|1
succession-stale|codex|2|wake=unarmed|-|-|1
succession-stale|copilot|0|wake=unarmed|block|-|1
succession-stale|pi|2|wake=unarmed|-|-|1
succession-armed|claude|0|-|-|-|0
succession-armed|codex|0|-|-|-|0
succession-armed|copilot|0|-|-|-|0
succession-armed|pi|0|-|-|-|0
no-follow|claude|2|wake=unarmed|-|-|1
no-follow|codex|2|wake=unarmed|-|-|1
no-follow|copilot|0|wake=unarmed|block|-|1
no-follow|pi|2|wake=unarmed|-|-|1
continuation|claude|0|wake=unarmed|-|-|1
continuation|codex|0|wake=unarmed|-|-|1
continuation|copilot|0|wake=unarmed|-|-|1
continuation|pi|0|wake=unarmed|-|-|1
continuation-mark|claude|2|context=612000|-|-|1|wake=unarmed
continuation-mark|codex|2|context=612000|-|-|1|wake=unarmed
continuation-mark|copilot|0|context=612000|block|-|1|wake=unarmed
continuation-mark|pi|2|context=612000|-|-|1|wake=unarmed
probe-error-mark|claude|2|context=612000|-|-|0|wake-process=
probe-error-mark|codex|2|context=612000|-|-|0|wake-process=
probe-error-mark|copilot|0|context=612000|block|-|0|wake-process=
probe-error-mark|pi|2|context=612000|-|-|0|wake-process=
agent-id|claude|0|-|-|-|0
agent-type|codex|0|-|-|-|0
subagent-stop|claude|0|-|-|-|0
other-session|claude|0|-|-|-|0
single|claude|0|-|-|-|0
jarvis-live|claude|0|-|-|-|0
jarvis-dead|claude|2|wake=unarmed|-|-|1
jarvis-continuation|claude|0|wake=unarmed|-|-|1
empty-keys|claude|0|-|-|-|0
absent-keys|claude|0|-|-|-|0
no-record|claude|0|-|-|-|0
no-pgrep|claude|0|wake-tools=pgrep|-|-|0
probe-error|claude|0|process|-|-|0
watch-probe-error|claude|0|record|-|-|0
record-cwd|claude|2|wake=unarmed|-|-|1
record-armed|claude|0|-|-|-|0
missing-cwd|claude|0|record|-|-|0
unreadable-record|claude|0|record|-|-|0
incomplete-jarvis|claude|0|wake-setting=ORCH_WAKE_START|-|-|0
ROWS

# Copilot's custom subagent names its own session and the lead's transcript.
# This is the measured agentStop producer, distinct from agent_id/type.
if [ -z "$SELECTED" ]; then
  stop_wake_processes
  wake_overseer wake-copilot-child copilot
  start_wake_watch repeat
  payload=$(jq -nc --arg p "$COP_HOME/session-state/s1/events.jsonl" '{sessionId:"child",transcriptPath:$p,timestamp:1}') || exit 1
  run_payload "$payload"
  got=$(wake_observation "$REARM") || exit 1
  assert_eq "$got" 'RC=0 first=- decision=- context=- command=0' 'Copilot custom subagent exclusion'

  wake_control disabled no-follow:claude \
    '      refuse wake unarmed "$start"' \
    '      message wake unarmed "$start"; return 0'
  wake_control stale-log-accepted succession-stale:claude \
    '        [ "$dir/watch.log" -ef "$log" ] || continue' \
    '        : "$dir/watch.log" "$log"'
  wake_control continued-held continuation:claude \
    '      [ "$CONTINUED" != true ] || { wake_report wake unarmed "$start"; return 0; }' \
    '      [ "$CONTINUED" != true ] || refuse wake unarmed "$start"'
  wake_control empty-held absent-keys:claude \
    '      [ "$mode" != single ] || return 0' \
    '      [ "$mode" != single ] || refuse wake unarmed "$start"'
  wake_control unavailable-held no-pgrep:claude \
    '  command -v pgrep >/dev/null 2>&1 || { wake_report wake-tools pgrep; return 0; }' \
    '  command -v pgrep >/dev/null 2>&1 || refuse wake-tools pgrep'
  wake_control warning-exits continuation-mark:claude \
    '  WAKE_NOTICE=$(message "$@" 2>&1) || refuse notice unwritten "$WAKE_NOTICE"' \
    '  WAKE_NOTICE=$(message "$@" 2>&1) || refuse notice unwritten "$WAKE_NOTICE"; exit 0'
  wake_control warning-continues continuation:claude \
    '      printf '\''%s\n'\'' "$WAKE_NOTICE" >&2' \
    '      printf '\''%s\n'\'' "$WAKE_NOTICE" >&2; CONTEXT_EVENT=Stop; hand_over "$WAKE_NOTICE"'
  wake_control watch-unknown-skips watch-probe-error:claude \
    '        *) exit "$rc" ;;' \
    '        *) printf "single\t" ;;'
fi

printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
