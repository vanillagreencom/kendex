# shellcheck shell=bash
#
# The Copilot CLI session record: the one writer and reader of the JSON the CLI
# hands its `statusLine` command on stdin, for every reader that wants a live
# context figure or the stop cause of a Copilot session.
#
# Copilot keeps no live context count anywhere a reader can open: its
# `events.jsonl` transcript carries usage only in the event a session writes as
# it ends, and the pane footer is a display. Two commands receive a live count:
# the orch copilot-lane-context extension, on Copilot's `session.usage_info`
# event, whose reading a turn end reads first, and the status line command,
# the fallback where no extension reading of the session stands.
# `copilot-statusline`, the script beside this library's directory, is that
# command: it persists the JSON it received as a record bound to the session,
# and lib/adapters/copilot.sh reads it back for the shared context judge.
# Nothing here parses a pane or a screen. The session store the CLI keeps
# beside it, `session-state/<id>/workspace.yaml`, is read here too, for the one
# question a reader outside the session asks of it: which session a lane in a
# given worktree runs.
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
# A reader answers with a record only where every binding it holds agrees: the
# session id it was handed, the account directory, the transcript path where it
# has one, and a record no older than COPILOT_SESSION_MAX_AGE_S, an age equal to
# the bound still fresh. Anything else is unmeasured under a reason the reader
# names, never a figure: a record from another session, or one the CLI stopped
# refreshing, would read as a session with room for as long as it stood.
#
# Sourced, never run. Bash 3.2-safe, like its callers.

COPILOT_SESSION_MAX_AGE_S="${COPILOT_SESSION_MAX_AGE_S:-120}"

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

# copilot_session_read HOME SESSION_ID TRANSCRIPT NOW — the record bound to
# SESSION_ID under HOME, into COPILOT_SESSION_RECORD, 0 where every binding
# agrees. Into a variable and never onto stdout: a caller reading it through a
# command substitution would lose the reason with the subshell. TRANSCRIPT is
# the path the caller's payload names, empty where it names none. 1 with
# COPILOT_SESSION_REASON naming the first binding that did not agree:
#   unbound           SESSION_ID is empty or outside a session id's alphabet
#   missing           no record for that session under HOME
#   unreadable        a file there that is not a record this library wrote
#   wrong-session     the record's own session_id is another session's
#   wrong-account     the record names another account directory
#   wrong-transcript  TRANSCRIPT was given and the record names another
#   stale             written_at is older than COPILOT_SESSION_MAX_AGE_S or
#                     later than NOW: a record the CLI stopped refreshing, and
#                     one stamped by a clock ahead of the reader's, are both
#                     records nothing vouches for
COPILOT_SESSION_RECORD=""
copilot_session_read() { # HOME SESSION_ID TRANSCRIPT NOW
  local home="$1" session="$2" transcript="$3" now="$4" path record fields
  local rec_session rec_home rec_transcript written age
  COPILOT_SESSION_REASON=""
  COPILOT_SESSION_RECORD=""
  path="$(copilot_session_record_path "$home" "$session")" || { COPILOT_SESSION_REASON=unbound; return 1; }
  [ -f "$path" ] || { COPILOT_SESSION_REASON=missing; return 1; }
  record="$(cat -- "$path" 2>/dev/null)" || { COPILOT_SESSION_REASON=unreadable; return 1; }
  fields="$(jq -r '
    if type != "object" or (.session_id | type) != "string" or (.copilot_home | type) != "string"
       or (.written_at | type) != "number" then error("shape") else . end
    | [.session_id, .copilot_home, ((.transcript_path | strings) // ""), (.written_at | floor | tostring)]
    | join("\t")' <<<"$record" 2>/dev/null)" || { COPILOT_SESSION_REASON=unreadable; return 1; }
  rec_session="${fields%%	*}"; fields="${fields#*	}"
  rec_home="${fields%%	*}"; fields="${fields#*	}"
  rec_transcript="${fields%%	*}"
  written="${fields#*	}"
  [ "$rec_session" = "$session" ] || { COPILOT_SESSION_REASON=wrong-session; return 1; }
  [ "$rec_home" = "$home" ] || { COPILOT_SESSION_REASON=wrong-account; return 1; }
  if [ -n "$transcript" ] && [ "$rec_transcript" != "$transcript" ]; then
    COPILOT_SESSION_REASON=wrong-transcript
    return 1
  fi
  age=$((now - written))
  { [ "$age" -ge 0 ] && [ "$age" -le "$COPILOT_SESSION_MAX_AGE_S" ]; } || { COPILOT_SESSION_REASON=stale; return 1; }
  COPILOT_SESSION_RECORD="$record"
}

# copilot_session_fields RECORD — one record split into the figures its readers
# act on, each empty where the CLI sent none or sent a value of another type:
#   CS_MODEL        status.model.id
#   CS_USED_PCT     status.context_window.used_percentage, rounded
#   CS_TOKENS       status.context_window.current_context_tokens, whole
#   CS_WINDOW       status.context_window.context_window_size, whole
#   CS_NANO_AIU     status.ai_used.total_nano_aiu, whole
#   CS_ALLOW_ALL    status.allow_all_enabled, `true` or `false`
# Empty is what a consumer reads as unmeasured; no field is defaulted to a
# number here. Exit 1 where RECORD is not JSON.
CS_MODEL="" CS_USED_PCT="" CS_TOKENS="" CS_WINDOW="" CS_NANO_AIU="" CS_ALLOW_ALL=""
copilot_session_fields() { # RECORD
  local line
  CS_MODEL="" CS_USED_PCT="" CS_TOKENS="" CS_WINDOW="" CS_NANO_AIU="" CS_ALLOW_ALL=""
  line="$(jq -r '
    def whole: if type == "number" and . >= 0 then (floor | tostring) else "" end;
    [ (.status.model.id | strings) // "",
      (.status.context_window.used_percentage | if type == "number" then (. + 0.5 | floor | tostring) else "" end),
      (.status.context_window.current_context_tokens | whole),
      (.status.context_window.context_window_size | whole),
      (.status.ai_used.total_nano_aiu | whole),
      (.status.allow_all_enabled | if type == "boolean" then tostring else "" end) ]
    | join("\t")' <<<"$1" 2>/dev/null)" || return 1
  CS_MODEL="${line%%	*}"; line="${line#*	}"
  CS_USED_PCT="${line%%	*}"; line="${line#*	}"
  CS_TOKENS="${line%%	*}"; line="${line#*	}"
  CS_WINDOW="${line%%	*}"; line="${line#*	}"
  CS_NANO_AIU="${line%%	*}"
  CS_ALLOW_ALL="${line#*	}"
}

# copilot_session_stop_cause RECORD GRANTED — the stop cause a record
# establishes for a session whose launch GRANTED allow-all:
# `allow-all-blocked-by-policy` where GRANTED is `true` and the CLI reports
# allow_all_enabled false. Enterprise managed settings, delivered for the
# account or for the machine, can block the allow-all mode, and the CLI
# refreshes them each hour, so a session launched with `--allow-all` can lose
# it mid-run; every tool call then waits on a permission prompt nobody at the
# pane answers. That is a stop with its own cause, never a quiet lane. A
# session launched without allow-all reports false as well and waits on its
# prompts by design; the record alone cannot tell the two apart, so every
# caller passes the launch's grant: copilot_session_lane_note the fleet
# record's `allow_all`, the lane-mail-check hook the session's
# COPILOT_ALLOW_ALL, which lib/lane-launch.sh lane_copilot_env sets `true` on
# a launch line granting it and empty on any other. Prints the cause, 0;
# prints nothing, 1, where GRANTED is anything but `true`, or the record says
# allow-all is on, does not say, or is not JSON.
copilot_session_stop_cause() { # RECORD GRANTED
  [ "$2" = true ] || return 1
  copilot_session_fields "$1" || return 1
  [ "$CS_ALLOW_ALL" = false ] || return 1
  printf 'allow-all-blocked-by-policy\n'
}

# The session id and the directory a session's workspace.yaml names, from its
# `id:` and `cwd:` lines, each empty where the file names none. The CLI writes
# both plain lines as a session starts and before any turn (measured on 1.0.88).
copilot_session_id() { # WORKSPACE_YAML
  awk 'index($0, "id: ") == 1 { print substr($0, 5); exit }' "$1"
}
copilot_session_cwd() { # WORKSPACE_YAML
  awk 'index($0, "cwd: ") == 1 { print substr($0, 6); exit }' "$1"
}

# copilot_session_in_worktree HOME WORKTREE [SINCE] — the workspace.yaml of
# the session a lane in WORKTREE runs under the account HOME, printed, 0: among
# the `HOME/session-state/<id>/workspace.yaml` files whose `cwd:` line is
# WORKTREE, resolved, and that hold events, the newest; with SINCE, epoch
# seconds the launch or relaunch that started the lane's running session read
# before it opened the terminal, the earliest written at or after SINCE, the
# session that launch started. A session a relaunch retired is written before
# SINCE, and a later Copilot session in the same worktree on the same account,
# a second-opinion run from it, after the lane's own, so neither is read in
# its place. A session that ended before its first event, one whose sign-in
# failed, leaves workspace.yaml and no events.jsonl, and
# `copilot --resume=<id>` on it exits 1, so it is passed over. 1 where no
# session qualifies; 2 where WORKTREE does not resolve or the store could not
# be read.
copilot_session_in_worktree() { # HOME WORKTREE [SINCE]
  local store="$1/session-state" since="${3:-}" cwd files file recorded written best=""
  cwd="$(cd -- "$2" 2>/dev/null && pwd -P)" || return 2
  [ -e "$store" ] || return 1
  { [ -d "$store" ] && [ -r "$store" ]; } || return 2
  files="$(find -H "$store" -mindepth 2 -maxdepth 2 -type f -name workspace.yaml -print 2>/dev/null)" || return 2
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    recorded="$(copilot_session_cwd "$file")" || return 2
    { [ "$recorded" = "$cwd" ] && [ -s "${file%/*}/events.jsonl" ]; } || continue
    if [ -z "$since" ]; then
      { [ -n "$best" ] && [ ! "$file" -nt "$best" ]; } || best="$file"
      continue
    fi
    written="$(stat -c %Y -- "$file" 2>/dev/null || stat -f %m -- "$file" 2>/dev/null)" || return 2
    case "$written" in '' | *[!0-9]*) return 2 ;; esac
    [ "$written" -ge "$since" ] || continue
    { [ -n "$best" ] && [ ! "$file" -ot "$best" ]; } || best="$file"
  done <<<"$files"
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# copilot_session_lane_note HOME SESSION_ID WORKTREE GRANTED NOW SINCE — what the
# session record of a Copilot lane on the account HOME says about a stop, for a
# reader outside the session, which holds no payload naming it: `lanes state`
# and oversee-watch, through lib/lane-context.sh lane_context_copilot_note.
# Into COPILOT_SESSION_NOTE as one `key=value` word, empty where the record
# names no cause:
#   stop-cause=<cause>       copilot_session_stop_cause's cause
#   session-record=<reason>  no record answered: copilot_session_read's reason,
#                            `worktree-unmatched` for no SESSION_ID and no
#                            session with events in WORKTREE since SINCE, or
#                            `store-unreadable` for a WORKTREE or a session
#                            store that could not be read
# GRANTED is `true` for a lane whose launch granted the full allow-all mode,
# `--allow-all` or `--yolo` (lib/lane-launch.sh lane_copilot_allows_all), and
# is handed on to copilot_session_stop_cause, which judges it. Only such a lane
# has an allow-all a policy can take, so any other GRANTED leaves the note
# empty and reads no record: a record reason for a lane that can carry no
# cause names nothing to act on. The session is SESSION_ID, else the one
# copilot_session_in_worktree names for WORKTREE since SINCE, in epoch seconds
# the record's `session_since`, the launch that started the running session,
# or the newest there where SINCE is empty. Always 0.
COPILOT_SESSION_NOTE=""
copilot_session_lane_note() { # HOME SESSION_ID WORKTREE GRANTED NOW SINCE
  local home="$1" session="$2" file rc=0
  COPILOT_SESSION_NOTE=""
  [ "$4" = true ] || return 0
  if [ -z "$session" ]; then
    if [ -z "$3" ]; then rc=1; else file="$(copilot_session_in_worktree "$home" "$3" "${6:-}")" || rc=$?; fi
    [ "$rc" -ne 0 ] || session="$(copilot_session_id "$file")" || rc=2
    case "$rc" in
      0) ;;
      1) COPILOT_SESSION_NOTE=session-record=worktree-unmatched; return 0 ;;
      *) COPILOT_SESSION_NOTE=session-record=store-unreadable; return 0 ;;
    esac
  fi
  if ! copilot_session_read "$home" "$session" "" "$5"; then
    COPILOT_SESSION_NOTE="session-record=$COPILOT_SESSION_REASON"
  elif COPILOT_SESSION_NOTE="$(copilot_session_stop_cause "$COPILOT_SESSION_RECORD" "$4")"; then
    COPILOT_SESSION_NOTE="stop-cause=$COPILOT_SESSION_NOTE"
  fi
}
