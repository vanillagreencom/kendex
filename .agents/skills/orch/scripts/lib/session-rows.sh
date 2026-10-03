# shellcheck shell=bash
# What an overseer session's harness says about that session, one row per hook
# event, so a reader judges whether the session is up, walled or gone from what
# the harness emitted and never from what its pane shows.
#
# The rows are JSON, one per line, in one file per session under the overseer
# mailbox directory at the main checkout (lib/lane-context.sh §
# lane_context_overseer_box), the transport lane mail already carries to every
# reader of that directory. The file is keyed by the `<tmux server pid> <pane
# id>` the session runs in, the pair the fleet state keys the overseer on, so a
# hook can name its own file before any record names the session, and the
# oversee state's `overseer.session_rows` names it: oversee-watch's liveness
# judgement reads the path there, and every other reader, the watch's context
# record check included, and the writer compute it through
# session_rows_overseer_file. Appends
# take the mailbox's own lock and line rules (lib/mailbox-append.sh), so a
# killed writer leaves a fragment no reader parses and no row glued to another.
#
# The writer is the lane-mail-check hook, run with the argument `row` and the
# event by the session-start-row, session-end-row and stop-failure-row hooks,
# on the harnesses each one's harnesses line names (hooks/README.md), and in
# its own turn-end run for the overseer: a Stop at every overseer turn end,
# which lifts a standing StopFailure row and dates the turn end oversee-watch
# holds the overseer's context record against. The readers are oversee-watch's
# overseer judgement, `oversee register` and oversee-succeed's caller identity.
#
# The verdict answers for Claude Code alone: a session whose last row names
# another harness reads `unsupported` and its reader takes the pane, the named
# fallback, reported as fallback.
#
# ONE OWNER, THE WRITER, for "whose facts are these": only the pane's own
# top-level harness writes a row, so a harness that session starts in its own
# pane (second-opinion's `claude -p`, a `codex exec`), which inherits
# TMUX_PANE, writes nothing and no reader has another session's row to judge
# (session_rows_top_level).
#
# A Pi LANE's rows are a second file of the same shape, in the lane's own
# mailbox directory, `tmp/lane-mail/<item>/session-rows.jsonl` under its
# worktree, the directory lane mail and `lanes context` already read from any
# host: the same hook writes a Stop row at each turn end and a PreToolUse row
# at the first tool call of each turn, after a turn end or on an empty file,
# which is all oversee-watch and `lanes state` need to tell an idle, working or
# walled Pi lane apart without its pane
# (session_rows_lane_write, session_rows_lane_verdict). Claude Code and Codex
# lanes write none: their pane is still what lib/lane-state.sh reads.
#
# The overseer writer requires lib/file-lock.sh, lib/mailbox-append.sh,
# lib/lane-context.sh and lib/lane-state.sh sourced by its caller, and the lane
# writer the first two; the overseer readers need jq and tail alone, and the
# lane verdict lib/lane-state.sh besides. Sourced, never run. Bash 3.2-safe,
# like its callers.

# Seconds an append waits for the file's lock before it gives up.
SESSION_ROWS_WAIT=5
# The rows a reader looks back over for the last row of an event: a session
# appends a start, an end, a failure per wall and a Stop per turn, so the rows
# are taken from those naming the event first and the span bounds that list.
SESSION_ROWS_SPAN=64

# session_rows_path BOX SERVER PANE — the rows file of the session in PANE on
# the tmux server whose pid is SERVER, inside the mailbox directory BOX. The
# pane id's `%` is dropped, so the name holds no character a shell or a glob
# reads.
session_rows_path() { # BOX SERVER PANE
  printf '%s/session-%s-%s.jsonl\n' "$1" "$2" "${3#%}"
}

# SESSION_ROWS_DEAD lists files of confirmed gone panes, never files named by
# the current or pending fleet record. An unreachable server is not dead.
# workflow-state prune archives this list before removing any of it.
SESSION_ROWS_DEAD=()
session_rows_dead() { # BOX FLEET_STATE
  local named="" file name server pane rc nl='
'
  SESSION_ROWS_DEAD=()
  if [ -f "$2" ]; then
    named="$(jq -r '[.overseer.session_rows, .overseer.pending.session_rows,
      .pending.session_rows] | .[] | strings' "$2")" || return 2
  fi
  for file in "$1"/session-*-*.jsonl; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    case "$nl$named$nl" in *"$nl$file$nl"*) continue ;; esac
    name="${file##*/session-}"
    server="${name%%-*}"
    pane="${name#*-}"; pane="${pane%.jsonl}"
    case "$server:$pane" in *[!0-9:]*) continue ;; esac
    [ -n "$server" ] && [ -n "$pane" ] || continue
    rc=0
    tmux_pane_live "$server" "" "%$pane" || rc=$?
    case "$rc" in
      0 | 2) ;;
      1) SESSION_ROWS_DEAD+=("$file") ;;
      *) return 2 ;;
    esac
  done
}

# session_rows_overseer_file DIR SERVER PANE — the same file for a session of
# the checkout DIR is in: the path every writer and every reader asks here, so
# a hook and a record writer cannot name one session's file two ways.
session_rows_overseer_file() { # DIR SERVER PANE
  session_rows_path "$(lane_context_overseer_box "$1")" "$2" "$3"
}

# session_rows_last FILE [EVENT] — the last row of FILE into SESSION_ROW, or
# the last whose event is EVENT, looked for over the last SESSION_ROWS_SPAN
# lines, or over the last that many lines spelling EVENT the way jq -c writes
# it, so a start many turns back is still found; empty where the file is
# missing or holds none. A line that is not JSON is a fragment a killed writer
# left, which the next append closes, and is passed over as the mailbox reader
# passes one. Exit 2 where the file is there and could not be read.
SESSION_ROW=""
session_rows_last() { # FILE [EVENT]
  local lines rc=0
  SESSION_ROW=""
  [ -e "$1" ] || return 0
  if [ -n "${2:-}" ]; then
    lines="$(grep -F -- "\"event\":\"$2\"" "$1")" || rc=$?
    [ "$rc" -le 1 ] || return 2
    lines="$(tail -n "$SESSION_ROWS_SPAN" <<<"$lines")" || return 2
  else
    lines="$(tail -n "$SESSION_ROWS_SPAN" -- "$1")" || return 2
  fi
  SESSION_ROW="$(jq -cR --arg event "${2:-}" 'fromjson? | objects
    | select($event == "" or .event == $event)' <<<"$lines" | tail -n 1)" || return 2
}

# session_rows_verdict FILE — what the last row says of the session, into
# SESSION_ROWS_VERDICT, with that row in SESSION_ROW:
#   none         no row, so nothing the harness said can be read
#   unsupported  the row names any harness but Claude Code, the one whose
#                rows this verdict answers for, so its silence settles nothing
#   ended        SessionEnd for any reason but `clear` and `resume`, the two a
#                SessionStart follows in the same harness
#   walled       StopFailure with `rate_limit`, the harness's own word for a
#                usage limit; its `message` carries the harness's text with the
#                reset in it
#   wedged       StopFailure whose `message` or `error_details` names a
#                request refused for its prompt's length, a phrase
#                SESSION_ROWS_PROMPT_TOO_LONG lists: the session's context
#                filled its window, so every turn it starts fails the same way
#                while its harness stays up
#   live         any other row
# Exit 2 where the file could not be read; the verdict is then `none` and says
# nothing.
#
# The phrases are the harness's own text, lowercased and matched as a
# substring, one table read by this judge alone. Claude Code writes
# `Prompt is too long` as the turn's last assistant message when a request
# outgrows the window; an overseer run with DISABLE_AUTO_COMPACT=1 met it on
# every turn once its context filled.
SESSION_ROWS_PROMPT_TOO_LONG='["prompt is too long"]'
SESSION_ROWS_VERDICT=none
session_rows_verdict() { # FILE
  SESSION_ROWS_VERDICT=none
  session_rows_last "$1" || return 2
  [ -n "$SESSION_ROW" ] || return 0
  SESSION_ROWS_VERDICT="$(jq -r --argjson too_long "$SESSION_ROWS_PROMPT_TOO_LONG" '
    if .harness != "claude" then "unsupported"
    elif .event == "SessionEnd" then
      (if .reason == "clear" or .reason == "resume" then "live" else "ended" end)
    elif .event == "StopFailure" and .error == "rate_limit" then "walled"
    elif .event == "StopFailure"
      and ((((.message // "") + "\n" + (.error_details // "")) | ascii_downcase) as $text
        | any($too_long[]; . as $p | $text | contains($p)))
    then "wedged"
    else "live" end' <<<"$SESSION_ROW")" || { SESSION_ROWS_VERDICT=none; return 2; }
}

# session_rows_start FILE [SINCE] — the last SessionStart row of FILE, at or
# after the epoch SINCE where given, split into SR_HARNESS, SR_ACCOUNT, SR_MODEL
# and SR_CWD, each empty where the row carries none. The row's `session_id`
# and `transcript_path` are not read here: the turn-end hook binds the
# transcript to the session from its own payload (lib/lane-context.sh §
# lane_context_transcript_owned), the one reader of that pair, and neither is
# copied into a record. Exit 1 where no such row stands, 2 where the file
# could not be read.
SR_HARNESS="" SR_ACCOUNT="" SR_MODEL="" SR_CWD=""
session_rows_start() { # FILE [SINCE]
  local fields sep=$'\x1f'
  SR_HARNESS="" SR_ACCOUNT="" SR_MODEL="" SR_CWD=""
  session_rows_last "$1" SessionStart || return 2
  [ -n "$SESSION_ROW" ] || return 1
  fields="$(jq -r --argjson since "${2:-0}" --arg sep "$sep" '
    select((.at // 0) >= $since)
    | [.harness, .account, .model, .cwd]
    | map(. // "" | tostring) | join($sep)' <<<"$SESSION_ROW")" || return 2
  [ -n "$fields" ] || return 1
  IFS="$sep" read -r SR_HARNESS SR_ACCOUNT SR_MODEL SR_CWD <<<"$fields"
}

# session_rows_top_level PANE_PID — 0 where exactly one process that is not a
# shell stands between this process and PANE_PID, the pane's own shell: the
# harness that ran this hook, directly under that shell or under the shells
# and exec'd wrappers a launch puts there (overseer-run, env). A harness
# nested under another, which the other one's tool shell started, has two;
# a process under no such pane never reaches it. Exit 1 for either, and for a
# process table `ps` could not read, which is no evidence of a top-level
# session. A harness that is the pane's process itself (`tmux new-window
# claude`, `exec claude` at the prompt, a tmux default command) is where the
# walk stops and is never counted, so it writes no row and its reader takes
# the pane fallback; a launched overseer is typed into the pane's shell and is
# not that shape. The shell set is lib/lane-state.sh's is_bare_shell.
session_rows_top_level() { # PANE_PID
  local pid="$$" line ppid comm harnesses=0 steps=0
  while [ "$pid" != "$1" ]; do
    [ "$steps" -lt 64 ] && [ "$pid" -gt 1 ] || return 1
    line="$(ps -o ppid= -o comm= -p "$pid" 2>/dev/null)" || return 1
    read -r ppid comm <<<"$line"
    [ -n "$ppid" ] || return 1
    is_bare_shell "${comm##*/}" || harnesses=$((harnesses + 1))
    pid="$ppid"
    steps=$((steps + 1))
  done
  [ "$harnesses" -eq 1 ]
}

# session_rows_write DIR HARNESS [EVENT] — the hook payload on stdin appended as one row
# to the file of the session this process runs in, the pane
# lane_context_caller_key names, in the overseer mailbox directory of the
# checkout DIR is in. HARNESS is the one the hook's install names, and the row
# carries the account that harness runs on as lane_context_caller_cfg reads it
# from this process's own environment, which is the harness's: a hook is its
# child, so no wrapper's value stands in for the one the session holds. EVENT
# names the event a payload that spells no hook_event_name is taken for: the
# turn-end run knows it ran at a Stop whatever its payload carries, and a row
# hook names its own event for Copilot's camelCase payloads, which spell none
# and name the session `sessionId` and the transcript `transcriptPath`.
#
# Nothing is written, with exit 0, where that directory is not there, since no
# fleet made it and no reader will look, for a session that is not its pane's
# top-level harness (session_rows_top_level), and for a subagent's payload. A
# Stop row is compact, its event, time, harness and session alone, except over
# a standing StopFailure, which it lifts and where it keeps the turn's last
# message: the file takes one per turn. Exit 3 where the session sits on
# no pane this can key, 1 where the payload names no event or jq could not
# build the row, and mailbox_append_locked's own 2 and 3 for the write and the
# lock. The cause is on stderr.
session_rows_write() { # DIR HARNESS [EVENT]
  local key file payload event account row pane_pid
  key="$(lane_context_caller_key)" || return 3
  file="$(session_rows_overseer_file "$1" "${key%% *}" "${key#* }")"
  [ -d "${file%/*}" ] || return 0
  pane_pid="$(tmux display-message -p -t "${key#* }" '#{pane_pid}' 2>/dev/null)" || return 3
  session_rows_top_level "$pane_pid" || return 0
  payload="$(cat)" || return 1
  # A subagent's payload carries its agent_id: its failure is its own turn's,
  # never the session's.
  event="$(jq -r --arg event "${3:-}" \
    'if (.agent_id // "") != "" then "subagent" else ((.hook_event_name | strings) // $event) end' \
    <<<"$payload")" || return 1
  [ "$event" != subagent ] || return 0
  [ -n "$event" ] || { printf 'the payload names no hook_event_name\n' >&2; return 1; }
  if [ "$event" = Stop ]; then
    session_rows_last "$file" || return 2
    if [ "$(jq -r '.event // ""' <<<"${SESSION_ROW:-null}")" != StopFailure ]; then
      row="$(jq -c --arg harness "$2" --argjson at "$(date +%s)" '
        {at: $at, event: "Stop", harness: $harness}
        + ({session_id: (.session_id // .sessionId)} | with_entries(select(.value | type == "string" and . != "")))' <<<"$payload")" || return 1
      printf '%s\n' "$row" | mailbox_append_locked "$file" "$SESSION_ROWS_WAIT"
      return
    fi
  fi
  account="$(lane_context_caller_cfg "$2")"
  row="$(jq -c --arg event "$event" --arg harness "$2" --arg account "$account" --argjson at "$(date +%s)" '
    {at: $at, event: $event, harness: $harness}
    + ({session_id: (.session_id // .sessionId), transcript_path: (.transcript_path // .transcriptPath),
        cwd, source, model, reason, error, error_details}
       | with_entries(select(.value | type == "string" and . != "")))
    + (if (.last_assistant_message | type) == "string" then {message: .last_assistant_message} else {} end)
    + (if $account == "" then {} else {account: $account} end)' <<<"$payload")" || return 1
  printf '%s\n' "$row" | mailbox_append_locked "$file" "$SESSION_ROWS_WAIT"
}

# ---------------------------------------------------------------------------
# A Pi lane's own rows.
# ---------------------------------------------------------------------------

# The lane rows file's name inside a lane's mailbox directory.
SESSION_ROWS_LANE=session-rows.jsonl
# The transcript tail the Stop row reads its turn's end from: the bound the
# turn-end hook reads a transcript under, since a session file grows without
# limit and its last assistant message is at its end.
SESSION_ROWS_TRANSCRIPT_TAIL=1048576

# Whether FILE's last row is a turn end, or FILE holds none: the one state a
# PreToolUse row is appended over, so a turn of many tool calls writes one.
# Run under the append's lock as its guard, whose refusal the writer reads as
# a turn already open; a file this cannot read answers yes, so the append
# itself meets the fault and reports it rather than the row going unwritten
# in silence.
session_rows_turn_open() { # FILE
  session_rows_last "$1" || return 0
  [ -z "$SESSION_ROW" ] && return 0
  [ "$(jq -r '.event // ""' <<<"$SESSION_ROW")" = Stop ]
}

# session_rows_lane_write BOX HARNESS EVENT [TRANSCRIPT] — one row for the lane
# whose mailbox directory is BOX: `Stop` at a turn end, carrying the
# `stopReason` of the turn's last assistant message in TRANSCRIPT, Pi's
# `message` record (`AssistantMessage`, @earendil-works/pi-ai), and its
# `errorMessage` as `message` where that reason is `error`; `PreToolUse` at a
# tool call, written only over a Stop row or an empty file. Nothing is written,
# with exit 0, where BOX is not there, or for a PreToolUse a turn already
# opened. Exit 1 where jq could not build the row, mailbox_append_locked's own
# 2 and 3 for the write and the lock. The cause is on stderr.
session_rows_lane_write() { # BOX HARNESS EVENT [TRANSCRIPT]
  local file="$1/$SESSION_ROWS_LANE" end='{}' row rc=0
  [ -d "$1" ] || return 0
  if [ "$3" = Stop ] && [ -n "${4:-}" ] && [ -f "$4" ]; then
    end="$(tail -c "$SESSION_ROWS_TRANSCRIPT_TAIL" -- "$4" | jq -Rnc '
      [inputs | fromjson? | select(.type == "message" and .message?.role == "assistant") | .message]
      | last // {}
      | {stop_reason: .stopReason, message: (if .stopReason == "error" then .errorMessage else null end)}
      | with_entries(select(.value | type == "string"))')" || return 1
  fi
  row="$(jq -c --arg event "$3" --arg harness "$2" --argjson at "$(date +%s)" \
    '{at: $at, event: $event, harness: $harness} + .' <<<"$end")" || return 1
  if [ "$3" = Stop ]; then
    printf '%s\n' "$row" | mailbox_append_locked "$file" "$SESSION_ROWS_WAIT"
    return
  fi
  printf '%s\n' "$row" | mailbox_append_locked "$file" "$SESSION_ROWS_WAIT" session_rows_turn_open || rc=$?
  # 4 is the guard's own answer: a turn already open, which is no failure.
  [ "$rc" -eq 4 ] && return 0
  return "$rc"
}

# session_rows_lane_verdict FILE — what a Pi lane's last row says of it, into
# SESSION_ROWS_VERDICT, with that row in SESSION_ROW:
#   none     no row: the lane has emitted nothing a reader can judge
#   working  a PreToolUse row, a turn started after the last turn end
#   walled   a Stop row whose turn ended on an error lib/lane-state.sh §
#            lane_limit_banner reads as the account's limit
#   idle     any other Stop row
# Exit 2 where the file could not be read, or its last row names an event no
# writer above writes; the verdict is then `none` and says nothing.
session_rows_lane_verdict() { # FILE
  local fields banner
  SESSION_ROWS_VERDICT=none
  session_rows_last "$1" || return 2
  [ -n "$SESSION_ROW" ] || return 0
  fields="$(jq -r '"\(.event // "")\t\(.stop_reason // "")"' <<<"$SESSION_ROW")" || return 2
  case "$fields" in
    PreToolUse$'\t'*) SESSION_ROWS_VERDICT=working ;;
    Stop$'\t'error)
      banner="$(lane_limit_banner "$(jq -r '.message // ""' <<<"$SESSION_ROW")")" || return 2
      SESSION_ROWS_VERDICT=idle
      [ -z "$banner" ] || SESSION_ROWS_VERDICT=walled ;;
    Stop$'\t'*) SESSION_ROWS_VERDICT=idle ;;
    *) return 2 ;;
  esac
}
