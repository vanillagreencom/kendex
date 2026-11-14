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
# oversee state's `overseer.session_rows` names it: the runtime watch
# (`orch-runtime watch`) reads the path there for its liveness judgement and
# its context record check, and every shell reader and the writer compute it
# through session_rows_overseer_file. Appends
# take the mailbox's own lock and line rules (lib/mailbox-append.sh), so a
# killed writer leaves a fragment no reader parses and no row glued to another.
#
# The writer is the lane-mail-check hook, run with the argument `row` and the
# event by the session-start-row, session-end-row and stop-failure-row hooks,
# on the harnesses that run each one (those `kendex show hook <name>` lists as
# neither unsupported nor advisory), and in its own turn-end run for the
# overseer: a Stop at every overseer turn end, which lifts a standing
# StopFailure row and dates the turn end the runtime watch holds the
# overseer's context record against. The readers are the runtime watch's
# overseer judgement and `oversee register`.
#
# A last row the session verdict (agent-runtime's `rows verdict --kind
# session`) cannot judge reads `unsupported`, and its
# reader takes the pane, the named fallback, reported as fallback.
#
# ONE OWNER, THE WRITER, for "whose facts are these": only the pane's own
# top-level harness writes a row, so a harness that session starts in its own
# pane (second-opinion's `claude -p`, a `codex exec`), which inherits
# TMUX_PANE, writes nothing and no reader has another session's row to judge
# (session_rows_top_level).
#
# A Pi LANE's rows are a second file of the same shape, in the lane's own
# mailbox directory, `tmp/lane-mail/<item>/session-rows.jsonl` under its
# worktree, the directory lane mail and the runtime watch read from any host:
# the same hook writes a Stop row at each turn end and a PreToolUse row at the
# first tool call of each turn, after a turn end or on an empty file, which is
# all the runtime watch and `orch-runtime lane status` need to tell an idle,
# working or walled Pi lane apart without its pane
# (session_rows_lane_write; agent-runtime's `rows verdict --kind lane` reads
# them). Claude Code and Codex
# lanes write none: their pane is what the watch's classifier reads.
#
# session_rows_overseer_file requires lib/lane-context.sh and session_rows_dead
# lib/tmux-server.sh, sourced by the caller; the readers need jq, grep and tail
# alone. Sourced, never run. Bash 3.2-safe, like its callers.

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
    named="$(jq -r '[.controller.session_rows, .controller.pending.session_rows,
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
