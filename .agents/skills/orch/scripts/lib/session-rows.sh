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
# The same hook writes the Jarvis runtime record below, never this file.
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
# A session the Jarvis runtime launched writes no file here of its own: its
# SessionStart fills the launch's pending row in the runtime record its
# environment names, with no fleet and no mailbox (session_rows_jarvis_write),
# and the lane-mail-check hook's own run at its first tool call, or on Claude
# Code, Codex and Copilot CLI its turn end, after the Start brief stamps that
# row once as the brief taken, and on Codex and Copilot CLI its turn end before
# the brief stamps it once as the kickoff turn ended (session_rows_jarvis_taken): the facts the
# Jarvis launch worker reads.
#
# The overseer writer requires lib/file-lock.sh, lib/mailbox-append.sh,
# lib/lane-context.sh and lib/lane-state.sh sourced by its caller, the lane
# writer the first two, and the Jarvis stamp lib/file-lock.sh and
# lib/lane-context.sh; the overseer readers need jq and tail alone. Sourced,
# never run. Bash 3.2-safe,
# like its callers.

# Seconds an append waits for the file's lock before it gives up. Below the
# least `timeout:` any hook that writes a row declares, session-end-row's 3 s,
# the longest Codex runs a SessionEnd hook: a writer that loses the lock says
# so on stderr rather than being killed first (hooks/tests/session-rows.test.sh).
SESSION_ROWS_WAIT=2
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

# The Jarvis runtime owns record format and terminal liveness. Both missing
# pane recovery and the turn-end role consume this same native binding.
# DEFAULT permits Session(home)'s canonical-home/XDG record lookup when the
# launch bindings are absent; the normal role keeps its explicit bindings.
session_rows_jarvis_identity() { # DIR HARNESS SESSION PANE [DEFAULT]
  local owner="${BASH_SOURCE[0]%/orch/scripts/lib/*}/jarvis/scripts/lib/session.py" socket="${TMUX:-}"
  [ -f "$owner" ] || return 1
  env JARVIS_BASH="$BASH" python3 - "$owner" "$1" "${JARVIS_RECORD:-}" \
    "${JARVIS_GENERATION:-}" "$2" "$3" "${socket%%,*}" "$4" "${5:-}" <<'PY'
import json
from pathlib import Path
import runpy
import sys

owner = runpy.run_path(sys.argv[1])
session = owner["Session"](sys.argv[2])
default = sys.argv[9] == "default"
if (not default or sys.argv[3]) and session.path != Path(sys.argv[3]):
    sys.exit(1)
record = session.read()
if not record or record["state"] not in ("starting", "running") or record.get("harness") != sys.argv[5]:
    sys.exit(1)
identity = record.get("pending") or {}
terminal = record.get("terminal") or {}
if (((not default or sys.argv[4]) and str(identity.get("generation")) != sys.argv[4])
        or identity.get("native_session_id") != sys.argv[6]
        or terminal.get("server") != sys.argv[7]
        or (sys.argv[8] and terminal.get("pane") != sys.argv[8])
        or not session.terminal(record)):
    sys.exit(1)
print(json.dumps({"home": session.home, "account_home": record.get("effective_home") or record.get("account"),
                  "pane": terminal["pane"], "state": record["state"],
                  "record": str(session.path), "generation": identity.get("generation")}))
PY
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

# Whether a record's pending row is the launch of the session a hook runs in:
# the record's harness, and the row's generation, tmux server pid and lead
# pane, against the hook's install, JARVIS_GENERATION and its own key. One
# def, which the identity write and the brief stamp both read.
SESSION_ROWS_JARVIS_BOUND='def bound($generation; $server; $pane; $harness):
  .harness == $harness and (.pending | type) == "object" and $generation != ""
  and (.pending.generation | tostring) == $generation
  and (.pending.server | tostring) == $server
  and .pending.pane == $pane;'

# session_rows_jarvis_write RECORD GENERATION KEY HARNESS: the SessionStart payload on
# stdin written as its session's native identity into the `pending` row of the
# Jarvis runtime record RECORD: the harness's own session id as
# `native_session_id`, its session file as `session_file` where it names one,
# `started_at`, and the effective account read from this native hook's
# environment. The launcher writes that row, with its launch `generation`,
# tmux `server` pid and lead `pane` id, before the harness starts, and hands the
# harness RECORD and GENERATION as JARVIS_RECORD and JARVIS_GENERATION; KEY is
# this session's `<server pid> <pane id>`. A row naming another generation,
# server or pane, or one already started, is another session's and is left as
# it stands, with exit 0. A launch that preassigned the id writes it in the row
# as `native_session_id`, and a start the harness names by any other id, or by
# none, is refused, exit 4: the identity is the harness's own word, never a
# transcript picked by its modification time. The write renames a new file
# over RECORD under the lock on `RECORD.lock`, which every writer of the record
# takes, as workflow-state's writers take theirs. Exit 1 where the payload names
# neither or RECORD could not be read, 2 where it could not be written, 3 where
# its lock was not taken. The cause is on stderr.
session_rows_jarvis_write() { # RECORD GENERATION KEY HARNESS
  local identity account
  account="$(lane_context_caller_cfg "$4")" || return 1
  [ -n "$account" ] || return 1
  identity="$(jq -c '{native_session_id: (.session_id // .sessionId),
      session_file: (.transcript_path // .transcriptPath)}
    | with_entries(select(.value | type == "string" and . != ""))')" || return 1
  (
    exec 200>>"$1.lock" || exit 2
    orch_take_lock 200 "$1.lock" "$SESSION_ROWS_WAIT" || exit 3
    verdict="$(jq -r --arg generation "$2" --arg server "${3%% *}" --arg pane "${3#* }" \
      --argjson identity "$identity" --arg harness "$4" "$SESSION_ROWS_JARVIS_BOUND"'
      .pending as $p
      | if (bound($generation; $server; $pane; $harness) | not) or $p.started_at != null then "other"
        elif ($p.native_session_id // $identity.native_session_id) != $identity.native_session_id then "mismatch"
        elif ($identity | length) == 0 then "unnamed"
        else "own" end' -- "$1")" || exit 1
    case "$verdict" in
      other) exit 0 ;;
      own) ;;
      *)
        printf 'jarvis-identity=%s record=%s\nthe start is not recorded as the launch the record awaits\n' \
          "$verdict" "$1" >&2
        [ "$verdict" = mismatch ] && exit 4
        exit 1 ;;
    esac
    jq -c --argjson identity "$identity" --arg account "$account" --argjson at "$(date +%s)" \
      '.pending += $identity + {started_at: $at, observed_account: $account}' -- "$1" >"$1.$$" || { rm -f -- "$1.$$"; exit 2; }
    mv -f -- "$1.$$" "$1" || { rm -f -- "$1.$$"; exit 2; }
  )
}

# session_rows_jarvis_taken RECORD GENERATION KEY HARNESS EVENT: the hook payload
# on stdin, of the session's tool call (EVENT PreToolUse) or turn end (Stop),
# stamped once into the pending row of the Jarvis runtime record RECORD, which
# the Jarvis launch worker reads. Either stamp lands only where that row is
# this session's launch (the bound def above), its identity started under the
# payload's own session id, the launch is still `starting`, and no
# `brief_taken` stands.
#
# `brief_taken`, the Start brief taken: where the record says the brief was
# delivered. The worker writes `brief_delivered` under the same lock in the
# hold that pastes the brief, so this stamp is ordered after the delivery
# with no clock; a hook that met the lock held retries at the session's next
# call that stamps. A turn end writes it on Claude Code, Codex and Copilot
# CLI. Claude Code fires StopFailure in place of Stop on an errored turn.
# Codex Stop has no outcome field, and Copilot agentStop's stopReason is
# always end_turn, so an errored brief turn that emits Stop also reads as
# taken on those harnesses. The worker still refuses a sign-in wall, trust
# question or wrong account before a stamp counts. Pi stamps only a Stop
# whose `pi_run_outcome` is `completed`: its carrier also dispatches Stop on
# errored and aborted runs. The outcome must travel on Stop itself, because
# the worker can read the stamp before the later StopFailure dispatch.
# A Pi carrier without that field still needs a tool call.
#
# `kickoff_ended`, the kickoff turn ended: a Codex or Copilot turn end where
# the brief is not yet delivered. Those harnesses fire SessionStart only at
# their first prompt, so their launch submits a fixed kickoff
# (lib/lane-launch.sh § lane_session_command), and the worker pastes the brief
# only once this stamp says that turn ended: the pane cannot tell a turn's
# first frames, or Copilot's composer during a turn, from its end. An errored
# kickoff turn also ends the turn the brief must wait out. Copilot fires
# agentStop for a subagent under the subagent's own session id, which never
# matches the launch's.
#
# Every other record is left as it stands, with exit 0. The verdict is read
# first without the lock, since every writer renames a whole record into
# place, so a running session's later calls take no lock and write nothing.
# Only a launch a stamp is due on, or would be once the worker's hold records
# the delivery, takes the lock and reads it again.
#
# Exit 1 where the payload or RECORD could not be read, 2 where RECORD could
# not be written, 3 where its lock was not taken. The cause is on stderr.
session_rows_jarvis_taken() { # RECORD GENERATION KEY HARNESS EVENT
  local session verdict due stamp
  case "$5:$4" in
    PreToolUse:* | Stop:claude) due=own ;;
    Stop:pi) due=completed ;;
    Stop:codex | Stop:copilot) due=turn ;;
    *) return 0 ;;
  esac
  session="$(jq -r --arg due "$due" '
    select($due != "completed" or .pi_run_outcome == "completed")
    | (.session_id // .sessionId) | strings')" || return 1
  [ -n "$session" ] || return 0
  [ "$due" != completed ] || due=own
  verdict="$(session_rows_jarvis_due "$1" "$2" "$3" "$4" "$session")" || return 1
  case "$due:$verdict" in
    own:own | own:undelivered | own:ended | turn:own | turn:undelivered) ;;
    *) return 0 ;;
  esac
  (
    exec 200>>"$1.lock" || exit 2
    orch_take_lock 200 "$1.lock" "$SESSION_ROWS_WAIT" || exit 3
    verdict="$(session_rows_jarvis_due "$1" "$2" "$3" "$4" "$session")" || exit 1
    case "$due:$verdict" in
      own:own | turn:own) stamp=brief_taken ;;
      turn:undelivered) stamp=kickoff_ended ;;
      *) exit 0 ;;
    esac
    jq -c --arg stamp "$stamp" '.pending[$stamp] = true' -- "$1" >"$1.$$" || { rm -f -- "$1.$$"; exit 2; }
    mv -f -- "$1.$$" "$1" || { rm -f -- "$1.$$"; exit 2; }
  )
}

# session_rows_jarvis_due RECORD GENERATION KEY HARNESS SESSION: `own` where
# RECORD's launch takes session_rows_jarvis_taken's `brief_taken` stamp,
# `undelivered` where it would but for the brief's delivery and its
# `kickoff_ended` is still due, `ended` where that stamp stands, `other`
# where the launch takes neither.
session_rows_jarvis_due() { # RECORD GENERATION KEY HARNESS SESSION
  jq -r --arg generation "$2" --arg server "${3%% *}" --arg pane "${3#* }" \
    --arg harness "$4" --arg session "$5" "$SESSION_ROWS_JARVIS_BOUND"'
    if (bound($generation; $server; $pane; $harness) and .pending.started_at != null
      and .pending.native_session_id == $session and .state == "starting"
      and .pending.brief_taken == null) | not then "other"
    elif .brief_delivered == true then "own"
    elif .pending.kickoff_ended != null then "ended" else "undelivered" end' -- "$1"
}
