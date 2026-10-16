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
  history) recorded_session_file "$@" ;;
  prepare)
    harness="$1" account="$2" home="$3" id="$4" file="$5"
    lane_trust_prepare "$harness" "$account" "$home" || exit 1
    lane_session_command "$harness" "$id" "$file" || exit 1
    cmd="$LANE_SESSION_CMD" var="$LANE_SESSION_ACCOUNT_VAR"
    form="$(lane_launch_form "$cmd" "$harness" "$LANE_TRUST_HOME" "")"
    child_env="JARVIS_RECORD=$(lane_single_quote "$6") JARVIS_GENERATION=$(lane_single_quote "$7")"
    # Jarvis acts on the owner's desktop, so its session keeps the live display.
    lane_launch_keep_live_session
    line="$(lane_launch_line "$cmd" "$harness" "$var" "$LANE_TRUST_HOME" "$form" "" "$child_env")" || exit 1
    jq -cn --arg line "$line" --arg var "$var" --arg home "$LANE_TRUST_HOME" \
      '{line:$line, var:$var, effective_home:$home}' ;;
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
    if [[ "$state" == working || "$6" == confirmed ]]; then
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
