#!/usr/bin/env bash
# Private bridge to the existing lock, launch, history and pane owners.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
SCRIPT_DIR="$ROOT/orch/scripts"
for package in mailbox orch; do
  if [[ ! -d "$ROOT/$package/scripts" ]]; then
    printf 'jarvis-session: dependency=%s\n' "$package" >&2
    exit 1
  fi
done
verb="$1"
shift
case "$verb" in
  lock)
    source "$ROOT/mailbox/scripts/lib/file-lock.sh"
    exec 200>>"$1.lock"
    orch_take_lock 200 "$1.lock" 10
    printf 'locked\n'
    cat >/dev/null
    orch_release_lock
    exit ;;
esac
source "$SCRIPT_DIR/lib/lane-launch.sh"
source "$SCRIPT_DIR/lib/lane-state.sh"
source "$SCRIPT_DIR/lib/pane-write.sh"
source "$SCRIPT_DIR/lib/copilot-session.sh"
source "$SCRIPT_DIR/lib/lane-relaunch.sh"
source "$SCRIPT_DIR/lib/tmux-server.sh"
# home_pane_live SOCKET SERVER START PANE: orch's pane liveness answer for a
# controller or task pane on the home's socket. The recorded server serves
# that socket until it exits, so a socket no server serves, or another server
# answering it, proves the pane gone (1), whatever process now holds the
# recorded pid.
home_pane_live() {
  local rc=0 serving
  export TMUX="$1,0,0"
  tmux_pane_live "$2" "$3" "$4" "$1" || rc=$?
  if [[ "$rc" == 2 ]] && serving="$(tmux display-message -p '#{pid}' 2>/dev/null)" \
    && [[ -n "$serving" && "$serving" != "$2" ]]; then
    rc=1
  fi
  return "$rc"
}
case "$verb" in
  select)
    source "$ROOT/jarvis/scripts/lib/jarvis-env.sh"
    jarvis_load "$3"
    DEP_ERR="$(mktemp)" || exit 1
    trap 'rm -f -- "$DEP_ERR"' EXIT
    source "$SCRIPT_DIR/lib/lane-context.sh"
    source "$SCRIPT_DIR/lib/overseer-launch.sh"
    harness="$1" account="$2" model="$4" effort="$5"
    trigger="${ORCH_OVERSEER_HEADROOM_PCT:-5}"
    ol_account "$harness" "$model"
    rc=4
    if ol_account_measured "$OL_ACCOUNT_HARNESS"; then
      # The source account and the walk both serve an overseer, so neither
      # takes the seat reserve that lanes keeps for ordinary work-item picks.
      rc=0
      ol_lanes "$OL_ACCOUNT_HARNESS" pick --lane "$account" --harness "$OL_ACCOUNT_HARNESS" --for-overseer \
        --min-headroom-pct "$trigger" ${OL_ACCOUNT_MODEL:+--native-model "$OL_ACCOUNT_MODEL"} --json >/dev/null || rc=$?
    fi
    case "$rc" in
      0|4|5) ;; # An unmeasured account keeps the existing context-only route.
      3)
        ol_preference_entries "$(ol_preference)" || { printf 'jarvis-session: invalid-preference entry=%s\n' "$OL_BAD_ENTRY" >&2; exit 1; }
        OL_WALK_CALLER_HARNESS="$harness" OL_WALK_CALLER_LANE="$account"
        OL_WALK_CALLER_MODEL="$model" OL_WALK_CALLER_PICK_MODEL="$model" OL_WALK_CALLER_EFFORT="$effort"
        # Select only. Jarvis launches native permission defaults and transfers
        # no predecessor flags, so this asks the walk about harness rows alone.
        OL_WALK_SOURCE_HARNESS="$harness" OL_WALK_SOURCE_ROWS=1
        OL_WALK_REFUSE_ID="$(ol_account_id "$account")"
        walk_rc=0
        ol_walk "$trigger" "$account" ${OL_ENTRIES[@]+"${OL_ENTRIES[@]}"} caller || walk_rc=$?
        for skip in ${OL_WALK_SKIPS[@]+"${OL_WALK_SKIPS[@]}"}; do
          IFS=$'\t' read -r -a fields <<<"$skip"
          printf 'jarvis-session: %s\n' "${fields[*]}" >&2
        done
        if (( walk_rc != 0 )); then
          printf 'jarvis-session: selection-failed account=%s reason=%s\n' "$account" "${OL_REASON:-no-lane-qualifies}" >&2
          [[ ! -s "$DEP_ERR" ]] || cat -- "$DEP_ERR" >&2
          exit 1
        fi
        harness="$OL_HARNESS" account="$OL_LANE_DIR" model="$OL_MODEL" effort="$OL_EFFORT"
        ;;
      *) printf 'jarvis-session: selection-failed account=%s exit=%s\n' "$account" "$rc" >&2
         [[ ! -s "$DEP_ERR" ]] || cat -- "$DEP_ERR" >&2
         exit 1 ;;
    esac
    jq -cn --arg harness "$harness" --arg account "$account" --arg model "$model" --arg effort "$effort" \
      '{harness:$harness,account:$account,model:$model,effort:$effort}' ;;
  task-prepare)
    source "$ROOT/jarvis/scripts/lib/jarvis-env.sh"
    jarvis_load "$5"
    source "$SCRIPT_DIR/lib/overseer-launch.sh"
    DEP_ERR=/dev/stderr
    ol_entry_model "$1:$2:$3" || { printf 'jarvis-task: selection=model-unread\n%s\n' "$OL_CLASS_ERR" >&2; exit 1; }
    harness="$OL_ENTRY_HARNESS" model="$OL_ENTRY_MODEL" effort="$OL_ENTRY_EFFORT"
    pick_args=(pick --harness "$harness" --json)
    [[ -z "$model" ]] || pick_args+=(--native-model "$model")
    [[ -z "$4" ]] || pick_args+=(--lane "$4")
    picked="$("$SCRIPT_DIR/lanes" "${pick_args[@]}")" || exit "$?"
    account="$(jq -er '.config_dir | strings | select(length > 0)' <<<"$picked")" || exit 1
    ol_model_line "$OL_ENTRY_WARNING"
    ol_launch_flags --question-off "$harness" "$model" "$effort" "$model" "" || exit 1
    ol_command_line --brief "$6" "$harness" "" "$account" "$5" "${OL_FLAGS[@]}" || exit 1
    jq -cn --arg line "$OL_CMD" --arg harness "$harness" --arg model "${model:-native-default}" \
      --arg account "$account" --arg effort "$effort" \
      '{line:$line,harness:$harness,model:$model,account:$account,effort:$effort}' ;;
  task-live)
    rc=0
    home_pane_live "$1" "$2" "$3" "$4" || rc=$?
    [[ "$rc" != 2 ]] || printf 'jarvis-task: terminal=unread\n%s\n' "$TMUX_PANE_DETAIL" >&2
    exit "$rc" ;;
  task-close)
    rc=0
    home_pane_live "$1" "$2" "$3" "$4" || rc=$?
    [[ "$rc" != 1 ]] || exit 0
    [[ "$rc" == 0 ]] || { printf 'jarvis-task: terminal=unread\n%s\n' "$TMUX_PANE_DETAIL" >&2; exit 1; }
    actual="$(tmux display-message -p -t "$4" '#{@jarvis-task}')" || exit 1
    [[ "$actual" == "$6" || ( "$7" == true && -z "$actual" ) ]] || { printf 'jarvis-task: terminal=identity-changed\n' >&2; exit 1; }
    binding="#{==:#{@jarvis-task},$6}"
    [[ "$7" != true ]] || binding="#{||:$binding,#{==:#{@jarvis-task},}}"
    tmux if-shell -F -t "$4" "#{&&:$binding,#{==:#{pid},$2}}" "kill-window -t $5" ;;
  live)
    home_pane_live "$1" "$2" "$3" "$4" || exit "$?"
    actual="$(tmux display-message -p -t "$4" '#{@jarvis-generation}')" || exit 2
    # Staging ownership precedes the native generation mark.
    [[ "$actual" == "$5" || ( "$7" == staging && -z "$actual" ) ]] || exit 1
    session="$(tmux display-message -p -t "$4" '#{session_name}')" || exit 2
    window="$(tmux display-message -p -t "$4" '#{window_id}')" || exit 2
    [[ "$session" == jarvis && "$window" == "$6" ]] || exit 1
    jq -cn --arg socket "$1" --arg session "$session" --arg window "$window" --arg pane "$4" \
      '{server:$socket,session:$session,window:$window,pane:$pane}' ;;
  process)
    at="$(lane_process_start "$1")" || exit 1
    [[ -n "$at" ]] || exit 1
    jq -cn --argjson pid "$1" --arg at "$at" '{pid:$pid,started_at:$at}' ;;
  worker-live)
    state="$(lane_process_state "$1")" || exit 2
    [[ -n "$state" && "$state" != Z ]] || exit 1
    at="$(lane_process_start "$1")" || exit 2
    [[ "$at" == "$2" ]] || exit 1 ;;
  process-ended)
    state="$(lane_process_state "$1")" || exit 2
    [[ -z "$state" || "$state" == Z ]] ;;
  stop-process)
    rc=0
    lane_stop_identity "$1" "$2" "$3" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      # Session.end_owned forwards this result to the caller's diagnostics.
      printf 'jarvis-session: operation=stop-process exit=%s cause=%s pid=%s\n' "$rc" "$LANE_STOP_CAUSE" "$LANE_STOP_PID" >&2
    fi
    exit "$rc" ;;
  history) recorded_session_file "$@" ;;
  prepare)
    harness="$1" account="$2" home="$3" id="$4" file="$5"
    lane_trust_prepare "$harness" "$account" "$home" || exit 1
    lane_session_command "$harness" "$id" "$file" || exit 1
    cmd="$LANE_SESSION_CMD" var="$LANE_SESSION_ACCOUNT_VAR"
    if [[ -n "${8:-}${9:-}" ]]; then
      flags="$(launch_choice_write "$harness" "${8:-}" "${9:-}")" || exit 1
      launch_choice_shell_words "$flags" || exit 1
      flags="$(printf ' %q' ${LAUNCH_CHOICE_ARGV[@]+"${LAUNCH_CHOICE_ARGV[@]}"})" || exit 1
      cmd="$harness$flags${cmd#"$harness"}"
    fi
    form="$(lane_launch_form "$cmd" "$harness" "$LANE_TRUST_HOME" "")"
    child_env="JARVIS_RECORD=$(lane_single_quote "$6") JARVIS_GENERATION=$(lane_single_quote "$7")"
    if [[ "$harness" == pi && -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
      child_env+=" CLAUDE_CONFIG_DIR=$(lane_single_quote "$CLAUDE_CONFIG_DIR")"
    fi
    # Jarvis acts on the owner's desktop, so its session keeps the live display.
    lane_launch_keep_live_session
    line="$(lane_launch_line "$cmd" "$harness" "$var" "$LANE_TRUST_HOME" "$form" "" "$child_env")" || exit 1
    jq -cn --arg line "$line" --arg var "$var" --arg home "$LANE_TRUST_HOME" --argjson kickoff "$LANE_SESSION_PROMPTED" \
      '{line:$line, var:$var, effective_home:$home, kickoff:$kickoff}' ;;
  inspect)
    socket="$1" pane="$2" harness="$3" var="$4" account="$5" brief="$8"
    export TMUX="$socket,0,0"
    screen="$(tmux -S "$socket" capture-pane -p -t "$pane")" || exit 1
    pid="$(tmux -S "$socket" display-message -p -t "$pane" '#{pane_pid}')" || exit 1
    cmd="$(tmux -S "$socket" display-message -p -t "$pane" '#{pane_current_command}')" || exit 1
    if [[ "$harness" == pi && "$6" == confirmed && "$brief" == undelivered ]]; then
      # A Pi session whose start is recorded and that has had no brief has run
      # no turn: the record is the idle rows verdict lane_input_ready demands,
      # beside Pi's live-editor proof. Pi alone, since that verdict passes
      # over every pane rung; its refusal is an answer, not a failure.
      rc=0
      lane_input_ready state listed "$cmd" "$pid" "$screen" "" "" idle "" pi || rc=$?
      [[ "$rc" -le 1 ]] || exit 1
    else
      lane_state state listed "$cmd" "$pid" "$screen" || exit 1
    fi
    if [[ "$LANE_WALL_KIND" == auth ]]; then printf 'auth\n'; exit; fi
    if [[ "$harness" == copilot && "$6" == pending ]]; then
      # A folder-trust question holds the harness until its owner answers it
      # natively; Jarvis never answers a native security request. Copilot's
      # alone, asked before its SessionStart: lane_trust_prepare records the
      # answer for Claude Code and Codex, and Pi asks none. Read below the
      # last turn, since a resumed session redraws its history. The pane
      # stands in for Copilot's documented `trustedFolders` config list
      # (`copilot help config`), which says what is listed but not how a
      # listed folder matches HOME: unlike `allowedUrls` beside it, the help
      # gives no rule for subfolders or path spelling, so a config read
      # cannot tell whether the dialog will show, and a wrong guess either
      # refuses a trusted home or launches into an untrusted one.
      slice="$(pane_below_last_turn "$screen")" || exit 1
      rc=0
      dialog="$(pane_trust_dialog "$slice")" || rc=$?
      case "$rc" in
        0) printf 'trust\n%s\n' "$dialog"; exit ;;
        1) ;;
        *) exit 1 ;;
      esac
    fi
    # The account is judged once SessionStart confirmed the start. Copilot and
    # Codex draw their kickoff turn before their stamp lands, and a pending
    # record holds no observed account to compare.
    if [[ "$6" == confirmed ]]; then
      lane_account_equivalent "${7:-}" "$account" || { printf 'wrong-account\n'; exit; }
      lane_account_check "$pane" "$var" "$account" prefix 2 || { printf 'wrong-account\n'; exit; }
      case "$LANE_ACCOUNT_RESULT" in
        verified|unobserved:*) ;;
        *) printf 'unjudged\n'; exit ;;
      esac
    fi
    printf '%s\n' "$state" ;;
  deliver)
    export TMUX="$1,0,0"
    pane_write pane "$2" "$3" file "$4" ;;
  *) printf 'jarvis-session: backend=%s\n' "$verb" >&2; exit 2 ;;
esac
