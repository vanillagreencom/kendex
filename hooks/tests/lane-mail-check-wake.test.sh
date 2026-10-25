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
  if [ "$harness" = codex ]; then
    (cd -- "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" update oversee \
      '.overseer += {harness:"codex",generation:1}' >/dev/null)
  fi
  command=$REARM
  payload='{"session_id":"s1","stop_hook_active":false}'
  if [ "$harness" = copilot ]; then
    payload=$(jq -nc --arg p "$COP_HOME/session-state/s1/events.jsonl" '{sessionId:"s1",transcriptPath:$p,timestamp:1}') || exit 1
  fi
  case "$scenario" in
    armed | continuation-live | native-handoff | duty-source-unavailable | duty-capability-unavailable) start_wake_watch repeat; start_follow ;;
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
    continuation | continuation-mark | continuation-live | jarvis-continuation) payload=$(jq -c '. + {stop_hook_active:true}' <<< "$payload") || exit 1 ;;
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
    native-handoff) record_overseer_handoff ;;
    duty-source-unavailable) hole_install lib/session-rows.sh "$LANE/.claude/skills/orch/scripts" ;;
    duty-capability-unavailable)
      hole_install lib/session-rows.sh "$LANE/.claude/skills/orch/scripts"
      sed 's/^session_rows_stop_duty()/session_rows_old_stop_duty()/' \
        "$REPO_ROOT/skills/orch/scripts/lib/session-rows.sh" > "$LANE/.claude/skills/orch/scripts/lib/session-rows.sh"
      ;;
  esac
  if [ -n "$wake_notice" ]; then
    # An unarmed continuation or failed wake probe coincides with a handoff
    # mark. Its Stop row and context record must still land.
    judge_says "$CONTEXT_MARK_LINE"
    wake_row_process_table
    # This row-writer process map ends at this synthetic pane boundary.
    CALL_ENV+=("TMUX_PANE_PID=$OVERSEER_SERVER")
    mkdir -p "$LANE/tmp/lane-mail/overseer"
  fi
  record_key="wake-record=${WAKE_STATE%/*}/oversee-watch.pid"
  process_key="wake-process=follow[.]sh ${LANE//./\\.}/tmp/waiter[.][^/]*/watch[.]log"
  case "$context" in record) context=$record_key ;; process) context=$process_key ;; esac
  case "$first" in record) first=$record_key ;; process) first=$process_key ;; esac
  [ "$first" = - ] || first="lane-mail-check: $first"
  [ "$context" = - ] || context="lane-mail-check: $context"
  run_payload "$payload"
  if [ "$scenario" = continuation-live ]; then
    # Both later Stops use the same live producer and follow, with no fixture
    # keeping a model turn alive. Each production Stop must refuse settlement.
    assert_eq "$RC:$(first_line)" '2:lane-mail-check: native-wait=s1' 'first continued Stop with live wake'
    run_payload "$payload"
  fi
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
armed|codex|2|native-wait=s1|-|-|0
continuation-live|codex|2|native-wait=s1|-|-|0
native-handoff|codex|2|native-wait=s1|-|-|0
duty-source-unavailable|codex|0|native-duty=unavailable|-|-|0
duty-capability-unavailable|codex|0|native-duty=unavailable|-|-|0
armed|copilot|0|-|-|-|0
armed|pi|0|-|-|-|0
succession-stale|claude|2|wake=unarmed|-|-|1
succession-stale|codex|2|wake=unarmed|-|-|1
succession-stale|copilot|0|wake=unarmed|block|-|1
succession-stale|pi|2|wake=unarmed|-|-|1
succession-armed|claude|0|-|-|-|0
succession-armed|codex|2|native-wait=s1|-|-|0
succession-armed|copilot|0|-|-|-|0
succession-armed|pi|0|-|-|-|0
no-follow|claude|2|wake=unarmed|-|-|1
no-follow|codex|2|wake=unarmed|-|-|1
no-follow|copilot|0|wake=unarmed|block|-|1
no-follow|pi|2|wake=unarmed|-|-|1
continuation|claude|0|wake=unarmed|-|-|1
continuation|codex|2|native-wait=s1|-|-|1
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

# The checkout's overseer mailbox reaching a Jarvis session whose wake is set
# through ORCH_WAKE_PROCESS. The hook is the one deliverer of mailbox text: a
# Jarvis wake moves no cursor, so it is no reader, and the pointer route the
# mailbox ships, `lane-mail watch`, run here for real, announces a count and a
# read command and no body. One envelope past the 4000 characters a wake
# event would cut reaches the session once, in full, from the hook's context
# after the tool call, and the turn end hands it no second time.
#   live       the wake runs
#   dead       ORCH_WAKE_PROCESS is set and nothing matches it
#   unwritten  the wake runs and the first tool call's context write fails:
#              the cursor stays, and the next tool call hands the envelope
# WAKE is `pointer`, the real watch, or `rows`, the control: a wake on the
# same argv printing each unread envelope's text cut to 4000 characters.
JARVIS_BODY="jarvis-owner-note:$(printf '0123456789%.0s' $(seq 500)):note-end"
JARVIS_GOT=""
NL=$'\n'
jarvis_text() { # STDOUT-FILE — the context the run wrote there, else nothing
  [ -s "$1" ] || return 0
  jq -r '.hookSpecificOutput.additionalContext // ""' "$1"
}
jarvis_mail() { # live|dead|unwritten pointer|rows
  local wake="$TMP_ROOT/jarvis-rows/lane-mail" out="$TMP_ROOT/jarvis-wake.out" seen=0 tries=0 text failed=- unread_after=- deliver stop
  local tool='{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash"}'
  stop_wake_processes
  wake_overseer "jarvis-mail-$1-$2" claude
  peer_send "$JARVIS_BODY"
  CALL_ENV+=("ORCH_WAKE_PROCESS=lane-mail watch --item overseer --root $LANE" "ORCH_WAKE_START=$JARVIS_START")
  : > "$out"
  if [ "$1" != dead ]; then
    if [ "$2" = rows ]; then
      mkdir -p "${wake%/*}"
      printf '%s\n' '#!/usr/bin/env bash' \
        "\"$LANE_MAIL\" inbox --item overseer --root \"\$5\" --peek | tail -n +2 | jq -r '\"lane-mail: event=mail item=overseer text=\" + (.text | .[0:4000])'" \
        'exec sleep 600' > "$wake"
    else
      wake=$LANE_MAIL
    fi
    (cd -- "$LANE" && exec bash "$wake" watch --item overseer --root "$LANE" --interval 1) > "$out" 2>&1 &
    WAKE_PIDS+=("$!")
    # Real time: the watch polls once a second; 100 tries bound the wait.
    while [ "$tries" -lt 100 ]; do
      seen=$(grep -c '^lane-mail: ' "$out" || :)
      [ "$seen" -eq 0 ] || break
      tries=$((tries + 1))
      sleep 0.1
    done
  fi
  ARM_ARGS=(deliver)
  if [ "$1" = unwritten ]; then
    printf '#!/usr/bin/env bash\nexec >&-\nexec bash %q "$@"\n' "$CASE_HOOK" > "$TMP_ROOT/jarvis-closed.sh"
    local judge=$CASE_HOOK
    CASE_HOOK="$TMP_ROOT/jarvis-closed.sh"
    run_payload "$tool"
    CASE_HOOK=$judge
    failed=$(first_line)
    unread_after=$(overseer_unread "$JARVIS_BODY")
  fi
  run_payload "$tool"
  text=$(jarvis_text "$TMP_ROOT/stdout")
  deliver="$RC:${text%%"$NL"*}"
  ARM_ARGS=()
  stop
  stop="$RC:$(first_line)"
  text="$text$NL$(cat -- "$ERR_FILE")$NL$(jarvis_text "$TMP_ROOT/stdout")$NL$(cat -- "$out")"
  JARVIS_GOT="deliver=$deliver stop=$stop failed=$failed unread-after-failure=$unread_after"
  JARVIS_GOT="$JARVIS_GOT full=$(grep -oF -- "$JARVIS_BODY" <<< "$text" | wc -l | tr -d ' ')"
  JARVIS_GOT="$JARVIS_GOT copies=$(grep -oF -- "jarvis-owner-note:" <<< "$text" | wc -l | tr -d ' ')"
  JARVIS_GOT="$JARVIS_GOT in-wake=$(grep -cF -- "jarvis-owner-note:" "$out" || :) unread=$(overseer_unread "$JARVIS_BODY")"
  stop_wake_processes
}
JARVIS_ONCE="full=1 copies=1 in-wake=0 unread=0"
for jarvis_case in \
  "live|deliver=0:lane-mail-check: unread=1 stop=0:- failed=- unread-after-failure=- $JARVIS_ONCE" \
  "dead|deliver=0:lane-mail-check: unread=1 stop=2:lane-mail-check: wake=unarmed failed=- unread-after-failure=- $JARVIS_ONCE" \
  "unwritten|deliver=0:lane-mail-check: unread=1 stop=0:- failed=lane-mail-check: notice=unwritten unread-after-failure=1 $JARVIS_ONCE"; do
  scenario=${jarvis_case%%|*}
  [ -z "$SELECTED" ] || [ "jarvis-mail-$scenario:claude" = "$SELECTED" ] || continue
  jarvis_mail "$scenario" pointer
  assert_eq "$JARVIS_GOT" "${jarvis_case#*|}" "jarvis-mail-$scenario:claude"
done

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
  wake_control native-process-accepted armed:codex \
    '  [ "$NATIVE_DUTY" != wait ] || refuse native-wait "$SESSION"' \
    '  [ "$NATIVE_DUTY" != wait ] || return 0'
  wake_control native-continued-escape continuation-live:codex \
    '  [ "$NATIVE_DUTY" != wait ] || refuse native-wait "$SESSION"' \
    '  [ "$CONTINUED" = true ] || { [ "$NATIVE_DUTY" != wait ] || refuse native-wait "$SESSION"; }'
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
  # A gate that counts the live Jarvis wake as the mailbox's reader hands the
  # session nothing, and the wake carries no body: the envelope never arrives.
  wake_control jarvis-wake-reads jarvis-mail-live:claude \
    '    ! watch_live || return 0' \
    '    ! watch_live || return 0; ! pgrep -f -- "$ORCH_WAKE_PROCESS" >/dev/null || return 0'
  # Handed and not acknowledged, the envelope is handed again at the turn end.
  wake_control jarvis-unacknowledged jarvis-mail-live:claude \
    '    acknowledge' \
    '    : acknowledge'
  # A context write that fails and passes acknowledges what never arrived.
  wake_control jarvis-unwritten-acks jarvis-mail-unwritten:claude \
    '    2>"$WORK_DIR/notice.err" || refuse notice unwritten "$(cat -- "$WORK_DIR/notice.err")"' \
    '    2>"$WORK_DIR/notice.err" || :'
  # A wake printing the box's rows as events puts the envelope in the
  # session twice, once cut at 4000 characters.
  jarvis_mail live rows
  assert_eq "${JARVIS_GOT#*unread-after-failure=- }" "full=1 copies=2 in-wake=1 unread=0" \
    "control: a wake printing the box's rows hands the envelope twice"
  wake_control watch-unknown-skips watch-probe-error:claude \
    '        *) exit "$rc" ;;' \
    '        *) printf "single\t" ;;'
fi

printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
