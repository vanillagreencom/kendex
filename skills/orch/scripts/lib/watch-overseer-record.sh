# shellcheck shell=bash
# The overseer's session record, as oversee-watch writes it at its start: the
# tail every oversee-succeed call carries, and the `overseer` object of the
# fleet state. Sourced by oversee-watch, and like the rest of its lib/ it
# reads that script's globals (HANDOFF, OVERSEER_FLAGS, WORKFLOW_STATE,
# WORKFLOW_STATE_ARGS, SUCCEED) and calls its `overseer_record_refuse` and
# `lane_context_caller_key`.

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
  [[ ${#OVERSEER_FLAGS[@]} -eq 0 ]] || OVERSEER_LAUNCH_ARGS+=(-- "${OVERSEER_FLAGS[@]}")
}

overseer_command_record() {
  local pane="${TMUX_PANE:-}" key server window line record detail
  [[ -n "${TMUX:-}" && -n "$pane" && -x "$WORKFLOW_STATE" && -x "$SUCCEED" ]] || return 0
  # The key is the orch library's, the same function the lane turn-end hook
  # and `oversee register` read a session's own key with: the hook compares its own
  # against the pair written here, and a second derivation that drifted would
  # leave the overseer's turn end judged by nothing, with no keyed line.
  # That library swallows tmux's own words, and a second read of `#{pid}` here
  # would be a twin of the verb it owns, so the refusal names the read that
  # failed instead of replaying a message this script cannot have. The window
  # read below runs here and does replay tmux's. A key that came back in some
  # other shape is its own cause and is replayed as one.
  if ! key="$(lane_context_caller_key)"; then
    overseer_record_refuse "tmux reported no server pid for pane $pane" \
      overseer-unrecorded "pane=$pane" "step=identity"
  fi
  [[ "$key" =~ ^([0-9]+)[[:blank:]]+(%[0-9]+)$ ]] \
    || overseer_record_refuse "the pane key read back as: $key" \
      overseer-unrecorded "pane=$pane" "step=identity"
  # Taken here, before the next match replaces BASH_REMATCH.
  server="${BASH_REMATCH[1]}"
  if ! window="$(tmux display-message -p -t "$pane" '#{window_id}' 2>&1)"; then
    overseer_record_refuse "$window" overseer-unrecorded "pane=$pane" "step=window"
  fi
  [[ "$window" =~ ^@[0-9]+$ ]] \
    || overseer_record_refuse "" overseer-unrecorded "pane=$pane" "step=window"
  overseer_launch_args
  if ! line="$("$SUCCEED" --print-launch-line "${OVERSEER_LAUNCH_ARGS[@]}" 2>&1)"; then
    overseer_record_refuse "$line" overseer-line-missing "pane=$pane" "path=$SUCCEED"
  fi
  [[ -n "$line" ]] \
    || overseer_record_refuse "" overseer-line-missing "pane=$pane" "path=$SUCCEED"
  # The four fields this watch observes replace the prior's; the launcher's
  # own, runtime, generation and account, stay only where the prior names
  # THIS pane on THIS server: another pane's record is another session's.
  detail="$("$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} \
    update oversee --arg server "$server" --arg pane "$pane" --arg window "$window" --arg line "$line" '
      .overseer = ((.overseer // {})
        | if (.server // "") == $server and (.pane // "") == $pane then . else {} end)
        + {server: $server, pane: $pane, window: $window, launch_line: $line}' 2>&1)" \
    || overseer_record_refuse "$detail" overseer-unrecorded "pane=$pane" "step=write"
}

