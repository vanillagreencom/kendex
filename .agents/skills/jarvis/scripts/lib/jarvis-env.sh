#!/usr/bin/env bash
# Settings and session evidence remain with their existing package owners.
set -euo pipefail
JARVIS_LIB="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
# Targets supply settings and session data, never dependency code.
MAILBOX_LIB="$JARVIS_LIB/../../../mailbox/scripts/lib"
[[ -r "$MAILBOX_LIB/kendex-env.sh" ]] || { echo 'jarvis: dependency=mailbox-missing' >&2; exit 1; }
source "$MAILBOX_LIB/kendex-env.sh"

jarvis_load() {
  kendex_load_project_env "$1" -- JARVIS_CONTROL_HOST JARVIS_CONTROL_USER JARVIS_FORWARD_CONFIRM JARVIS_LOG_DIR JARVIS_MAIN_HOST JARVIS_REMOTE_HOSTS JARVIS_REPO_ALIASES JARVIS_STYLE JARVIS_TECHNICAL JARVIS_UNATTENDED_HARNESSES JARVIS_VOICE_REMIND_SECS JARVIS_WAKE_SETTLE_SECS ORCH_REPORT_EVERY_MINUTES || return 1
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
  case "${JARVIS_TECHNICAL:-}" in off | on) ;; *) JARVIS_TECHNICAL=off ;; esac
  case "${JARVIS_STYLE:-}" in friendly | concise | fun) ;; *) JARVIS_STYLE=concise ;; esac
  export JARVIS_TECHNICAL JARVIS_STYLE
}

# The bound session: the one the native turn end last stamped into the
# overseer mailbox's context record is the fleet record's controller, live,
# bound to that pane on its server's recorded start, of that harness, under
# the native id the record names. agent-runtime's status read answers all of
# it. A home with no fleet record binds nothing. A status read the runtime
# refuses prints `jarvis: dependency=agent-runtime-refused` and the runtime's
# first stderr line, such as the wrapper's setup-required, so each caller
# judges a refusal apart from an unbound session. Sets the caller's locals
# runtime, box, server, pane, at and status.
jarvis_bound() {
  local root="$1" harness session record refusal first code=0
  runtime="$JARVIS_LIB/../../../agent-runtime/scripts/agent-runtime"
  [[ -r "$MAILBOX_LIB/common-root.sh" ]] || { echo 'jarvis: dependency=mailbox-missing' >&2; return 1; }
  [[ -x "$runtime" ]] || { echo 'jarvis: dependency=agent-runtime-missing' >&2; return 1; }
  source "$MAILBOX_LIB/common-root.sh"
  box="$(mailbox_common_root "$root")" || box="$root"
  IFS=$'\t' read -r harness server pane session at < <(jq -er '
    select(all(.harness, .session_id, .at; type == "string" and length > 0)
      and (.pane_key | type == "string" and test("^[^ \t]+ [^ \t]+$")))
    | [.harness, (.pane_key | split(" ") | .[0], .[1]), .session_id, .at] | @tsv' \
    "$box/tmp/lane-mail/overseer/context.json") || return 1
  record="$(mailbox_fleet_record full "$root")" || return 1
  [[ -e "$record" ]] || return 1
  refusal="$(mktemp)" || return 1
  status="$("$runtime" controller status --record "$record" --server="$server" --pane="$pane" \
    --harness="$harness" --session="$session" 2>"$refusal")" || code=$?
  first="$(head -n 1 -- "$refusal")" || first=""
  rm -f -- "${refusal:?}"
  if ((code)); then
    printf 'jarvis: dependency=agent-runtime-refused %s\n' "${first:-exit=$code}" >&2
    return 1
  fi
  jq -e '.result | .live and .binding == "bound" and .native_match
    and (.recorded.session_id | type == "string" and length > 0)' <<<"$status" >/dev/null || return 1
}

# Presence: the bound session, with its context stamp.
jarvis_live() {
  local runtime box server pane at status
  jarvis_bound "$1" || return 1
  # No native route exposes an external health acknowledgement here. Fresh
  # context is sufficient, including work that only invokes existing hooks.
  printf '%s\n' "$at"
}

# The bound session, whatever the context stamp's age, with its pane, its
# recorded account and the rows file its hooks write for that pane: the one
# the stop-failure-row hook names, the pane number without its `%`. The
# caller reads the rows' verdict itself, so a refused verdict read is never
# taken for an unbound session.
jarvis_wall() {
  local runtime box server pane at status
  jarvis_bound "$1" || return 1
  jq -nc --argjson status "$status" --arg pane "$server $pane" \
    --arg rows "$box/tmp/lane-mail/overseer/session-$server-${pane#%}.jsonl" \
    '{session: $status.result.recorded.session_id, pane: $pane,
      account: $status.result.recorded.account, rows: $rows}'
}

case "${1:-}" in
  config)
    jarvis_load "$2"
    python3 -c 'import json,os; print(json.dumps({k:os.environ.get(k,"") for k in ("JARVIS_CONTROL_HOST","JARVIS_CONTROL_USER","JARVIS_REMOTE_HOSTS","JARVIS_REPO_ALIASES","JARVIS_MAIN_HOST","JARVIS_FORWARD_CONFIRM","JARVIS_LOG_DIR","JARVIS_WAKE_SETTLE_SECS","JARVIS_VOICE_REMIND_SECS","ORCH_REPORT_EVERY_MINUTES","JARVIS_TECHNICAL","JARVIS_STYLE")}))'
    ;;
  common-root)
    [[ -r "$MAILBOX_LIB/common-root.sh" ]] || { echo 'jarvis: dependency=mailbox-missing' >&2; exit 1; }
    source "$MAILBOX_LIB/common-root.sh"
    mailbox_common_root "$2"
    ;;
  live) jarvis_live "$2" ;;
  wall) jarvis_wall "$2" ;;
esac
