#!/usr/bin/env bash
# Path resolvers + helper functions for the pi Session Bridge adapter.
#
# Pi bridge is a vstack-vendored pi-extension package living at
# ~/.pi/agent/packages/pi-session-bridge with the `pi-bridge` CLI
# symlinked at ~/.pi/agent/bin/pi-bridge. When a pi process starts
# with the bridge package loaded (default vstack pi config), the
# bridge writes:
#   ${PI_BRIDGE_DIR:-/tmp/pi-session-bridge-$UID}/instances/<pid>.json
#   ${PI_BRIDGE_DIR}/pi-<pid>.sock
# Both 0700/0600 — single-user-on-machine isolation only.
#
# Sourced by open-terminal (post-spawn discovery), pane-registry
# (auto-load metadata), pane-respond + pane-poll (read bridge
# metadata), flightdeck-daemon (per-pane stream subscriber).

# shellcheck source=daemon-paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/daemon-paths.sh"

pi_spawn_file()    { echo "$(fd_resolve_state_dir)/pi-spawn-$1.json"; }

pi_pane_id_safe() {
  local id="$1"
  echo "${id#%}"
}

# Session-keyed subscriber PID file. Caller MUST pass session_key as $2.
# See oc_subscriber_pid_file for the rationale (cross-session glob race).
pi_subscriber_pid_file() { echo "$(fd_resolve_state_dir)/fd-pi-subscriber-${2:?session_key required}-$(pi_pane_id_safe "$1").pid"; }

# Resolve the pi-bridge CLI. Prefer an explicit test/operator override,
# then PATH, then the canonical vstack install path. Empty stdout +
# non-zero exit when not found.
pi_resolve_bridge_bin() {
  if [[ -n "${PI_BRIDGE_BIN:-}" && -x "$PI_BRIDGE_BIN" ]]; then
    echo "$PI_BRIDGE_BIN"
    return 0
  fi
  local p
  p=$(command -v pi-bridge 2>/dev/null || true)
  if [[ -n "$p" && -x "$p" ]]; then
    echo "$p"
    return 0
  fi
  if [[ -x "$HOME/.pi/agent/bin/pi-bridge" ]]; then
    echo "$HOME/.pi/agent/bin/pi-bridge"
    return 0
  fi
  return 1
}

# Resolve the pi binary similarly.
pi_resolve_pi_bin() {
  if [[ -n "${PI_BIN:-}" && -x "$PI_BIN" ]]; then
    echo "$PI_BIN"
    return 0
  fi
  if [[ -x /usr/bin/pi ]]; then
    echo "/usr/bin/pi"
    return 0
  fi
  local p
  p=$(type -P pi 2>/dev/null || true)
  if [[ -n "$p" && -x "$p" ]]; then
    echo "$p"
    return 0
  fi
  return 1
}

# Resolve the path to the session-bridge extension. We pass this as
# `-e <PATH>` to pi so the bridge auto-loads regardless of whether
# the user's settings.json has the package registered (vstack install
# adds it, but the array can drift).
pi_resolve_bridge_extension() {
  if [[ -n "${PI_SESSION_BRIDGE_EXTENSION:-}" && -f "$PI_SESSION_BRIDGE_EXTENSION" ]]; then
    echo "$PI_SESSION_BRIDGE_EXTENSION"
    return 0
  fi
  local p="$HOME/.pi/agent/packages/pi-session-bridge/extensions/session-bridge.ts"
  if [[ -f "$p" ]]; then
    echo "$p"
    return 0
  fi
  return 1
}

# Find the pi bridge pid whose cwd matches the given worktree and which
# was NOT in the pre-spawn snapshot. Caller passes the snapshot of pids
# present before the new pane was spawned via `pi-bridge list --json |
# jq -c '[.[].pid]'` (or `[]` if it failed). Without the snapshot exclude,
# discovery would happily return a pre-existing pi process in the same
# worktree before the new pane registers, and downstream spawn metadata
# would target the wrong session (bugs review finding #7).
pi_discover_pid() {
  local wt_path="$1"
  local timeout_secs="${2:-30}"
  local pre_pids_json="${3:-[]}"
  local bin
  bin=$(pi_resolve_bridge_bin) || return 1
  local abs_wt
  abs_wt=$(cd "$wt_path" && pwd)
  local deadline=$((SECONDS + timeout_secs))
  while (( SECONDS < deadline )); do
    # `pi-bridge list --json` returns an array of {pid, cwd, sessionId, ...}
    local out
    out=$("$bin" list --json 2>/dev/null || echo "[]")
    if [[ -n "$out" ]]; then
      local pid
      pid=$(jq -r --arg dir "$abs_wt" --argjson pre "$pre_pids_json" '
        ( . // [] )
        | map(select((.cwd // "") == $dir))
        | map(select(.pid as $p | ($pre // []) | index($p) | not))
        | sort_by(.startedAt // .started_at // 0)
        | last
        | (.pid // empty)
      ' <<< "$out" 2>/dev/null)
      if [[ -n "$pid" && "$pid" != "null" ]]; then
        echo "$pid"
        return 0
      fi
    fi
    sleep 0.5
  done
  return 1
}

# Snapshot existing pi-bridge pids. Caller takes this BEFORE spawning the
# new pi pane and passes the result to `pi_discover_pid` so we can
# exclude already-running pi processes from the cwd match.
pi_snapshot_pids() {
  local bin; bin=$(pi_resolve_bridge_bin 2>/dev/null) || { echo "[]"; return 0; }
  local out; out=$("$bin" list --json 2>/dev/null || echo "[]")
  jq -c '( . // [] ) | map(.pid) | map(select(. != null))' <<< "$out" 2>/dev/null || echo "[]"
}

# Stale check: pid alive + socket exists + protocol matches.
# Returns 0 if bridge metadata is fresh, non-zero if stale.
pi_bridge_is_fresh() {
  local pid="$1"
  local socket="$2"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [[ -S "$socket" ]] || return 1
  local bin; bin=$(pi_resolve_bridge_bin) || return 1
  local target_args=()
  if [[ -n "$socket" ]]; then
    target_args=(--socket "$socket")
  else
    target_args=(--pid "$pid")
  fi
  local proto
  proto=$("$bin" state "${target_args[@]}" 2>/dev/null \
    | jq -r '.data.protocol // ""' 2>/dev/null)
  [[ "$proto" == "pi-session-bridge.v1" ]]
}

# Issue #37(D): drain pi-questions that are already open in the bridge
# when a subscriber attaches. The live `pi-bridge stream` only emits
# future events; a question opened before the daemon subscribed would
# otherwise be invisible to master (the classifier can't see it either,
# since questions live in bridge state, not the tmux pane buffer).
#
# Synthesizes the same `pi-question-emit` sub_log line and
# WAKE_EVENTS_LOG row that the live-stream branch emits, then seeds
# the caller's seen_qids dedup string so the future stream event is
# treated as already-handled.
#
# Round-1 reviewer-error blocker (#37): fail open with explicit
# diagnostics. Timeout the bridge call so a hung pi-bridge cannot
# block the subscriber before it reaches `pi-bridge stream`; capture
# exit code + stderr; validate the JSON envelope before iterating;
# log structured tags on every failure mode so the operator can tell
# drain-quiet from drain-broken.
#
# Usage:
#   pi_subscriber_drain_questions <pane_id> <pi_bin> <sub_log> \
#                                 <pi_target_args_arrayname> \
#                                 <seen_qids_varname>
#
# Honors FD_ADAPTER_READ_TIMEOUT_SEC (default 2, matching pane-poll).
# Requires WAKE_EVENTS_LOG and SESSION_LOCK in env.
pi_subscriber_drain_questions() {
  local pane_id="$1" pi_bin="$2" sub_log="$3"
  local -n _pi_drain_target_args="$4"
  local -n _pi_drain_seen="$5"
  local drain_timeout="${FD_ADAPTER_READ_TIMEOUT_SEC:-2}"
  local err_file resp rc stderr_tail excerpt pending
  err_file=$(mktemp -t fd-pi-drain-err.XXXXXX)
  # `timeout(1)` SIGTERMs the bridge after the deadline (exit 124),
  # bounding the worst-case attach delay so even a hung pi-bridge
  # falls through to the live stream. stderr is captured separately
  # so a non-zero rc has actionable diagnostics.
  resp=$(timeout "${drain_timeout}s" "$pi_bin" questions "${_pi_drain_target_args[@]}" 2>"$err_file")
  rc=$?
  if (( rc != 0 )); then
    stderr_tail=$(tail -c 200 "$err_file" 2>/dev/null | tr '\n' ' ' || true)
    rm -f "$err_file"
    printf '%s [pi-sub-drain-error] pane=%s rc=%s stderr=%s\n' \
      "$(date -Iseconds)" "$pane_id" "$rc" "${stderr_tail:-<empty>}" \
      >> "$sub_log" 2>/dev/null || true
    return 0
  fi
  rm -f "$err_file"
  if [[ -z "$resp" ]]; then
    printf '%s [pi-sub-drain-empty] pane=%s\n' \
      "$(date -Iseconds)" "$pane_id" \
      >> "$sub_log" 2>/dev/null || true
    return 0
  fi
  # Validate JSON envelope shape before walking it. A malformed body
  # would otherwise be silently swallowed by the inner `jq -c`.
  if ! jq -e '.success == true' <<< "$resp" >/dev/null 2>&1 \
     || ! jq -e '.data.questions | type == "array"' <<< "$resp" >/dev/null 2>&1; then
    excerpt=$(printf '%s' "$resp" | head -c 200 | tr '\n' ' ')
    printf '%s [pi-sub-drain-malformed] pane=%s excerpt=%s\n' \
      "$(date -Iseconds)" "$pane_id" "${excerpt:-<empty>}" \
      >> "$sub_log" 2>/dev/null || true
    return 0
  fi
  pending=$(jq -c '.data.questions' <<< "$resp" 2>/dev/null || echo '[]')
  [[ -z "$pending" || "$pending" == "null" || "$pending" == "[]" ]] && return 0
  local item qid payload qhash
  while IFS= read -r item; do
    [[ -z "$item" || "$item" == "null" ]] && continue
    qid=$(jq -r '.requestId // .request.id // ""' <<< "$item" 2>/dev/null)
    [[ -z "$qid" || "$qid" == "null" ]] && continue
    if [[ "$_pi_drain_seen" == *",$qid,"* ]]; then continue; fi
    payload=$(jq -c '.request // .' <<< "$item" 2>/dev/null)
    [[ -z "$payload" || "$payload" == "null" ]] && continue
    qhash=$(printf '%s' "$qid" | sha256sum | awk '{print substr($1,1,12)}')
    printf '%s [pi-question-emit] pane=%s request_id=%s drain=1\n' \
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
             --argjson q "$payload" \
             '{ts:$ts, pane_id:$pid, harness:$harness, event_type:"question", request_id:$req, question:$q, classifier_tag:$tag, hash:$h}' \
             >> "$WAKE_EVENTS_LOG"
    )
    _pi_drain_seen+="$qid,"
  done < <(jq -c '.[]' <<< "$pending" 2>/dev/null || true)
}

# jq filter that extracts the last assistant message text from
# `pi-bridge history` output. Pi events shape:
#   {type:"event", event:"message_update", data:{message:{role:"assistant",
#    content:[{type:"text", text:"..."}], stopReason:"stop"}}}
PI_LAST_ASSISTANT_JQ='
  ( .data.events // [] )
  | map(select(.data.message.role == "assistant" and (.data.message.stopReason // "") != ""))
  | last
  | if . == null then ""
    else
      ( .data.message.content // [] )
      | (if type == "array" then map(select(.type == "text") | .text // "") | join("") else . end)
    end
'
