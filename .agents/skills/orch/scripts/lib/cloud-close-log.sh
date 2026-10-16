# shellcheck shell=bash

# Keep the cloud session before a launch replaces its lane record. Both close
# and replacement use this writer, including the last directive's readings.
cloud_close_log() ( # WORKFLOW_STATE RECORD [STATE_ARGS...]; prints cause on failure
  local workflow_state="$1" record="$2" row file
  shift 2
  row="$(jq -c '
    {kind: "close", item: .item, text: ("cloud lane closed; session=\(.session_id // "none") account=\(.account // "none")"
      + (.directive_send | if type == "object" then " send=\(.result) "
        + (.credit | if type == "object" then "credit=\(.remaining_dollars // "none") locked=\(.locked_reason // "none")" else "credit=unread" end)
        + " cli=\(.text | gsub("\\s+"; " ") | .[0:300])" else "" end))}' <<<"$record")" \
    || { printf '%s\n' record-invalid; return 1; }
  file="$(mktemp)" || { printf '%s\n' scratch-unmade; return 1; }
  trap 'rm -f -- "${file:?}"' EXIT
  if ! printf '%s\n' "$row" > "$file" \
    || ! "$workflow_state" "$@" append-file oversee fleet_log "$file" >/dev/null; then
    printf '%s\n' append
    return 1
  fi
)
