#!/usr/bin/env bash
# Settings and session evidence remain with their existing package owners.
set -euo pipefail
JARVIS_LIB="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
# Targets supply settings and session data, never dependency code.
MAILBOX_LIB="$JARVIS_LIB/../../../mailbox/scripts/lib"
ORCH_SCRIPTS="$JARVIS_LIB/../../../orch/scripts"
[[ -r "$MAILBOX_LIB/kendex-env.sh" ]] || { echo 'jarvis: dependency=mailbox-missing' >&2; exit 1; }
source "$MAILBOX_LIB/kendex-env.sh"

jarvis_load() {
  kendex_load_project_env "$1" || return 1
  export JARVIS_CONTROL_HOST="${JARVIS_CONTROL_HOST:-}"
  export JARVIS_LOG_DIR="${JARVIS_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/jarvis}"
  export JARVIS_WAKE_SETTLE_SECS="${JARVIS_WAKE_SETTLE_SECS:-15}"
}

jarvis_live() {
  local root="$1" pane server native harness account rows record start
  SCRIPT_DIR="$ORCH_SCRIPTS"
  DEP_ERR=/dev/stderr
  [[ -r "$SCRIPT_DIR/lib/lane-context.sh" && -r "$SCRIPT_DIR/lib/overseer-launch.sh" ]] || {
    echo 'jarvis: dependency=orch-missing' >&2; return 1;
  }
  source "$SCRIPT_DIR/lib/lane-context.sh"
  source "$SCRIPT_DIR/lib/overseer-launch.sh"
  cd -- "$root" || return 1
  ol_record_read || return 1
  [[ "$OL_PRIOR" != null ]] || return 1
  record="$OL_PRIOR"
  pane="$(jq -er '.pane' <<<"$record")" || return 1
  native="$(jq -er '.session_id | strings | select(length > 0)' <<<"$record")" || return 1
  harness="$(jq -er '.harness' <<<"$record")" || return 1
  account="$(jq -r '.home // ""' <<<"$record")" || return 1
  jq -e '.exit == null' <<<"$record" >/dev/null || return 1
  ol_session_inspect "$pane" || return 1
  case "$OL_INSPECT_STATE" in working|idle|asking|walled) ;; *) return 1 ;; esac
  server="$OL_INSPECT_SERVER"
  start="$OL_INSPECT_START"
  [[ -n "$start" ]] || start="$(ol_session_start "$server" "$pane")" || return 1
  jq -e --arg server "$server" --arg start "$start" --arg pane "$pane" \
    "$OL_JQ_DEFS"' ol_names($server; $start; $pane)' <<<"$record" >/dev/null || return 1
  rows="$(session_rows_overseer_file "$root" "$server" "$pane")" || return 1
  session_rows_last "$rows" SessionStart || return 1
  jq -e --arg harness "$harness" --arg home "$account" --arg session "$native" \
    "$OL_JQ_DEFS"' .session_id == $session and ol_native_match($harness; $home; $session)' \
    <<<"${SESSION_ROW:-null}" >/dev/null || return 1
  record="$(cat -- "$(lane_context_overseer_box "$root")/$LANE_CONTEXT_RECORD")" || return 1
  lane_context_record_fields "$record" || return 1
  [[ "$LANE_CTX_HARNESS" == "$harness" && "$LANE_CTX_PANE_KEY" == "$server $pane" && "$LANE_CTX_SESSION" == "$native" ]] || return 1
  # No native route exposes an external health acknowledgement here. Fresh
  # context is sufficient, including work that only invokes existing hooks.
  printf '%s\n' "$LANE_CTX_AT"
}

case "${1:-}" in
  config)
    jarvis_load "$2"
    python3 -c 'import json,os; print(json.dumps({k:os.environ.get(k,"") for k in ("JARVIS_CONTROL_HOST","JARVIS_LOG_DIR","JARVIS_WAKE_SETTLE_SECS")}))'
    ;;
  common-root)
    [[ -r "$MAILBOX_LIB/common-root.sh" ]] || { echo 'jarvis: dependency=mailbox-missing' >&2; exit 1; }
    source "$MAILBOX_LIB/common-root.sh"
    mailbox_common_root "$2"
    ;;
  live) jarvis_live "$2" ;;
esac
