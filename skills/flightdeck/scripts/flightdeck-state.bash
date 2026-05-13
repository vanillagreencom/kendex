#!/usr/bin/env bash
# Master-state CRUD wrapper for flightdeck.
#
# Atomic init/get/set/append/increment on the per-tmux-session master-state
# file (`tmp/flightdeck-state-<TMUX_SESSION>.json` by default). Modeled on
# orchestration/scripts/workflow-state — same locking primitives, different
# file naming convention (session-scoped instead of issue-scoped).
#
# Usage:
#   flightdeck-state init                                    # uses $TMUX session id
#   flightdeck-state init --session <name>                   # explicit
#   flightdeck-state get [--session <name>] <jq-path>        # e.g. .issues
#   flightdeck-state set [--session <name>] <field> <value>  # value is JSON
#   flightdeck-state append [--session <name>] <field> <value>
#   flightdeck-state increment [--session <name>] <field>
#   flightdeck-state archive [--session <name>]              # rotate live file to <file>-<ts>.archive
#   flightdeck-state path [--session <name>]                 # print state file path
#   flightdeck-state phase <ISSUE_ID>                        # derive orchestration phase from workflow-state-<ID>.json
#
# Environment:
#   FLIGHTDECK_STATE_DIR  - state file directory (default: tmp)
#
# Exit codes:
#   0 - success
#   1 - lookup miss / no state file
#   2 - bad arguments
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$PROJECT_ROOT" ]]; then
  echo "Error: not inside a git repository" >&2
  exit 2
fi

# Inside a worktree, resolve to main repo root
_git_common_dir=$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir 2>/dev/null)
if [[ "$_git_common_dir" != ".git" && -n "$_git_common_dir" ]]; then
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && cd "$(dirname "$_git_common_dir")" && pwd)"
fi

ENV_FILE="$PROJECT_ROOT/.env.local"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
elif [[ -f "$PROJECT_ROOT/.env" ]]; then
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/.env"
fi

STATE_DIR="${FLIGHTDECK_STATE_DIR:-tmp}"
STATE_BASE="$PROJECT_ROOT/$STATE_DIR"
mkdir -p "$STATE_BASE"

# Resolve session id
resolve_session() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    echo "$explicit"
    return
  fi
  if [[ -n "${TMUX:-}" ]]; then
    tmux display-message -p '#S' 2>/dev/null
  else
    echo "Error: no \$TMUX session and no --session given" >&2
    exit 2
  fi
}

state_path() {
  echo "$STATE_BASE/flightdeck-state-$1.json"
}

# Accept both bare field names (`terminated`) and explicit jq paths
# (`.issues["CC-486"].state`). Bare names get a leading `.` so the resulting
# jq filter is well-formed; existing path expressions pass through.
normalize_path() {
  local p="$1"
  if [[ "$p" == .* || "$p" == "(."* ]]; then
    echo "$p"
  else
    echo ".$p"
  fi
}

# Atomic update via flock + tmp-file rename. EXIT trap removes the tmp file
# if the script aborts mid-write (signal, jq failure, etc.) so we don't leave
# zero-byte `.tmp.<PID>` orphans piling up next to the live state file.
update_state() {
  local file="$1" jq_filter="$2"
  local lock="${file}.lock"
  local tmp="${file}.tmp.$$"

  trap 'rm -f "$tmp"' EXIT

  exec 9>"$lock"
  flock 9

  if [[ -f "$file" ]]; then
    jq "$jq_filter" "$file" > "$tmp"
  else
    echo '{}' | jq "$jq_filter" > "$tmp"
  fi
  mv "$tmp" "$file"

  exec 9>&-
  trap - EXIT
}

# Sweep stale `.tmp.<PID>` orphans for this state file. Only files whose owner
# PID is no longer running are removed — guards against racing a concurrent
# writer. Called from `init` so each session start cleans up after prior crashes.
gc_tmp_orphans() {
  local file="$1"
  local dir
  dir=$(dirname "$file")
  local base
  base=$(basename "$file")
  shopt -s nullglob
  for orphan in "$dir/$base".tmp.*; do
    local pid="${orphan##*.tmp.}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$orphan"
    fi
  done
  shopt -u nullglob
}

# Owner metadata is additive state written at init time. Test paths can pin
# every value with FLIGHTDECK_OWNER_* env vars; production falls back to the
# current tmux pane + owner process context and Pi bridge discovery when present.
resolve_owner_pid() {
  local pid="${FLIGHTDECK_OWNER_PID:-}"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "$pid"
    return
  fi
  if [[ "${PPID:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "$PPID"
    return
  fi
  echo "Warning: FLIGHTDECK_OWNER_PID unset and parent pid unavailable; using helper pid as owner.pid." >&2
  echo "$$"
}

resolve_owner_pane_id() {
  if [[ -n "${FLIGHTDECK_OWNER_PANE_ID:-}" ]]; then
    echo "$FLIGHTDECK_OWNER_PANE_ID"
    return
  fi
  if [[ -n "${TMUX:-}" ]]; then
    tmux display-message -p '#{pane_id}' 2>/dev/null || true
  fi
}

resolve_owner_pane_target() {
  if [[ -n "${FLIGHTDECK_OWNER_PANE_TARGET:-}" ]]; then
    echo "$FLIGHTDECK_OWNER_PANE_TARGET"
    return
  fi
  if [[ -n "${TMUX:-}" ]]; then
    tmux display-message -p '#S:#{window_index}.#{pane_index}' 2>/dev/null || true
  fi
}

resolve_pi_bridge_metadata() {
  local owner_pid="$1"
  local env_session="${FLIGHTDECK_OWNER_PI_SESSION_ID:-${PI_SESSION_ID:-}}"
  local env_socket="${FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET:-${PI_BRIDGE_SOCKET_PATH:-}}"
  if [[ -n "$env_session" && -n "$env_socket" ]]; then
    printf '%s\t%s\t%s\n' "$env_session" "$env_socket" ""
    return
  fi
  local found_session="" found_socket="" discovery_error=""
  if ! command -v pi-bridge >/dev/null 2>&1; then
    discovery_error="pi_bridge_not_found"
  else
    local json
    local status=0
    local timeout_sec="${FLIGHTDECK_PI_BRIDGE_DISCOVERY_TIMEOUT_SEC:-1}"
    json=$(timeout "${timeout_sec}s" pi-bridge list --json --pid "$owner_pid" 2>&1) || status=$?
    if (( status != 0 )); then
      if (( status == 124 )); then
        discovery_error="pi_bridge_timeout"
      else
        discovery_error="pi_bridge_exit_$status"
      fi
    elif [[ -z "${json//[[:space:]]/}" ]]; then
      discovery_error="pi_bridge_empty_output"
    else
      local line
      local jq_status=0
      line=$(jq -r --arg pid "$owner_pid" '
        if type != "array" then
          ["", "", "pi_bridge_json_not_array"]
        else
          (map(select((.pid | tostring) == $pid)) | .[0] // {}) as $m
          | if $m == {} then
              ["", "", "pi_bridge_no_instance_for_pid"]
            else
              [($m.sessionId // $m.session_id // ""), ($m.socketPath // $m.socket // ""), (if (($m.sessionId // $m.session_id // "") == "" or ($m.socketPath // $m.socket // "") == "") then "pi_bridge_partial_metadata" else "" end)]
            end
        end
        | @tsv
      ' <<< "$json" 2>&1) || jq_status=$?
      if (( jq_status != 0 )); then
        discovery_error="pi_bridge_malformed_json"
      else
        found_session=$(awk -F'\t' '{print $1}' <<< "$line")
        found_socket=$(awk -F'\t' '{print $2}' <<< "$line")
        discovery_error=$(awk -F'\t' '{print $3}' <<< "$line")
      fi
    fi
  fi
  printf '%s\t%s\t%s\n' "${env_session:-$found_session}" "${env_socket:-$found_socket}" "$discovery_error"
}

resolve_owner_harness() {
  local pi_session="$1"
  local pi_socket="$2"
  if [[ -n "${FLIGHTDECK_OWNER_HARNESS:-}" ]]; then
    echo "$FLIGHTDECK_OWNER_HARNESS"
    return
  fi
  if [[ -n "$pi_session" || -n "$pi_socket" ]]; then
    echo "pi"
    return
  fi
  if [[ -n "${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}" ]]; then
    echo "claude"
    return
  fi
  if [[ -n "${OPENCODE_SESSION_ID:-${OPENCODE_APP_INFO:-}}" ]]; then
    echo "opencode"
    return
  fi
  if [[ -n "${CODEX_SESSION_ID:-${CODEX_SANDBOX:-}}" ]]; then
    echo "codex"
    return
  fi
  echo "unknown"
}

# --- Argument parsing -----------------------------------------------------

ACTION="${1:-}"
[[ -z "$ACTION" ]] && { echo "Usage: flightdeck-state <action> [args]" >&2; exit 2; }
shift

SESSION=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    --session=*) SESSION="${1#--session=}"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

SESSION=$(resolve_session "$SESSION")
FILE=$(state_path "$SESSION")

case "$ACTION" in
  path)
    echo "$FILE"
    ;;

  init)
    gc_tmp_orphans "$FILE"
    owner_pid=$(resolve_owner_pid)
    owner_pane_id=$(resolve_owner_pane_id)
    owner_pane_target=$(resolve_owner_pane_target)
    owner_cwd="${FLIGHTDECK_OWNER_CWD:-$PWD}"
    pi_meta=$(resolve_pi_bridge_metadata "$owner_pid")
    owner_pi_session_id=$(awk -F'\t' '{print $1}' <<< "$pi_meta")
    owner_pi_bridge_socket=$(awk -F'\t' '{print $2}' <<< "$pi_meta")
    owner_discovery_error=$(awk -F'\t' '{print $3}' <<< "$pi_meta")
    owner_harness=$(resolve_owner_harness "$owner_pi_session_id" "$owner_pi_bridge_socket")
    if [[ "$owner_harness" == "pi" && ( -z "$owner_pi_session_id" || -z "$owner_pi_bridge_socket" ) ]]; then
      [[ -n "$owner_discovery_error" ]] || owner_discovery_error="pi_bridge_partial_metadata"
      echo "Warning: pi-bridge metadata discovery failed ($owner_discovery_error); proceeding with null pi_session_id/pi_bridge_socket." >&2
    else
      owner_discovery_error=""
    fi
    # Acquire the same lock the update_state helper uses so concurrent
    # `pane-registry init` paths don't race here (bugs review finding #5):
    # one path could pass the `-f $FILE` existence check while another is
    # mid-write, leaving the loser to truncate freshly-written state.
    init_lock="${FILE}.lock"
    init_tmp="${FILE}.tmp.$$"
    trap 'rm -f "$init_tmp"' EXIT
    exec 9>"$init_lock"
    flock 9
    if [[ -f "$FILE" ]]; then
      # Idempotent — don't clobber existing state (compaction-recovery path),
      # but backfill the additive owner block on pre-owner live state files.
      # Stale `terminated: true` files are rotated by `terminate.md § 5` via
      # the `archive` action, so a present file here is always a live session.
      if jq -e '.owner? == null' "$FILE" >/dev/null 2>&1; then
        jq \
          --arg owner_harness "$owner_harness" \
          --arg owner_pane_id "$owner_pane_id" \
          --arg owner_pane_target "$owner_pane_target" \
          --arg owner_cwd "$owner_cwd" \
          --argjson owner_pid "$owner_pid" \
          --arg owner_pi_session_id "$owner_pi_session_id" \
          --arg owner_pi_bridge_socket "$owner_pi_bridge_socket" \
          --arg owner_discovery_error "$owner_discovery_error" \
          'def owner: {
             harness: $owner_harness,
             pane_id: ($owner_pane_id | if . == "" then null else . end),
             pane_target: ($owner_pane_target | if . == "" then null else . end),
             cwd: $owner_cwd,
             pid: $owner_pid,
             pi_session_id: ($owner_pi_session_id | if . == "" then null else . end),
             pi_bridge_socket: ($owner_pi_bridge_socket | if . == "" then null else . end),
             discovery_error: ($owner_discovery_error | if . == "" then null else . end)
           };
           . + {owner: owner}' "$FILE" > "$init_tmp"
        mv "$init_tmp" "$FILE"
      fi
      exec 9>&-
      exit 0
    fi
    started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq -n \
      --arg session_id "$SESSION" \
      --arg started_at "$started_at" \
      --arg owner_harness "$owner_harness" \
      --arg owner_pane_id "$owner_pane_id" \
      --arg owner_pane_target "$owner_pane_target" \
      --arg owner_cwd "$owner_cwd" \
      --argjson owner_pid "$owner_pid" \
      --arg owner_pi_session_id "$owner_pi_session_id" \
      --arg owner_pi_bridge_socket "$owner_pi_bridge_socket" \
      --arg owner_discovery_error "$owner_discovery_error" \
      '{
        session_id: $session_id,
        started_at: $started_at,
        terminated: false,
        owner: {
          harness: $owner_harness,
          pane_id: ($owner_pane_id | if . == "" then null else . end),
          pane_target: ($owner_pane_target | if . == "" then null else . end),
          cwd: $owner_cwd,
          pid: $owner_pid,
          pi_session_id: ($owner_pi_session_id | if . == "" then null else . end),
          pi_bridge_socket: ($owner_pi_bridge_socket | if . == "" then null else . end),
          discovery_error: ($owner_discovery_error | if . == "" then null else . end)
        },
        issues: {},
        merge_queue: [],
        conflict_graph: {edges: [], computed_at: null},
        paused_for_user: null
      }' > "$init_tmp"
    mv "$init_tmp" "$FILE"
    exec 9>&-
    ;;

  get)
    [[ ${#ARGS[@]} -lt 1 ]] && { echo "Usage: get <jq-path>" >&2; exit 2; }
    [[ ! -f "$FILE" ]] && exit 1
    jq -r "${ARGS[0]}" "$FILE"
    ;;

  set)
    [[ ${#ARGS[@]} -lt 2 ]] && { echo "Usage: set <field> <json-value>" >&2; exit 2; }
    field=$(normalize_path "${ARGS[0]}")
    value="${ARGS[1]}"
    update_state "$FILE" "$field = ($value)"
    ;;

  append)
    [[ ${#ARGS[@]} -lt 2 ]] && { echo "Usage: append <field> <json-value>" >&2; exit 2; }
    field=$(normalize_path "${ARGS[0]}")
    value="${ARGS[1]}"
    update_state "$FILE" "$field += [($value)]"
    ;;

  increment)
    [[ ${#ARGS[@]} -lt 1 ]] && { echo "Usage: increment <field>" >&2; exit 2; }
    field=$(normalize_path "${ARGS[0]}")
    update_state "$FILE" "$field = (($field // 0) + 1)"
    ;;

  phase)
    # Derive a one-line orchestration phase descriptor for the dashboard.
    # Reads the issue's workflow-state-<ID>.json (if present) and composes
    # a phase string from existing fields. Falls back to the flightdeck
    # registry's own state field when no orchestration state file exists.
    [[ ${#ARGS[@]} -lt 1 ]] && { echo "Usage: phase <ISSUE_ID>" >&2; exit 2; }
    issue="${ARGS[0]}"
    orch_state_dir="${ORCH_STATE_DIR:-tmp}"
    orch_file="$PROJECT_ROOT/$orch_state_dir/workflow-state-$issue.json"
    if [[ -f "$orch_file" ]]; then
      cycles=$(jq -r '.cycles // 0' "$orch_file" 2>/dev/null)
      review_count=$(jq -r '.review_agents // [] | length' "$orch_file" 2>/dev/null)
      escalated=$(jq -r '.escalated_items // [] | length' "$orch_file" 2>/dev/null)
      pr_review=$(jq -r '.pr_comment_review.iterations // 0' "$orch_file" 2>/dev/null)
      child_count=$(jq -r '.child_sessions // {} | length' "$orch_file" 2>/dev/null)
      parts=()
      (( cycles > 0 ))      && parts+=("cycle=$cycles")
      (( review_count > 0 )) && parts+=("reviewers=$review_count")
      (( pr_review > 0 ))   && parts+=("pr-review=$pr_review")
      (( child_count > 0 )) && parts+=("children=$child_count")
      (( escalated > 0 ))   && parts+=("escalated=$escalated")
      if (( ${#parts[@]} == 0 )); then
        echo "pre-cycle"
      else
        (IFS=' '; echo "${parts[*]}")
      fi
    else
      # No orchestration state — use flightdeck's own view.
      if [[ -f "$FILE" ]]; then
        fd_state=$(jq -r ".issues[\"$issue\"].state // empty" "$FILE" 2>/dev/null)
        if [[ -n "$fd_state" ]]; then
          echo "fd:$fd_state"
        else
          echo "unknown"
        fi
      else
        echo "unknown"
      fi
    fi
    ;;

  archive)
    [[ ! -f "$FILE" ]] && exit 0
    ts=$(jq -r '.terminated_at // empty' "$FILE" 2>/dev/null)
    [[ -z "$ts" ]] && ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    safe_ts="${ts//:/}"
    archive_path="${FILE%.json}-${safe_ts}.json.archive"
    lock="${FILE}.lock"
    exec 9>"$lock"
    flock 9
    mv "$FILE" "$archive_path"
    exec 9>&-
    echo "$archive_path"
    ;;

  master-busy)
    # Wrapper for the daemon's master-busy lockfile. Master holds this for
    # the duration of a turn so the daemon defers wake delivery. Atomic
    # temp+mv on lock so daemon never reads a partial JSON write.
    #
    # Resolves the busy file path via lib/daemon-paths.sh — the SAME
    # resolution the daemon uses. Both writers MUST agree on this path or
    # the daemon never sees the master-busy signal (silent wake-during-turn
    # race).
    [[ ${#ARGS[@]} -lt 1 ]] && { echo "Usage: master-busy <lock|unlock|check> [--master-pane <%N>] [--owner-pid <PID>]" >&2; exit 2; }
    sub_action="${ARGS[0]}"
    # Resolve session_id-keyed busy file path (matches daemon's SESSION_KEY).
    sid=$(tmux display-message -p -t "$SESSION" '#{session_id}' 2>/dev/null || echo "")
    [[ -z "$sid" ]] && { echo "Error: cannot resolve session_id for $SESSION" >&2; exit 2; }
    # shellcheck source=lib/daemon-paths.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/daemon-paths.sh"
    fd_dir=$(fd_resolve_state_dir)
    sid_key=$(fd_session_key_from_id "$sid")
    busy_file=$(fd_busy_file "$fd_dir" "$sid_key")
    case "$sub_action" in
      lock)
        master_pane=""
        owner_pid=""
        for ((i=1; i<${#ARGS[@]}; i++)); do
          case "${ARGS[$i]}" in
            --master-pane) master_pane="${ARGS[$((i+1))]}" ;;
            --owner-pid)   owner_pid="${ARGS[$((i+1))]}" ;;
          esac
        done
        if [[ -z "$master_pane" ]]; then
          # Auto-resolve from the current pane this script runs from.
          master_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "")
        fi
        [[ -z "$master_pane" ]] && { echo "Error: cannot resolve master pane id" >&2; exit 2; }
        started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Hold the daemon's SESSION_LOCK across the busy-file write AND the
        # WAKE_PENDING clear. This is the contract that prevents the daemon
        # from extending in_flight (or seeing a half-written lock) during a
        # turn handoff.
        #
        # Without the WAKE_PENDING clear, a stale "in flight" entry from a
        # prior wake attempt that was never ack'd (e.g., user message arrived
        # before the wake landed and master treated the user message as the
        # turn) would block every subsequent daemon wake for WAKE_PENDING_TTL
        # seconds. Clearing under the same lock makes the lock-and-take
        # transition atomic against the daemon's append paths.
        session_lock=$(fd_session_lock "$fd_dir" "$sid_key")
        wake_pending=$(fd_wake_pending "$fd_dir" "$sid_key")
        exec 8>"$session_lock"
        flock 8
        tmp="${busy_file}.tmp.$$"
        # owner_pid: caller's long-lived agent PID, if known. The previous
        # implementation wrote `$$` of this wrapper script — which exits
        # immediately after the file is written, so the daemon's
        # `kill -0 $pid` check always reported the master as "not busy"
        # and could deliver a wake mid-turn (bugs review finding #1).
        # Daemon treats a missing pid field as "validate by pane + TTL".
        if [[ -n "$owner_pid" && "$owner_pid" =~ ^[1-9][0-9]*$ ]]; then
          jq -nc --argjson pid "$owner_pid" --arg mp "$master_pane" --arg sa "$started_at" \
            '{pid:$pid, master_pane_id:$mp, started_at:$sa}' > "$tmp"
        else
          jq -nc --arg mp "$master_pane" --arg sa "$started_at" \
            '{master_pane_id:$mp, started_at:$sa}' > "$tmp"
        fi
        mv "$tmp" "$busy_file"
        rm -f "$wake_pending"
        exec 8>&-
        ;;
      unlock)
        rm -f "$busy_file"
        ;;
      check)
        if [[ -f "$busy_file" ]]; then
          cat "$busy_file"
          exit 0
        fi
        exit 1
        ;;
      *)
        echo "Usage: master-busy <lock|unlock|check>" >&2
        exit 2
        ;;
    esac
    ;;

  *)
    echo "Unknown action: $ACTION" >&2
    echo "Actions: init | get | set | append | increment | archive | master-busy | path" >&2
    exit 2
    ;;
esac
