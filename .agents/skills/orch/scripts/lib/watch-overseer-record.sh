# shellcheck shell=bash
# The overseer's session record, as oversee-watch writes it at its start: the
# tail every oversee-succeed call carries, and the `overseer` object of the
# fleet state. Sourced by oversee-watch, and like the rest of its lib/ it
# reads that script's globals (HANDOFF, OVERSEER_FLAGS, WORKFLOW_STATE,
# WORKFLOW_STATE_ARGS, SUCCEED) and calls its `overseer_record_notice` and
# `lane_context_caller_key`. Whether the record names this pane is
# lib/overseer-launch.sh's `ol_names`, the test its launchers write and read
# the record by.
# shellcheck source=overseer-launch.sh
source "$SCRIPT_DIR/lib/overseer-launch.sh"

# The tail every oversee-succeed call this watch makes carries: the handoff
# path the successor's brief must name, and the overseer's own flags after the
# `--` that ends that script's parser. Spelled here and nowhere else, because
# two sites ask for the same successor — the record of the line a death would
# replay, and the walled recovery that builds one now — and a flag added to
# one spelling and not the other is a successor launched two ways.
#
# An array rather than a printed list: a flag is one argv word whatever it
# holds, and a line-per-word rendering would split one carrying a newline into
# two. Never empty, so every call site expands it plainly.
OVERSEER_LAUNCH_ARGS=()
overseer_launch_args() {
  OVERSEER_LAUNCH_ARGS=(--handoff "$HANDOFF")
  [[ -z "$OVERSEER_HARNESS" ]] || OVERSEER_LAUNCH_ARGS+=(--harness "$OVERSEER_HARNESS")
  [[ ${#OVERSEER_FLAGS[@]} -eq 0 ]] || OVERSEER_LAUNCH_ARGS+=(-- "${OVERSEER_FLAGS[@]}")
}

# The record, written once at the watch's start. A step that fails is a
# NOTICE through `overseer_record_notice` and never a refusal, because the
# record is not all the watch judges the pane on: where no rows file is
# recorded for this pane, its death and its wall are read off the pane itself,
# the named fallback, so an overseer whose record could not be written is
# still watched. What a failed record costs is the line a dead-pane
# relaunch replays: the record is left as it stood, so a line already there
# stays where the record names this pane, the last line a launch, a
# succession or a watch start recorded for it, and check_overseer replays
# that one on a death; a record naming another pane, or holding no line, is a
# death reported with no successor, since the line there is another
# session's. Each notice from here carries that held line as `held=`, so the
# operator sees which command a death would replay without opening the
# state; `unread` where the record, or the pane key or server start that
# names it, was not read. Always returns 0.
overseer_command_record() {
  local pane="${TMUX_PANE:-}" key server window line detail errf rows start rc=0 held=unread
  [[ -n "${TMUX:-}" && -n "$pane" && -x "$WORKFLOW_STATE" && -x "$SUCCEED" ]] || return 0
  # The key is the orch library's, the same function the lane turn-end hook
  # and `oversee register` read a session's own key with: the hook compares its own
  # against the pair written here, and a second derivation that drifted would
  # leave the overseer's turn end judged by nothing, with no keyed line.
  # That library swallows tmux's own words, and a second read of `#{pid}` here
  # would be a twin of the verb it owns, so the notice names the read that
  # failed instead of replaying a message this script cannot have. The window
  # read below runs here and does replay tmux's. A key that came back in some
  # other shape is its own cause and is replayed as one.
  if ! key="$(lane_context_caller_key)"; then
    overseer_record_notice "tmux reported no server pid for pane $pane" "$held" \
      overseer-unrecorded "pane=$pane" "step=identity"
    return 0
  fi
  if [[ ! "$key" =~ ^([0-9]+)[[:blank:]]+(%[0-9]+)$ ]]; then
    overseer_record_notice "the pane key read back as: $key" "$held" \
      overseer-unrecorded "pane=$pane" "step=identity"
    return 0
  fi
  # Taken here, before the next match replaces BASH_REMATCH.
  server="${BASH_REMATCH[1]}"
  # The start of the server holding the pane: what the record is bound to
  # below, and what ol_names judges it by. Unread, it writes nothing: judged as
  # no start, this pane's own bound record reads as another session's and
  # loses its launch identity.
  if ! start="$(ol_session_start "$server" "$pane")"; then
    overseer_record_notice "" "$held" overseer-unrecorded "pane=$pane" "step=server-start"
    return 0
  fi
  # The line a death would replay as the record stands, for every notice
  # below: the read's own words, where it fails, go to stderr ahead of the
  # notice, which then says `unread`.
  if overseer_record_read "$server" "$start" "$pane"; then
    held="${OVERSEER_RECORD_LINE:-none}"
  fi
  if ! window="$(tmux display-message -p -t "$pane" '#{window_id}' 2>&1)"; then
    overseer_record_notice "$window" "$held" overseer-unrecorded "pane=$pane" "step=window"
    return 0
  fi
  if [[ ! "$window" =~ ^@[0-9]+$ ]]; then
    overseer_record_notice "" "$held" overseer-unrecorded "pane=$pane" "step=window"
    return 0
  fi
  overseer_launch_args
  # The line is the print's stdout alone, so no notice on its stderr enters
  # the command a relaunch types; that stderr is the notice's detail or relayed.
  if ! errf="$(mktemp)"; then
    overseer_record_notice "" "$held" overseer-unrecorded "pane=$pane" "step=mktemp"
    return 0
  fi
  line="$("$SUCCEED" --print-launch-line "${OVERSEER_LAUNCH_ARGS[@]}" 2>"$errf")" || rc=$?
  detail="$(cat -- "$errf")" || detail=""
  rm -f -- "${errf:?}"
  if (( rc != 0 )); then
    overseer_record_notice "$detail" "$held" overseer-line-missing "pane=$pane" "path=$SUCCEED"
    return 0
  fi
  [[ -z "$detail" ]] || printf '%s\n' "$detail" >&2
  if [[ -z "$line" ]]; then
    overseer_record_notice "" "$held" overseer-line-missing "pane=$pane" "path=$SUCCEED"
    return 0
  fi
  # The pane's own event rows file, the one path its hooks write to and every
  # reader of this record reads (lib/session-rows.sh).
  rows="$(session_rows_overseer_file "$PWD" "$server" "$pane")"
  # A start is a live session, so no exit a record carries stands.
  # The six fields this watch observes replace the prior's; the launcher's
  # own, runtime, generation and the launch identity (harness, account, home,
  # model, effort and cwd), stay only where the prior names THIS pane on THIS
  # server, started when this one was, or names this pane on this server with
  # no start at all (ol_owns), the record a writer from
  # before starts were recorded left for the very session in the pane, whose
  # identity the start is written beside: another pane's record is another
  # session's, and so is one an earlier server handed the same pid wrote,
  # whose start is not this server's. A start there has no launch identity to
  # record, which leaves its readers on the pane and the environment until a
  # launcher or `oversee register` writes one. A
  # `pending`
  # successor goes either way: the line this start records is the current
  # session's, as a start always replaced the pending line it met, so a
  # succession that died before its launch leaves nothing a later death would
  # replay. A kept record naming an account, no home and no harness takes the
  # account as its home: `oversee register` and `oversee launch` wrote that
  # shape before they recorded a launch identity, and the turn-end hook binds
  # the overseer's transcript to the home and reads no context without one.
  # The account is a claude session's home (ol_identity), so a record naming
  # claude takes it too; a codex home is its own directory and is never read
  # off the account.
  detail="$("$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} \
    update oversee --arg server "$server" --arg pane "$pane" --arg window "$window" --arg line "$line" \
      --arg rows "$rows" --arg start "$start" "$OL_JQ_DEFS"'
      .overseer = ((((.overseer // {})
        | if ol_owns($server; $start; $pane) then . else {} end)
        + {server: $server, pane: $pane, window: $window, launch_line: $line, session_rows: $rows,
           server_start: ($start | tonumber)})
        | del(.pending, .exit)
        | if (.harness // "claude") == "claude" and (.account // "") != "" and (.home // "") == ""
          then .home = .account else . end)' 2>&1)" \
    || overseer_record_notice "$detail" "$held" overseer-unrecorded "pane=$pane" "step=write"
  return 0
}

# overseer_record_read SERVER START PANE — the fleet state's overseer record as
# the four questions this watch asks of it, into OVERSEER_RECORD_KEY,
# OVERSEER_RECORD_MINE, OVERSEER_RECORD_LINE and OVERSEER_RECORD_HARNESS: the
# record's own `<server> <pane>` key, empty where the state holds no record;
# 1 where the record names that pane on that server, started at START
# (ol_session_start's), by `ol_names`, and 0 otherwise,
# since the key alone is also what an earlier server handed the same pid and
# pane id left; the line a death of SERVER PANE would replay, a standing
# `pending.launch_line` ahead of `launch_line`; and the harness the record
# names for that session. The last two only where the record is this
# session's, and empty otherwise. One reader for the start's `held=` field
# and check_overseer's relaunch, so the two cannot disagree about which line
# a death replays. SERVER, START and PANE are spelled into the filter: every
# caller matched SERVER and PANE against `^[0-9]+$` and `^%[0-9]+$` first,
# START is tmux_server_start's digits, and the `get` verb takes no
# binding. Returns 1 where the state could not be read, with the reader's
# words on stderr.
OVERSEER_RECORD_KEY="" OVERSEER_RECORD_MINE=0 OVERSEER_RECORD_LINE="" OVERSEER_RECORD_HARNESS=""
overseer_record_read() { # SERVER START PANE
  local out sep=$'\x1f'
  OVERSEER_RECORD_KEY="" OVERSEER_RECORD_MINE=0 OVERSEER_RECORD_LINE="" OVERSEER_RECORD_HARNESS=""
  out="$("$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} \
    get oversee "$OL_JQ_DEFS"'
      .overseer as $o
      | ($o | ol_names("'"$1"'"; "'"$2"'"; "'"$3"'")) as $mine
      | [ (if ($o | type) == "object" then (($o.server // "") + " " + ($o.pane // $o.session // "")) else "" end),
          (if $mine then "1" else "0" end),
          (if $mine then ($o.harness // "") else "" end),
          (if $mine then ($o.pending.launch_line // $o.launch_line // "") else "" end) ]
      | join("\u001f")')" || return 1
  OVERSEER_RECORD_KEY="${out%%"$sep"*}"
  out="${out#*"$sep"}"
  OVERSEER_RECORD_MINE="${out%%"$sep"*}"
  out="${out#*"$sep"}"
  OVERSEER_RECORD_HARNESS="${out%%"$sep"*}"
  OVERSEER_RECORD_LINE="${out#*"$sep"}"
}
