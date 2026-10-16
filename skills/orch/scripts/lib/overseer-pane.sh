#!/usr/bin/env bash
# Mandatory tmux pane reads shared by the provider and the bootstrap mark
# check. The caller owns OTP_ERR, a diagnostic file distinct from stderr.
# Operations return 1 with OTP_ERROR on unreadable evidence. A successful
# listing alone can set OTP_STATE=gone. No operation exits or changes TMUX.

otp_session() { # SESSION VERB
  local LC_ALL=C
  OTP_ERROR=""
  if [[ -z "$1" ]]; then
    printf -v OTP_ERROR 'overseer-host-tmux: option-missing option=--session verb=%s\nThe verb needs the named option.\n' "$2"
    return 2
  fi
  if [[ ! "$1" =~ ^%[0-9]+$ ]]; then
    printf -v OTP_ERROR 'overseer-host-tmux: invalid-session value=%s\nA session is a tmux pane id, %%N.\n' "$1"
    return 2
  fi
}

otp_error() { # FIELD=VALUE...
  local detail
  detail="$(<"$OTP_ERR")"
  printf -v OTP_ERROR 'overseer-host-tmux: session-unreadable session=%s' "$OTP_SESSION"
  if [[ $# -gt 0 ]]; then
    local field
    for field in "$@"; do OTP_ERROR="$OTP_ERROR $field"; done
  fi
  OTP_ERROR="$OTP_ERROR"$'\nThe session could not be read; tmux says why below.\n'
  OTP_ERROR="$OTP_ERROR$detail"
  [[ ! -s "$OTP_ERR" ]] || OTP_ERROR="$OTP_ERROR"$'\n'
  return 1
}

otp_listed() { # PANE: 0 listed, 3 absent, 1 unreadable
  local panes pane
  panes="$(exec tmux list-panes -a -F '#{pane_id}' 2>"$OTP_ERR")" || { otp_error; return 1; }
  while IFS= read -r pane; do
    [[ "$pane" != "$1" ]] || return 0
  done <<<"$panes"
  return 3
}

otp_settled() {
  local rc=0
  otp_listed "$OTP_SESSION" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) OTP_STATE=gone; return 0 ;;
    *) return 1 ;;
  esac
}

otp_unread() { # FIELD=VALUE...
  local detail
  detail="$(<"$OTP_ERR")"
  otp_settled || return 1
  [[ "$OTP_STATE" != gone ]] || return 0
  printf '%s\n' "$detail" > "$OTP_ERR"
  otp_error "$@"
}

otp_field() { # VAR FIELD SHAPE FORMAT
  local out LC_ALL=C
  if ! out="$(exec tmux display-message -p -t "$OTP_SESSION" "$4" 2>"$OTP_ERR")" || [[ ! "$out" =~ $3 ]]; then
    otp_unread "field=$2" "value=${out:-none}"
    return $?
  fi
  printf -v "$1" '%s' "$out"
}

otp_observe() { # SESSION DIAGNOSTIC_FILE LAUNCH
  OTP_SESSION="$1" OTP_ERR="$2" OTP_STATE=live OTP_ERROR=""
  OTP_WINDOW="" OTP_SERVER="" OTP_SCREEN="" OTP_PROCESS=""
  otp_session "$1" inspect || return 1
  otp_settled || return 1
  [[ "$OTP_STATE" != gone ]] || return 0
  otp_field OTP_WINDOW window_id '^@[0-9]+$' '#{window_id}' || return 1
  [[ "$OTP_STATE" != gone ]] || return 0
  otp_field OTP_SERVER pid '^[0-9]+$' '#{pid}' || return 1
  [[ "$OTP_STATE" != gone ]] || return 0
  if ! OTP_SCREEN="$(exec tmux capture-pane -pJ -t "$OTP_SESSION" 2>"$OTP_ERR")"; then
    otp_unread field=capture
    return $?
  fi
  if [[ "$3" != 1 ]]; then
    otp_field OTP_PROCESS pane_pid '^[0-9]+[[:blank:]]+[^[:space:]]' '#{pane_pid} #{pane_current_command}' || return 1
  fi
}
