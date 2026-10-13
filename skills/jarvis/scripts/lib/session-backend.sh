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
case "$verb" in
  live)
    export TMUX="$1,0,0"
    tmux_pane_live "$2" "$3" "$4" || exit "$?"
    actual="$(tmux display-message -p -t "$4" '#{@jarvis-generation}')" || exit 2
    [[ "$actual" == "$5" ]] || exit 1
    session="$(tmux display-message -p -t "$4" '#{session_name}')" || exit 2
    window="$(tmux display-message -p -t "$4" '#{window_id}')" || exit 2
    [[ "$session" == jarvis && "$window" == "$6" ]] || exit 1
    jq -cn --arg socket "$1" --arg session "$session" --arg window "$window" --arg pane "$4" \
      '{server:$socket,session:$session,window:$window,pane:$pane}' ;;
  server-start)
    export TMUX="$1,0,0"
    tmux_server_start "$2" "$3" ;;
  process)
    at="$(lane_process_start "$1")" || exit 1
    [[ -n "$at" ]] || exit 1
    jq -cn --argjson pid "$1" --arg at "$at" '{pid:$pid,started_at:$at}' ;;
  worker-live)
    state="$(lane_process_state "$1")" || exit 2
    [[ -n "$state" && "$state" != Z ]] || exit 1
    at="$(lane_process_start "$1")" || exit 2
    [[ "$at" == "$2" ]] || exit 1 ;;
  history) recorded_session_file "$@" ;;
  prepare)
    harness="$1" account="$2" home="$3" id="$4" file="$5"
    lane_trust_prepare "$harness" "$account" "$home" || exit 1
    lane_session_command "$harness" "$id" "$file" || exit 1
    cmd="$LANE_SESSION_CMD" var="$LANE_SESSION_ACCOUNT_VAR"
    form="$(lane_launch_form "$cmd" "$harness" "$LANE_TRUST_HOME" "")"
    child_env="JARVIS_RECORD=$(lane_single_quote "$6") JARVIS_GENERATION=$(lane_single_quote "$7")"
    line="$(lane_launch_line "$cmd" "$harness" "$var" "$LANE_TRUST_HOME" "$form" "" "$child_env")" || exit 1
    jq -cn --arg line "$line" --arg var "$var" --arg home "$LANE_TRUST_HOME" \
      '{line:$line, var:$var, effective_home:$home}' ;;
  inspect)
    socket="$1" pane="$2" harness="$3" var="$4" account="$5"
    export TMUX="$socket,0,0"
    screen="$(tmux -S "$socket" capture-pane -p -t "$pane")" || exit 1
    if lane_auth_failure "$screen"; then printf 'auth\n'; exit; fi
    pid="$(tmux -S "$socket" display-message -p -t "$pane" '#{pane_pid}')" || exit 1
    cmd="$(tmux -S "$socket" display-message -p -t "$pane" '#{pane_current_command}')" || exit 1
    lane_state state listed "$cmd" "$pid" "$screen" || exit 1
    if [[ "$state" == working || "$6" == confirmed ]]; then
      lane_account_check "$pane" "$var" "$account" prefix 2 || { printf 'wrong-account\n'; exit; }
      case "$LANE_ACCOUNT_RESULT" in
        verified|unobserved:no-process-environment) ;;
        *) printf 'unjudged\n'; exit ;;
      esac
    fi
    printf '%s\n' "$state" ;;
  deliver)
    export TMUX="$1,0,0"
    pane_write pane "$2" "$3" file "$4" ;;
  *) printf 'jarvis-session: backend=%s\n' "$verb" >&2; exit 2 ;;
esac
