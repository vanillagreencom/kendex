#!/usr/bin/env bash
# Settings and session evidence remain with their existing package owners.
set -euo pipefail
JARVIS_LIB="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
# Targets supply settings and session data, never dependency code.
MAILBOX_LIB="$JARVIS_LIB/../../../mailbox/scripts/lib"
[[ -r "$MAILBOX_LIB/kendex-env.sh" ]] || { echo 'jarvis: dependency=mailbox-missing' >&2; exit 1; }
source "$MAILBOX_LIB/kendex-env.sh"

jarvis_load() {
  kendex_load_project_env "$1" -- COMMUNICATION_TECHNICAL JARVIS_CONTROL_HOST JARVIS_CONTROL_USER JARVIS_FORWARD_CONFIRM JARVIS_LOG_DIR JARVIS_MAIN_HOST JARVIS_REMOTE_HOSTS JARVIS_REPO_ALIASES JARVIS_STYLE JARVIS_UNATTENDED_HARNESSES JARVIS_VOICE_REMIND_SECS JARVIS_WAKE_SETTLE_SECS ORCH_REPORT_EVERY_MINUTES || return 1
  export JARVIS_CONTROL_HOST="${JARVIS_CONTROL_HOST:-}"
  export JARVIS_CONTROL_USER="${JARVIS_CONTROL_USER:-}"
  export JARVIS_REMOTE_HOSTS="${JARVIS_REMOTE_HOSTS:-}"
  export JARVIS_REPO_ALIASES="${JARVIS_REPO_ALIASES:-}"
  export JARVIS_MAIN_HOST="${JARVIS_MAIN_HOST:-}"
  export JARVIS_FORWARD_CONFIRM="${JARVIS_FORWARD_CONFIRM:-off}"
  export JARVIS_LOG_DIR="${JARVIS_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/jarvis}"
  export JARVIS_WAKE_SETTLE_SECS="${JARVIS_WAKE_SETTLE_SECS:-15}"
  export JARVIS_VOICE_REMIND_SECS="${JARVIS_VOICE_REMIND_SECS:-0}"
  # Presentation typos take the default: config also serves mail delivery,
  # which must not stop because a presentation value is unlisted.
  case "${COMMUNICATION_TECHNICAL:-}" in off | on) ;; *) COMMUNICATION_TECHNICAL=off ;; esac
  case "${JARVIS_STYLE:-}" in friendly | concise | fun) ;; *) JARVIS_STYLE=concise ;; esac
  export COMMUNICATION_TECHNICAL JARVIS_STYLE
}

# The live fleet controller, as agent-runtime's observer status reports it.
# Its native id and tmux coordinates identify the session and its rows.
# A home with no fleet record binds nothing. A status read the runtime
# refuses prints `jarvis: dependency=agent-runtime-refused` and the runtime's
# keyed refusal, such as the wrapper's setup-required, so each caller
# judges a refusal apart from an unbound session. Sets the caller's locals
# box, server, pane and status.
jarvis_bound() {
  local root="$1" runtime="$JARVIS_LIB/../../../agent-runtime/scripts/agent-runtime"
  local record refusal diagnostic coordinates code=0
  [[ -r "$MAILBOX_LIB/common-root.sh" ]] || { echo 'jarvis: dependency=mailbox-missing' >&2; return 1; }
  [[ -x "$runtime" ]] || { echo 'jarvis: dependency=agent-runtime-missing' >&2; return 1; }
  source "$MAILBOX_LIB/common-root.sh"
  box="$(mailbox_common_root "$root")" || box="$root"
  record="$(mailbox_fleet_record full "$root")" || return 1
  [[ -e "$record" ]] || return 1
  refusal="$(mktemp)" || return 1
  status="$("$runtime" controller status --record "$record" 2>"$refusal")" || code=$?
  if ((code)); then
    # The wrapper can print build progress before setup or status refuses.
    diagnostic="$(awk '
      /^agent-runtime: setup-building( |$)/ { next }
      /^agent-runtime(-setup)?: / { keyed = $0 }
      first == "" { first = $0 }
      END { print (keyed != "" ? keyed : first) }
    ' "$refusal")" || diagnostic=""
  fi
  rm -f -- "${refusal:?}"
  if ((code)); then
    printf 'jarvis: dependency=agent-runtime-refused %s\n' "${diagnostic:-exit=$code}" >&2
    return 1
  fi
  coordinates="$(jq -er '.result | select(.live == true) | .recorded
    | select(.session_id | type == "string" and length > 0)
    | [(.server | tostring), (.pane // .session)]
    | select((.[0] | test("\\A[0-9]+\\z")) and (.[1] | strings | test("\\A%[0-9]+\\z")))
    | @tsv' <<<"$status")" || return 1
  IFS=$'\t' read -r server pane <<<"$coordinates"
}

# Presence needs a recent activity stamp from the recorded controller.
jarvis_live() {
  local box server pane status
  jarvis_bound "$1" || return 1
  # No native route exposes an external health acknowledgement here. Fresh
  # context is sufficient, including work that only invokes existing hooks.
  jq -er --argjson status "$status" --arg pane "$server $pane" '
    $status.result.recorded as $controller
    | select((.harness | type == "string" and length > 0)
        and .harness == $controller.harness and .session_id == $controller.session_id
        and .pane_key == $pane)
    | .at | select(type == "string" and length > 0)' "$box/tmp/lane-mail/overseer/context.json"
}

# The recorded session with its pane, account and the rows file its hooks
# write for that pane: the one
# the stop-failure-row hook names, the pane number without its `%`. The
# caller reads the rows' verdict itself, so a refused verdict read is never
# taken for an unbound session.
jarvis_wall() {
  local box server pane status
  jarvis_bound "$1" || return 1
  jq -nc --argjson status "$status" --arg pane "$server $pane" \
    --arg rows "$box/tmp/lane-mail/overseer/session-$server-${pane#%}.jsonl" \
    '{session: $status.result.recorded.session_id, pane: $pane,
      account: $status.result.recorded.account, rows: $rows}'
}

case "${1:-}" in
  config)
    jarvis_load "$2"
    python3 -c 'import json,os; print(json.dumps({k:os.environ.get(k,"") for k in ("JARVIS_CONTROL_HOST","JARVIS_CONTROL_USER","JARVIS_REMOTE_HOSTS","JARVIS_REPO_ALIASES","JARVIS_MAIN_HOST","JARVIS_FORWARD_CONFIRM","JARVIS_LOG_DIR","JARVIS_WAKE_SETTLE_SECS","JARVIS_VOICE_REMIND_SECS","ORCH_REPORT_EVERY_MINUTES","COMMUNICATION_TECHNICAL","JARVIS_STYLE")}))'
    ;;
  common-root)
    [[ -r "$MAILBOX_LIB/common-root.sh" ]] || { echo 'jarvis: dependency=mailbox-missing' >&2; exit 1; }
    source "$MAILBOX_LIB/common-root.sh"
    mailbox_common_root "$2"
    ;;
  live) jarvis_live "$2" ;;
  wall) jarvis_wall "$2" ;;
esac
