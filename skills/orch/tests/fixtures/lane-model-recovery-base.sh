# shellcheck shell=bash
# KEN-4033 must-fail control: lane_model_recovery at b23b769a0d110c854a460f8dadbe2b343fd35247.
lane_model_recovery() { # RECORD STATE_DIR SCRIPTS SESSION
  local record="$1" state_dir="$2" SCRIPT_DIR="$3" session="$4" fields item host harness pane pid start wake_pid wake_start account out claim pane_pid identity
  fields="$(jq -er '[.item, (.host // "local"), .harness, (.launch.pane // ""),
    (.launch.pid // ""), (.launch.start // ""), (.wake.pid // ""),
    (.wake.start // ""), (.account // "")] | join("\u001f")' <<<"$record")" || return 1
  IFS=$'\x1f' read -r item host harness pane pid start wake_pid wake_start account <<<"$fields"
  claim="$("$SCRIPT_DIR/workflow-state" --state-dir "$state_dir" update-report oversee '
    first(.lanes[]? | select(.item == $item)) as $current
    | if $current.launch != $record.launch or $current.launched_at != $record.launched_at
        or $current.session_id != $record.session_id or $current.model_check.session_id != $session
        or $current.model_check.recovery_started == true
      then {state:.,report:false}
      else (.lanes[] | select(.item == $item)).model_check.recovery_started = true
        | {state:.,report:true} end' --arg item "$item" --arg session "$session" --argjson record "$record")" || return 1
  [[ "$claim" == true ]] || return 0
  lane_recovery_args "$record" "$account" "$state_dir" "$SCRIPT_DIR/open-terminal" model-switched || {
    printf 'lane-relaunch: model-recovery=prepare-failed item=%s cause=%s\n' "$item" "$LANE_RECOVERY_CAUSE" >&2
    return 1
  }
  if [[ "$host" == local ]]; then
    # Older launches recorded the pane but no process identity. Read that
    # identity once; a stale positive recorded identity never takes this path.
    if [[ -z "$pid$start" ]]; then
      pane_pid="$(tmux display-message -p -t "$pane" '#{pane_pid}')" || return 1
      identity="$(lane_harness_identity "$pane_pid" "$harness")" || return 1
      pid=${identity%% *} start=${identity#* }
    fi
    # Never substitute a pane's new process for this predecessor's identity.
    lane_stop_local "" "$pid" "$start" "$wake_pid" "$wake_start" "$harness" || {
      printf 'lane-relaunch: model-recovery=stop-failed item=%s cause=%s\n' "$item" "$LANE_STOP_CAUSE" >&2
      return 1
    }
  else
    out="$(ORCH_LANE_HOST="$host" "$SCRIPT_DIR/lane-host" stop --item "$item" --harness "$harness")" || return 1
    lane_recovery_stop_confirmed "$out" "$item" || return 1
  fi
  "$SCRIPT_DIR/workflow-state" --state-dir "$state_dir" update oversee \
    '(.lanes[] | select(.item == $item and .launched_at == $launch)) |= (.status = "stopped")' \
    --arg item "$item" --arg launch "$(jq -r '.launched_at' <<<"$record")" >/dev/null || return 1
  export ORCH_TMUX_SESSION="$LANE_RECOVERY_SESSION"
  cd -- "$LANE_RECOVERY_CWD" || return 1
  "${LANE_RECOVERY_ARGS[@]}"
}
