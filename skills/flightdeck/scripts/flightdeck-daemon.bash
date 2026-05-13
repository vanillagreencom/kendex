#!/usr/bin/env bash
# flightdeck-daemon — external wake driver for the flightdeck master agent.
#
# Replaces harness-specific scheduler primitives (e.g. Claude Code's
# ScheduleWakeup) with a long-lived bash poller spawned at flightdeck-start
# time. Polls every tracked inner tmux pane on FD_POLL_SEC cadence; wakes
# the master agent via the per-harness delivery channel when any pane needs
# attention.
# Harness-independent — works for claude / codex / opencode / pi.
#
# Architecture:
#   - Bell flag → wake immediately (orchestrator bells signal real input).
#   - Buffer hash stable for FD_STABILITY ticks → run prompt-classify; wake
#     only on a canonical classifier tag (rendering / unknown → ignore).
#   - Multiple ready panes coalesced into one wake per tick.
#   - All wake/event state mutations under SESSION_LOCK (race-safe with
#     master's atomic ack action).
#
# Master contract (MANDATORY):
#   1. Turn-start: atomic write BUSY_FILE = '{"pid":<long-lived-pid>?,"master_pane_id":
#      "%N","started_at":"<ISO>"}' via temp+mv.
#   2. Drain hint: events=$(flightdeck-daemon events --session <id>)
#   3. Handle panes per registry/classifier.
#   4. Turn-end:
#      a. pending=$(flightdeck-daemon ack --session <id>)
#         — atomic drain-of-newcomers + clear of WAKE_PENDING.
#      b. Process newcomer events from 4a.
#      c. rm BUSY_FILE last.
#   Bare `rm WAKE_PENDING` is UNSAFE — use `ack`.
#
# Operational caveats:
#   - Worst-case wake latency on master crash = FD_WAKE_PENDING_TTL +
#     FD_POLL_SEC (default 302s).
#   - FD_STATE_DIR must be user-owned/private. Recommended:
#     FD_STATE_DIR=$XDG_RUNTIME_DIR/flightdeck or /tmp/flightdeck-$UID with
#     0700 mode.
#   - Stranded `.draining.<pid>` and stale BUSY_FILE recovery can be delayed
#     if the PID is reused before the next startup GC runs.
#
# Usage:
#   flightdeck-daemon start  --session <S> --master <pane> --inner <p1>[,<p2>...] [--inner-harnesses <h1>[,<h2>...]]
#   flightdeck-daemon stop   --session <S>
#   flightdeck-daemon status --session <S>
#   flightdeck-daemon events --session <S>     # turn-start drain (no clear)
#   flightdeck-daemon ack    --session <S>     # turn-end drain + clear
#
# Env (defaults shown):
#   FD_STATE_DIR        $XDG_RUNTIME_DIR/flightdeck or /tmp/flightdeck-$UID
#                                   State file directory. Created mode 0700.
#                                   Resolved via lib/daemon-paths.sh — same
#                                   resolution flightdeck-state uses for the
#                                   master-busy lock file.
#   FD_POLL_SEC         2           Inner-pane polling interval.
#   FD_STABILITY        3           Seconds of buffer-hash stability before classify.
#   FD_CAPTURE_LINES    200         tmux capture-pane -S -<N>; visible-only for opencode.
#   FD_HARNESS          ""          Per-harness capture strategy ("opencode" → visible-only).
#   FD_CLASSIFIER       <sibling>   Path to prompt-classify; falls back to built-in stub.
#   FD_WAKE_PENDING_TTL 300         Stale wake-pending recovery threshold.
#   FD_VERBOSE          0           Log non-canonical/no-action classifies.
#   FD_HEARTBEAT_TICKS  60          Ticks between heartbeat log lines.
#   FD_MAX_LIFETIME     14400       Seconds before daemon exec()s itself
#                                   for a fresh process. 0 disables.
#   FD_SPAWN_MODE       detach      "detach" (setsid+nohup, default) or
#                                   "tmux-window" (spawn in tmux session).
#   FD_GRACE_SEC        30          Suppress wakes for newly-tracked panes
#                                   for this long after first sighting.
#                                   Prevents cold-start TUI banners from
#                                   firing classifier wakes.
#   FD_OC_POLL_SEC      2           Per-opencode-pane subscriber poll
#                                   interval against /session/<id>/message.
#   FD_OC_BACKOFF_MAX_SEC 16        Max OpenCode subscriber exponential
#                                   backoff after unchanged polls.
set -euo pipefail

# Resolve daemon state dir + session-keyed file paths via shared helper so
# flightdeck-state's master-busy writer and the daemon's reader agree.
# Also resolve opencode HTTP-attach paths.
_daemon_script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")")"
# shellcheck source=lib/daemon-paths.sh
source "$_daemon_script_dir/lib/daemon-paths.sh"
# shellcheck source=lib/oc-paths.sh
source "$_daemon_script_dir/lib/oc-paths.sh"
# shellcheck source=lib/cc-channel-paths.sh
source "$_daemon_script_dir/lib/cc-channel-paths.sh"
# shellcheck source=lib/pi-bridge-paths.sh
source "$_daemon_script_dir/lib/pi-bridge-paths.sh"
# shellcheck source=lib/codex-paths.sh
source "$_daemon_script_dir/lib/codex-paths.sh"
# vstack#15: canonical pi-bg-task-exit emit helper, kept in its own
# file so this script does not grow on new event classes.
# shellcheck source=lib/daemon-bg-task-events.sh
source "$_daemon_script_dir/lib/daemon-bg-task-events.sh"
STATE_DIR=$(fd_resolve_state_dir)
POLL_SEC="${FD_POLL_SEC:-2}"
STABILITY_SEC="${FD_STABILITY:-3}"
CAPTURE_LINES="${FD_CAPTURE_LINES:-200}"
HARNESS="${FD_HARNESS:-}"
# Default classifier path: sibling prompt-classify in skills/flightdeck/scripts.
# Resolved relative to this script's directory so production layout works
# without setting FD_CLASSIFIER explicitly.
_default_classifier="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")" 2>/dev/null)/prompt-classify"
CLASSIFIER="${FD_CLASSIFIER:-$_default_classifier}"
# Don't actually use it if it doesn't exist (prototype test mode falls back to stub).
[[ ! -x "$CLASSIFIER" ]] && CLASSIFIER=""
VERBOSE="${FD_VERBOSE:-0}"
WAKE_PENDING_TTL="${FD_WAKE_PENDING_TTL:-300}"
# Bound on a master turn's lifetime. The master-busy lock is treated as
# stale beyond this even when the recorded pane is still alive, so an
# agent that crashed mid-turn without unlocking eventually unblocks wakes.
MASTER_TURN_TTL="${FD_MASTER_TURN_TTL:-3600}"
HEARTBEAT_TICKS="${FD_HEARTBEAT_TICKS:-60}"
MAX_LIFETIME="${FD_MAX_LIFETIME:-14400}"  # 4h; 0 disables
GRACE_SEC="${FD_GRACE_SEC:-30}"           # cold-start wake-suppression window
OC_POLL_SEC="${FD_OC_POLL_SEC:-2}"        # opencode subscriber poll interval
OC_BACKOFF_MAX_SEC="${FD_OC_BACKOFF_MAX_SEC:-16}" # max opencode unchanged-poll backoff

# Canonical classifier tag allowlist for stable-wake. Only these wake the
# master from a stable buffer. Bell wake is independent and unconditional.
CANONICAL_TAGS=(
  terminal-state-reached
  force-push-prompt
  merge-now
  cleanup-prompt
  stale-no-pr-branch
  stale-orphan-worktree
  rebase-multi-choice
  generic-multi-choice
  multi-select-tabbed
  awaiting-direction
  bash-permission-prompt
  modal-prompt
  bot-review-wait-stuck
  audit-relation-prompt
  merge-ready-but-unknown
  force-merge-confirm
  external-fix-suggestions
  cycle-fix-suggestions
  descope-related
  oc-question
  pi-question
  pi-subagent-completion
  pi-bg-task-exit
)

is_canonical_tag() {
  local t="$1"
  for c in "${CANONICAL_TAGS[@]}"; do
    [[ "$c" == "$t" ]] && return 0
  done
  return 1
}

usage() { cat >&2 <<EOF
Usage:
  flightdeck-daemon start       --session <S> --master <pane> --inner <p1>[,<p2>...] [--master-harness <h>] [--inner-harnesses <h1>[,<h2>...]] [--foreground|--in-tmux-window] [--debug-pane <pane_id>]
  flightdeck-daemon stop        --session <S>
  flightdeck-daemon status      --session <S>
  flightdeck-daemon health      --session <S>     # operator-friendly diagnosis
  flightdeck-daemon find-window --session <S>     # tmux window-id of daemon (tmux-window mode)
  flightdeck-daemon events      --session <S>     # drain events JSONL (turn-start)
  flightdeck-daemon ack         --session <S>     # drain + clear pending (turn-end)

start spawn modes:
  default (detach)   — setsid + nohup; survives caller shell. Recommended
                       for Claude Code. Set FD_SPAWN_MODE=tmux-window to
                       change the default.
  --in-tmux-window   — spawn a dedicated tmux window in the same session
                       running 'start --foreground'. Lifetime ties to the
                       tmux session. Recommended for codex/opencode/pi/omp
                       harnesses where backgrounding is unreliable.
  --foreground       — keep the process attached. Used internally by both
                       spawn modes; pass directly for ops debugging.
EOF
exit 2; }

# Capture original args before any shifts so we can re-exec ourselves with
# the same invocation when detaching the start action.
ORIG_ARGS=("$@")

ACTION="${1:-}"; [[ -z "$ACTION" ]] && usage; shift

SESSION_NAME="" MASTER_TARGET="" INNER_TARGETS="" INNER_HARNESSES=""
MASTER_HARNESS=""
FOREGROUND=0
SPAWN_MODE="${FD_SPAWN_MODE:-detach}"  # detach | tmux-window
DEBUG_PANE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SESSION_NAME="$2"; shift 2 ;;
    --master)  MASTER_TARGET="$2"; shift 2 ;;
    --master-harness) MASTER_HARNESS="$2"; shift 2 ;;
    --inner)   INNER_TARGETS="$2"; shift 2 ;;
    --inner-harnesses) INNER_HARNESSES="$2"; shift 2 ;;
    --foreground|--no-detach) FOREGROUND=1; shift ;;
    --in-tmux-window) SPAWN_MODE="tmux-window"; shift ;;
    --debug-pane) DEBUG_PANE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -z "$SESSION_NAME" ]] && { echo "--session required" >&2; usage; }

# Dependency preflight runs BEFORE session resolution so missing tmux fails
# with a clean error instead of "session not found".
_check_deps_inline() {
  local missing=()
  local cmd
  for cmd in tmux jq flock awk sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "Error: missing required commands: ${missing[*]}" >&2
    exit 2
  fi
}
_check_deps_inline

# Resolve --session input to canonical (name, id) pair. Accepts EITHER
# session_name or session_id (e.g. "$143"). tmux's -t target flag accepts
# both forms; we look up both fields once so downstream code never has to
# care which the caller passed.
resolve_session_pair() {
  local input="$1"
  local sid sname
  sid=$(tmux display-message -p -t "$input" '#{session_id}' 2>/dev/null) || sid=""
  sname=$(tmux display-message -p -t "$input" '#{session_name}' 2>/dev/null) || sname=""
  printf '%s|%s\n' "$sname" "$sid"
}

# Single helper: tmux session_id "$143" → state-file key "s143". Used
# everywhere we need to derive a key from an id (avoids drift between sed
# and parameter-expansion paths). Aliased to the lib helper.
session_key_from_id() { fd_session_key_from_id "$1"; }

# Normalize the input. After this, SESSION_NAME is the canonical tmux
# session name (regardless of whether the caller passed a name or id) and
# SESSION_ID is the canonical session_id form ("$N").
_session_pair=$(resolve_session_pair "$SESSION_NAME")
_resolved_name="${_session_pair%|*}"
SESSION_ID="${_session_pair#*|}"
if [[ -n "$_resolved_name" ]]; then
  SESSION_NAME="$_resolved_name"
fi
if [[ -z "$SESSION_ID" ]]; then
  # For stop/status the daemon may be running for a session that's already
  # gone — fall back to a name-keyed lookup so cleanup works.
  SESSION_KEY="$SESSION_NAME"
else
  SESSION_KEY=$(session_key_from_id "$SESSION_ID")
fi

PID_FILE=$(fd_pid_file "$STATE_DIR" "$SESSION_KEY")
PID_LOCK=$(fd_pid_lock "$STATE_DIR" "$SESSION_KEY")
LOG=$(fd_log_file "$STATE_DIR" "$SESSION_KEY")
BUSY_FILE=$(fd_busy_file "$STATE_DIR" "$SESSION_KEY")
WAKE_PENDING=$(fd_wake_pending "$STATE_DIR" "$SESSION_KEY")
EVENTS_FILE=$(fd_events_file "$STATE_DIR" "$SESSION_KEY")
# Session-wide lock guarding wake-pending mutations + events drain. All
# operations that touch BOTH wake-pending and events file MUST take this
# lock to prevent post-drain append races. Master's ack action takes it
# to atomically drain events + clear wake-pending.
SESSION_LOCK=$(fd_session_lock "$STATE_DIR" "$SESSION_KEY")

# log() writes a structured timestamped line to the daemon log file. When
# stdout is a tty (i.e., the daemon is running inside a dedicated tmux
# window in --in-tmux-window mode), we also echo to stdout so the window
# shows live activity instead of being a blank black screen. Detach mode
# redirects stdout to the log file itself, so the `-t 1` guard prevents
# double-writing the same line.
log() {
  local line
  printf -v line '%s [%s] %s\n' "$(date -Iseconds)" "$1" "$2"
  printf '%s' "$line" >> "$LOG"
  [[ -t 1 ]] && printf '%s' "$line"
}
warn() {
  local line
  printf -v line '%s [%s] %s\n' "$(date -Iseconds)" "$1" "$2"
  printf '%s' "$line" >> "$LOG"
  printf '%s' "$line" >&2
}

# Startup GC for orphaned daemon state files (sessions that no longer exist).
# Uses exact-match comparison via case statement (glob-char safe).
gc_orphan_state() {
  declare -A live_keys=()
  local sid
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    local k; k=$(session_key_from_id "$sid")
    [[ -n "$k" ]] && live_keys["$k"]=1
  done < <(tmux list-sessions -F '#{session_id}' 2>/dev/null)

  shopt -s nullglob
  local old_pid_file key opid f
  for old_pid_file in "$STATE_DIR"/fd-daemon-s*.pid; do
    key=$(basename "$old_pid_file" .pid); key="${key#fd-daemon-}"
    if [[ -z "${live_keys[$key]:-}" ]]; then
      opid=$(cat "$old_pid_file" 2>/dev/null || echo "")
      if [[ -z "$opid" ]] || ! kill -0 "$opid" 2>/dev/null; then
        log gc "removing orphan state for dead session $key (pid=$opid)"
        # Lock-aware cleanup of all wake/events/draining state.
        locked_cleanup_for_key "$key"
        # Direct removal of files with no in-flight contract.
        # IMPORTANT: never glob `${key}.*` — that would match the
        # `.session-lock` file itself, splitting future locking onto a new
        # inode. Enumerate explicitly.
        rm -f "$STATE_DIR/fd-daemon-${key}.pid" \
              "$STATE_DIR/fd-daemon-${key}.lock" \
              "$STATE_DIR/fd-daemon-${key}.log" \
              "$STATE_DIR/fd-daemon-${key}.heartbeat" \
              "$STATE_DIR/fd-master-${key}.busy" \
              "$STATE_DIR/fd-wake-events-${key}.log"
      fi
    fi
  done
  # Sweep subscriber pid files whose pid is dead. Live subscribers
  # belong to live daemons elsewhere on this host — leave them alone.
  local sub_file sub_pid
  for sub_file in "$STATE_DIR"/fd-subscriber-*.pid "$STATE_DIR"/fd-cc-subscriber-*.pid "$STATE_DIR"/fd-pi-subscriber-*.pid "$STATE_DIR"/fd-cx-subscriber-*.pid; do
    sub_pid=$(cat "$sub_file" 2>/dev/null || echo "")
    if [[ ! "$sub_pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$sub_pid" 2>/dev/null; then
      rm -f "$sub_file"
    fi
  done
  shopt -u nullglob
}

# --- Pane resolution -----------------------------------------------------------
resolve_pane_id() {
  local target="$1" pid
  # Gate the display-message call: `tmux display-message -t <bogus>`
  # silently falls back to the active pane. `list-panes -t <pane>` exits
  # non-zero for a missing target, which is what we want when callers
  # pass a stale pane_target string (e.g., the registry's recorded
  # `session:window.idx` after a window rename).
  tmux list-panes -t "$target" >/dev/null 2>&1 || { echo ""; return 1; }
  pid=$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null) || true
  [[ -z "$pid" || "$pid" != %* ]] && { echo ""; return 1; }
  echo "$pid"
}

# Per-tick cache of pane metadata keyed by pane_id. Refreshed at the
# start of each tick via one tmux list-panes pass. Replaces per-pane
# `tmux list-panes -a` / `tmux display-message` lookups (quadratic pane
# scans plus one extra bell subprocess per fallback pane per tick).
declare -A PANE_TARGET_CACHE PANE_WINDOW_CACHE PANE_BELL_CACHE PANE_ACTIVITY_CACHE PANE_MODE_CACHE

refresh_pane_cache() {
  PANE_TARGET_CACHE=()
  PANE_WINDOW_CACHE=()
  PANE_BELL_CACHE=()
  PANE_ACTIVITY_CACHE=()
  PANE_MODE_CACHE=()
  local pid tgt wid bell activity in_mode
  while IFS='|' read -r pid tgt wid bell activity in_mode; do
    [[ -z "$pid" ]] && continue
    PANE_TARGET_CACHE[$pid]="$tgt"
    PANE_WINDOW_CACHE[$pid]="$wid"
    PANE_BELL_CACHE[$pid]="${bell:-0}"
    PANE_ACTIVITY_CACHE[$pid]="${activity:-0}"
    PANE_MODE_CACHE[$pid]="${in_mode:-0}"
  done < <(tmux list-panes -a -F '#{pane_id}|#{session_name}:#{window_index}.#{pane_index}|#{window_id}|#{window_bell_flag}|#{window_activity_flag}|#{pane_in_mode}' 2>/dev/null)
}

pane_target_from_id() {
  local pid="$1"
  echo "${PANE_TARGET_CACHE[$pid]:-}"
}

window_id_for_pane() {
  local pid="$1"
  echo "${PANE_WINDOW_CACHE[$pid]:-}"
}

bell_flag_for_pane() {
  local pid="$1"
  echo "${PANE_BELL_CACHE[$pid]:-0}"
}

activity_flag_for_pane() {
  local pid="$1"
  echo "${PANE_ACTIVITY_CACHE[$pid]:-0}"
}

pane_in_mode_for_pane() {
  local pid="$1"
  echo "${PANE_MODE_CACHE[$pid]:-0}"
}

pane_alive() {
  local pid="$1"
  # Cache-backed: empty cache entry means the pane is gone (or cache
  # not yet refreshed; refresh_pane_cache is called at the top of every
  # tick so this is reliable inside run_loop).
  [[ -n "${PANE_TARGET_CACHE[$pid]:-}" ]]
}

session_alive() {
  # Use stable session_id rather than name (rename-safe).
  tmux list-sessions -F '#{session_id}' 2>/dev/null | grep -qx "$SESSION_ID"
}

# --- Capture strategy ---------------------------------------------------------
# Harness-agnostic. Per-harness quirks live in adapters (opencode HTTP attach,
# Phase 1; claude channels, Phase 2; ...) — the tmux capture path is the
# fallback for harnesses without adapters and panes with absent metadata.
capture_pane() {
  local target="$1"
  tmux capture-pane -t "$target" -p -S "-${CAPTURE_LINES}" 2>/dev/null
}

capture_hash_12() {
  # Fallback capture hashing is a hot path. Keep the hash in the same
  # SHA-12 domain as adapter events and pane-poll output, but avoid the
  # previous sha256sum | cut | head helper pipeline.
  local sum
  sum=$(sha256sum < <(printf '%s' "$1") 2>/dev/null) || { printf '000000000000'; return; }
  sum=${sum%% *}
  printf '%s' "${sum:0:12}"
}

stability_for_harness() {
  echo "$STABILITY_SEC"
}

# --- Classifier ----------------------------------------------------------------
classify_buffer() {
  local buf="$1"
  if [[ -n "$CLASSIFIER" && -x "$CLASSIFIER" ]]; then
    # Real prompt-classify reads stdin directly — no flag needed.
    printf '%s' "$buf" | "$CLASSIFIER" 2>/dev/null || echo "rendering"
    return
  fi
  # Built-in stub for prototype testing only.
  if echo "$buf" | grep -qiE 'merged.*please end|terminal.state|please end the session'; then
    echo "terminal-state-reached"; return
  fi
  if echo "$buf" | grep -qiE 'force.?push|--force-with-lease'; then
    echo "force-push-prompt"; return
  fi
  if echo "$buf" | grep -qiE 'merge now|merge.?ready|ready to merge'; then
    echo "merge-now"; return
  fi
  if echo "$buf" | grep -qiE 'cleanup|delete worktree|keep worktree'; then
    echo "cleanup-prompt"; return
  fi
  if echo "$buf" | grep -qiE 'rebase.*conflict|how.*resolve.*conflict'; then
    echo "rebase-multi-choice"; return
  fi
  if echo "$buf" | grep -qE '\[1\][^\n]*\[2\]|\(1\)[^\n]*\(2\)'; then
    echo "generic-multi-choice"; return
  fi
  if echo "$buf" | grep -qiE 'allow.*\?|permission.*to run|approve this command'; then
    echo "bash-permission-prompt"; return
  fi
  echo "rendering"
}

# --- Busy-lock (PID-only recovery) ---------------------------------------------
# Reads the busy lock JSON in one jq call. Returns 0 if master is busy and
# the lock is well-formed and matches our master pane id. Returns 1 on:
#   - no busy file
#   - JSON malformed
#   - missing required fields (pid, master_pane_id)
#   - non-numeric pid
#   - master_pane_id mismatch
#   - PID is dead
# NEVER removes BUSY_FILE in the hot path (TOCTOU-safe). Master may be
# mid-write of a fresh lock; removing here could clobber a live lock.
# Returns 1 ("not busy") for any unrecoverable condition; cleanup happens
# at startup GC for orphaned/stale leftovers.
is_master_busy() {
  local master_id="$1"
  [[ ! -f "$BUSY_FILE" ]] && return 1

  local fields
  fields=$(jq -r '[(.pid // ""|tostring), (.master_pane_id // ""), (.started_at // "")] | @tsv' "$BUSY_FILE" 2>/dev/null) || {
    return 1  # malformed JSON
  }
  local lock_pid lock_pane lock_started
  lock_pid=$(echo "$fields" | awk -F'\t' '{print $1}')
  lock_pane=$(echo "$fields" | awk -F'\t' '{print $2}')
  lock_started=$(echo "$fields" | awk -F'\t' '{print $3}')

  # Required field: pane match. pid is optional (older lockfiles, or callers
  # that don't know their long-lived owner pid).
  [[ -z "$lock_pane" ]] && return 1
  [[ "$lock_pane" != "$master_id" ]] && return 1

  # Pane must still exist in tmux. A vanished pane means the master's
  # window/process is gone; the lock is stale.
  if ! tmux list-panes -t "$lock_pane" >/dev/null 2>&1; then
    return 1
  fi

  # Owner PID check, when present. If absent (master-busy lock was written
  # without --owner-pid), fall through to the TTL gate. Reject pid=0 / pid=$$
  # of a long-dead helper script (bugs review finding #1: the wrapper used
  # to write its own short-lived `$$` here, so `kill -0` always failed and
  # the daemon treated the master as not busy mid-turn).
  if [[ -n "$lock_pid" && "$lock_pid" != "null" && "$lock_pid" != "0" ]]; then
    if [[ "$lock_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
      return 0
    fi
    # Pid was recorded but is dead. Fall through to TTL — the agent may have
    # crashed mid-turn and we want to eventually wake on someone else.
  fi

  # TTL gate: if started_at parses and exceeds MASTER_TURN_TTL, treat the
  # lock as stale even if the pane is still alive. `date -d` is GNU-only;
  # on platforms without it, skip the TTL rather than mis-parsing to epoch
  # 0 and declaring a live missing-owner lock stale immediately.
  if [[ -n "$lock_started" ]]; then
    local started_epoch now_epoch age
    if started_epoch=$(date -d "$lock_started" +%s 2>/dev/null); then
      now_epoch=$(date +%s)
      age=$(( now_epoch - started_epoch ))
      if (( age > MASTER_TURN_TTL )); then
        return 1
      fi
    fi
  fi

  return 0
}

# --- Wake-pending lifecycle ----------------------------------------------------
# Stale-recovery: clear if master is provably gone (busy lock invalid AND
# pending exceeds TTL). On stale-clear, REVERT all state for in-flight
# entries so daemon re-wakes instead of going silent on master crash.
# Reverts:
#   - NOTIFIED_HASH[$pane]      (so stable wake re-fires on same hash)
#   - LAST_EVENT_KEY[$pane|$hash|$tag]  (so event re-appends on next wake)
#   - LAST_BELL_HASH[$pane]     (only if entry was bell-triggered)
clear_stale_wake_pending() {
  local master_id="$1"
  local -n notified_ref="$2"
  local -n event_key_ref="$3"
  local -n bell_hash_ref="$4"

  # All WAKE_PENDING reads + mutations under SESSION_LOCK (round-8 fix).
  exec 206>"$SESSION_LOCK"
  flock 206

  if [[ ! -f "$WAKE_PENDING" ]]; then
    exec 206>&-
    return
  fi

  local delivered age
  delivered=$(jq -r '.delivered_at_epoch // 0' "$WAKE_PENDING" 2>/dev/null || echo 0)
  [[ "$delivered" =~ ^[0-9]+$ ]] || delivered=0
  age=$(( $(date +%s) - delivered ))
  (( age < 0 )) && age=0

  if is_master_busy "$master_id"; then
    exec 206>&-
    return
  fi
  if (( age <= WAKE_PENDING_TTL )); then
    exec 206>&-
    return
  fi

  local in_flight
  in_flight=$(jq -r '.in_flight[]? | "\(.pane_id)\t\(.hash)\t\(.tag)\t\(.is_bell // false)"' "$WAKE_PENDING" 2>/dev/null || echo "")
  while IFS=$'\t' read -r p h t is_bell; do
    [[ -z "$p" ]] && continue
    if [[ "${notified_ref[$p]:-}" == "$h" ]]; then
      unset 'notified_ref[$p]'
    fi
    local ek="${p}|${h}|${t}"
    if [[ -n "${event_key_ref[$ek]:-}" ]]; then
      unset 'event_key_ref[$ek]'
    fi
    if [[ "$is_bell" == "true" ]] && [[ "${bell_hash_ref[$p]:-}" == "$h" ]]; then
      unset 'bell_hash_ref[$p]'
    fi
    log wake-pending-revert "reverted state for $p hash=$h tag=$t bell=$is_bell"
  done <<< "$in_flight"

  log wake-pending-stale "age=${age}s > TTL=${WAKE_PENDING_TTL}s, no busy lock; clearing"
  rm -f "$WAKE_PENDING"
  exec 206>&-
}

# --- Wake delivery -------------------------------------------------------------

# Build the wake message payload for a given master harness. Each TUI
# parses commands with its own grammar prefix; sending the slash form to
# codex (which uses `$` for commands) or to a Pi session via the bridge
# (slash/skill expansion is bypassed) means the master LLM only sees raw
# text it has to interpret rather than a real command invocation
# (cross-harness review finding #1). Default keeps the legacy slash form
# for unspecified harnesses so existing claude/opencode behavior is
# unchanged.
# Pi uses /skill:flightdeck now that pi-session-bridge expands skill
# commands client-side before sendUserMessage (vstack#13). If the bridge
# is unavailable, the pi fallback uses tmux send-keys -l rather than
# paste-buffer so the slash text enters Pi's editor input path.
wake_payload_for_harness() {
  case "${1:-}" in
    codex) printf '%s' '$flightdeck watch --from-daemon' ;;
    pi)    printf '%s' '/skill:flightdeck watch --from-daemon' ;;
    *)     printf '%s' '/flightdeck watch --from-daemon' ;;
  esac
}

# Resolve the pi-bridge pid for a pi master pane. Pi runs in alt-screen mode
# and reads keyboard input through its own loop, NOT through tmux's pasted
# scrollback; `tmux paste-buffer` writes bytes that pi's UI treats as
# decorative escape sequences and the wake message never lands in the input
# buffer (#4 finding 1). For pi masters we route the wake through
# `pi-bridge send --pid <pid>`, which is the same channel a sibling Pi
# session uses to deliver a follow-up to a peer.
#
# Resolution: ask `pi-bridge list --json`, prefer a bridge pid in the
# master pane's process tree, then use an unambiguous cwd + /proc + pane-tty
# match. Cheap (single CLI call per wake) and self-healing if the master pi
# restarts between wakes.
resolve_pi_master_pid() {
  local master_id="$1"
  local bridge_bin; bridge_bin=$(pi_resolve_bridge_bin 2>/dev/null) || return 1
  local out
  out=$("$bridge_bin" list --json 2>/dev/null) || return 1
  [[ -z "$out" || "$out" == "null" ]] && return 1

  # Prefer matching the master pane's process tree to the bridge pid: the
  # pane's shell pid is the parent of the running pi process, and bridge
  # entries record the pi pid. This avoids the cwd-only ambiguity where
  # two pi sessions sharing a cwd (e.g., master + a sibling worktree
  # pane) could be confused for each other (bugs review finding #7).
  local master_shell_pid
  master_shell_pid=$(tmux display-message -t "$master_id" -p '#{pane_pid}' 2>/dev/null || echo "")
  if [[ "$master_shell_pid" =~ ^[1-9][0-9]*$ ]]; then
    # Collect the full descendant tree plus the pane pid itself: tmux may
    # report the pi process directly when the pane was launched without an
    # intermediate shell, and deeper wrappers can put pi below grandchildren.
    local descendants descendants_json
    descendants=$(printf '%s\n' "$master_shell_pid"; collect_descendants "$master_shell_pid" 2>/dev/null || true)
    descendants_json=$(printf '%s\n' "$descendants" | awk 'NF && $1 ~ /^[0-9]+$/ {print $1}' | sort -u | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)' 2>/dev/null || echo "[]")
    if [[ "$descendants_json" != "[]" ]]; then
      local pid_by_tree
      pid_by_tree=$(jq -r --argjson tree "$descendants_json" '
        ( . // [] )
        | map(select(.pid as $p | $tree | index($p)))
        | last
        | (.pid // empty)
      ' <<< "$out" 2>/dev/null)
      if [[ -n "$pid_by_tree" && "$pid_by_tree" != "null" ]]; then
        echo "$pid_by_tree"
        return 0
      fi
    fi
  fi

  # Fallback: cwd + process identity match. Cwd alone is ambiguous when
  # two Pi sessions share a repo. Intersect bridge entries with real `pi`
  # processes whose /proc cwd matches the master pane, then prefer a pid
  # attached to the master pane's tty. If more than one candidate remains,
  # fail closed so wake_master falls back to tmux instead of sending the
  # wake to the wrong Pi session.
  local master_cwd master_tty
  master_cwd=$(tmux display-message -t "$master_id" -p '#{pane_current_path}' 2>/dev/null || echo "")
  [[ -z "$master_cwd" ]] && return 1
  master_tty=$(tmux display-message -t "$master_id" -p '#{pane_tty}' 2>/dev/null || echo "")

  local bridge_cwd_pids
  bridge_cwd_pids=$(jq -r --arg dir "$master_cwd" '
    ( . // [] )
    | map(select((.cwd // "") == $dir))
    | sort_by(.startedAt // .started_at // 0)
    | .[].pid
  ' <<< "$out" 2>/dev/null)
  [[ -z "$bridge_cwd_pids" ]] && return 1

  local pi_cwd_pids
  pi_cwd_pids=$(pgrep -a -f '(^|/)pi( |$)' 2>/dev/null | while read -r p _cmd; do
    [[ "$p" =~ ^[1-9][0-9]*$ ]] || continue
    local pcwd
    pcwd=$(readlink -f "/proc/$p/cwd" 2>/dev/null || echo "")
    [[ "$pcwd" == "$master_cwd" ]] && echo "$p"
  done | sort -u)
  [[ -z "$pi_cwd_pids" ]] && return 1

  local candidates=() tty_candidates=() p fd_target
  for p in $bridge_cwd_pids; do
    [[ "$p" =~ ^[1-9][0-9]*$ ]] || continue
    grep -qx "$p" <<< "$pi_cwd_pids" || continue
    kill -0 "$p" 2>/dev/null || continue
    candidates+=("$p")
    if [[ -n "$master_tty" ]]; then
      for _fd in 0 1 2; do
        fd_target=$(readlink -f "/proc/$p/fd/$_fd" 2>/dev/null || echo "")
        if [[ "$fd_target" == "$master_tty" ]]; then
          tty_candidates+=("$p")
          break
        fi
      done
    fi
  done

  if (( ${#tty_candidates[@]} == 1 )); then
    echo "${tty_candidates[0]}"
    return 0
  fi
  if (( ${#candidates[@]} == 1 )); then
    echo "${candidates[0]}"
    return 0
  fi
  return 1
}

# wake_master takes master_id, joined reason string, and an in-flight JSON
# array of {pane_id, hash} entries. Records the in-flight list in
# WAKE_PENDING so stale-recovery can revert NOTIFIED_HASH on master crash.
wake_master() {
  local master_id="$1" combined="$2" in_flight_json="$3"

  # All WAKE_PENDING mutations under SESSION_LOCK (round-8 fix).
  exec 204>"$SESSION_LOCK"
  flock 204

  if [[ -f "$WAKE_PENDING" ]]; then
    log skip-wake "wake-pending already in flight"
    exec 204>&-
    return 1
  fi
  if is_master_busy "$master_id"; then
    log skip-wake "master busy ($combined)"
    exec 204>&-
    return 1
  fi
  local target
  target=$(pane_target_from_id "$master_id")
  if [[ -z "$target" ]]; then
    log master-gone "master pane $master_id no longer resolvable"
    exec 204>&-
    return 1
  fi

  # Pre-mark pending atomically via temp+mv. Master clears at turn-end via ack.
  local now_iso now_epoch tmp_pending
  now_iso=$(date -Iseconds)
  now_epoch=$(date +%s)
  tmp_pending="${WAKE_PENDING}.tmp.$$"
  if ! jq -nc --arg ts "$now_iso" \
        --argjson epoch "$now_epoch" \
        --arg mid "$master_id" \
        --argjson dpid $$ \
        --argjson inflight "$in_flight_json" \
        '{delivered_at:$ts, delivered_at_epoch:$epoch, master_pane_id:$mid, daemon_pid:$dpid, in_flight:$inflight}' \
    > "$tmp_pending"; then
    log wake-fail "wake-pending write failed"
    rm -f "$tmp_pending"
    exec 204>&-
    return 1
  fi
  mv "$tmp_pending" "$WAKE_PENDING"
  exec 204>&-

  # Wake delivery happens AFTER releasing SESSION_LOCK to avoid blocking
  # daemon's append paths during tmux IO. If delivery fails, we re-take the
  # lock to clean up wake-pending atomically.

  # Pi master: use pi-bridge first so /skill:flightdeck expands inline via
  # session-bridge (vstack#13). If the bridge is unavailable, fall back to
  # send-keys -l + Enter so tmux writes into Pi's editor input path instead
  # of paste-buffer scrollback.
  local wake_payload
  wake_payload=$(wake_payload_for_harness "$MASTER_HARNESS")

  if [[ "$MASTER_HARNESS" == "pi" ]]; then
    local bridge_bin master_pid
    bridge_bin=$(pi_resolve_bridge_bin 2>/dev/null || echo "")
    master_pid=$(resolve_pi_master_pid "$master_id" || echo "")
    if [[ -n "$bridge_bin" && -n "$master_pid" ]]; then
      # 10s timeout caps the worst case if the bridge socket hangs;
      # pi-bridge send normally returns in <100ms (ack from bridge
      # daemon, not from master turn completion).
      if timeout 10 "$bridge_bin" send --pid "$master_pid" "$wake_payload" >/dev/null 2>&1; then
        log wake "master=$master_id harness=pi via=pi-bridge pid=$master_pid reasons=$combined"
        return 0
      fi
      log wake-fail "pi-bridge send failed pid=$master_pid; falling back to tmux send-keys"
    else
      log wake-fail "pi master bridge unresolved (bin=${bridge_bin:-missing} pid=${master_pid:-unknown}); falling back to tmux send-keys"
    fi

    if ! tmux send-keys -t "$target" -l "$wake_payload" 2>/dev/null; then
      log wake-fail "send-keys -l failed"
      locked_rm_wake_pending
      return 1
    fi
    if ! tmux send-keys -t "$target" Enter 2>/dev/null; then
      log wake-fail "send-keys Enter failed"
      locked_rm_wake_pending
      return 1
    fi
    log wake "master=$master_id harness=pi via=tmux-send-keys reasons=$combined"
    return 0
  fi

  local buffer_name="fd-wake-${SESSION_KEY}"
  if ! printf '%s' "$wake_payload" | tmux load-buffer -b "$buffer_name" -; then
    log wake-fail "load-buffer failed"
    locked_rm_wake_pending
    return 1
  fi
  if ! tmux paste-buffer -p -t "$target" -b "$buffer_name" -d 2>/dev/null; then
    log wake-fail "paste-buffer failed"
    locked_rm_wake_pending
    return 1
  fi
  if ! tmux send-keys -t "$target" Enter 2>/dev/null; then
    log wake-fail "send-keys Enter failed"
    locked_rm_wake_pending
    return 1
  fi
  log wake "master=$master_id harness=${MASTER_HARNESS:-?} via=tmux reasons=$combined"
  return 0
}

# Helper to remove WAKE_PENDING under SESSION_LOCK.
locked_rm_wake_pending() {
  exec 205>"$SESSION_LOCK"
  flock 205
  rm -f "$WAKE_PENDING"
  exec 205>&-
}

# Helper for lifecycle cleanup of all per-session wake/event state.
# --nonblock: skip if lock can't be acquired immediately (used in signal traps
# to avoid self-deadlock if the trap fires while we already hold the lock).
# Subshell-test for exec to avoid permanent stderr redirection.
locked_state_cleanup() {
  local nonblock=""
  [[ "${1:-}" == "--nonblock" ]] && nonblock="-n"

  if ! ( exec 207>"$SESSION_LOCK" ) 2>/dev/null; then
    return 0
  fi
  exec 207>"$SESSION_LOCK"
  if ! flock $nonblock 207; then
    exec 207>&-
    return 0
  fi
  rm -f "$WAKE_PENDING" "$EVENTS_FILE"
  [[ -n "${WAKE_EVENTS_LOG:-}" ]] && rm -f "$WAKE_EVENTS_LOG"
  shopt -s nullglob
  local f
  for f in "$EVENTS_FILE".draining.*; do
    rm -f "$f"
  done
  if [[ -n "${WAKE_EVENTS_LOG:-}" ]]; then
    for f in "$WAKE_EVENTS_LOG".draining.*; do
      rm -f "$f"
    done
  fi
  shopt -u nullglob
  exec 207>&-
}

# Lifecycle cleanup for an arbitrary session key (used by gc_orphan_state).
# Takes that session's own SESSION_LOCK non-blocking; safe even if a
# concurrent daemon is starting for the same key (very unlikely path).
# Also removes any stranded `.draining.*` snapshots under the same lock.
# Note: subshell-test for exec to avoid permanent stderr redirection.
locked_cleanup_for_key() {
  local key="$1"
  local lock="$STATE_DIR/fd-daemon-${key}.session-lock"
  local wp="$STATE_DIR/fd-wake-pending-${key}"
  local ef="$STATE_DIR/fd-daemon-events-${key}.jsonl"
  local wel="$STATE_DIR/fd-wake-events-${key}.log"

  if ! ( exec 208>"$lock" ) 2>/dev/null; then
    # Lock file unmakeable; best-effort direct rm.
    rm -f "$wp" "$ef" "$wel" "$ef".draining.* "$wel".draining.*
    return
  fi
  exec 208>"$lock"
  if flock -n 208; then
    rm -f "$wp" "$ef" "$wel"
    shopt -s nullglob
    local f
    for f in "$ef".draining.* "$wel".draining.*; do
      rm -f "$f"
    done
    shopt -u nullglob
  fi
  exec 208>&-
}

# --- Events JSONL with dedup ---------------------------------------------------
# Dedup key: (pane_id, hash, tag) — `reason` and `stable_age_sec` are payload
# but not part of the key, so longer-stable updates don't bypass dedup.
declare -A LAST_EVENT_KEY  # pane_id|hash|tag → 1

append_event() {
  local pane_id="$1" hash="$2" tag="$3" reason="$4" age="${5:-0}" is_bell="${6:-false}" extra_json="${7:-null}"
  local key="${pane_id}|${hash}|${tag}"
  if [[ -n "${LAST_EVENT_KEY[$key]:-}" ]]; then
    return
  fi
  LAST_EVENT_KEY[$key]=1

  # Single session-wide lock for all events + wake-pending mutations.
  exec 202>"$SESSION_LOCK"
  flock 202
  jq -nc --arg ts "$(date -Iseconds)" \
        --arg pid "$pane_id" \
        --arg hash "$hash" \
        --arg tag "$tag" \
        --arg reason "$reason" \
        --argjson age "$age" \
        --argjson extra "$extra_json" \
        '{ts:$ts, pane_id:$pid, hash:$hash, tag:$tag, reason:$reason, stable_age_sec:$age} + (if $extra == null then {} else {details:$extra} end)' >> "$EVENTS_FILE"
  # If a wake is already in flight, extend in_flight under the same lock.
  if [[ -f "$WAKE_PENDING" ]]; then
    local tmp="${WAKE_PENDING}.tmp.$$"
    if jq --arg p "$pane_id" --arg h "$hash" --arg t "$tag" --argjson ib "$is_bell" \
       '.in_flight += [{pane_id:$p, hash:$h, tag:$t, is_bell:$ib}]' \
       "$WAKE_PENDING" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$WAKE_PENDING"
    else
      rm -f "$tmp"
    fi
  fi
  exec 202>&-
}

# Recover any stranded `.draining.<pid>` snapshots from prior killed drains.
# If owning PID is dead (or 0/missing), fold the file into our drain output.
recover_stranded_drains() {
  shopt -s nullglob
  local f pid_part
  for f in "${EVENTS_FILE}".draining.*; do
    pid_part="${f##*.draining.}"
    if [[ ! "$pid_part" =~ ^[0-9]+$ ]]; then
      cat "$f"
      rm -f "$f"
      continue
    fi
    if ! kill -0 "$pid_part" 2>/dev/null; then
      cat "$f"
      rm -f "$f"
    fi
  done
  shopt -u nullglob
}

# Atomic events drain. Locked against append_event via SESSION_LOCK. Does
# NOT clear wake-pending — use `ack` for that. `events` is for turn-start
# (drain hint without ack); `ack` is for turn-end (drain + clear pending).
drain_events() {
  exec 201>"$SESSION_LOCK"
  flock 201
  recover_stranded_drains
  if [[ -f "$EVENTS_FILE" ]]; then
    local snap="${EVENTS_FILE}.draining.$$"
    if mv "$EVENTS_FILE" "$snap" 2>/dev/null; then
      cat "$snap"
      rm -f "$snap"
    fi
  fi
  exec 201>&-
}

# Atomic ack: drains events AND clears wake-pending under the SAME lock so
# master's turn-end is race-free with daemon's append_event/extend_in_flight.
# This is the contract master MUST use to clear wake-pending — bare `rm`
# leaves a window where daemon could extend in_flight after master drained
# but before master cleared, orphaning an event.
ack_and_drain() {
  exec 201>"$SESSION_LOCK"
  flock 201
  recover_stranded_drains
  if [[ -f "$EVENTS_FILE" ]]; then
    local snap="${EVENTS_FILE}.draining.$$"
    if mv "$EVENTS_FILE" "$snap" 2>/dev/null; then
      cat "$snap"
      rm -f "$snap"
    fi
  fi
  rm -f "$WAKE_PENDING"
  exec 201>&-
}

# --- Bell clear (stable window-id targeting) -----------------------------------
clear_bell_for_window() {
  local win_id="$1"
  # Capture currently-focused window-id to restore after select cycle.
  local orig_wid
  orig_wid=$(tmux display-message -p -t "$SESSION_ID" '#{window_id}' 2>/dev/null) || return
  [[ -z "$orig_wid" ]] && return
  # Atomic chained select.
  tmux select-window -t "$win_id" \; select-window -t "$orig_wid" 2>/dev/null || true
}

# --- Opencode HTTP-attach subscriber ------------------------------------------
# Per-opencode-pane subprocess that polls /session/<id>/message at
# OC_POLL_SEC cadence, classifies the last assistant text, and appends a
# normalized turn-end event to the wake-events log under SESSION_LOCK.
# Replaces the per-tick capture-pane → hash → classify path for opencode
# panes with adapter metadata in the registry.
PANE_REGISTRY="$_daemon_script_dir/pane-registry"
WAKE_EVENTS_LOG=$(oc_wake_events_log "$SESSION_KEY")

pane_registry_find_id() {
  local target="$1" raw
  raw=$("$PANE_REGISTRY" find-by-pane "$target" 2>/dev/null || true)
  if [[ "$raw" == \{* ]]; then
    jq -r '.id // empty' <<< "$raw" 2>/dev/null || true
  else
    printf '%s' "$raw"
  fi
}

oc_bell_marker_file() {
  local pane_id="$1"
  printf '%s/oc-bell-%s' "$STATE_DIR" "$(oc_pane_id_safe "$pane_id")"
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

touch_oc_bell_marker() {
  local pane_id="$1" marker
  marker=$(oc_bell_marker_file "$pane_id")
  printf '%s\n' "$(date +%s%N)" > "$marker" 2>/dev/null || touch "$marker" 2>/dev/null || true
}

oc_subscriber_loop() {
  # Run defensively: don't let the parent's set -e/pipefail kill the
  # subscriber on a transient curl/jq hiccup. We log + retry on the
  # next tick instead.
  set +e
  set +o pipefail
  # Close inherited FDs that hold daemon-level locks (PID_LOCK on
  # FD 200, etc.). Subscribers shouldn't keep those locks alive past
  # the daemon's lifetime — otherwise stop+restart races for several
  # seconds while subscribers reap.
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
  # Comma-bracketed list of question request_ids we've already emitted
  # for this pane, e.g., ",que_abc,que_def,". Lookup uses substring
  # match. Resets only on subscriber restart — once a question is
  # emitted, we won't re-emit even if the master takes a while to
  # answer; the daemon's NOTIFIED_HASH dedup handles wake-side
  # idempotency.
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

    # --- Question-tool poll (always-on; cheap when no questions are
    # pending). The opencode HTTP server is per-pane, so /question
    # returns only this pane's pending questions across parent +
    # sub-agent sessions. Emits one wake event per never-before-seen
    # request_id with the full structured payload (header, question
    # text, options, multiple) so master can answer via
    # `pane-respond --question <id> --answer <label>`.
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
            # Adapter input has no TUI footer — pass --no-footer-gate
            # so the classifier doesn't gate option-list / merge / etc
            # detection on a rendered footer that will never exist.
            tag=$(printf '%s' "$last_text" | "$CLASSIFIER" --no-footer-gate 2>/dev/null)
            [[ -z "$tag" ]] && tag="rendering"
          else
            tag="rendering"
          fi
          text_excerpt=$(printf '%s' "$last_text" | awk 'BEGIN{RS=""} {print substr($0,1,1024); exit}')
          printf '%s [oc-sub-emit] pane=%s hash=%s tag=%s text_len=%s\n' \
            "$(date -Iseconds)" "$pane_id" "$hash" "$tag" "${#last_text}" \
            >> "$sub_log" 2>/dev/null || true
          # Append under SESSION_LOCK on a fresh FD so concurrent
          # subscribers + the main loop's drain serialize.
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

# --- Claude Channels JSONL subscriber (Phase 2) -----------------------------
# Per-claude-pane subprocess that tails the session's JSONL transcript
# (~/.claude/projects/<encoded-cwd>/<uuid>.jsonl), filters for
# `.message.role == "assistant"` lines with a non-null stop_reason
# (turn-complete signal), classifies the assistant text, and appends
# normalized turn-end events to fd-wake-events-<KEY>.log under
# SESSION_LOCK. Symmetric with oc_subscriber_loop.
cc_subscriber_loop() {
  set +e
  set +o pipefail
  exec 200<&- 2>/dev/null || true
  local pane_id="$1" transcript="$2" parent_pid="$3"
  local last_hash=""
  local sub_log; sub_log="${LOG}.cc-sub-$(cc_pane_id_safe "$pane_id")"
  printf '%s [cc-sub-start] pane=%s transcript=%s parent=%s\n' \
    "$(date -Iseconds)" "$pane_id" "$transcript" "$parent_pid" \
    >> "$sub_log" 2>/dev/null || true

  # Wait for the transcript to exist (claude creates it on first
  # assistant turn). Sleep + check loop.
  while [[ ! -f "$transcript" ]]; do
    if ! kill -0 "$parent_pid" 2>/dev/null; then exit 0; fi
    sleep 1
  done

  # `tail -F` (capital F) follows even if the file is replaced. jq
  # processes line-by-line; --unbuffered ensures each completion event
  # is emitted as it arrives.
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

spawn_cc_subscriber() {
  local pane_id="$1" transcript="$2"
  local pid_file; pid_file=$(cc_subscriber_pid_file "$pane_id" "$SESSION_KEY")
  if [[ -f "$pid_file" ]]; then
    local existing; existing=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ "$existing" =~ ^[1-9][0-9]*$ ]] && kill -0 "$existing" 2>/dev/null; then
      log cc-subscriber "pane=$pane_id existing pid=$existing; reattaching"
      return 0
    fi
  fi
  cc_subscriber_loop "$pane_id" "$transcript" $$ &
  local sub_pid=$!
  echo "$sub_pid" > "$pid_file"
  log cc-subscriber-spawn "pane=$pane_id pid=$sub_pid transcript=$transcript"
}

# Resolve cc-channel metadata for a pane_target via registry lookup.
resolve_cc_meta() {
  local pane_target="$1"
  local issue
  issue=$(pane_registry_find_id "$pane_target")
  [[ -z "$issue" ]] && return 1
  local args
  args=$("$PANE_REGISTRY" cc-channel-args "$issue" 2>/dev/null || echo "")
  [[ -z "$args" ]] && return 1
  echo "$args"
}

# --- Pi Session Bridge subscriber (Phase 3) ---------------------------------
# Per-pi-pane subprocess that pipes `pi-bridge stream --socket <SOCK>`
# (or --pid fallback) → jq filter for assistant turn-end events,
# classifies, appends to fd-wake-events log.
pi_subscriber_loop() {
  set +e
  set +o pipefail
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

  # Stream bridge events. We emit four classes:
  #   - pi-question: structured pi-questions prompts opened by the child pane.
  #   - pi-subagent-completion: blocked/failed/needs-completion inner persistent-subagent completions.
  #   - pi-bg-task-exit: vstack-background-tasks 'exit' events; daemon wakes master
  #     directly so a bg_task terminal state lands even if the agent's follow-up
  #     turn never fires (vstack#15).
  #   - normal assistant turn-end text events, classified through prompt-classify.
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
        # vstack#15: dispatch through the shared helper in
        # lib/daemon-bg-task-events.sh so this file does not grow on
        # new event classes.
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

spawn_pi_subscriber() {
  local pane_id="$1" pi_pid="$2" pi_socket="${3:-}"
  local pid_file; pid_file=$(pi_subscriber_pid_file "$pane_id" "$SESSION_KEY")
  if [[ -f "$pid_file" ]]; then
    local existing; existing=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ "$existing" =~ ^[1-9][0-9]*$ ]] && kill -0 "$existing" 2>/dev/null; then
      log pi-subscriber "pane=$pane_id existing pid=$existing; reattaching"
      return 0
    fi
  fi
  local parent_pid=$$
  (
    set +e
    set +o pipefail
    exec 200<&- 2>/dev/null || true
    local rc sub_log
    sub_log="${LOG}.pi-sub-$(pi_pane_id_safe "$pane_id")"
    while kill -0 "$parent_pid" 2>/dev/null; do
      pi_subscriber_loop "$pane_id" "$pi_pid" "$pi_socket" "$parent_pid"
      rc=$?
      kill -0 "$parent_pid" 2>/dev/null || exit 0
      printf '%s [pi-sub-restart] pane=%s stream exited rc=%s; reconnecting in 1s\n' \
        "$(date -Iseconds)" "$pane_id" "$rc" >> "$sub_log" 2>/dev/null || true
      sleep 1
    done
  ) &
  local sub_pid=$!
  echo "$sub_pid" > "$pid_file"
  log pi-subscriber-spawn "pane=$pane_id pid=$sub_pid pi_pid=$pi_pid socket=$pi_socket"
}

resolve_pi_meta() {
  local pane_target="$1"
  local issue
  issue=$(pane_registry_find_id "$pane_target")
  [[ -z "$issue" ]] && return 1
  local args
  args=$("$PANE_REGISTRY" pi-bridge-args "$issue" 2>/dev/null || echo "")
  [[ -z "$args" ]] && return 1
  echo "$args"
}

# --- Codex bridge subscriber (Phase 4) --------------------------------------
# Per-codex-pane subprocess that pipes `cx_bridge_run stream` through
# jq filtered for thread/status/changed → idle events. On each idle,
# fetches the thread's last assistant text and emits a wake event.
cx_subscriber_loop() {
  set +e
  set +o pipefail
  exec 200<&- 2>/dev/null || true
  local pane_id="$1" cx_url="$2" thread_id="$3" parent_pid="$4"
  local last_hash=""
  local sub_log; sub_log="${LOG}.cx-sub-$(cx_pane_id_safe "$pane_id")"
  printf '%s [cx-sub-start] pane=%s url=%s thread=%s parent=%s\n' \
    "$(date -Iseconds)" "$pane_id" "$cx_url" "$thread_id" "$parent_pid" \
    >> "$sub_log" 2>/dev/null || true

  # Capture bridge + jq stderr to the per-pane log for diagnosis.
  cx_bridge_run stream --url "$cx_url" 2>>"$sub_log" \
    | tee -a "$sub_log.raw" \
    | jq --unbuffered -c --arg tid "$thread_id" 'select(.method == "thread/status/changed" and (.params.threadId // .params.thread_id) == $tid and ((.params.status // "") | tostring | test("idle"; "i")))' 2>>"$sub_log" \
    | while IFS= read -r line; do
      if ! kill -0 "$parent_pid" 2>/dev/null; then exit 0; fi
      [[ -z "$line" ]] && continue
      # Fetch last assistant text via turns/list.
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

spawn_cx_subscriber() {
  local pane_id="$1" cx_url="$2" thread_id="$3"
  local pid_file; pid_file=$(cx_subscriber_pid_file "$pane_id" "$SESSION_KEY")
  if [[ -f "$pid_file" ]]; then
    local existing; existing=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ "$existing" =~ ^[1-9][0-9]*$ ]] && kill -0 "$existing" 2>/dev/null; then
      log cx-subscriber "pane=$pane_id existing pid=$existing; reattaching"
      return 0
    fi
  fi
  local parent_pid=$$
  (
    set +e
    set +o pipefail
    exec 200<&- 2>/dev/null || true
    local rc sub_log
    sub_log="${LOG}.cx-sub-$(cx_pane_id_safe "$pane_id")"
    while kill -0 "$parent_pid" 2>/dev/null; do
      cx_subscriber_loop "$pane_id" "$cx_url" "$thread_id" "$parent_pid"
      rc=$?
      kill -0 "$parent_pid" 2>/dev/null || exit 0
      printf '%s [cx-sub-restart] pane=%s stream exited rc=%s; reconnecting in 1s\n' \
        "$(date -Iseconds)" "$pane_id" "$rc" >> "$sub_log" 2>/dev/null || true
      sleep 1
    done
  ) &
  local sub_pid=$!
  echo "$sub_pid" > "$pid_file"
  log cx-subscriber-spawn "pane=$pane_id pid=$sub_pid url=$cx_url thread=$thread_id"
}

resolve_cx_meta() {
  local pane_target="$1"
  local issue
  issue=$(pane_registry_find_id "$pane_target")
  [[ -z "$issue" ]] && return 1
  local args
  args=$("$PANE_REGISTRY" cx-bridge-args "$issue" 2>/dev/null || echo "")
  [[ -z "$args" ]] && return 1
  echo "$args"
}

spawn_oc_subscriber() {
  local pane_id="$1" oc_url="$2" session_id="$3"
  local pid_file; pid_file=$(oc_subscriber_pid_file "$pane_id" "$SESSION_KEY")
  if [[ -f "$pid_file" ]]; then
    local existing; existing=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ "$existing" =~ ^[1-9][0-9]*$ ]] && kill -0 "$existing" 2>/dev/null; then
      log oc-subscriber "pane=$pane_id existing pid=$existing; reattaching"
      return 0
    fi
  fi
  oc_subscriber_loop "$pane_id" "$oc_url" "$session_id" $$ &
  local sub_pid=$!
  echo "$sub_pid" > "$pid_file"
  log oc-subscriber-spawn "pane=$pane_id pid=$sub_pid url=$oc_url session=$session_id"
}

# Recursively collect descendant PIDs (children, grandchildren, ...)
# of the given PID. Used by kill_all_oc_subscribers to reap pipeline
# children (e.g., `tail -F | jq` chains) that bash backgrounded
# subscribers spawn — those would otherwise orphan and keep daemon-
# inherited FDs (notably PID_LOCK on FD 200) alive past the daemon's
# lifetime, blocking restarts.
collect_descendants() {
  local pid="$1"
  local children
  children=$(pgrep -P "$pid" 2>/dev/null)
  if [[ -n "$children" ]]; then
    local c
    for c in $children; do
      echo "$c"
      collect_descendants "$c"
    done
  fi
}

kill_all_oc_subscribers() {
  # Glob is scoped to this session's key. Without the scope, this would
  # reap subscribers belonging to other concurrent flightdeck daemons in
  # the same shared state dir (bugs review finding #3).
  shopt -s nullglob
  local f pid descendants
  for f in "$STATE_DIR"/fd-subscriber-"${SESSION_KEY}"-*.pid "$STATE_DIR"/fd-cc-subscriber-"${SESSION_KEY}"-*.pid "$STATE_DIR"/fd-pi-subscriber-"${SESSION_KEY}"-*.pid "$STATE_DIR"/fd-cx-subscriber-"${SESSION_KEY}"-*.pid; do
    pid=$(cat "$f" 2>/dev/null || echo "")
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      # Reap the entire descendant tree (pipeline children) BEFORE
      # killing the subscriber itself — order matters so we don't
      # lose track of children when the subscriber dies and its
      # children get reparented to init.
      descendants=$(collect_descendants "$pid")
      if [[ -n "$descendants" ]]; then
        # shellcheck disable=SC2086
        kill $descendants 2>/dev/null || true
      fi
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$f"
  done
  shopt -u nullglob
}

# Recover any stranded `${WAKE_EVENTS_LOG}.draining.<pid>` snapshots from
# prior killed drains. Symmetric with recover_stranded_drains for
# EVENTS_FILE: if the owning PID is dead (or 0/missing), fold the file
# into our drain output so events from a crashed drain are not lost.
recover_stranded_oc_drains() {
  shopt -s nullglob
  local f pid_part
  for f in "${WAKE_EVENTS_LOG}".draining.*; do
    pid_part="${f##*.draining.}"
    if [[ ! "$pid_part" =~ ^[0-9]+$ ]]; then
      cat "$f"
      rm -f "$f"
      continue
    fi
    if ! kill -0 "$pid_part" 2>/dev/null; then
      cat "$f"
      rm -f "$f"
    fi
  done
  shopt -u nullglob
}

# Atomically drain the wake-events log under SESSION_LOCK. Each line is
# emitted as a JSONL record; caller consumes line-by-line. Snapshot+rm
# pattern matches drain_events: lock-held read+remove guarantees no
# subscriber can append a record we miss. Stranded snapshots from prior
# killed drains are folded back in via recover_stranded_oc_drains.
drain_oc_wake_events() {
  exec 212>"$SESSION_LOCK"
  flock 212
  recover_stranded_oc_drains
  if [[ -f "$WAKE_EVENTS_LOG" ]]; then
    local snap="${WAKE_EVENTS_LOG}.draining.$$"
    if mv "$WAKE_EVENTS_LOG" "$snap" 2>/dev/null; then
      cat "$snap"
      rm -f "$snap"
    fi
  fi
  exec 212>&-
}

# Resolve oc-attach metadata for a pane_target. Looks up the issue via
# pane-registry find-by-pane, then oc-attach-args. Empty stdout when
# either resolution fails — caller falls back to capture-pane loop.
resolve_oc_meta() {
  local pane_target="$1"
  local issue
  issue=$(pane_registry_find_id "$pane_target")
  [[ -z "$issue" ]] && return 1
  local args
  args=$("$PANE_REGISTRY" oc-attach-args "$issue" 2>/dev/null || echo "")
  [[ -z "$args" ]] && return 1
  echo "$args"
}

# --- Main loop -----------------------------------------------------------------
run_loop() {
  declare -A LAST_HASH HASH_SINCE NOTIFIED_HASH LAST_BELL_HASH LAST_GONE_LOG FIRST_SEEN PANE_HARNESS
  # Initialize associative arrays with `=()` so `${#arr[@]}` reads 0 under
  # `set -u` even before any keys are populated. Bash quirk: `declare -A
  # foo` alone is treated as "not set" for `${#foo[@]}` (raises unbound
  # variable), and `[[ -v foo[@] ]]` is unreliable in 5.x — it returns
  # false even when the array has entries. Explicit `=()` is the only form
  # that lets us read the count safely without a separate guard (#3
  # finding 2).
  declare -A OC_SUBSCRIBED=() OC_PANE_TARGET=()
  # Startup banner — only visible when the daemon runs in --in-tmux-window
  # mode (stdout connected to a tty). In detach mode stdout is the log file
  # so the `-t 1` guard avoids double-writing the same lines.
  if [[ -t 1 ]]; then
    printf '\n'
    printf '  flightdeck-daemon\n'
    printf '    session   %s (%s)\n' "$SESSION_NAME" "$SESSION_KEY"
    printf '    master    %s (harness=%s)\n' "$MASTER_TARGET" "${MASTER_HARNESS:-unset}"
    printf '    inner     %s\n' "${INNER_TARGETS:-(none)}"
    printf '    state dir %s\n' "$STATE_DIR"
    printf '    log       %s\n' "$LOG"
    printf '\n'
    printf '  Live log follows. Closing this window exits the daemon; the master agent\n'
    printf '  will spawn a new one on next start.\n\n'
  fi
  IFS=',' read -r -a INNER_TARGET_ARR <<< "$INNER_TARGETS"
  # Parallel harness list. Caller passes either the same length as
  # --inner (per-pane mapping) or omits it entirely (fallback to global
  # FD_HARNESS or "" for unspecified).
  declare -a INNER_HARNESS_ARR=()
  if [[ -n "$INNER_HARNESSES" ]]; then
    IFS=',' read -r -a INNER_HARNESS_ARR <<< "$INNER_HARNESSES"
    if (( ${#INNER_HARNESS_ARR[@]} != ${#INNER_TARGET_ARR[@]} )); then
      echo "Error: --inner-harnesses count (${#INNER_HARNESS_ARR[@]}) != --inner count (${#INNER_TARGET_ARR[@]})" >&2
      exit 2
    fi
  fi

  local master_id
  master_id=$(resolve_pane_id "$MASTER_TARGET") || {
    echo "Error: cannot resolve master pane '$MASTER_TARGET'" >&2; exit 2; }

  declare -a INNER_IDS=()
  declare -A SEEN_INNER=()
  local idx=0
  for t in "${INNER_TARGET_ARR[@]}"; do
    local id
    id=$(resolve_pane_id "$t") || { echo "Error: cannot resolve inner pane '$t'" >&2; exit 2; }
    if [[ "$id" == "$master_id" ]]; then
      echo "Error: inner pane '$t' resolves to master pane id $master_id (feedback loop)" >&2
      exit 2
    fi
    if [[ -n "${SEEN_INNER[$id]:-}" ]]; then
      echo "Error: duplicate inner pane id $id (target '$t' resolves to already-tracked pane)" >&2
      exit 2
    fi
    SEEN_INNER[$id]=1
    INNER_IDS+=("$id")
    PANE_HARNESS[$id]="${INNER_HARNESS_ARR[$idx]:-$HARNESS}"
    OC_PANE_TARGET[$id]="$t"
    # Pre-increment: returns the new value (always >= 1), so set -e
    # doesn't fire on the first iteration the way (( idx++ )) does
    # (post-increment returns 0 on the initial idx=0).
    (( ++idx ))
  done

  # Spawn opencode + claude subscribers for panes with adapter metadata
  # in the registry. Panes without metadata fall through to the per-tick
  # capture-pane loop (legacy fallback path). Subscribers survive
  # max-lifetime exec; on re-entry, spawn_*_subscriber sees the
  # existing pid file and reattaches without spawning a duplicate.
  for inner_id in "${INNER_IDS[@]}"; do
    case "${PANE_HARNESS[$inner_id]:-}" in
      opencode)
        local _meta _url _sid
        if _meta=$(resolve_oc_meta "${OC_PANE_TARGET[$inner_id]}"); then
          _url=$(awk '{for(i=1;i<=NF;i++)if($i=="--url"){print $(i+1);exit}}' <<< "$_meta")
          _sid=$(awk '{for(i=1;i<=NF;i++)if($i=="--session"){print $(i+1);exit}}' <<< "$_meta")
          if [[ -n "$_url" && -n "$_sid" ]]; then
            spawn_oc_subscriber "$inner_id" "$_url" "$_sid"
            OC_SUBSCRIBED[$inner_id]=1
          fi
        fi
        ;;
      claude)
        local _cmeta _ctranscript
        if _cmeta=$(resolve_cc_meta "${OC_PANE_TARGET[$inner_id]}"); then
          _ctranscript=$(awk '{for(i=1;i<=NF;i++)if($i=="--transcript"){print $(i+1);exit}}' <<< "$_cmeta")
          if [[ -n "$_ctranscript" ]]; then
            spawn_cc_subscriber "$inner_id" "$_ctranscript"
            OC_SUBSCRIBED[$inner_id]=1
          fi
        fi
        ;;
      pi)
        local _pmeta _ppid _psocket
        if _pmeta=$(resolve_pi_meta "${OC_PANE_TARGET[$inner_id]}"); then
          _ppid=$(awk '{for(i=1;i<=NF;i++)if($i=="--pid"){print $(i+1);exit}}' <<< "$_pmeta")
          _psocket=$(awk '{for(i=1;i<=NF;i++)if($i=="--socket"){print $(i+1);exit}}' <<< "$_pmeta")
          if [[ -n "$_ppid" || -n "$_psocket" ]]; then
            spawn_pi_subscriber "$inner_id" "$_ppid" "$_psocket"
            OC_SUBSCRIBED[$inner_id]=1
          fi
        fi
        ;;
      codex)
        local _xmeta _xurl _xthread
        if _xmeta=$(resolve_cx_meta "${OC_PANE_TARGET[$inner_id]}"); then
          _xurl=$(awk '{for(i=1;i<=NF;i++)if($i=="--url"){print $(i+1);exit}}' <<< "$_xmeta")
          _xthread=$(awk '{for(i=1;i<=NF;i++)if($i=="--thread"){print $(i+1);exit}}' <<< "$_xmeta")
          if [[ -n "$_xurl" && -n "$_xthread" ]]; then
            spawn_cx_subscriber "$inner_id" "$_xurl" "$_xthread"
            OC_SUBSCRIBED[$inner_id]=1
          fi
        fi
        ;;
    esac
  done

  local HEARTBEAT_COUNTER=0
  local START_EPOCH; START_EPOCH=$(date +%s)
  local HEARTBEAT_FILE; HEARTBEAT_FILE=$(fd_heartbeat_file "$STATE_DIR" "$SESSION_KEY")

  # Auto-detect master harness when caller didn't pass --master-harness.
  # `pi-bridge list` is authoritative for pi masters: if there's a bridge
  # entry whose cwd matches the master pane's cwd, the master is a pi
  # session and wake delivery must route through pi-bridge first (#4 finding 1).
  # Other harnesses fall through to the tmux paste-buffer path.
  if [[ -z "$MASTER_HARNESS" ]]; then
    if [[ -n "$(resolve_pi_master_pid "$master_id" 2>/dev/null || echo "")" ]]; then
      MASTER_HARNESS="pi"
      log master-harness "auto-detected master harness=pi via pi-bridge list cwd match"
    fi
  fi
  log start "pid=$$ session_id=$SESSION_ID name=$SESSION_NAME master_id=$master_id master_harness=${MASTER_HARNESS:-unknown} inner_ids=${INNER_IDS[*]} oc_subscribed=${#OC_SUBSCRIBED[@]}"
  # Separate traps:
  #   - EXIT: cleanup only (called on natural exit too).
  #   - INT/TERM: cleanup + explicit exit (so SIGTERM from `stop` actually
  #     terminates the daemon, not just runs handler then continues).
  # Both use non-blocking SESSION_LOCK to avoid self-deadlock if signal fires
  # while we already hold the lock.
  # set -u guards: when run_loop aborts before HEARTBEAT_FILE /
  # WAKE_EVENTS_LOG are bound, the trap fires under set -u and
  # `unbound variable` masks the real failure. Use defaults so the trap
  # is always safe to run.
  _on_exit() {
    kill_all_oc_subscribers || true
    rm -f "${PID_FILE:-}" "${HEARTBEAT_FILE:-}" 2>/dev/null || true
    rm -f "${WAKE_EVENTS_LOG:-}" 2>/dev/null || true
    locked_state_cleanup --nonblock || true
    log stop "pid=$$"
  }
  trap '_on_exit' EXIT
  trap '_on_exit; exit 0' INT TERM

  while true; do
    # Watchdog: touch the heartbeat file every tick. Master can read its
    # mtime during watch re-entry to detect a hung daemon (compare to
    # date +%s; stale > FD_HEARTBEAT_TICKS * FD_POLL_SEC + slack means
    # the daemon needs a kick).
    touch "$HEARTBEAT_FILE" 2>/dev/null || true

    # Max-lifetime guard — exec self with the same args after MAX_LIFETIME
    # seconds so long sessions don't accumulate subshell drift, FD bloat,
    # or tmux-query overhead. PID + lock + state files survive exec
    # (same PID, FDs inherited unless CLOEXEC); the new instance just
    # reads through the same setup again with fresh in-memory state.
    if (( MAX_LIFETIME > 0 )); then
      local elapsed=$(( $(date +%s) - START_EPOCH ))
      if (( elapsed >= MAX_LIFETIME )); then
        log max-lifetime "elapsed=${elapsed}s >= MAX_LIFETIME=${MAX_LIFETIME}s; exec self for fresh process"
        # Note: we already hold flock on FD 200 (PID_LOCK). flock survives
        # exec for the same PID, so the new instance's flock -n succeeds
        # (it inherits the lock). PID_FILE keeps our PID, which is correct
        # since exec preserves it.
        exec "$0" "${ORIG_ARGS[@]}"
      fi
    fi

    # Self-exit on session gone.
    if ! session_alive; then
      log session-gone "session_id=$SESSION_ID gone; exiting"
      break
    fi

    # Refresh pane→target/window cache once per tick BEFORE any cache-
    # backed pane_alive checks. The previous order called pane_alive on
    # the master before the first cache populate, so an empty cache made
    # the first tick always log master-gone and exit.
    refresh_pane_cache

    if ! pane_alive "$master_id"; then
      log master-gone "master $master_id gone; exiting"
      break
    fi

    clear_stale_wake_pending "$master_id" NOTIFIED_HASH LAST_EVENT_KEY LAST_BELL_HASH

    local now; now=$(date +%s)
    declare -a tick_reasons=()
    declare -a tick_pending_ids=()
    declare -a tick_pending_hashes=()
    declare -a tick_pending_tags=()    # parallel: tag for each pending entry
    declare -a tick_pending_is_bell=()  # subset of tick_pending_ids that came from bell branch
    declare -a tick_bell_wins=()

    # Drain adapter subscriber events first. Each event is a structured
    # turn-end or question signal from opencode/claude/pi/codex: tag + hash. We
    # apply the same wake-decision pipeline (cold-start grace,
    # NOTIFIED_HASH dedup, canonical-tag check) as the per-pane bell /
    # stable-hash branches below.
    local _wake_events
    _wake_events=$(drain_oc_wake_events)
    if [[ -n "$_wake_events" ]]; then
      while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        local ev_pid ev_hash ev_tag
        ev_pid=$(jq -r '.pane_id // ""' <<< "$_line" 2>/dev/null)
        ev_hash=$(jq -r '.hash // ""' <<< "$_line" 2>/dev/null)
        ev_tag=$(jq -r '.classifier_tag // "rendering"' <<< "$_line" 2>/dev/null)
        [[ -z "$ev_pid" || -z "$ev_hash" ]] && continue
        pane_alive "$ev_pid" || continue
        if [[ -z "${FIRST_SEEN[$ev_pid]:-}" ]]; then
          FIRST_SEEN[$ev_pid]="$now"
        fi
        # No cold-start grace for OC adapter events: cold-start grace
        # exists to suppress TUI banners that incidentally match
        # classifier patterns in tmux capture buffers. Adapter input is
        # structured assistant text only (no chrome) — there's no
        # banner-flicker source for false positives. With grace on,
        # canonical prompts emitted within the first GRACE_SEC seconds
        # were dropped (NOTIFIED_HASH marked them "handled" but they
        # were never routed; subscriber's hash dedup prevented
        # re-emission once stable).
        if [[ "${NOTIFIED_HASH[$ev_pid]:-}" == "$ev_hash" ]]; then
          continue
        fi
        # Distinguish question events from turn-end events in logs +
        # daemon-events source field.
        local _src
        if [[ "$ev_tag" == "oc-question" ]]; then
          _src="oc-question-event"
        elif [[ "$ev_tag" == "pi-question" ]]; then
          _src="pi-question-event"
        elif [[ "$ev_tag" == "pi-subagent-completion" ]]; then
          _src="pi-subagent-completion-event"
        elif [[ "$ev_tag" == "pi-bg-task-exit" ]]; then
          _src="pi-bg-task-exit-event"
        else
          _src="adapter-event"
        fi
        if is_canonical_tag "$ev_tag"; then
          log classify "$ev_pid $_src tag=$ev_tag (canonical)"
          tick_reasons+=("adapter:$ev_pid:$ev_tag")
          tick_pending_ids+=("$ev_pid")
          tick_pending_hashes+=("$ev_hash")
          tick_pending_tags+=("$ev_tag")
          _extra="null"
          if [[ "$ev_tag" == "oc-question" || "$ev_tag" == "pi-question" ]]; then
            _extra=$(jq -c '{event_type, request_id, question, harness}' <<< "$_line" 2>/dev/null || echo 'null')
          elif [[ "$ev_tag" == "pi-subagent-completion" ]]; then
            _extra=$(jq -c '{event_type, completion, harness}' <<< "$_line" 2>/dev/null || echo 'null')
          elif [[ "$ev_tag" == "pi-bg-task-exit" ]]; then
            _extra=$(jq -c '{event_type, task, harness}' <<< "$_line" 2>/dev/null || echo 'null')
          fi
          append_event "$ev_pid" "$ev_hash" "$ev_tag" "$_src" 0 false "$_extra"
        else
          (( VERBOSE == 1 )) && log classify "$ev_pid $_src tag=$ev_tag (non-canonical)"
          NOTIFIED_HASH[$ev_pid]="$ev_hash"
        fi
      done <<< "$_wake_events"
    fi

    for inner_id in "${INNER_IDS[@]}"; do
      if ! pane_alive "$inner_id"; then
        local last_gone="${LAST_GONE_LOG[$inner_id]:-0}"
        if (( now - last_gone > 30 )); then
          log pane-gone "$inner_id no longer exists; skipping"
          LAST_GONE_LOG[$inner_id]="$now"
        fi
        continue
      fi

      # Subscriber-liveness watchdog (bugs review finding #4). Stream
      # subscribers now run under reconnecting wrappers for pi/codex, but
      # the wrapper itself can still die (missing binary, killed process,
      # bad metadata). Verify the subscriber pid is alive each tick; if
      # dead, clear the flag and let this tick fall through to the legacy
      # bell/hash branch below until daemon restart or a later respawn.
      if [[ "${OC_SUBSCRIBED[$inner_id]:-}" == "1" ]]; then
        local _sub_harness="${PANE_HARNESS[$inner_id]:-$HARNESS}"
        local _sub_pid_file="" _sub_pid=""
        case "$_sub_harness" in
          opencode) _sub_pid_file=$(oc_subscriber_pid_file "$inner_id" "$SESSION_KEY") ;;
          claude)   _sub_pid_file=$(cc_subscriber_pid_file "$inner_id" "$SESSION_KEY") ;;
          pi)       _sub_pid_file=$(pi_subscriber_pid_file "$inner_id" "$SESSION_KEY") ;;
          codex)    _sub_pid_file=$(cx_subscriber_pid_file "$inner_id" "$SESSION_KEY") ;;
        esac
        if [[ -n "$_sub_pid_file" && -f "$_sub_pid_file" ]]; then
          _sub_pid=$(cat "$_sub_pid_file" 2>/dev/null || echo "")
        fi
        if [[ "$_sub_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$_sub_pid" 2>/dev/null; then
          # Subscriber alive — skip expensive fallback capture/classify.
          # OpenCode still needs the cheap cached bell check so a backed-off
          # HTTP poller resets promptly when tmux rings the pane bell.
          if [[ "$_sub_harness" == "opencode" ]] && (( $(bell_flag_for_pane "$inner_id") == 1 )); then
            touch_oc_bell_marker "$inner_id"
            local _sub_win_id
            _sub_win_id=$(window_id_for_pane "$inner_id")
            [[ -n "$_sub_win_id" ]] && clear_bell_for_window "$_sub_win_id"
          fi
          continue
        fi
        log subscriber-dead "pane=$inner_id harness=$_sub_harness pid=${_sub_pid:-missing}; clearing OC_SUBSCRIBED and falling back to capture-pane"
        unset 'OC_SUBSCRIBED[$inner_id]'
        rm -f "$_sub_pid_file" 2>/dev/null
        # Fall through to the legacy bell/hash branch below this tick.
      fi

      # Record first sighting for the cold-start grace window. Newly
      # tracked panes (initial spawn or mid-session add) suppress wake
      # delivery for FD_GRACE_SEC so TUI startup banners that happen to
      # match a sentinel don't fire spurious wakes.
      if [[ -z "${FIRST_SEEN[$inner_id]:-}" ]]; then
        FIRST_SEEN[$inner_id]="$now"
      fi
      local pane_age=$(( now - ${FIRST_SEEN[$inner_id]} ))
      local in_grace=0
      (( pane_age < GRACE_SEC )) && in_grace=1

      local target
      target=$(pane_target_from_id "$inner_id")
      [[ -z "$target" ]] && continue
      local win_id
      win_id=$(window_id_for_pane "$inner_id")
      local pane_harness="${PANE_HARNESS[$inner_id]:-$HARNESS}"
      local bell
      bell=$(bell_flag_for_pane "$inner_id")
      local buf
      buf=$(capture_pane "$target" "$pane_harness" || echo "")
      local hash
      hash=$(capture_hash_12 "$buf")
      local stab; stab=$(stability_for_harness "$pane_harness")

      # Per-tick debug-pane hook: log every observation for the targeted
      # pane so missed wakes can be diagnosed without external capture.
      if [[ -n "$DEBUG_PANE" && "$DEBUG_PANE" == "$inner_id" ]]; then
        local _dbg_tag; _dbg_tag=$(classify_buffer "$buf")
        log debug-pane "$inner_id harness=$pane_harness bell=$bell hash=$hash stable=$stab tag=$_dbg_tag in_grace=$in_grace pane_age=${pane_age}s"
      fi

      local prev_hash="${LAST_HASH[$inner_id]:-}"
      local prev_since="${HASH_SINCE[$inner_id]:-0}"

      # Bell — wake unconditionally (user trusts orchestrator bells)
      # EXCEPT during the cold-start grace window where TUI init may
      # ring the bell as part of normal startup.
      if (( bell == 1 )) && (( in_grace == 1 )); then
        log grace-skip "$inner_id bell suppressed during cold-start grace (age=${pane_age}s < ${GRACE_SEC}s)"
        continue
      fi
      if (( bell == 1 )) && [[ "${LAST_BELL_HASH[$inner_id]:-}" != "$hash" ]]; then
        touch_oc_bell_marker "$inner_id"
        local tag; tag=$(classify_buffer "$buf")
        tick_reasons+=("bell:$inner_id:$tag")
        tick_pending_ids+=("$inner_id")
        tick_pending_hashes+=("$hash")
        tick_pending_tags+=("$tag")
        tick_pending_is_bell+=("$inner_id")
        tick_bell_wins+=("$win_id")
        append_event "$inner_id" "$hash" "$tag" "bell" 0 true
        LAST_HASH[$inner_id]="$hash"
        HASH_SINCE[$inner_id]="$now"
        continue
      fi

      if [[ "$hash" != "$prev_hash" ]]; then
        LAST_HASH[$inner_id]="$hash"
        HASH_SINCE[$inner_id]="$now"
        (( VERBOSE == 1 )) && log hash-change "$inner_id $prev_hash -> $hash"
        continue
      fi

      local age=$(( now - prev_since ))
      if (( age >= stab )) && [[ "${NOTIFIED_HASH[$inner_id]:-}" != "$hash" ]]; then
        local tag; tag=$(classify_buffer "$buf")
        # Cold-start grace: classify for visibility but skip wake firing.
        if (( in_grace == 1 )) && is_canonical_tag "$tag"; then
          log grace-skip "$inner_id stable wake suppressed; tag=$tag age=${age}s pane_age=${pane_age}s < ${GRACE_SEC}s"
          NOTIFIED_HASH[$inner_id]="$hash"
          continue
        fi
        # Strict canonical-tag allowlist for stable wakes.
        if is_canonical_tag "$tag"; then
          # Always log canonical classifications at INFO so missed wakes
          # are debuggable from the log alone (no need to grep capture-pane).
          log classify "$inner_id age=${age}s tag=$tag (canonical)"
          tick_reasons+=("stable:$inner_id:$tag(${age}s)")
          tick_pending_ids+=("$inner_id")
          tick_pending_hashes+=("$hash")
          tick_pending_tags+=("$tag")
          # Dedup key uses (pane,hash,tag); age stays as separate JSON field.
          append_event "$inner_id" "$hash" "$tag" "stable" "$age" false
        else
          # Non-canonical → don't wake, but mark notified so we don't
          # re-classify the same hash repeatedly. VERBOSE-only since this
          # is the no-action path.
          (( VERBOSE == 1 )) && log classify "$inner_id age=${age}s tag=$tag (non-canonical)"
          NOTIFIED_HASH[$inner_id]="$hash"
        fi
      fi
    done

    # Heartbeat — emit a periodic "still alive" log line so silent steady
    # state doesn't look indistinguishable from "daemon dead". Cadence is
    # tick-based, not wall-clock, so it scales with FD_POLL_SEC.
    (( ++HEARTBEAT_COUNTER ))
    if (( HEARTBEAT_COUNTER >= HEARTBEAT_TICKS )); then
      HEARTBEAT_COUNTER=0
      local alive_count=0
      for iid in "${INNER_IDS[@]}"; do
        pane_alive "$iid" && (( ++alive_count ))
      done
      local wp_state="absent"
      [[ -f "$WAKE_PENDING" ]] && wp_state="in-flight"
      local bf_state="unlocked"
      [[ -f "$BUSY_FILE" ]] && bf_state="held"
      log heartbeat "panes=${#INNER_IDS[@]} alive=$alive_count wake_pending=$wp_state busy_lock=$bf_state"
    fi

    if (( ${#tick_reasons[@]} > 0 )); then
      local combined; combined=$(IFS='|'; echo "${tick_reasons[*]}")

      # Build in-flight JSON array (records pane_id, hash, tag, is_bell so
      # stale-recovery can revert ALL state on master crash, not just NOTIFIED).
      local in_flight_json
      in_flight_json=$(
        for i in "${!tick_pending_ids[@]}"; do
          local pid="${tick_pending_ids[$i]}"
          local hash="${tick_pending_hashes[$i]}"
          local tag="${tick_pending_tags[$i]}"
          local is_bell="false"
          for bp in "${tick_pending_is_bell[@]}"; do
            [[ "$bp" == "$pid" ]] && { is_bell="true"; break; }
          done
          jq -nc --arg p "$pid" --arg h "$hash" --arg t "$tag" --argjson ib "$is_bell" \
            '{pane_id:$p, hash:$h, tag:$t, is_bell:$ib}'
        done | jq -sc '.'
      )

      if wake_master "$master_id" "$combined" "$in_flight_json"; then
        for i in "${!tick_pending_ids[@]}"; do
          NOTIFIED_HASH[${tick_pending_ids[$i]}]="${tick_pending_hashes[$i]}"
        done
        # LAST_BELL_HASH update: only for entries flagged as bell branch.
        for bell_pane in "${tick_pending_is_bell[@]}"; do
          # Find matching hash from tick_pending arrays.
          for i in "${!tick_pending_ids[@]}"; do
            if [[ "${tick_pending_ids[$i]}" == "$bell_pane" ]]; then
              LAST_BELL_HASH[$bell_pane]="${tick_pending_hashes[$i]}"
              touch_oc_bell_marker "$bell_pane"
              break
            fi
          done
        done
        for w in "${tick_bell_wins[@]}"; do
          [[ -n "$w" ]] && clear_bell_for_window "$w"
        done
      fi
    fi

    sleep "$POLL_SEC"
  done
}

# --- Action dispatch -----------------------------------------------------------
case "$ACTION" in
  start)
    [[ -z "$MASTER_TARGET" || -z "$INNER_TARGETS" ]] && { echo "start needs --master and --inner" >&2; usage; }
    [[ -z "$SESSION_ID" ]] && { echo "Error: tmux session '$SESSION_NAME' not found" >&2; exit 2; }

    # --- Spawn mode dispatch:
    #   detach (default)  → re-exec self with --foreground via setsid + nohup.
    #                        Survives the calling shell. Recommended for
    #                        Claude Code (which has reliable
    #                        run_in_background reparenting).
    #   tmux-window       → spawn a dedicated tmux window inside the same
    #                        session running 'start --foreground'.
    #                        Recommended for codex/opencode/pi/omp where
    #                        backgrounding semantics vary; the tmux session
    #                        is the natural lifetime boundary for a
    #                        flightdeck session anyway.
    # Block until the child writes its PID file so the caller knows the
    # daemon is alive before returning.
    if (( FOREGROUND == 0 )); then
      script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
      # Build child args: original invocation minus mode-selection flags
      # (we'd loop and re-detach), plus --foreground.
      child_args=()
      for a in "${ORIG_ARGS[@]}"; do
        case "$a" in
          --in-tmux-window|--foreground|--no-detach) ;;
          *) child_args+=("$a") ;;
        esac
      done
      child_args+=(--foreground)

      case "$SPAWN_MODE" in
        tmux-window)
          # Spawn a detached tmux window in the master's session running
          # 'start --foreground ...'. The window's lifetime ties to the
          # tmux session; killing the session reaps the daemon.
          window_name="flightdeck-daemon-${SESSION_KEY}"
          # Build the command string for tmux to execute; quote each arg.
          cmd_str=$(printf '%q ' "$script_path" "${child_args[@]}")
          if ! tmux new-window -d -t "$SESSION_ID" -n "$window_name" "$cmd_str" 2>/dev/null; then
            echo "Error: failed to spawn flightdeck-daemon tmux window" >&2
            exit 1
          fi
          ;;
        detach|*)
          # Detach stdio entirely; child appends to LOG via its own log() helper.
          setsid nohup "$script_path" "${child_args[@]}" \
            </dev/null >>"$LOG" 2>&1 &
          child_pid=$!
          ;;
      esac

      deadline=$((SECONDS + 10))
      while (( SECONDS < deadline )); do
        if [[ -f "$PID_FILE" ]]; then
          written_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
          if [[ "$written_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$written_pid" 2>/dev/null; then
            echo "daemon spawned pid=$written_pid session=$SESSION_NAME mode=$SPAWN_MODE"
            exit 0
          fi
        fi
        # Bail early if the detach child died before writing the PID file.
        # tmux-window mode has no parent PID to check (window owns lifetime).
        if [[ "$SPAWN_MODE" == "detach" ]] && ! kill -0 "${child_pid:-0}" 2>/dev/null; then
          echo "Error: detached child (pid=${child_pid:-?}) exited before writing PID file; check $LOG" >&2
          exit 1
        fi
        sleep 0.2
      done
      echo "Error: spawn timed out after 10s ($SPAWN_MODE); check $LOG" >&2
      exit 1
    fi

    exec 200>"$PID_LOCK"
    # Retry briefly: a recently-stopped daemon's flock takes a moment to
    # release after SIGKILL (kernel FD cleanup is async). Subscribers
    # are spawned as backgrounded subshells that inherit FD 200 — they
    # close it on entry now, but pre-existing daemons (or daemons
    # killed before the FD-close fix landed) may still hold it.
    # 30 × 0.2s = 6s grace covers near-all cases.
    _flock_attempts=0
    while ! flock -n 200; do
      _flock_attempts=$(( _flock_attempts + 1 ))
      if (( _flock_attempts >= 30 )); then
        echo "daemon already running for session=$SESSION_NAME (lock held after ${_flock_attempts} retries)" >&2
        exit 1
      fi
      sleep 0.2
    done

    if [[ -f "$PID_FILE" ]]; then
      old=$(cat "$PID_FILE" 2>/dev/null || echo "")
      if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
        # Allow same-pid case: max-lifetime self-exec preserves the PID,
        # so the re-entered start path legitimately sees PID_FILE
        # containing its own pid. Without this allowance the daemon
        # would exit with "race?" immediately after every self-exec
        # (bugs review finding #2).
        if [[ "$old" != "$$" ]]; then
          echo "PID file claims pid=$old which is alive but lock free — race?" >&2
          exit 1
        fi
        log self-exec-resume "reusing pid_file pid=$$ (max-lifetime exec)"
      else
        log refuse-stale "removing stale pid file pid=$old"
      fi
    fi

    # Startup GC: sweep state files for tmux sessions that no longer exist.
    gc_orphan_state

    # Self-check: warn if legacy busy-file locations from pre-#41 layouts
    # still hold files. Master writes via flightdeck-state's master-busy
    # action; that path is now resolved through lib/daemon-paths.sh and
    # MUST agree with the daemon's read path. Stragglers from older
    # versions indicate a stale install or a partial upgrade.
    legacy_busy_candidates=(
      "/tmp/fd-master-${SESSION_KEY}.busy"
    )
    if proj_root=$(git rev-parse --show-toplevel 2>/dev/null); then
      legacy_busy_candidates+=(
        "$proj_root/tmp/fd-master-${SESSION_KEY}.busy"
      )
    fi
    for legacy in "${legacy_busy_candidates[@]}"; do
      [[ "$legacy" == "$BUSY_FILE" ]] && continue
      if [[ -f "$legacy" ]]; then
        warn path-mismatch "legacy busy file at $legacy (current: $BUSY_FILE) — remove it; pre-#41 install"
      fi
    done

    echo $$ > "$PID_FILE"
    # Fresh start: clear any stale wake/event state under SESSION_LOCK.
    locked_state_cleanup
    run_loop
    ;;

  stop)
    [[ ! -f "$PID_FILE" ]] && { echo "no daemon for session=$SESSION_NAME" >&2; exit 1; }
    pid=$(cat "$PID_FILE" 2>/dev/null || echo "")

    # Fail-closed: only kill when we can positively prove the lock is held by
    # another process. Validate PID format → check lock state → kill only if
    # the lock is currently held (daemon is actually running).
    if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
      echo "stale PID file for session=$SESSION_NAME (content=$pid); removing without kill" >&2
      rm -f "$PID_FILE"
      locked_state_cleanup
      exit 0
    fi

    # Lock open + flock test. We open the lock RW and try non-blocking flock.
    # Outcomes:
    #   - file missing OR open fails → ambiguous → REFUSE kill
    #   - flock succeeds → no holder → stale PID file → don't kill
    #   - flock fails (held) → daemon is running → safe to kill
    if [[ ! -f "$PID_LOCK" ]]; then
      echo "PID lock missing for session=$SESSION_NAME; refusing to kill (ambiguous state)" >&2
      exit 1
    fi
    # Open lock file in subshell to test holder without polluting parent stderr.
    # Subshell inherits FDs but redirections don't persist.
    if ( exec 199<>"$PID_LOCK" ) 2>/dev/null; then
      # Re-open in parent shell now that we know it works.
      exec 199<>"$PID_LOCK"
    else
      echo "cannot open PID lock for session=$SESSION_NAME; refusing to kill" >&2
      exit 1
    fi
    if flock -n 199; then
      flock -u 199
      exec 199<&-
      echo "stale PID file for session=$SESSION_NAME (lock free); removing without kill" >&2
      rm -f "$PID_FILE"
      locked_state_cleanup
      exit 0
    fi
    exec 199<&-
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      sleep 0.5
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" || true
      log stop-via-cli "pid=$pid"
    fi
    rm -f "$PID_FILE"
    # Reap subscriber pid files explicitly. Daemon's EXIT trap may not
    # complete cleanly under the SIGTERM-then-SIGKILL race (KILL after
    # 0.5s grace), leaving subscriber pid files behind. Do it from the
    # stop action directly so cleanup is deterministic. Glob is scoped to
    # this session's key so a stop on session A doesn't reap session B's
    # subscribers (bugs review finding #3).
    shopt -s nullglob
    for _sub_file in "$STATE_DIR"/fd-subscriber-"${SESSION_KEY}"-*.pid "$STATE_DIR"/fd-cc-subscriber-"${SESSION_KEY}"-*.pid "$STATE_DIR"/fd-pi-subscriber-"${SESSION_KEY}"-*.pid "$STATE_DIR"/fd-cx-subscriber-"${SESSION_KEY}"-*.pid; do
      _sub_pid=$(cat "$_sub_file" 2>/dev/null || echo "")
      if [[ "$_sub_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$_sub_pid" 2>/dev/null; then
        # Reap pipeline descendants BEFORE the subscriber itself
        # (orphan-prevention; see collect_descendants comment).
        _desc=$(collect_descendants "$_sub_pid")
        if [[ -n "$_desc" ]]; then
          # shellcheck disable=SC2086
          kill $_desc 2>/dev/null || true
        fi
        kill "$_sub_pid" 2>/dev/null || true
      fi
      rm -f "$_sub_file"
    done
    shopt -u nullglob
    locked_state_cleanup
    echo "stopped daemon pid=$pid"
    ;;

  status)
    if [[ -f "$PID_FILE" ]]; then
      pid=$(cat "$PID_FILE")
      if kill -0 "$pid" 2>/dev/null; then
        echo "session=$SESSION_NAME daemon=$pid running session_id=$SESSION_ID"
        exit 0
      fi
      echo "session=$SESSION_NAME pid-file present but pid=$pid dead"
      exit 2
    fi
    echo "session=$SESSION_NAME no daemon"
    exit 1
    ;;

  events)
    drain_events
    ;;

  ack)
    ack_and_drain
    ;;

  find-window)
    # Print the tmux window-id of the daemon's window if it was spawned in
    # tmux-window mode. Empty output (exit 1) when not found.
    [[ -z "$SESSION_ID" ]] && { echo "Error: tmux session '$SESSION_NAME' not found" >&2; exit 1; }
    window_name="flightdeck-daemon-${SESSION_KEY}"
    wid=$(tmux list-windows -t "$SESSION_ID" -F '#{window_id} #{window_name}' 2>/dev/null \
          | awk -v n="$window_name" '$2==n {print $1; exit}')
    if [[ -z "$wid" ]]; then
      exit 1
    fi
    echo "$wid"
    ;;

  health)
    # Operator-friendly diagnosis: PID + last log timestamp + queue + lock state.
    if [[ ! -f "$PID_FILE" ]]; then
      echo "session=$SESSION_NAME no daemon"
      exit 1
    fi
    pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if ! [[ "$pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$pid" 2>/dev/null; then
      echo "session=$SESSION_NAME pid=$pid DEAD (stale pid file)"
      exit 2
    fi
    last_log_line=""
    last_log_ts=""
    if [[ -f "$LOG" ]]; then
      last_log_line=$(tail -n 1 "$LOG" 2>/dev/null)
      last_log_ts=$(awk '{print $1}' <<< "$last_log_line")
    fi
    wp_state="absent"
    wp_in_flight=""
    if [[ -f "$WAKE_PENDING" ]]; then
      wp_state="in-flight"
      wp_in_flight=$(jq -r '[.in_flight[]?] | length' "$WAKE_PENDING" 2>/dev/null || echo "?")
    fi
    bf_state="unlocked"
    bf_pid=""
    if [[ -f "$BUSY_FILE" ]]; then
      bf_state="held"
      bf_pid=$(jq -r '.pid // empty' "$BUSY_FILE" 2>/dev/null)
    fi
    events_count=0
    if [[ -f "$EVENTS_FILE" ]]; then
      events_count=$(wc -l < "$EVENTS_FILE" 2>/dev/null || echo 0)
    fi
    heartbeat_file=$(fd_heartbeat_file "$STATE_DIR" "$SESSION_KEY")
    heartbeat_age="(missing)"
    if [[ -f "$heartbeat_file" ]]; then
      hb_mtime=$(stat -c %Y "$heartbeat_file" 2>/dev/null || stat -f %m "$heartbeat_file" 2>/dev/null || echo "")
      if [[ -n "$hb_mtime" ]]; then
        heartbeat_age="$(( $(date +%s) - hb_mtime ))s"
      fi
    fi
    cat <<EOF
session=$SESSION_NAME session_id=$SESSION_ID daemon_pid=$pid alive=true
state_dir=$STATE_DIR
last_log_ts=${last_log_ts:-"(none)"}
last_log=${last_log_line:-"(empty)"}
heartbeat_age=$heartbeat_age
wake_pending=$wp_state${wp_in_flight:+ in_flight=$wp_in_flight}
busy_lock=$bf_state${bf_pid:+ master_pid=$bf_pid}
events_queued=$events_count
EOF
    ;;

  *)
    echo "unknown action: $ACTION" >&2; usage ;;
esac
