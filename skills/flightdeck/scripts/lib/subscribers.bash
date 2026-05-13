#!/usr/bin/env bash
# Subscriber loop bodies extracted from flightdeck-daemon.bash so the
# TS daemon can spawn them without re-implementing the long-running
# cooperative async streams. Bodies are verbatim copies; the parity
# test in lib/flightdeck-core/tests/parity/subscriber-bodies.test.ts
# enforces byte equivalence with the bash daemon source.
#
# Usage:
#   bash subscribers.bash oc <pane_id> <oc_url> <session_id> <parent_pid>
#   bash subscribers.bash cc <pane_id> <transcript> <parent_pid>
#   bash subscribers.bash pi <pane_id> <pi_pid> <pi_socket> <parent_pid>
#   bash subscribers.bash cx <pane_id> <cx_url> <thread_id> <parent_pid>
#
# Required env (the TS daemon exports these before spawning):
#   FD_STATE_DIR, SESSION_LOCK, WAKE_EVENTS_LOG, LOG
#   OC_POLL_SEC, OC_BACKOFF_MAX_SEC (oc only)
#   CLASSIFIER                  (path to prompt-classify binary; may be empty)
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
          if [[ -n "${CLASSIFIER:-}" && -x "${CLASSIFIER:-}" ]]; then
            tag=$(printf '%s' "$last_text" | "$CLASSIFIER" --no-footer-gate 2>/dev/null)
            [[ -z "$tag" ]] && tag="rendering"
          else
            tag="rendering"
          fi
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
      if [[ -n "${CLASSIFIER:-}" && -x "${CLASSIFIER:-}" ]]; then
        tag=$(printf '%s' "$last_text" | "$CLASSIFIER" --no-footer-gate 2>/dev/null)
        [[ -z "$tag" ]] && tag="rendering"
      else
        tag="rendering"
      fi
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

pi_subscriber_loop() {
  exec 200<&- 2>/dev/null || true
  local pane_id="$1" pi_pid="$2" pi_socket="${3:-}" parent_pid="${4:-}"
  local last_hash=""
  local seen_qids=","
  local sub_log; sub_log="${LOG}.pi-sub-$(pi_pane_id_safe "$pane_id")"
  printf '%s [pi-sub-start] pane=%s pi_pid=%s socket=%s parent=%s\n' \
    "$(date -Iseconds)" "$pane_id" "$pi_pid" "$pi_socket" "$parent_pid" \
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

  "$pi_bin" stream "${pi_target_args[@]}" 2>/dev/null \
    | jq --unbuffered -c 'select(
        (.type == "event" and .event == "question" and (.data.action // "") == "opened")
        or
        (.type == "event" and .event == "message_end" and ((.data.message.customType // "") == "subagent-completion"))
        or
        (.type == "event" and .event == "message_end" and ((.data.message.customType // "") == "vstack-background-tasks:event") and ((.data.message.details.eventType // "") == "exit"))
        or
        (.type == "event" and .data.message.role == "assistant" and (.data.message.stopReason // "") != "")
      )' \
    | while IFS= read -r line; do
      if ! kill -0 "$parent_pid" 2>/dev/null; then exit 0; fi
      [[ -z "$line" ]] && continue

      local event_name
      event_name=$(jq -r '.event // ""' <<< "$line" 2>/dev/null)
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
        # vstack#15: dispatch the new branch via the shared
        # daemon-bg-task-events.sh helper. Returns 0 on emit, 1 on
        # dedup (caller `continue`s either way), 2 on malformed input.
        emit_pi_bg_task_exit_event "$pane_id" "$line" last_hash "$sub_log"
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
        if [[ "$has_bad" == "1" ]]; then
          ( exec 218>"$SESSION_LOCK"
            flock 218
            jq -nc --arg ts "$(date -Iseconds)" \
                   --arg pid "$pane_id" \
                   --arg harness "pi" \
                   --arg tag "pi-subagent-completion" \
                   --arg h "$hash" \
                   --argjson details "$details" \
                   '{ts:$ts, pane_id:$pid, harness:$harness, event_type:"subagent-completion", completion:$details, classifier_tag:$tag, hash:$h}' \
                   >> "$WAKE_EVENTS_LOG"
          )
        fi
        last_hash="$hash"
        continue
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
      if [[ -n "${CLASSIFIER:-}" && -x "${CLASSIFIER:-}" ]]; then
        tag=$(printf '%s' "$last_text" | "$CLASSIFIER" --no-footer-gate 2>/dev/null)
        [[ -z "$tag" ]] && tag="rendering"
      else
        tag="rendering"
      fi
      local text_excerpt
      text_excerpt=$(printf '%s' "$last_text" | head -c 1024 || true)
      printf '%s [pi-sub-emit] pane=%s hash=%s tag=%s text_len=%s\n' \
        "$(date -Iseconds)" "$pane_id" "$hash" "$tag" "${#last_text}" \
        >> "$sub_log" 2>/dev/null || true
      ( exec 218>"$SESSION_LOCK"
        flock 218
        jq -nc --arg ts "$(date -Iseconds)" \
               --arg pid "$pane_id" \
               --arg harness "pi" \
               --arg text "$text_excerpt" \
               --arg tag "$tag" \
               --arg h "$hash" \
               '{ts:$ts, pane_id:$pid, harness:$harness, last_assistant_text:$text, classifier_tag:$tag, hash:$h}' \
               >> "$WAKE_EVENTS_LOG"
      )
      last_hash="$hash"
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
      if [[ -n "${CLASSIFIER:-}" && -x "${CLASSIFIER:-}" ]]; then
        tag=$(printf '%s' "$last_text" | "$CLASSIFIER" --no-footer-gate 2>/dev/null)
        [[ -z "$tag" ]] && tag="rendering"
      else
        tag="rendering"
      fi
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
