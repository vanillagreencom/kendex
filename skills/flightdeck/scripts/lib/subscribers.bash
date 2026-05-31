#!/usr/bin/env bash
# Subscriber loop bodies. The flightdeck daemon spawns one of these
# per tracked pane to follow the harness adapter's long-running
# cooperative async stream and translate it into wake-events the
# daemon can act on.
#
# Usage:
#   bash subscribers.bash oc <pane_id> <oc_url> <session_id> <parent_pid>
#   bash subscribers.bash cc <pane_id> <transcript> <parent_pid>
#   bash subscribers.bash pi <pane_id> <pi_pid> <pi_socket> <parent_pid> [expected_pi_session_id]
#   bash subscribers.bash cx <pane_id> <cx_url> <thread_id> <parent_pid>
#
# Required env (the TS daemon exports these before spawning):
#   FD_STATE_DIR, SESSION_LOCK, WAKE_EVENTS_LOG, LOG
#   OC_POLL_SEC, OC_BACKOFF_MAX_SEC (oc only)
#   CLASSIFIER                  (path to prompt-classify binary; may be empty)
#   FD_ENTRY_KIND, FD_ENTRY_HARNESS (optional tracked-entry context for classifier domain guards)
#   OC_LAST_ASSISTANT_JQ        (jq filter for oc adapter text extract)
#   CC_LAST_ASSISTANT_JQ        (jq filter for cc adapter text extract)
#   PI_LAST_ASSISTANT_JQ        (jq filter for pi adapter text extract)
#   CX_LAST_ASSISTANT_JQ        (jq filter for cx adapter text extract)
#
# Body sources its helpers (oc_pane_id_safe / cc_pane_id_safe / etc.)
# from the path libs so the bash daemon and this entry point share a
# single helper implementation.

set +e
set +o pipefail

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=oc-paths.sh
source "$_lib_dir/oc-paths.sh"
# shellcheck source=cc-channel-paths.sh
source "$_lib_dir/cc-channel-paths.sh"
# shellcheck source=pi-bridge-paths.sh
source "$_lib_dir/pi-bridge-paths.sh"
# shellcheck source=codex-paths.sh
source "$_lib_dir/codex-paths.sh"
# shellcheck source=daemon-bg-task-events.sh
source "$_lib_dir/daemon-bg-task-events.sh"

OC_POLL_SEC="${OC_POLL_SEC:-2}"
OC_BACKOFF_MAX_SEC="${OC_BACKOFF_MAX_SEC:-16}"
CLASSIFIER="${CLASSIFIER:-}"

classify_adapter_text() {
  local text="$1" pane_id="${2:-}" sub_log="${3:-/dev/null}" tag
  if [[ -n "${CLASSIFIER:-}" && -x "${CLASSIFIER:-}" ]]; then
    local classifier_args=(--no-footer-gate)
    [[ -n "${FD_ENTRY_KIND:-}" ]] && classifier_args+=(--entry-kind "$FD_ENTRY_KIND")
    [[ -n "${FD_ENTRY_HARNESS:-}" ]] && classifier_args+=(--entry-harness "$FD_ENTRY_HARNESS")
    local classifier_err_file classifier_rc classifier_stderr
    classifier_err_file=$(mktemp -t fd-classifier-err.XXXXXX)
    tag=$(printf '%s' "$text" | "$CLASSIFIER" "${classifier_args[@]}" 2>"$classifier_err_file")
    classifier_rc=$?
    classifier_stderr=$(tr '\n' ' ' < "$classifier_err_file" 2>/dev/null | tail -c 400)
    rm -f "$classifier_err_file" 2>/dev/null || true
    if (( classifier_rc != 0 )); then
      printf '%s [classifier-error] pane=%s rc=%s tag=%s entry_kind=%s entry_harness=%s stderr=%s\n' \
        "$(date -Iseconds)" "${pane_id:-unknown}" "$classifier_rc" "${tag:-}" "${FD_ENTRY_KIND:-}" "${FD_ENTRY_HARNESS:-}" "${classifier_stderr:-<empty>}" \
        >> "$sub_log" 2>/dev/null || true
      tag="rendering"
    elif [[ -n "$classifier_stderr" ]]; then
      printf '%s [classifier-warn] pane=%s tag=%s entry_kind=%s entry_harness=%s stderr=%s\n' \
        "$(date -Iseconds)" "${pane_id:-unknown}" "${tag:-}" "${FD_ENTRY_KIND:-}" "${FD_ENTRY_HARNESS:-}" "$classifier_stderr" \
        >> "$sub_log" 2>/dev/null || true
    fi
    if [[ -z "$tag" ]]; then
      printf '%s [classifier-empty] pane=%s entry_kind=%s entry_harness=%s\n' \
        "$(date -Iseconds)" "${pane_id:-unknown}" "${FD_ENTRY_KIND:-}" "${FD_ENTRY_HARNESS:-}" \
        >> "$sub_log" 2>/dev/null || true
      tag="rendering"
    fi
  else
    tag="rendering"
  fi
  printf '%s\n' "$tag"
}

# Bell-marker helpers (used by oc subscriber to interrupt backoff when
# the daemon sees a tmux bell on the pane).
oc_bell_marker_file() {
  local pane_id="$1"
  printf '%s/oc-bell-%s' "$FD_STATE_DIR" "$(oc_pane_id_safe "$pane_id")"
}

bell_marker_mtime() {
  local marker="$1" token
  [[ -f "$marker" ]] || { echo 0; return; }
  token=$(head -n1 "$marker" 2>/dev/null || echo "")
  if [[ "$token" =~ ^[0-9]+$ ]]; then
    echo "$token"
    return
  fi
  stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null || echo 0
}

oc_subscriber_loop() {
  exec 200<&- 2>/dev/null || true
  local pane_id="$1" oc_url="$2" session_id="$3" parent_pid="$4"
  local last_hash=""
  local base_sleep="$OC_POLL_SEC" max_sleep="$OC_BACKOFF_MAX_SEC" next_sleep="$OC_POLL_SEC"
  [[ "$base_sleep" =~ ^[1-9][0-9]*$ ]] || base_sleep=2
  [[ "$max_sleep" =~ ^[1-9][0-9]*$ ]] || max_sleep=16
  (( max_sleep < base_sleep )) && max_sleep="$base_sleep"
  next_sleep="$base_sleep"
  local bell_marker last_bell_mtime
  bell_marker=$(oc_bell_marker_file "$pane_id")
  last_bell_mtime=$(bell_marker_mtime "$bell_marker")
  local seen_qids=","
  local sub_log; sub_log="${LOG}.oc-sub-$(oc_pane_id_safe "$pane_id")"
  printf '%s [oc-sub-start] pane=%s url=%s session=%s parent=%s\n' \
    "$(date -Iseconds)" "$pane_id" "$oc_url" "$session_id" "$parent_pid" \
    >> "$sub_log" 2>/dev/null || true
  while true; do
    if ! kill -0 "$parent_pid" 2>/dev/null; then
      printf '%s [oc-sub-exit] parent gone\n' "$(date -Iseconds)" >> "$sub_log" 2>/dev/null || true
      exit 0
    fi

    local qresp question_changed=0
    qresp=$(curl -s --max-time 5 "$oc_url/question" 2>/dev/null)
    if [[ -n "$qresp" && "$qresp" != "[]" ]]; then
      while IFS= read -r qid; do
        [[ -z "$qid" || "$qid" == "null" ]] && continue
        if [[ "$seen_qids" != *",$qid,"* ]]; then
          seen_qids="${seen_qids}${qid},"
          local qpayload qhash
          qpayload=$(jq -c --arg q "$qid" '.[] | select(.id == $q)' <<< "$qresp" 2>/dev/null)
          [[ -z "$qpayload" ]] && continue
          qhash=$(printf '%s' "$qid" | sha256sum | awk '{print substr($1,1,12)}')
          question_changed=1
          printf '%s [oc-question-emit] pane=%s request_id=%s\n' \
            "$(date -Iseconds)" "$pane_id" "$qid" \
            >> "$sub_log" 2>/dev/null || true
          ( exec 211>"$SESSION_LOCK"
            flock 211
            jq -nc --arg ts "$(date -Iseconds)" \
                   --arg pid "$pane_id" \
                   --arg harness "opencode" \
                   --arg req "$qid" \
                   --arg tag "oc-question" \
                   --arg h "$qhash" \
                   --argjson q "$qpayload" \
                   '{ts:$ts, pane_id:$pid, harness:$harness, event_type:"question", request_id:$req, question:$q, classifier_tag:$tag, hash:$h}' \
                   >> "$WAKE_EVENTS_LOG"
          )
        fi
      done < <(jq -r '.[].id // empty' <<< "$qresp" 2>/dev/null)
    fi

    local resp last_text hash tag text_excerpt response_changed=0
    resp=$(curl -s --max-time 5 "$oc_url/session/$session_id/message" 2>/dev/null)
    if [[ -n "$resp" ]]; then
      last_text=$(jq -r "$OC_LAST_ASSISTANT_JQ" <<< "$resp" 2>/dev/null)
      if [[ -n "$last_text" ]]; then
        hash=$(printf '%s' "$last_text" | sha256sum | awk '{print substr($1,1,12)}')
        if [[ "$hash" != "$last_hash" ]]; then
          response_changed=1
          tag=$(classify_adapter_text "$last_text" "$pane_id" "$sub_log")
          text_excerpt=$(printf '%s' "$last_text" | awk 'BEGIN{RS=""} {print substr($0,1,1024); exit}')
          printf '%s [oc-sub-emit] pane=%s hash=%s tag=%s text_len=%s\n' \
            "$(date -Iseconds)" "$pane_id" "$hash" "$tag" "${#last_text}" \
            >> "$sub_log" 2>/dev/null || true
          ( exec 211>"$SESSION_LOCK"
            flock 211
            jq -nc --arg ts "$(date -Iseconds)" \
                   --arg pid "$pane_id" \
                   --arg harness "opencode" \
                   --arg text "$text_excerpt" \
                   --arg tag "$tag" \
                   --arg h "$hash" \
                   '{ts:$ts, pane_id:$pid, harness:$harness, last_assistant_text:$text, classifier_tag:$tag, hash:$h}' \
                   >> "$WAKE_EVENTS_LOG"
          )
          last_hash="$hash"
        fi
      fi
    else
      printf '%s [oc-sub-tick] pane=%s curl_empty\n' "$(date -Iseconds)" "$pane_id" \
        >> "$sub_log" 2>/dev/null || true
    fi

    local current_bell_mtime bell_seen=0 prev_sleep="$next_sleep"
    current_bell_mtime=$(bell_marker_mtime "$bell_marker")
    if [[ "$current_bell_mtime" =~ ^[0-9]+$ && "$last_bell_mtime" =~ ^[0-9]+$ && "$current_bell_mtime" -gt "$last_bell_mtime" ]]; then
      bell_seen=1
      last_bell_mtime="$current_bell_mtime"
    fi
    if (( response_changed == 1 || question_changed == 1 || bell_seen == 1 )); then
      next_sleep="$base_sleep"
    else
      if (( next_sleep < max_sleep )); then
        next_sleep=$(( next_sleep * 2 ))
        (( next_sleep > max_sleep )) && next_sleep="$max_sleep"
      fi
    fi
    if [[ "$next_sleep" != "$prev_sleep" ]]; then
      printf '%s [oc-sub-backoff] pane=%s sleep=%ss response_changed=%s question_changed=%s bell_seen=%s max=%ss\n' \
        "$(date -Iseconds)" "$pane_id" "$next_sleep" "$response_changed" "$question_changed" "$bell_seen" "$max_sleep" \
        >> "$sub_log" 2>/dev/null || true
    fi
    local slept=0 sleep_chunk sleep_bell_mtime
    while (( slept < next_sleep )); do
      sleep_chunk=$(( next_sleep - slept ))
      (( sleep_chunk > 1 )) && sleep_chunk=1
      sleep "$sleep_chunk"
      slept=$(( slept + sleep_chunk ))
      sleep_bell_mtime=$(bell_marker_mtime "$bell_marker")
      if [[ "$sleep_bell_mtime" =~ ^[0-9]+$ && "$last_bell_mtime" =~ ^[0-9]+$ && "$sleep_bell_mtime" -gt "$last_bell_mtime" ]]; then
        last_bell_mtime="$sleep_bell_mtime"
        next_sleep="$base_sleep"
        printf '%s [oc-sub-backoff] pane=%s sleep=%ss response_changed=0 question_changed=0 bell_seen=1 interrupted=1 max=%ss\n' \
          "$(date -Iseconds)" "$pane_id" "$next_sleep" "$max_sleep" \
          >> "$sub_log" 2>/dev/null || true
        break
      fi
    done
  done
}

cc_subscriber_loop() {
  exec 200<&- 2>/dev/null || true
  local pane_id="$1" transcript="$2" parent_pid="$3"
  local last_hash=""
  local sub_log; sub_log="${LOG}.cc-sub-$(cc_pane_id_safe "$pane_id")"
  printf '%s [cc-sub-start] pane=%s transcript=%s parent=%s\n' \
    "$(date -Iseconds)" "$pane_id" "$transcript" "$parent_pid" \
    >> "$sub_log" 2>/dev/null || true

  while [[ ! -f "$transcript" ]]; do
    if ! kill -0 "$parent_pid" 2>/dev/null; then exit 0; fi
    sleep 1
  done

  tail -n 0 -F "$transcript" 2>/dev/null \
    | jq --unbuffered -c 'select((.message.role // .role // "") == "assistant" and (.message.stop_reason // .stop_reason // "") != "")' \
    | while IFS= read -r line; do
      if ! kill -0 "$parent_pid" 2>/dev/null; then exit 0; fi
      [[ -z "$line" ]] && continue
      local last_text
      last_text=$(jq -r '
        ( .message.content // .content // [] )
        | (if type == "array" then map(select(.type == "text") | .text // "") | join("") else . end)
      ' <<< "$line" 2>/dev/null)
      [[ -z "$last_text" ]] && continue
      local hash
      hash=$(printf '%s' "$last_text" | sha256sum | awk '{print substr($1,1,12)}')
      [[ "$hash" == "$last_hash" ]] && continue
      local tag
      tag=$(classify_adapter_text "$last_text" "$pane_id" "$sub_log")
      local text_excerpt
      text_excerpt=$(printf '%s' "$last_text" | head -c 1024 || true)
      printf '%s [cc-sub-emit] pane=%s hash=%s tag=%s text_len=%s\n' \
        "$(date -Iseconds)" "$pane_id" "$hash" "$tag" "${#last_text}" \
        >> "$sub_log" 2>/dev/null || true
      ( exec 217>"$SESSION_LOCK"
        flock 217
        jq -nc --arg ts "$(date -Iseconds)" \
               --arg pid "$pane_id" \
               --arg harness "claude" \
               --arg text "$text_excerpt" \
               --arg tag "$tag" \
               --arg h "$hash" \
               '{ts:$ts, pane_id:$pid, harness:$harness, last_assistant_text:$text, classifier_tag:$tag, hash:$h}' \
               >> "$WAKE_EVENTS_LOG"
      )
      last_hash="$hash"
    done
}

pi_subscriber_emit_session_connected() {
  local pane_id="$1" connected_session_id="$2" expected_session_id="$3" pi_pid="$4" pi_socket="$5"
  [[ -n "$expected_session_id" ]] || return 0
  local connected_hash
  connected_hash=$(printf '%s|pi-session-connected|%s|%s|%s|%s' "$pane_id" "$connected_session_id" "$expected_session_id" "$pi_pid" "$pi_socket" | sha256sum | awk '{print substr($1,1,12)}')
  ( exec 211>"$SESSION_LOCK"
    flock 211
    jq -nc --arg ts "$(date -Iseconds)" \
           --arg pid "$pane_id" \
           --arg harness "pi" \
           --arg event "pi_session_connected" \
           --arg tag "pi-session-connected" \
           --arg h "$connected_hash" \
           --arg session "$connected_session_id" \
           --arg expected "$expected_session_id" \
           --arg pi_pid "$pi_pid" \
           --arg socket "$pi_socket" \
           '{ts:$ts, pane_id:$pid, harness:$harness, event_type:$event, classifier_tag:$tag, hash:$h, pi_session_id:$session, expected_pi_session_id:$expected, pi_pid:$pi_pid, pi_socket:$socket}' \
           >> "$WAKE_EVENTS_LOG"
  )
}

pi_subscriber_extract_session_id() {
  jq -r '.state.sessionId // .state.session_id // .data.sessionId // .data.session_id // .sessionId // .session_id // ""' 2>/dev/null
}

pi_subscriber_loop() {
  exec 200<&- 2>/dev/null || true
  local pane_id="$1" pi_pid="$2" pi_socket="${3:-}" parent_pid="${4:-}" expected_pi_session_id="${5:-}"
  local last_hash=""
  local last_activity_hash=""
  local seen_qids=","
  local sub_log; sub_log="${LOG}.pi-sub-$(pi_pane_id_safe "$pane_id")"
  printf '%s [pi-sub-start] pane=%s pi_pid=%s socket=%s parent=%s expected_session=%s\n' \
    "$(date -Iseconds)" "$pane_id" "$pi_pid" "$pi_socket" "$parent_pid" "$expected_pi_session_id" \
    >> "$sub_log" 2>/dev/null || true

  local pi_bin; pi_bin=$(pi_resolve_bridge_bin) || {
    printf '%s [pi-sub-error] pi-bridge bin not found\n' "$(date -Iseconds)" \
      >> "$sub_log" 2>/dev/null || true
    return 1
  }
  local pi_target_args=()
  if [[ -n "$pi_socket" ]]; then
    pi_target_args=(--socket "$pi_socket")
  else
    pi_target_args=(--pid "$pi_pid")
  fi

  local pi_session_verified=0
  if [[ -z "$expected_pi_session_id" ]]; then
    pi_session_verified=1
  else
    local preflight_state_rc preflight_state preflight_session_id preflight_timeout preflight_err_file preflight_stderr_tail
    preflight_timeout="${FD_ADAPTER_READ_TIMEOUT_SEC:-2}"
    preflight_err_file=$(mktemp -t fd-pi-state-err.XXXXXX)
    preflight_state=$(timeout "${preflight_timeout}s" "$pi_bin" state "${pi_target_args[@]}" 2>"$preflight_err_file")
    preflight_state_rc=$?
    if (( preflight_state_rc != 0 )); then
      preflight_stderr_tail=$(tail -c 200 "$preflight_err_file" 2>/dev/null | tr '\n' ' ' || true)
      rm -f "$preflight_err_file"
      printf '%s [pi-sub-session-preflight-error] pane=%s rc=%s stderr=%s expected_session=%s; skip initial drain until bridge_hello\n' \
        "$(date -Iseconds)" "$pane_id" "$preflight_state_rc" "${preflight_stderr_tail:-<empty>}" "$expected_pi_session_id" \
        >> "$sub_log" 2>/dev/null || true
    elif [[ -n "${preflight_state//[[:space:]]/}" ]]; then
      rm -f "$preflight_err_file"
      if ! jq -e 'type == "object"' <<< "$preflight_state" >/dev/null 2>&1; then
        local preflight_excerpt
        preflight_excerpt=$(printf '%s' "$preflight_state" | head -c 200 | tr '\n' ' ')
        printf '%s [pi-sub-session-preflight-malformed] pane=%s expected_session=%s excerpt=%s; skip initial drain until bridge_hello\n' \
          "$(date -Iseconds)" "$pane_id" "$expected_pi_session_id" "${preflight_excerpt:-<empty>}" \
          >> "$sub_log" 2>/dev/null || true
      else
        preflight_session_id=$(pi_subscriber_extract_session_id <<< "$preflight_state")
        if [[ -z "$preflight_session_id" || "$preflight_session_id" == "null" ]]; then
          local preflight_excerpt
          preflight_excerpt=$(printf '%s' "$preflight_state" | head -c 200 | tr '\n' ' ')
          printf '%s [pi-sub-session-preflight-malformed] pane=%s expected_session=%s reason=missing-session excerpt=%s; skip initial drain until bridge_hello\n' \
            "$(date -Iseconds)" "$pane_id" "$expected_pi_session_id" "${preflight_excerpt:-<empty>}" \
            >> "$sub_log" 2>/dev/null || true
        else
          printf '%s [pi-sub-session-preflight] pane=%s pi_session_id=%s expected_session=%s\n' \
            "$(date -Iseconds)" "$pane_id" "$preflight_session_id" "$expected_pi_session_id" \
            >> "$sub_log" 2>/dev/null || true
          pi_subscriber_emit_session_connected "$pane_id" "$preflight_session_id" "$expected_pi_session_id" "$pi_pid" "$pi_socket"
          if [[ "$preflight_session_id" == "$expected_pi_session_id" ]]; then
            pi_session_verified=1
          else
            printf '%s [pi-sub-session-mismatch] pane=%s pi_session_id=%s expected_session=%s phase=preflight; exiting before drain\n' \
              "$(date -Iseconds)" "$pane_id" "$preflight_session_id" "$expected_pi_session_id" \
              >> "$sub_log" 2>/dev/null || true
            return 1
          fi
        fi
      fi
    else
      rm -f "$preflight_err_file"
      printf '%s [pi-sub-session-preflight-empty] pane=%s expected_session=%s; skip initial drain until bridge_hello\n' \
        "$(date -Iseconds)" "$pane_id" "$expected_pi_session_id" \
        >> "$sub_log" 2>/dev/null || true
    fi
  fi

  # Issue #37(D): drain pi-questions that were opened before the
  # subscriber attached. `pi-bridge stream` only delivers future
  # events, so a question opened before daemon startup is invisible
  # to master and pane-poll can't see it either (questions live in
  # the bridge state, not the tmux buffer). Synthesize the same
  # pi-question-emit log + WAKE_EVENTS_LOG append the live-stream
  # path emits, then seed seen_qids so the future stream event
  # dedupes. When the daemon supplies an expected Pi session id, this
  # drain is gated on a matching `pi-bridge state` preflight so a
  # wrongly-bound subscriber cannot forward stale questions.
  if [[ "$pi_session_verified" == "1" ]]; then
    pi_subscriber_drain_questions "$pane_id" "$pi_bin" "$sub_log" pi_target_args seen_qids
  fi

  # Issue #37 round-1 reviewer-arch major: re-drain after stream
  # connect closes the race where a question opens between the
  # initial drain (above) and the stream subscription registering
  # with the bridge. pi-bridge sends `{type:"bridge_hello",...}`
  # the instant the socket is accepted; passing that line through
  # the jq filter lets the while loop fire one re-drain on the very
  # first emitted message. seen_qids is shared into the pipe
  # subshell, so prior drain ids dedupe automatically.
  # vstack#67 workaround: edit-loop detector state. Mirrors the canonical
  # decision in src/daemon/edit-loop-detector.ts evaluateEditLoop(); the TS
  # function is the source of truth and tests (edit-loop-detector.test.ts +
  # edit-loop-wiring.test.ts) assert this bash stays in lock step.
  local edit_loop_enabled="${VSTACK_EDIT_LOOP_DETECTOR:-1}"
  case "$edit_loop_enabled" in 0|false|FALSE|off|OFF) edit_loop_enabled=0 ;; *) edit_loop_enabled=1 ;; esac
  local edit_loop_threshold="${VSTACK_EDIT_LOOP_THRESHOLD_N:-5}"
  local edit_loop_window="${VSTACK_EDIT_LOOP_WINDOW_SEC:-120}"
  [[ "$edit_loop_threshold" =~ ^[1-9][0-9]*$ ]] || edit_loop_threshold=5
  [[ "$edit_loop_window" =~ ^[1-9][0-9]*$ ]] || edit_loop_window=120
  local edit_loop_fired=0
  local -a edit_loop_ts=()

  # vstack#108: rate-limit watchdog state. Mirrors the canonical decision
  # in src/daemon/rate-limit-watchdog.ts decideRateLimitRetry(); the TS
  # function is the source of truth and parity tests assert this bash
  # stays in lock step. Per-pane attempt counter is tracked in this
  # process; daemon restart resets the budget (acceptable per the brief).
  local rate_limit_enabled="${VSTACK_RATE_LIMIT_WATCHDOG:-1}"
  case "$rate_limit_enabled" in 0|false|FALSE|off|OFF) rate_limit_enabled=0 ;; *) rate_limit_enabled=1 ;; esac
  local rate_limit_attempt=0
  local rate_limit_skip_seq=0
  local rate_limit_max="${VSTACK_RATE_LIMIT_MAX_ATTEMPTS:-5}"
  [[ "$rate_limit_max" =~ ^[1-9][0-9]*$ ]] || rate_limit_max=5
  local rate_limit_decider="${VSTACK_RATE_LIMIT_DECIDER_BIN:-}"
  if [[ -z "$rate_limit_decider" ]]; then
    rate_limit_decider="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib/flightdeck-core/src/daemon" 2>/dev/null && pwd)/rate-limit-watchdog.ts"
  fi

  pi_rate_limit_emit_event() {
    local tag="$1" event_type="$2" hash="$3" reason="${4:-}" attempt="${5:-}" next_retry_at="${6:-}" error="${7:-}" rc="${8:-}"
    local attempt_json="null" next_retry_at_json="null" rc_json="null"
    [[ "$attempt" =~ ^[0-9]+$ ]] && attempt_json="$attempt"
    [[ "$next_retry_at" =~ ^[0-9]+$ ]] && next_retry_at_json="$next_retry_at"
    [[ "$rc" =~ ^[0-9]+$ ]] && rc_json="$rc"
    ( exec 219>"$SESSION_LOCK"
      flock 219
      jq -nc --arg ts "$(date -Iseconds)" \
             --arg pid "$pane_id" \
             --arg harness "pi" \
             --arg tag "$tag" \
             --arg h "$hash" \
             --arg event_type "$event_type" \
             --arg reason "$reason" \
             --arg error "$error" \
             --argjson attempt "$attempt_json" \
             --argjson next_retry_at "$next_retry_at_json" \
             --argjson rc "$rc_json" \
             '{ts:$ts, pane_id:$pid, harness:$harness, event_type:$event_type, classifier_tag:$tag, hash:$h}
              + (if $reason == "" then {} else {reason:$reason} end)
              + (if $error == "" then {} else {error:$error} end)
              + (if $attempt == null then {} else {attempt:$attempt} end)
              + (if $next_retry_at == null then {} else {next_retry_at:$next_retry_at} end)
              + (if $rc == null then {} else {exit_code:$rc} end)' \
             >> "$WAKE_EVENTS_LOG"
    )
  }

  "$pi_bin" stream "${pi_target_args[@]}" 2>/dev/null \
    | jq --unbuffered -c 'select(
        (.type == "bridge_hello")
        or
        (.type == "event" and .event == "vstack_activity")
        or
        (.type == "event" and .event == "question" and (.data.action // "") == "opened")
        or
        (.type == "event" and .event == "message_end" and ((.data.message.customType // "") == "subagent-completion"))
        or
        (.type == "event" and .event == "message_end" and ((.data.message.customType // "") == "vstack-background-tasks:event"))
        or
        (.type == "event" and .event == "tool_execution_end" and ((.data.toolName // "") == "edit") and (.data.isError == true))
        or
        (.type == "event" and .event == "message_end" and ((.data.message.customType // "") == ""))
        or
        (.type == "event" and .data.message.role == "assistant" and (.data.message.stopReason // "") != "")
        or
        (.type == "event" and .event == "message_end" and (.data.message.role // "") == "assistant" and (.data.message.stopReason // "") == "error" and ((.data.message.errorMessage // "") | test("temporarily limiting requests|[Rr]ate.{0,5}[Ll]imit|429|too many requests")))
      )' \
    | while IFS= read -r line; do
      if ! kill -0 "$parent_pid" 2>/dev/null; then exit 0; fi
      [[ -z "$line" ]] && continue

      local msg_type
      msg_type=$(jq -r '.type // ""' <<< "$line" 2>/dev/null)
      if [[ "$msg_type" == "bridge_hello" ]]; then
        local connected_pi_session_id
        connected_pi_session_id=$(pi_subscriber_extract_session_id <<< "$line")
        printf '%s [pi-sub-stream-connected] pane=%s pi_session_id=%s expected_session=%s\n' \
          "$(date -Iseconds)" "$pane_id" "$connected_pi_session_id" "$expected_pi_session_id" \
          >> "$sub_log" 2>/dev/null || true
        if [[ -n "$expected_pi_session_id" ]]; then
          pi_subscriber_emit_session_connected "$pane_id" "$connected_pi_session_id" "$expected_pi_session_id" "$pi_pid" "$pi_socket"
          if [[ "$connected_pi_session_id" != "$expected_pi_session_id" ]]; then
            printf '%s [pi-sub-session-mismatch] pane=%s pi_session_id=%s expected_session=%s phase=stream; exiting before drain/events\n' \
              "$(date -Iseconds)" "$pane_id" "$connected_pi_session_id" "$expected_pi_session_id" \
              >> "$sub_log" 2>/dev/null || true
            exit 1
          fi
        fi
        pi_session_verified=1
        pi_subscriber_drain_questions "$pane_id" "$pi_bin" "$sub_log" pi_target_args seen_qids
        continue
      fi

      if [[ -n "$expected_pi_session_id" && "$pi_session_verified" != "1" ]]; then
        printf '%s [pi-sub-session-unverified-drop] pane=%s expected_session=%s\n' \
          "$(date -Iseconds)" "$pane_id" "$expected_pi_session_id" \
          >> "$sub_log" 2>/dev/null || true
        continue
      fi

      local event_name
      event_name=$(jq -r '.event // ""' <<< "$line" 2>/dev/null)

      # vstack#67 workaround: tool_execution_end with toolName=edit + error.
      # Inline threshold-window check mirrors evaluateEditLoop() in
      # src/daemon/edit-loop-detector.ts. On fire, emits a wake-event row
      # with classifier_tag=pi-edit-tool-loop so the daemon wakes master.
      if [[ "$event_name" == "tool_execution_end" && "$edit_loop_enabled" == "1" && "$edit_loop_fired" == "0" ]]; then
        # vstack#67 wiring fix: upstream ToolExecutionEndEvent exposes
        # error state via .data.isError (boolean) and tool name via
        # .data.toolName. Earlier filters guessed at .data.error /
        # .data.success / .data.result.error which never match the real
        # event shape (pi-coding-agent dist/core/extensions/types.d.ts).
        local tool_name tool_error
        tool_name=$(jq -r '.data.toolName // ""' <<< "$line" 2>/dev/null)
        tool_error=$(jq -r '.data.isError == true' <<< "$line" 2>/dev/null)
        if [[ "$tool_name" == "edit" && "$tool_error" == "true" ]]; then
          local edit_now edit_cutoff edit_count edit_fire edit_oldest
          edit_now=$(date +%s)
          edit_cutoff=$((edit_now - edit_loop_window))
          local -a edit_pruned=()
          for ts in "${edit_loop_ts[@]}"; do
            (( ts >= edit_cutoff )) && edit_pruned+=("$ts")
          done
          edit_pruned+=("$edit_now")
          # Trim to most recent threshold entries so memory stays bounded.
          while (( ${#edit_pruned[@]} > edit_loop_threshold )); do
            edit_pruned=("${edit_pruned[@]:1}")
          done
          edit_loop_ts=("${edit_pruned[@]}")
          edit_count=${#edit_loop_ts[@]}
          edit_oldest=${edit_loop_ts[0]:-$edit_now}
          edit_fire=0
          if (( edit_count >= edit_loop_threshold && edit_oldest >= edit_cutoff )); then edit_fire=1; fi
          printf '%s [pi-edit-loop-tick] pane=%s count=%s threshold=%s window=%s fire=%s\n' \
            "$(date -Iseconds)" "$pane_id" "$edit_count" "$edit_loop_threshold" "$edit_loop_window" "$edit_fire" \
            >> "$sub_log" 2>/dev/null || true
          if [[ "$edit_fire" == "1" ]]; then
            edit_loop_fired=1
            local edit_hash
            edit_hash=$(printf '%s|edit-loop|%s' "$pane_id" "$edit_now" | sha256sum | awk '{print substr($1,1,12)}')
            ( exec 218>"$SESSION_LOCK"
              flock 218
              jq -nc --arg ts "$(date -Iseconds)" \
                     --arg pid "$pane_id" \
                     --arg harness "pi" \
                     --arg tag "pi-edit-tool-loop" \
                     --arg h "$edit_hash" \
                     --argjson failures "$edit_count" \
                     --argjson window "$edit_loop_window" \
                     '{ts:$ts, pane_id:$pid, harness:$harness, event_type:"tool_execution_error", tool_name:"edit", consecutive_failures:$failures, window_sec:$window, classifier_tag:$tag, hash:$h}' \
                     >> "$WAKE_EVENTS_LOG"
            )
          fi
        fi
        continue
      fi

      # vstack#108/#126: rate-limit watchdog. The jq filter above keeps
      # message_end events (excluding extension custom messages) so the
      # canonical TS decider can classify both positive detections and
      # skipped decisions. Per-pane attempt counter advances through the
      # env-driven backoff ladder; on retry-at we both write an activity
      # row and fork a detached background sleeper that delivers
      # `pi-bridge send --steer` once the API window has plausibly reset.
      # On exhausted we emit a distinct activity tag before normal
      # completion/blocking handling resumes.
      if [[ "$event_name" == "message_end" && "$rate_limit_enabled" == "1" ]]; then
        local rl_custom_type
        rl_custom_type=$(jq -r '.data.message.customType // ""' <<< "$line" 2>/dev/null)
        if [[ -z "$rl_custom_type" ]]; then
          local rl_event_json rl_decision="" rl_kind rl_at rl_attempt_next rl_skip_reason rl_role
          rl_role=$(jq -r '.data.message.role // ""' <<< "$line" 2>/dev/null)
          rl_event_json=$(jq -c '.data // {}' <<< "$line" 2>/dev/null)
          local rl_unavailable=""
          if [[ -z "$rl_event_json" || "$rl_event_json" == "null" ]]; then
            rl_unavailable="event-json-empty"
          elif ! command -v bun >/dev/null 2>&1; then
            rl_unavailable="bun-unavailable"
          elif [[ ! -f "$rate_limit_decider" ]]; then
            rl_unavailable="decider-missing"
          fi
          if [[ -n "$rl_unavailable" ]]; then
            local rl_hash
            rl_hash=$(printf '%s|rate-limit-decider-unavailable|%s|%s' "$pane_id" "$rl_unavailable" "$(date +%s%3N)" | sha256sum | awk '{print substr($1,1,12)}')
            pi_rate_limit_emit_event "pi-rate-limit-decider-error" "rate_limit_decider_unavailable" "$rl_hash" "$rl_unavailable" "" "" ""
            printf '%s [pi-rate-limit-decider-unavailable] pane=%s reason=%s hash=%s\n' \
              "$(date -Iseconds)" "$pane_id" "$rl_unavailable" "$rl_hash" \
              >> "$sub_log" 2>/dev/null || true
            [[ "$rl_role" != "assistant" ]] && continue
          else
            local rl_err_file rl_stderr rl_rc
            rl_err_file="${FD_STATE_DIR}/rate-limit-decider-${BASHPID:-$$}-${rate_limit_skip_seq}.err"
            rl_decision=$(printf '%s' "$rl_event_json" | bun "$rate_limit_decider" decide \
              --pane "$pane_id" \
              --attempt "$rate_limit_attempt" \
              --now "$(date +%s%3N)" 2>"$rl_err_file")
            rl_rc=$?
            rl_stderr=$(tr '\n' ' ' < "$rl_err_file" 2>/dev/null | tail -c 400)
            rm -f "$rl_err_file" 2>/dev/null || true
            if [[ "$rl_rc" -ne 0 ]]; then
              local rl_hash
              rl_hash=$(printf '%s|rate-limit-decider-error|%s|%s' "$pane_id" "$rl_rc" "$(date +%s%3N)" | sha256sum | awk '{print substr($1,1,12)}')
              pi_rate_limit_emit_event "pi-rate-limit-decider-error" "rate_limit_decider_error" "$rl_hash" "decider-exit" "" "" "$rl_stderr" "$rl_rc"
              printf '%s [pi-rate-limit-decider-error] pane=%s rc=%s error=%s hash=%s\n' \
                "$(date -Iseconds)" "$pane_id" "$rl_rc" "$rl_stderr" "$rl_hash" \
                >> "$sub_log" 2>/dev/null || true
              rl_decision=""
              [[ "$rl_role" != "assistant" ]] && continue
            elif ! jq -e 'type == "object" and (.kind | type == "string")' <<< "$rl_decision" >/dev/null 2>&1; then
              local rl_hash rl_stdout_tail
              rl_stdout_tail=$(printf '%s' "$rl_decision" | tr '\n' ' ' | tail -c 400)
              rl_hash=$(printf '%s|rate-limit-decider-invalid-output|%s' "$pane_id" "$(date +%s%3N)" | sha256sum | awk '{print substr($1,1,12)}')
              pi_rate_limit_emit_event "pi-rate-limit-decider-error" "rate_limit_decider_error" "$rl_hash" "invalid-output" "" "" "$rl_stdout_tail"
              printf '%s [pi-rate-limit-decider-error] pane=%s reason=invalid-output output=%s hash=%s\n' \
                "$(date -Iseconds)" "$pane_id" "$rl_stdout_tail" "$rl_hash" \
                >> "$sub_log" 2>/dev/null || true
              rl_decision=""
              [[ "$rl_role" != "assistant" ]] && continue
            fi
          fi
          rl_kind=$(jq -r '.kind // ""' <<< "$rl_decision" 2>/dev/null)
          if [[ "$rl_kind" == "retry-at" ]]; then
            rl_at=$(jq -r '.at // 0' <<< "$rl_decision" 2>/dev/null)
            rl_attempt_next=$(jq -r '.attempt // 0' <<< "$rl_decision" 2>/dev/null)
            rate_limit_attempt="$rl_attempt_next"
            local rl_hash rl_now_ms rl_delay_ms
            rl_now_ms=$(date +%s%3N)
            rl_delay_ms=$(( rl_at - rl_now_ms ))
            (( rl_delay_ms < 0 )) && rl_delay_ms=0
            rl_hash=$(printf '%s|rate-limit|%s|%s' "$pane_id" "$rl_attempt_next" "$rl_at" | sha256sum | awk '{print substr($1,1,12)}')
            pi_rate_limit_emit_event "pi-rate-limit-retry" "rate_limit_retry" "$rl_hash" "" "$rl_attempt_next" "$rl_at"
            # Detached steer dispatcher: sleep then deliver via pi-bridge.
            # nohup + disown so the sleeper survives the loop body.
            local rl_delay_sec=$(( rl_delay_ms / 1000 ))
            (( rl_delay_sec < 1 )) && rl_delay_sec=1
            ( nohup bash -c "sleep $rl_delay_sec; '$pi_bin' send ${pi_target_args[*]} --steer 'API rate limit was detected. Try to continue from where you left off.' >/dev/null 2>&1" >/dev/null 2>&1 & ) >/dev/null 2>&1
            printf '%s [pi-rate-limit-scheduled] pane=%s attempt=%s delay_sec=%s\n' \
              "$(date -Iseconds)" "$pane_id" "$rl_attempt_next" "$rl_delay_sec" \
              >> "$sub_log" 2>/dev/null || true
            continue
          elif [[ "$rl_kind" == "exhausted" ]]; then
            rl_attempt_next=$(jq -r '.attempt // 0' <<< "$rl_decision" 2>/dev/null)
            local rl_hash
            rl_hash=$(printf '%s|rate-limit-exhausted|%s' "$pane_id" "$rl_attempt_next" | sha256sum | awk '{print substr($1,1,12)}')
            pi_rate_limit_emit_event "pi-rate-limit-exhausted" "rate_limit_exhausted" "$rl_hash" "" "$rl_attempt_next"
            printf '%s [pi-rate-limit-exhausted] pane=%s attempt=%s\n' \
              "$(date -Iseconds)" "$pane_id" "$rl_attempt_next" \
              >> "$sub_log" 2>/dev/null || true
            continue
          elif [[ "$rl_kind" == "not-rate-limited" ]]; then
            rl_skip_reason=$(jq -r '.reason // ""' <<< "$rl_decision" 2>/dev/null)
            if [[ -n "$rl_skip_reason" && "$rl_skip_reason" != "null" ]]; then
              rate_limit_skip_seq=$((rate_limit_skip_seq + 1))
              local rl_hash
              rl_hash=$(printf '%s|rate-limit-skipped|%s|%s|%s' "$pane_id" "$rl_skip_reason" "$rate_limit_skip_seq" "$(date +%s%3N)" | sha256sum | awk '{print substr($1,1,12)}')
              pi_rate_limit_emit_event "pi-rate-limit-skipped" "rate_limit_skipped" "$rl_hash" "$rl_skip_reason"
              printf '%s [pi-rate-limit-skipped] pane=%s reason=%s hash=%s\n' \
                "$(date -Iseconds)" "$pane_id" "$rl_skip_reason" "$rl_hash" \
                >> "$sub_log" 2>/dev/null || true
            fi
            if [[ "$rl_role" != "assistant" ]]; then
              continue
            fi
            if [[ "$rate_limit_attempt" =~ ^[1-9][0-9]*$ ]]; then
              local rl_previous_attempt rl_hash
              rl_previous_attempt="$rate_limit_attempt"
              rate_limit_attempt=0
              rl_hash=$(printf '%s|rate-limit-resolved|%s|%s' "$pane_id" "$rl_previous_attempt" "$(date +%s%3N)" | sha256sum | awk '{print substr($1,1,12)}')
              pi_rate_limit_emit_event "pi-rate-limit-resolved" "rate_limit_resolved" "$rl_hash" "" "$rl_previous_attempt"
              printf '%s [pi-rate-limit-resolved] pane=%s attempt=%s hash=%s\n' \
                "$(date -Iseconds)" "$pane_id" "$rl_previous_attempt" "$rl_hash" \
                >> "$sub_log" 2>/dev/null || true
            fi
          fi
        fi
      fi

      if [[ "$event_name" == "vstack_activity" ]]; then
        [[ "${FLIGHTDECK_PI_ACTIVITY_BROKER:-1}" == "0" ]] && continue
        local activity_payload activity_type activity_hash
        activity_payload=$(jq -c '.data // {}' <<< "$line" 2>/dev/null)
        [[ -z "$activity_payload" || "$activity_payload" == "null" ]] && continue
        activity_type=$(jq -r '.type // ""' <<< "$activity_payload" 2>/dev/null)
        [[ -z "$activity_type" || "$activity_type" == "null" ]] && continue
        activity_hash=$(printf '%s' "$activity_payload" | sha256sum | awk '{print substr($1,1,12)}')
        [[ "$activity_hash" == "$last_activity_hash" ]] && continue
        local append_error append_rc error_tail
        append_rc=0
        append_error=$( ( exec 218>"$SESSION_LOCK"
          flock 218
          jq -nc --arg ts "$(date -Iseconds)" \
                 --arg pid "$pane_id" \
                 --arg harness "pi" \
                 --arg tag "pi-activity-broker" \
                 --arg h "$activity_hash" \
                 --argjson activity "$activity_payload" \
                 '{ts:$ts, pane_id:$pid, harness:$harness, event_type:"vstack_activity", activity:$activity, classifier_tag:$tag, hash:$h}' \
                 >> "$WAKE_EVENTS_LOG"
        ) 2>&1 ) || append_rc=$?
        if [[ "$append_rc" -eq 0 ]]; then
          printf '%s [pi-activity-broker-emit-ok] pane=%s type=%s hash=%s rc=0\n' \
            "$(date -Iseconds)" "$pane_id" "$activity_type" "$activity_hash" \
            >> "$sub_log" 2>/dev/null || true
          last_activity_hash="$activity_hash"
        else
          error_tail=$(printf '%s' "$append_error" | tr '\n' ' ' | tail -c 400)
          printf '%s [pi-activity-broker-emit-error] pane=%s type=%s hash=%s rc=%s error=%s\n' \
            "$(date -Iseconds)" "$pane_id" "$activity_type" "$activity_hash" "$append_rc" "$error_tail" \
            >> "$sub_log" 2>/dev/null || true
        fi
        continue
      fi

      if [[ "$event_name" == "question" ]]; then
        local qid
        qid=$(jq -r '.data.requestId // .data.request.id // ""' <<< "$line" 2>/dev/null)
        [[ -z "$qid" || "$qid" == "null" ]] && continue
        if [[ "$seen_qids" != *",$qid,"* ]]; then
          seen_qids+="$qid,"
          local qpayload qhash
          qpayload=$(jq -c '.data.request // .data' <<< "$line" 2>/dev/null)
          [[ -z "$qpayload" || "$qpayload" == "null" ]] && continue
          qhash=$(printf '%s' "$qid" | sha256sum | awk '{print substr($1,1,12)}')
          printf '%s [pi-question-emit] pane=%s request_id=%s\n' \
            "$(date -Iseconds)" "$pane_id" "$qid" \
            >> "$sub_log" 2>/dev/null || true
          ( exec 218>"$SESSION_LOCK"
            flock 218
            jq -nc --arg ts "$(date -Iseconds)" \
                   --arg pid "$pane_id" \
                   --arg harness "pi" \
                   --arg req "$qid" \
                   --arg tag "pi-question" \
                   --arg h "$qhash" \
                   --argjson q "$qpayload" \
                   '{ts:$ts, pane_id:$pid, harness:$harness, event_type:"question", request_id:$req, question:$q, classifier_tag:$tag, hash:$h}' \
                   >> "$WAKE_EVENTS_LOG"
          )
        fi
        continue
      fi

      local custom_type
      custom_type=$(jq -r '.data.message.customType // ""' <<< "$line" 2>/dev/null)
      if [[ "$custom_type" == "$BG_TASK_EVENT_CUSTOM_TYPE" ]]; then
        local bg_event_type
        bg_event_type=$(jq -r '.data.message.details.eventType // ""' <<< "$line" 2>/dev/null)
        # vstack#15: terminal exits remain canonical wake rows. Other
        # bg-task signals are activity-only rows drained by the TS daemon;
        # they must not change wake routing.
        if [[ "$bg_event_type" == "$BG_TASK_EXIT_EVENT_TYPE" ]]; then
          emit_pi_bg_task_exit_event "$pane_id" "$line" last_hash "$sub_log"
        else
          emit_pi_bg_task_activity_event "$pane_id" "$line" last_hash "$sub_log"
        fi
        continue
      fi
      if [[ "$custom_type" == "subagent-completion" ]]; then
        local details hash has_bad
        details=$(jq -c '.data.message.details // {}' <<< "$line" 2>/dev/null)
        [[ -z "$details" || "$details" == "null" ]] && details="{}"
        hash=$(printf '%s' "$details" | sha256sum | awk '{print substr($1,1,12)}')
        [[ "$hash" == "$last_hash" ]] && continue
        if jq -e '(.completions // []) | any((.status // "") == "blocked" or (.status // "") == "failed" or (.status // "") == "needs_completion")' <<< "$details" >/dev/null 2>&1; then
          has_bad=1
        else
          has_bad=0
        fi
        printf '%s [pi-subagent-completion] pane=%s hash=%s bad=%s\n' \
          "$(date -Iseconds)" "$pane_id" "$hash" "$has_bad" \
          >> "$sub_log" 2>/dev/null || true
        ( exec 218>"$SESSION_LOCK"
          flock 218
          local tag="pi-subagent-completion-ok"
          [[ "$has_bad" == "1" ]] && tag="pi-subagent-completion"
          jq -nc --arg ts "$(date -Iseconds)" \
                 --arg pid "$pane_id" \
                 --arg harness "pi" \
                 --arg tag "$tag" \
                 --arg h "$hash" \
                 --argjson details "$details" \
                 '{ts:$ts, pane_id:$pid, harness:$harness, event_type:"subagent-completion", completion:$details, classifier_tag:$tag, hash:$h}' \
                 >> "$WAKE_EVENTS_LOG"
        )
        last_hash="$hash"
        continue
      fi

      if [[ -z "$custom_type" ]]; then
        local downstream_role
        downstream_role=$(jq -r '.data.message.role // ""' <<< "$line" 2>/dev/null)
        [[ "$downstream_role" != "assistant" ]] && continue
      fi

      local last_text
      last_text=$(jq -r '
        ( .data.message.content // [] )
        | (if type == "array" then map(select(.type == "text") | .text // "") | join("") else . end)
      ' <<< "$line" 2>/dev/null)
      [[ -z "$last_text" ]] && continue
      local hash
      hash=$(printf '%s' "$last_text" | sha256sum | awk '{print substr($1,1,12)}')
      [[ "$hash" == "$last_hash" ]] && continue
      local tag
      tag=$(classify_adapter_text "$last_text" "$pane_id" "$sub_log")
      local text_excerpt
      text_excerpt=$(printf '%s' "$last_text" | head -c 1024 || true)
      printf '%s [pi-sub-emit] pane=%s hash=%s tag=%s text_len=%s entry_kind=%s\n' \
        "$(date -Iseconds)" "$pane_id" "$hash" "$tag" "${#last_text}" "${FD_ENTRY_KIND:-}" \
        >> "$sub_log" 2>/dev/null || true
      ( exec 218>"$SESSION_LOCK"
        flock 218
        jq -nc --arg ts "$(date -Iseconds)" \
               --arg pid "$pane_id" \
               --arg harness "pi" \
               --arg text "$text_excerpt" \
               --arg tag "$tag" \
               --arg h "$hash" \
               --arg entry_kind "${FD_ENTRY_KIND:-}" \
               --arg entry_harness "${FD_ENTRY_HARNESS:-}" \
               '{ts:$ts, pane_id:$pid, harness:$harness, last_assistant_text:$text, classifier_tag:$tag, hash:$h}
                + (if $entry_kind == "" then {} else {entry_kind:$entry_kind} end)
                + (if $entry_harness == "" then {} else {entry_harness:$entry_harness} end)' \
               >> "$WAKE_EVENTS_LOG"
      )
      last_hash="$hash"

      # vstack#61/#117: generic Pi panes (adhoc/workflow) have no
      # issue-mode prompt tags master can read; emit terminal-state-reached
      # on isIdle:true/no-pending transitions so session-watch advances
      # waiting -> complete.
      # Mirror of src/daemon/pi-adhoc-wake.ts decidePiAdhocWake() +
      # src/classifier/pi-bridge-state.ts classifyPiBridgeState(): the
      # canonical TS function is the source of truth, this bash check
      # must stay in lock step.
      if [[ "${FD_ENTRY_KIND:-}" == "adhoc" || "${FD_ENTRY_KIND:-}" == "workflow" ]]; then
        local pi_state_json pi_state_rc terminal_idle terminal_rc term_hash
        if pi_state_json=$("$pi_bin" state "${pi_target_args[@]}" 2>>"$sub_log"); then
          pi_state_rc=0
        else
          pi_state_rc=$?
        fi
        if (( pi_state_rc != 0 )); then
          printf '%s [pi-sub-terminal-state-error] pane=%s reason=state_rc rc=%s\n' \
            "$(date -Iseconds)" "$pane_id" "$pi_state_rc" \
            >> "$sub_log" 2>/dev/null || true
        elif [[ -n "$pi_state_json" ]]; then
          if terminal_idle=$(jq -r '(.data // .) as $s | ($s.isIdle == true) and (($s.hasPendingMessages // false) == false)' <<< "$pi_state_json" 2>>"$sub_log"); then
            terminal_rc=0
          else
            terminal_rc=$?
          fi
          if (( terminal_rc != 0 )); then
            printf '%s [pi-sub-terminal-state-error] pane=%s reason=state_json rc=%s\n' \
              "$(date -Iseconds)" "$pane_id" "$terminal_rc" \
              >> "$sub_log" 2>/dev/null || true
          elif [[ "$terminal_idle" == "true" ]]; then
            term_hash=$(printf '%s|adhoc-pi-idle|%s' "$pane_id" "$hash" | sha256sum | awk '{print substr($1,1,12)}')
            if [[ "${last_terminal_hash:-}" != "$term_hash" ]]; then
              if ( exec 218>"$SESSION_LOCK"
                flock 218
                jq -nc --arg ts "$(date -Iseconds)" \
                       --arg pid "$pane_id" \
                       --arg harness "pi" \
                       --arg tag "terminal-state-reached" \
                       --arg h "$term_hash" \
                       '{ts:$ts, pane_id:$pid, harness:$harness, last_assistant_text:"", classifier_tag:$tag, hash:$h}' \
                       >> "$WAKE_EVENTS_LOG"
              ); then
                last_terminal_hash="$term_hash"
                printf '%s [pi-sub-adhoc-terminal] pane=%s hash=%s\n' \
                  "$(date -Iseconds)" "$pane_id" "$term_hash" \
                  >> "$sub_log" 2>/dev/null || true
              else
                printf '%s [pi-sub-terminal-state-error] pane=%s reason=append_failed hash=%s\n' \
                  "$(date -Iseconds)" "$pane_id" "$term_hash" \
                  >> "$sub_log" 2>/dev/null || true
              fi
            fi
          fi
        fi
      fi
    done
}

cx_subscriber_loop() {
  exec 200<&- 2>/dev/null || true
  local pane_id="$1" cx_url="$2" thread_id="$3" parent_pid="$4"
  local last_hash=""
  local sub_log; sub_log="${LOG}.cx-sub-$(cx_pane_id_safe "$pane_id")"
  printf '%s [cx-sub-start] pane=%s url=%s thread=%s parent=%s\n' \
    "$(date -Iseconds)" "$pane_id" "$cx_url" "$thread_id" "$parent_pid" \
    >> "$sub_log" 2>/dev/null || true

  cx_bridge_run stream --url "$cx_url" 2>>"$sub_log" \
    | tee -a "$sub_log.raw" \
    | jq --unbuffered -c --arg tid "$thread_id" 'select(.method == "thread/status/changed" and (.params.threadId // .params.thread_id) == $tid and ((.params.status // "") | tostring | test("idle"; "i")))' 2>>"$sub_log" \
    | while IFS= read -r line; do
      if ! kill -0 "$parent_pid" 2>/dev/null; then exit 0; fi
      [[ -z "$line" ]] && continue
      local turns; turns=$(cx_bridge_run turns --url "$cx_url" --thread "$thread_id" 2>/dev/null || echo "")
      [[ -z "$turns" ]] && continue
      local last_text
      last_text=$(jq -r "$CX_LAST_ASSISTANT_JQ" <<< "$turns" 2>/dev/null)
      [[ -z "$last_text" ]] && continue
      local hash
      hash=$(printf '%s' "$last_text" | sha256sum | awk '{print substr($1,1,12)}')
      [[ "$hash" == "$last_hash" ]] && continue
      local tag
      tag=$(classify_adapter_text "$last_text" "$pane_id" "$sub_log")
      local text_excerpt
      text_excerpt=$(printf '%s' "$last_text" | head -c 1024 || true)
      printf '%s [cx-sub-emit] pane=%s hash=%s tag=%s text_len=%s\n' \
        "$(date -Iseconds)" "$pane_id" "$hash" "$tag" "${#last_text}" \
        >> "$sub_log" 2>/dev/null || true
      ( exec 222>"$SESSION_LOCK"
        flock 222
        jq -nc --arg ts "$(date -Iseconds)" \
               --arg pid "$pane_id" \
               --arg harness "codex" \
               --arg text "$text_excerpt" \
               --arg tag "$tag" \
               --arg h "$hash" \
               '{ts:$ts, pane_id:$pid, harness:$harness, last_assistant_text:$text, classifier_tag:$tag, hash:$h}' \
               >> "$WAKE_EVENTS_LOG"
      )
      last_hash="$hash"
    done
}

# Idle-stream watchdog (round-4 #5): cc/pi/cx subscribers block in
# `tail -F` / `pi-bridge stream` / `cx_bridge_run stream` waiting on
# new data. The inner `while read` parent_pid check only fires on
# each new line; on a quiet stream the check never runs and the
# subscriber + its pipeline children orphan on parent death.
#
# Fix: spawn an external watchdog (background subshell) that polls
# `kill -0 parent_pid` every 5s; on death, SIGTERM the main
# subscriber pgroup (which includes the pipeline children) and exit.
# Each subscriber dispatch is enclosed in `setsid` so the subscriber
# + its pipeline children share one pgroup we can kill atomically.
start_watchdog() {
  local parent_pid="$1" sub_pgid="$2" pane_log="$3"
  (
    while kill -0 "$sub_pgid" 2>/dev/null; do
      if ! kill -0 "$parent_pid" 2>/dev/null; then
        printf '%s [parent-gone] killing subscriber pgroup %s\n' \
          "$(date -Iseconds)" "$sub_pgid" >> "$pane_log" 2>/dev/null || true
        kill -TERM "-$sub_pgid" 2>/dev/null || true
        sleep 0.5
        kill -KILL "-$sub_pgid" 2>/dev/null || true
        exit 0
      fi
      sleep 5
    done
  ) &
  # Disown so the watchdog doesn't accumulate as a zombie when the
  # parent of THIS script exits via subscriber-loop exit.
  disown $! 2>/dev/null || true
}

# Dispatch on first positional arg. Each kind runs in the current
# process (which is already its own pgroup leader because the daemon
# spawned us with detached:true → setsid effectively); we just need
# the watchdog to monitor + kill our pgroup on parent death.
my_pgid=$$
case "${1:-}" in
  oc)
    shift
    pane_log="${LOG}.oc-sub-$(oc_pane_id_safe "$1")"
    start_watchdog "$4" "$my_pgid" "$pane_log"
    oc_subscriber_loop "$@"
    ;;
  cc)
    shift
    pane_log="${LOG}.cc-sub-$(cc_pane_id_safe "$1")"
    start_watchdog "$3" "$my_pgid" "$pane_log"
    cc_subscriber_loop "$@"
    ;;
  pi)
    shift
    pane_log="${LOG}.pi-sub-$(pi_pane_id_safe "$1")"
    start_watchdog "$4" "$my_pgid" "$pane_log"
    parent_pid="$4"
    while kill -0 "$parent_pid" 2>/dev/null; do
      pi_subscriber_loop "$@"
      kill -0 "$parent_pid" 2>/dev/null || exit 0
      printf '%s [pi-sub-restart] pane=%s stream exited; reconnecting in 1s\n' \
        "$(date -Iseconds)" "$1" >> "$pane_log" 2>/dev/null || true
      sleep 1
    done
    ;;
  cx)
    shift
    pane_log="${LOG}.cx-sub-$(cx_pane_id_safe "$1")"
    start_watchdog "$4" "$my_pgid" "$pane_log"
    parent_pid="$4"
    while kill -0 "$parent_pid" 2>/dev/null; do
      cx_subscriber_loop "$@"
      kill -0 "$parent_pid" 2>/dev/null || exit 0
      printf '%s [cx-sub-restart] pane=%s stream exited; reconnecting in 1s\n' \
        "$(date -Iseconds)" "$1" >> "$pane_log" 2>/dev/null || true
      sleep 1
    done
    ;;
  *) echo "usage: subscribers.bash {oc|cc|pi|cx} <args>" >&2; exit 2 ;;
esac
