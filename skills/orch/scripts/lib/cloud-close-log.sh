# shellcheck shell=bash

# Keep the cloud session before a launch replaces its lane record. Both close
# and replacement use this writer, including the last directive's readings.
cloud_close_log() ( # RECORD [STATE_ARGS...]; caller binds WORKFLOW_STATE; prints cause on failure
  local record="$1" row file
  shift
  row="$(jq -c '
    {kind: "close", item: .item, text: ("cloud lane closed; session=\(.session_id // "none") account=\(.account // "none")"
      + (.directive_send | if type == "object" then " send=\(.result) "
        + (.credit | if type == "object" then "credit=\(.remaining_dollars // "none") locked=\(.locked_reason // "none")" else "credit=unread" end)
        + " cli=\(.text | gsub("\\s+"; " ") | .[0:300])" else "" end))}' <<<"$record")" \
    || { printf '%s\n' record-invalid; return 1; }
  file="$(mktemp)" || { printf '%s\n' scratch-unmade; return 1; }
  trap 'rm -f -- "${file:?}"' EXIT
  if ! printf '%s\n' "$row" > "$file" \
    || ! "$WORKFLOW_STATE" "$@" append-file oversee fleet_log "$file" >/dev/null; then
    printf '%s\n' append
    return 1
  fi
)
