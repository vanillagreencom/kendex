# shellcheck shell=bash
#
# The writer for the Copilot CLI session record receives the CLI's JSON on
# stdin from its `statusLine` command.
#
# Copilot's `events.jsonl` record holds a context count in each
# `tool.execution_complete` row (Copilot CLI 1.0.112), and the pane footer is a
# display. Two commands receive a live count: agent-runtime's
# copilot-lane-context extension, on Copilot's `session.usage_info`
# event, whose reading a turn end reads first, and the status line command,
# the fallback where no extension reading of the session stands.
# `copilot-statusline`, the script beside this library's directory, is that
# command: it persists the JSON it received as a record bound to the session.
# Nothing here parses a pane or a screen.
#
# One record per session, at `<COPILOT_HOME>/lane-status/<session_id>.json`,
# under the account directory the session runs on. The record carries the CLI's
# own object under `status`, exactly as received, and beside it what binds it:
#
#   session_id       the CLI's, repeated at the top for the reader's match
#   transcript_path  the CLI's, so a hook payload naming a transcript is held
#                    to the record and never to a guess
#   copilot_home     the account directory the command ran under
#   written_at       epoch seconds, for the freshness rule below
#
# agent-runtime's reader (`context.rs` `copilot_record`) answers with a record
# only where every binding it holds agrees: the session id it was handed, the
# account directory, the folder that holds the transcript where it has one, and
# a record no older than its 120-second bound (`COPILOT_RECORD_MAX_AGE`), an age
# equal to the bound still fresh. Anything else is unmeasured under a reason the reader
# names, never a figure: a record from another session, or one the CLI stopped
# refreshing, would read as a session with room for as long as it stood.
#
# Sourced, never run. Bash 3.2-safe, like its callers.

# The record path for one session of the account at HOME. The id is held to the
# alphabet a session id is spelled in, so no id names a path outside the
# directory; an empty id or one outside it answers 1.
copilot_session_record_path() { # HOME SESSION_ID
  case "$2" in
    '' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s/lane-status/%s.json\n' "$1" "$2"
}

# copilot_session_write HOME NOW < JSON — the record for the JSON on stdin,
# written whole under HOME and stamped NOW. Prints nothing; 0 once the record
# stands. Otherwise COPILOT_SESSION_REASON names why:
#   payload=invalid-json   stdin is not a JSON object
#   payload=unbound        the object names no session_id, or one outside the
#                          alphabet a session id is spelled in
#   record=unwritable      the directory or the file could not be written
# The write is a temporary file renamed over the target, so a reader never meets
# half a record, and the directory is private: the record names the account
# directory and the session's transcript.
COPILOT_SESSION_REASON=""
copilot_session_write() { # HOME NOW
  local home="$1" now="$2" input session path staged
  COPILOT_SESSION_REASON=""
  input="$(cat)" || { COPILOT_SESSION_REASON=payload=invalid-json; return 1; }
  session="$(jq -r 'if type == "object" then (.session_id | strings) // "" else error("not an object") end' \
    <<<"$input" 2>/dev/null)" || { COPILOT_SESSION_REASON=payload=invalid-json; return 1; }
  path="$(copilot_session_record_path "$home" "$session")" || { COPILOT_SESSION_REASON=payload=unbound; return 1; }
  ( umask 077 && mkdir -p -- "${path%/*}" ) || { COPILOT_SESSION_REASON=record=unwritable; return 1; }
  staged="$path.$$"
  if ! ( umask 077 && jq -c --arg home "$home" --argjson now "$now" '
      {session_id: .session_id,
       transcript_path: ((.transcript_path | strings) // null),
       copilot_home: $home,
       written_at: $now,
       status: .}' <<<"$input" >"$staged" ); then
    rm -f -- "$staged"
    COPILOT_SESSION_REASON=record=unwritable
    return 1
  fi
  mv -f -- "$staged" "$path" || { rm -f -- "$staged"; COPILOT_SESSION_REASON=record=unwritable; return 1; }
}

# copilot_session_fields RECORD — the status line's display fields, each
# empty where the CLI sent none or sent a value of another type:
#   CS_MODEL        status.model.id
#   CS_USED_PCT     status.context_window.used_percentage, rounded
#   CS_NANO_AIU     status.ai_used.total_nano_aiu, whole
# Empty is what a consumer reads as unmeasured; no field is defaulted to a
# number here. Exit 1 where RECORD is not JSON.
CS_MODEL="" CS_USED_PCT="" CS_NANO_AIU=""
copilot_session_fields() { # RECORD
  local line
  CS_MODEL="" CS_USED_PCT="" CS_NANO_AIU=""
  line="$(jq -r '
    def whole: if type == "number" and . >= 0 then (floor | tostring) else "" end;
    [ (.status.model.id | strings) // "",
      (.status.context_window.used_percentage | if type == "number" then (. + 0.5 | floor | tostring) else "" end),
      (.status.ai_used.total_nano_aiu | whole) ]
    | join("\t")' <<<"$1" 2>/dev/null)" || return 1
  CS_MODEL="${line%%	*}"; line="${line#*	}"
  CS_USED_PCT="${line%%	*}"; line="${line#*	}"
  CS_NANO_AIU="$line"
}
