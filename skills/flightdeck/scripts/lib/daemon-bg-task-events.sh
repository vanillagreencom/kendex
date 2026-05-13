#!/usr/bin/env bash
# vstack#15: emit canonical pi-bg-task-exit wake events.
#
# Extracted from flightdeck-daemon.bash + subscribers.bash so the new
# pi-background-tasks event handling does not balloon either file. Both
# the bash daemon's inline pi_subscriber_loop and the shared
# subscribers.bash pi_subscriber_loop source this file and call
# emit_pi_bg_task_exit_event when they see a vstack-background-tasks:event
# message_end with details.eventType="exit".
#
# Required env (already set by both callers):
#   SESSION_LOCK     — flock target for the wake-events log
#   WAKE_EVENTS_LOG  — append target for canonical wake rows
#
# Reviewer-structure (vstack#15 round 3, BLOCKER #1) target: keep
# flightdeck-daemon.bash growth to zero on new event classes.

# Canonical contract constants. Kept in sync with the TS port via
# lib/flightdeck-core/src/events/bg-task-exit.ts; the parity test in
# tests/unit/bg-task-exit-contract.test.ts asserts both match.
export BG_TASK_EVENT_CUSTOM_TYPE="vstack-background-tasks:event"
export BG_TASK_EXIT_EVENT_TYPE="exit"
export BG_TASK_EXIT_CLASSIFIER_TAG="pi-bg-task-exit"

# jq select expression matching a `pi-bridge stream` event line for a
# vstack-background-tasks exit message. Echoed so callers can splice it
# into their broader filter.
bg_task_exit_jq_select() {
  cat <<'JQ'
(.type == "event" and .event == "message_end" and ((.data.message.customType // "") == "vstack-background-tasks:event") and ((.data.message.details.eventType // "") == "exit"))
JQ
}

# Emit a pi-bg-task-exit wake event for a JSONL line that already passed
# the message_end + customType + eventType=exit jq filter. Dedupes
# against a caller-supplied last_hash variable name (bash nameref) so
# repeated reads of the same JSONL row do not fire twice.
#
# Args:
#   $1: pane_id (e.g. "%18")
#   $2: jsonl line
#   $3: name of last_hash variable in caller's scope (passed by name)
#   $4: optional sub_log path for human-readable trace lines
#
# Returns:
#   0 — wake row appended
#   1 — duplicate (hash matches last_hash); caller should `continue`
#   2 — malformed input (bg_details missing/null)
emit_pi_bg_task_exit_event() {
  local pane_id="$1" line="$2" last_hash_var="$3" sub_log="${4:-/dev/null}"
  local bg_details bg_task_id bg_status bg_exit_code bg_hash
  bg_details=$(jq -c '.data.message.details // {}' <<< "$line" 2>/dev/null)
  if [[ -z "$bg_details" || "$bg_details" == "null" ]]; then
    bg_details="{}"
  fi
  bg_task_id=$(jq -r '.task.id // ""' <<< "$bg_details" 2>/dev/null)
  bg_status=$(jq -r '.task.status // ""' <<< "$bg_details" 2>/dev/null)
  bg_exit_code=$(jq -r '.task.exitCode // "null"' <<< "$bg_details" 2>/dev/null)
  bg_hash=$(printf '%s|%s|%s' "$bg_task_id" "$bg_status" "$bg_exit_code" | sha256sum | awk '{print substr($1,1,12)}')

  if [[ -n "$last_hash_var" ]]; then
    # bash 4.3+ nameref; flightdeck-daemon already requires bash 4.x
    # everywhere it runs.
    local -n _bg_last_hash_ref="$last_hash_var"
    if [[ "$bg_hash" == "$_bg_last_hash_ref" ]]; then
      return 1
    fi
  fi

  printf '%s [pi-bg-task-exit] pane=%s task=%s status=%s exit=%s\n' \
    "$(date -Iseconds)" "$pane_id" "$bg_task_id" "$bg_status" "$bg_exit_code" \
    >> "$sub_log" 2>/dev/null || true
  ( exec 218>"$SESSION_LOCK"
    flock 218
    jq -nc --arg ts "$(date -Iseconds)" \
           --arg pid "$pane_id" \
           --arg harness "pi" \
           --arg tag "$BG_TASK_EXIT_CLASSIFIER_TAG" \
           --arg h "$bg_hash" \
           --argjson details "$bg_details" \
           '{ts:$ts, pane_id:$pid, harness:$harness, event_type:"bg-task-exit", task:(($details).task // {}), classifier_tag:$tag, hash:$h}' \
           >> "$WAKE_EVENTS_LOG"
  )

  if [[ -n "$last_hash_var" ]]; then
    local -n _bg_last_hash_ref2="$last_hash_var"
    _bg_last_hash_ref2="$bg_hash"
  fi
  return 0
}
