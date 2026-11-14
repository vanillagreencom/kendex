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
  [[ ! -r "$ORCH_SCRIPTS/lib/settings-names.sh" ]] || source "$ORCH_SCRIPTS/lib/settings-names.sh"; kendex_load_project_env "$1" -- JARVIS_CONTROL_HOST JARVIS_CONTROL_USER JARVIS_LOG_DIR JARVIS_MAIN_HOST JARVIS_REMOTE_HOSTS JARVIS_UNATTENDED_HARNESSES JARVIS_WAKE_SETTLE_SECS ${orch_settings_names[@]+"${orch_settings_names[@]}"} || return 1
  export JARVIS_CONTROL_HOST="${JARVIS_CONTROL_HOST:-}"
  export JARVIS_CONTROL_USER="${JARVIS_CONTROL_USER:-}"
  export JARVIS_REMOTE_HOSTS="${JARVIS_REMOTE_HOSTS:-}"
  export JARVIS_MAIN_HOST="${JARVIS_MAIN_HOST:-}"
  export JARVIS_LOG_DIR="${JARVIS_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/jarvis}"
  export JARVIS_WAKE_SETTLE_SECS="${JARVIS_WAKE_SETTLE_SECS:-15}"
}

# Presence: the session the native turn end last stamped into the overseer
# mailbox's context record is the fleet record's controller, live, bound to
# that pane on its server's recorded start, of that harness, under the
# native id the record names. agent-runtime's status read answers all of it;
# a read it cannot make is never presence.
jarvis_live() {
  local root="$1" runtime="$JARVIS_LIB/../../../agent-runtime/scripts/agent-runtime"
  local box harness server pane session at record status
  [[ -r "$MAILBOX_LIB/common-root.sh" ]] || { echo 'jarvis: dependency=mailbox-missing' >&2; return 1; }
  [[ -x "$runtime" ]] || { echo 'jarvis: dependency=agent-runtime-missing' >&2; return 1; }
  source "$MAILBOX_LIB/common-root.sh"
  cd -- "$root" || return 1
  box="$(mailbox_common_root "$root")" || box="$root"
  IFS=$'\t' read -r harness server pane session at < <(jq -er '
    select(all(.harness, .session_id, .at; type == "string" and length > 0)
      and (.pane_key | type == "string" and test("^[^ \t]+ [^ \t]+$")))
    | [.harness, (.pane_key | split(" ") | .[0], .[1]), .session_id, .at] | @tsv' \
    "$box/tmp/lane-mail/overseer/context.json") || return 1
  record="$(mailbox_fleet_record full "$root")" || return 1
  status="$("$runtime" controller status --record "$record" --server="$server" --pane="$pane" \
    --harness="$harness" --session="$session")" || return 1
  jq -e '.result | .live and .binding == "bound" and .native_match
    and (.recorded.session_id | type == "string" and length > 0)' <<<"$status" >/dev/null || return 1
  # No native route exposes an external health acknowledgement here. Fresh
  # context is sufficient, including work that only invokes existing hooks.
  printf '%s\n' "$at"
}

case "${1:-}" in
  config)
    jarvis_load "$2"
    python3 -c 'import json,os; print(json.dumps({k:os.environ.get(k,"") for k in ("JARVIS_CONTROL_HOST","JARVIS_CONTROL_USER","JARVIS_REMOTE_HOSTS","JARVIS_MAIN_HOST","JARVIS_LOG_DIR","JARVIS_WAKE_SETTLE_SECS")}))'
    ;;
  common-root)
    [[ -r "$MAILBOX_LIB/common-root.sh" ]] || { echo 'jarvis: dependency=mailbox-missing' >&2; exit 1; }
    source "$MAILBOX_LIB/common-root.sh"
    mailbox_common_root "$2"
    ;;
  live) jarvis_live "$2" ;;
esac
