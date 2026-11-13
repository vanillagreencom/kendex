# shellcheck shell=bash
#
# Owner: a Jarvis session, which reads a recorded session file through
# `recorded_session_file`.

# The id a harness resumes a transcript by: the file's basename for claude,
# the session_meta id inside a codex transcript, the file itself for pi,
# whose --session takes a path, and a copilot session's own id, read from its
# workspace.yaml by lib/copilot-session.sh, for recorded_session_file below.
# Empty is a transcript the harness cannot resume, and a failure.
session_id_of() { # HARNESS SESSION_FILE
  local id=""
  case "$1" in
    claude) id="$(basename "$2" .jsonl)" ;;
    codex) id="$(jq -Rrn 'first(inputs|fromjson?|select(.type=="session_meta")|.payload.id)//empty' "$2")" ;;
    pi) id="$2" ;;
    copilot) id="$(copilot_session_id "$2")" || return 1 ;;
  esac
  [[ -n "$id" ]] || return 1
  printf '%s\n' "$id"
}

# A recorded target is exact. Jarvis uses this instead of the newest-session
# search above. A missing target is 1; unreadable or changed identity is 2.
recorded_session_file() { # HARNESS ACCOUNT NATIVE_ID SESSION_FILE
  local harness="$1" account="$2" id="$3" file="$4" actual
  if [[ "$harness" == copilot && -z "$file" ]]; then
    case "$id" in ''|.|..|*[!A-Za-z0-9._-]*) return 2 ;; esac
    file="$account/session-state/$id/workspace.yaml"
  fi
  [[ -n "$file" ]] || return 1
  [[ -e "$file" ]] || { [[ ! -L "$file" ]] || return 2; return 1; }
  [[ -f "$file" && -r "$file" ]] || return 2
  if [[ "$harness" == copilot ]]; then
    [[ -e "${file%/*}/events.jsonl" ]] || return 1
    [[ -f "${file%/*}/events.jsonl" && -r "${file%/*}/events.jsonl" ]] || return 2
    [[ -s "${file%/*}/events.jsonl" ]] || return 1
  else
    jq -Rne '[inputs | fromjson] | length > 0' -- "$file" >/dev/null || return 2
  fi
  actual="$(session_id_of "$harness" "$file")" || return 2
  if [[ "$harness" == pi ]]; then
    actual="$(jq -Rrn 'first(inputs|fromjson|select(.type=="session")|.id)//empty' -- "$file")" || return 2
  fi
  [[ "$actual" == "$id" ]] || return 2
  printf '%s\n' "$file"
}
