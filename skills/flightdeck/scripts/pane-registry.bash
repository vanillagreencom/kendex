#!/usr/bin/env bash
# TrackedEntry↔pane registry CRUD. Wraps flightdeck-state for .entries and
# dual-writes issue entries to the legacy .issues map.
#
# Usage:
#   pane-registry init-entry <ENTRY_ID> --title <T> --kind adhoc|issue|workflow --cwd <path> --window <N> --harness <h> [--worktree <path>] [--pr <N>]
#   pane-registry init <ISSUE> --window <name> --harness <h> --worktree <path> [--pane-index <N>] [--pr <N>]
#                                  [--oc-url <URL> --oc-session-id <ID> [--oc-port <N>]]
#   pane-registry list [--format json|inner-panes|inner-harnesses]
#   pane-registry get <ISSUE>
#   pane-registry set-state <ISSUE> <state>             # waiting|prompting|submitting|merge-ready|merged|aborted|dead
#   pane-registry set-substate <ISSUE> <substate>      # tag string from prompt-classify
#   pane-registry set <ISSUE> <field> <json-value>      # arbitrary field write
#   pane-registry log-decision <ISSUE> <prompt-tag> <answer>
#   pane-registry remove <ISSUE>                         # also releases oc port + deletes spawn file
#   pane-registry remove-merged                          # drop terminal-state issues with closed windows
#   pane-registry reconcile                              # drop entries whose windows no longer exist
#   pane-registry teardown-window <ISSUE> [--force]      # safely kill the issue's window/pane using stable pane_id
#   pane-registry teardown-entry <ENTRY_ID> [--force]    # alias for teardown-window (TrackedEntry alignment)
#   pane-registry oc-attach-args <ISSUE>                # prints '--url U --session S' or empty
#   pane-registry find-by-pane <pane-target>             # prints {id,kind} JSON matching pane target/id
#
# When --harness is opencode and --oc-url is omitted, init auto-loads from
# the spawn-discovery file written by open-terminal at oc_spawn_file(<ISSUE>).
#
# All commands operate on the master state for the current $TMUX session
# (override via FLIGHTDECK_STATE_DIR + flightdeck-state --session).
#
# Exit codes:
#   0 - success
#   1 - issue not found (where applicable)
#   2 - bad arguments
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FD_STATE="$SCRIPT_DIR/flightdeck-state"

# shellcheck source=lib/oc-paths.sh
source "$SCRIPT_DIR/lib/oc-paths.sh"
# shellcheck source=lib/cc-channel-paths.sh
source "$SCRIPT_DIR/lib/cc-channel-paths.sh"
# shellcheck source=lib/pi-bridge-paths.sh
source "$SCRIPT_DIR/lib/pi-bridge-paths.sh"
# shellcheck source=lib/codex-paths.sh
source "$SCRIPT_DIR/lib/codex-paths.sh"

ACTION="${1:-}"
[[ -z "$ACTION" ]] && { echo "Usage: pane-registry <action> [args]" >&2; exit 2; }
shift

now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

entry_list_filter() {
  cat <<'JQ'
to_entries | map(
  .value as $e
  | ($e.adapter // {}) as $a
  | ($e.domain.issue // {}) as $i
  | $e + {
      id: ($e.id // .key),
      issue: (if ($e.kind // "issue") == "issue" then ($i.id // $e.id // .key) else null end),
      worktree: ($i.worktree // $e.cwd // null),
      pr_number: ($i.pr_number // null),
      oc_url: ($a.oc_url // null),
      oc_session_id: ($a.oc_session_id // null),
      oc_port: ($a.oc_port // null),
      cc_url: ($a.cc_url // null),
      cc_session_uuid: ($a.cc_session_uuid // null),
      cc_port: ($a.cc_port // null),
      cc_transcript: ($a.cc_transcript // null),
      pi_bridge_pid: ($a.pi_bridge_pid // null),
      pi_bridge_socket: ($a.pi_bridge_socket // null),
      pi_session_id: ($a.pi_session_id // null),
      cx_ws: ($a.cx_ws // null),
      cx_thread_id: ($a.cx_thread_id // null),
      orchestration_started: ($i.orchestration_started // null),
      scope_files_declared: ($i.scope_files_declared // null),
      scope_files_actual: ($i.scope_files_actual // null)
    }
)
JQ
}

lookup_id() {
  local raw="$1"
  if [[ "$raw" == \{* ]]; then
    jq -r '.id // empty' <<< "$raw" 2>/dev/null || true
  else
    printf '%s' "$raw"
  fi
}

read_registry_field() {
  local raw_id="$1" field="$2" id id_json
  id=$(lookup_id "$raw_id")
  [[ -n "$id" ]] || return 1
  id_json=$(jq -Rn --arg v "$id" '$v')
  "$FD_STATE" get "(.issues[$id_json].$field // .entries[$id_json].adapter.$field // .entries[$id_json].$field // empty)" 2>/dev/null | tr -d '"'
}

pane_match_is_live() {
  local pane_id="$1" pane_target="$2" lookup="${pane_id:-$pane_target}"
  [[ -n "$lookup" ]] || return 1
  if [[ -n "$pane_id" ]]; then
    tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qFx "$pane_id"
    return $?
  fi
  tmux list-panes -t "$pane_target" >/dev/null 2>&1
}

warn_stale_pane_match() {
  local pane_id="$1" pane_target="$2" lookup="${pane_id:-$pane_target}"
  printf 'Warning: find-by-pane match %s is stale (pane no longer exists); use pane-registry reconcile.\n' "${lookup:-<none>}" >&2
}

cmd_init_entry() {
  local ENTRY_ID="$1" MODE="${2:-entry}"
  shift 2 || true
  [[ -n "$ENTRY_ID" ]] || { echo "Usage: pane-registry init-entry <ENTRY_ID> [flags]" >&2; exit 2; }

  DEFAULT_PANE_INDEX="$(tmux show-options -g pane-base-index 2>/dev/null | awk '{print $2}')"
  DEFAULT_PANE_INDEX="${DEFAULT_PANE_INDEX:-0}"
  TITLE="$ENTRY_ID"; KIND="adhoc"; CWD=""; WINDOW=""; HARNESS=""; WORKTREE=""; PANE_INDEX="$DEFAULT_PANE_INDEX"; PR=""
  PANE_ID=""; PANE_TARGET=""; WINDOW_ID=""; WINDOW_INDEX=""
  OC_URL=""; OC_SESSION_ID=""; OC_PORT=""
  CC_URL=""; CC_SESSION_UUID=""; CC_PORT=""; CC_TRANSCRIPT=""
  PI_BRIDGE_PID=""; PI_BRIDGE_SOCKET=""; PI_SESSION_ID=""
  CX_WS=""; CX_THREAD_ID=""
  LAUNCH_MODEL=""; LAUNCH_EFFORT=""; LAUNCH_CMD=""; DISCOVERY_ERROR=""

  if [[ "$MODE" == "issue" ]]; then
    KIND="issue"
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) TITLE="$2"; shift 2 ;;
      --kind) KIND="$2"; shift 2 ;;
      --cwd) CWD="$2"; shift 2 ;;
      --window) WINDOW="$2"; shift 2 ;;
      --harness) HARNESS="$2"; shift 2 ;;
      --worktree) WORKTREE="$2"; shift 2 ;;
      --pane-index) PANE_INDEX="$2"; shift 2 ;;
      --pane-id) PANE_ID="$2"; shift 2 ;;
      --pane-target) PANE_TARGET="$2"; shift 2 ;;
      --window-id) WINDOW_ID="$2"; shift 2 ;;
      --window-index) WINDOW_INDEX="$2"; shift 2 ;;
      --pr) PR="$2"; shift 2 ;;
      --oc-url) OC_URL="$2"; shift 2 ;;
      --oc-session-id) OC_SESSION_ID="$2"; shift 2 ;;
      --oc-port) OC_PORT="$2"; shift 2 ;;
      --cc-url) CC_URL="$2"; shift 2 ;;
      --cc-session-uuid) CC_SESSION_UUID="$2"; shift 2 ;;
      --cc-port) CC_PORT="$2"; shift 2 ;;
      --cc-transcript) CC_TRANSCRIPT="$2"; shift 2 ;;
      --pi-bridge-pid) PI_BRIDGE_PID="$2"; shift 2 ;;
      --pi-bridge-socket) PI_BRIDGE_SOCKET="$2"; shift 2 ;;
      --pi-session-id) PI_SESSION_ID="$2"; shift 2 ;;
      --cx-ws) CX_WS="$2"; shift 2 ;;
      --cx-thread-id) CX_THREAD_ID="$2"; shift 2 ;;
      --launch-model) LAUNCH_MODEL="$2"; shift 2 ;;
      --launch-effort) LAUNCH_EFFORT="$2"; shift 2 ;;
      --launch-cmd) LAUNCH_CMD="$2"; shift 2 ;;
      --discovery-error) DISCOVERY_ERROR="$2"; shift 2 ;;
      *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
  done

  case "$KIND" in adhoc|issue|workflow) ;; *) echo "init-entry requires --kind adhoc|issue|workflow" >&2; exit 2 ;; esac
  if [[ "$MODE" == "issue" ]]; then
    [[ -z "$CWD" ]] && CWD="$WORKTREE"
    [[ -z "$TITLE" ]] && TITLE="$ENTRY_ID"
    [[ -z "$WORKTREE" ]] && { echo "init requires --window, --harness, --worktree" >&2; exit 2; }
  fi
  [[ -z "$WORKTREE" && "$KIND" == "issue" ]] && WORKTREE="$CWD"
  [[ -z "$CWD" ]] && CWD="$WORKTREE"
  [[ -z "$TITLE" ]] && TITLE="$ENTRY_ID"
  [[ -z "$WINDOW" || -z "$HARNESS" || -z "$CWD" ]] && {
    echo "init-entry requires --title, --kind, --cwd, --window, --harness" >&2; exit 2; }

  # Auto-hydrate bridge metadata from legacy issue-keyed spawn files when
  # callers do not pass adapter fields explicitly. This preserves init alias
  # behavior and lets issue-mode init-entry share the same code path.
  if [[ "$HARNESS" == "opencode" && -z "$OC_URL" ]]; then
    _spawn_file="$(oc_spawn_file "$ENTRY_ID")"
    if [[ -f "$_spawn_file" ]]; then
      OC_URL=$(jq -r '.url // ""' "$_spawn_file" 2>/dev/null || echo "")
      OC_SESSION_ID=$(jq -r '.session_id // ""' "$_spawn_file" 2>/dev/null || echo "")
      OC_PORT=$(jq -r '.port // ""' "$_spawn_file" 2>/dev/null || echo "")
      LAUNCH_MODEL=${LAUNCH_MODEL:-$(jq -r '.launch.model // ""' "$_spawn_file" 2>/dev/null || echo "")}
      LAUNCH_EFFORT=${LAUNCH_EFFORT:-$(jq -r '.launch.effort // ""' "$_spawn_file" 2>/dev/null || echo "")}
    fi
  fi
  if [[ "$HARNESS" == "claude" && -z "$CC_URL" ]]; then
    _cc_spawn_file="$(cc_spawn_file "$ENTRY_ID")"
    if [[ -f "$_cc_spawn_file" ]]; then
      CC_URL=$(jq -r '.url // ""' "$_cc_spawn_file" 2>/dev/null || echo "")
      CC_SESSION_UUID=$(jq -r '.session_uuid // ""' "$_cc_spawn_file" 2>/dev/null || echo "")
      CC_PORT=$(jq -r '.port // ""' "$_cc_spawn_file" 2>/dev/null || echo "")
      CC_TRANSCRIPT=$(jq -r '.transcript // ""' "$_cc_spawn_file" 2>/dev/null || echo "")
      LAUNCH_MODEL=${LAUNCH_MODEL:-$(jq -r '.launch.model // ""' "$_cc_spawn_file" 2>/dev/null || echo "")}
      LAUNCH_EFFORT=${LAUNCH_EFFORT:-$(jq -r '.launch.effort // ""' "$_cc_spawn_file" 2>/dev/null || echo "")}
    fi
  fi
  if [[ "$HARNESS" == "pi" && -z "$PI_BRIDGE_PID" ]]; then
    _pi_spawn_file="$(pi_spawn_file "$ENTRY_ID")"
    if [[ -f "$_pi_spawn_file" ]]; then
      PI_BRIDGE_PID=$(jq -r '.pid // ""' "$_pi_spawn_file" 2>/dev/null || echo "")
      PI_BRIDGE_SOCKET=$(jq -r '.socket // ""' "$_pi_spawn_file" 2>/dev/null || echo "")
      PI_SESSION_ID=$(jq -r '.session_id // ""' "$_pi_spawn_file" 2>/dev/null || echo "")
      LAUNCH_MODEL=${LAUNCH_MODEL:-$(jq -r '.launch.model // ""' "$_pi_spawn_file" 2>/dev/null || echo "")}
      LAUNCH_EFFORT=${LAUNCH_EFFORT:-$(jq -r '.launch.effort // ""' "$_pi_spawn_file" 2>/dev/null || echo "")}
    fi
  fi
  if [[ "$HARNESS" == "codex" && -z "$CX_WS" ]]; then
    _cx_spawn_file="$(cx_spawn_file "$ENTRY_ID")"
    if [[ -f "$_cx_spawn_file" ]]; then
      CX_WS=$(jq -r '.url // ""' "$_cx_spawn_file" 2>/dev/null || echo "")
      CX_THREAD_ID=$(jq -r '.thread_id // ""' "$_cx_spawn_file" 2>/dev/null || echo "")
      LAUNCH_MODEL=${LAUNCH_MODEL:-$(jq -r '.launch.model // ""' "$_cx_spawn_file" 2>/dev/null || echo "")}
      LAUNCH_EFFORT=${LAUNCH_EFFORT:-$(jq -r '.launch.effort // ""' "$_cx_spawn_file" 2>/dev/null || echo "")}
    fi
  fi

  "$FD_STATE" init >/dev/null
  SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo unknown)
  if [[ -z "$PANE_TARGET" ]]; then
    PANE_TARGET="${SESSION}:${WINDOW}.${PANE_INDEX}"
  fi
  if [[ -z "$PANE_ID" ]] && tmux list-panes -t "$PANE_TARGET" >/dev/null 2>&1; then
    PANE_ID=$(tmux display-message -t "$PANE_TARGET" -p '#{pane_id}' 2>/dev/null || echo "")
  fi

  entry_obj=$(jq -n \
    --arg id "$ENTRY_ID" \
    --arg title "$TITLE" \
    --arg kind "$KIND" \
    --arg cwd "$CWD" \
    --arg window "$WINDOW" \
    --arg window_id "$WINDOW_ID" \
    --arg window_index "$WINDOW_INDEX" \
    --arg pane_target "$PANE_TARGET" \
    --arg pane_id "$PANE_ID" \
    --arg harness "$HARNESS" \
    --arg worktree "$WORKTREE" \
    --arg pr "$PR" \
    --arg oc_url "$OC_URL" \
    --arg oc_session_id "$OC_SESSION_ID" \
    --arg oc_port "$OC_PORT" \
    --arg cc_url "$CC_URL" \
    --arg cc_session_uuid "$CC_SESSION_UUID" \
    --arg cc_port "$CC_PORT" \
    --arg cc_transcript "$CC_TRANSCRIPT" \
    --arg pi_bridge_pid "$PI_BRIDGE_PID" \
    --arg pi_bridge_socket "$PI_BRIDGE_SOCKET" \
    --arg pi_session_id "$PI_SESSION_ID" \
    --arg cx_ws "$CX_WS" \
    --arg cx_thread_id "$CX_THREAD_ID" \
    --arg launch_model "$LAUNCH_MODEL" \
    --arg launch_effort "$LAUNCH_EFFORT" \
    --arg launch_cmd "$LAUNCH_CMD" \
    --arg discovery_error "$DISCOVERY_ERROR" \
    --arg now "$(now)" \
    'def s($v): if $v == "" then null else $v end;
     def n($v): if $v == "" then null else ($v | tonumber) end;
     {
       id: $id,
       title: $title,
       kind: $kind,
       state: "waiting",
       substate: null,
       harness: $harness,
       cwd: $cwd,
       window: $window,
       window_id: s($window_id),
       window_index: n($window_index),
       pane_target: s($pane_target),
       pane_id: s($pane_id),
       discovery_error: s($discovery_error),
       launch: (if $launch_model == "" and $launch_effort == "" and $launch_cmd == "" then null else {model: s($launch_model), effort: s($launch_effort), cmd: s($launch_cmd)} end),
       adapter: {
         oc_url: s($oc_url), oc_session_id: s($oc_session_id), oc_port: n($oc_port),
         cc_url: s($cc_url), cc_session_uuid: s($cc_session_uuid), cc_port: n($cc_port), cc_transcript: s($cc_transcript),
         pi_bridge_pid: n($pi_bridge_pid), pi_bridge_socket: s($pi_bridge_socket), pi_session_id: s($pi_session_id),
         cx_ws: s($cx_ws), cx_thread_id: s($cx_thread_id)
       },
       domain: (if $kind == "issue" then {issue: {id: $id, worktree: s($worktree), pr_number: n($pr), orchestration_started: false, scope_files_declared: null, scope_files_actual: null}} else null end),
       last_capture_hash: null,
       last_response_at: null,
       spawned_at: $now,
       last_polled_at: $now,
       decisions_log: [],
       unknown_since: null
     }')

  "$FD_STATE" write-entry "$ENTRY_ID" "$entry_obj"
}

case "$ACTION" in
  init)
    ISSUE="${1:-}"; shift || true
    [[ -z "$ISSUE" ]] && { echo "Usage: pane-registry init <ISSUE> [flags]" >&2; exit 2; }
    cmd_init_entry "$ISSUE" issue --title "$ISSUE" "$@"
    ;;

  init-entry)
    ENTRY_ID="${1:-}"; shift || true
    cmd_init_entry "$ENTRY_ID" entry "$@"
    ;;
  list)
    FORMAT="json"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --format) FORMAT="$2"; shift 2 ;;
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
      esac
    done
    case "$FORMAT" in
      json)
        "$FD_STATE" tracked-entries | jq -c "$(entry_list_filter)"
        ;;
      inner-panes)
        # Comma-separated target list, one per tracked entry, suitable for
        # `flightdeck-daemon start --inner`. Prefer immutable pane_id.
        "$FD_STATE" tracked-entries | jq -r 'to_entries | map(.value.pane_id // .value.pane_target // empty) | join(",")'
        ;;
      inner-harnesses)
        # Comma-separated harness list in the same order as `inner-panes`.
        "$FD_STATE" tracked-entries | jq -r 'to_entries | map(.value.harness // "") | join(",")'
        ;;
      *)
        echo "Unknown format: $FORMAT (supported: json, inner-panes, inner-harnesses)" >&2
        exit 2
        ;;
    esac
    ;;

  get)
    ISSUE="${1:-}"
    [[ -z "$ISSUE" ]] && { echo "Usage: pane-registry get <ISSUE>" >&2; exit 2; }
    out=$("$FD_STATE" get ".issues[\"$ISSUE\"] // empty")
    [[ -z "$out" || "$out" == "null" ]] && exit 1
    echo "$out"
    ;;

  set-state)
    ISSUE="${1:-}"; STATE="${2:-}"
    [[ -z "$ISSUE" || -z "$STATE" ]] && { echo "Usage: set-state <ISSUE> <state>" >&2; exit 2; }
    case "$STATE" in
      waiting|prompting|submitting|merge-ready|merged|aborted|dead) ;;
      *) echo "Unknown state: $STATE" >&2; exit 2 ;;
    esac
    "$FD_STATE" set ".issues[\"$ISSUE\"].state" "\"$STATE\""
    ;;

  set-substate)
    ISSUE="${1:-}"; SUB="${2:-}"
    [[ -z "$ISSUE" || -z "$SUB" ]] && { echo "Usage: set-substate <ISSUE> <substate>" >&2; exit 2; }
    "$FD_STATE" set ".issues[\"$ISSUE\"].substate" "\"$SUB\""
    ;;

  set)
    ISSUE="${1:-}"; FIELD="${2:-}"; VALUE="${3:-}"
    [[ -z "$ISSUE" || -z "$FIELD" || -z "$VALUE" ]] && {
      echo "Usage: set <ISSUE> <field> <json-value>" >&2; exit 2; }
    "$FD_STATE" set ".issues[\"$ISSUE\"].$FIELD" "$VALUE"
    ;;

  log-decision)
    ISSUE="${1:-}"; TAG="${2:-}"; ANSWER="${3:-}"
    [[ -z "$ISSUE" || -z "$TAG" || -z "$ANSWER" ]] && {
      echo "Usage: log-decision <ISSUE> <prompt-tag> <answer>" >&2; exit 2; }
    entry=$(jq -n \
      --arg ts "$(now)" --arg tag "$TAG" --arg ans "$ANSWER" \
      '{ts: $ts, prompt_tag: $tag, answer: $ans}')
    "$FD_STATE" append ".issues[\"$ISSUE\"].decisions_log" "$entry"
    ;;

  remove)
    ISSUE="${1:-}"
    [[ -z "$ISSUE" ]] && { echo "Usage: remove <ISSUE>" >&2; exit 2; }
    # Release any opencode adapter resources owned by this issue before
    # dropping the registry entry. Idempotent — missing fields are no-ops.
    # Server pid lives in the spawn file (write-once at allocation),
    # NOT in the registry, so we read it from there.
    _oc_spawn_file="$(oc_spawn_file "$ISSUE")"
    if [[ -f "$_oc_spawn_file" ]]; then
      _oc_server_pid=$(jq -r '.server_pid // empty' "$_oc_spawn_file" 2>/dev/null || echo "")
      if [[ "$_oc_server_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$_oc_server_pid" 2>/dev/null; then
        # Kill the whole process group (server was spawned via setsid →
        # PGID == server PID) so any forked children die with it. Then
        # escalate to KILL after a brief grace if TERM was ignored.
        kill -- -"$_oc_server_pid" 2>/dev/null || kill "$_oc_server_pid" 2>/dev/null || true
        for _i in 1 2 3 4 5; do
          kill -0 "$_oc_server_pid" 2>/dev/null || break
          sleep 0.2
        done
        if kill -0 "$_oc_server_pid" 2>/dev/null; then
          kill -9 -- -"$_oc_server_pid" 2>/dev/null || kill -9 "$_oc_server_pid" 2>/dev/null || true
        fi
      fi
    fi
    _oc_port=$("$FD_STATE" get ".issues[\"$ISSUE\"].oc_port // empty" 2>/dev/null | tr -d '"')
    if [[ -n "$_oc_port" && "$_oc_port" != "null" ]]; then
      oc_release_port "$_oc_port" 2>/dev/null || true
    fi
    rm -f "$_oc_spawn_file" 2>/dev/null || true
    # Claude channel cleanup (Phase 2): release port, drop spawn + mcp
    # config files. The MCP webhook subprocess is a child of claude
    # itself, so killing the tmux pane (or the user exiting claude)
    # reaps it — no separate kill needed here.
    _cc_port=$("$FD_STATE" get ".issues[\"$ISSUE\"].cc_port // empty" 2>/dev/null | tr -d '"')
    if [[ -n "$_cc_port" && "$_cc_port" != "null" ]]; then
      cc_release_port "$_cc_port" 2>/dev/null || true
    fi
    rm -f "$(cc_spawn_file "$ISSUE")" 2>/dev/null || true
    rm -rf "$(cc_mcp_dir "$ISSUE")" 2>/dev/null || true
    # Pi bridge cleanup: drop spawn file. Pi process itself isn't
    # ours to kill (the user spawned the pi tmux pane); when the
    # user closes the pane, pi exits and the bridge cleans up its
    # registry entry naturally.
    rm -f "$(pi_spawn_file "$ISSUE")" 2>/dev/null || true
    # Codex cleanup: drop spawn file. Server is per-session (not per-
    # pane); kept alive via codex-app-server-spawn idempotency until
    # terminate.md § 5 calls codex-app-server-stop.
    rm -f "$(cx_spawn_file "$ISSUE")" 2>/dev/null || true
    "$FD_STATE" set ".issues" "(.issues | del(.[\"$ISSUE\"]))"
    ;;

  oc-attach-args)
    # Print "--url <U> --session <S>" when both are set AND the
    # opencode-serve process is alive. Empty stdout when stale or
    # missing — caller falls back to capture-pane. Without the
    # freshness gate the daemon would mark the pane as subscribed
    # against a dead adapter and silently disable fallback polling
    # (cross-harness review finding #2).
    ISSUE="${1:-}"
    [[ -z "$ISSUE" ]] && { echo "Usage: oc-attach-args <ISSUE>" >&2; exit 2; }
    ISSUE=$(lookup_id "$ISSUE")
    url=$(read_registry_field "$ISSUE" oc_url || true)
    sid=$(read_registry_field "$ISSUE" oc_session_id || true)
    if [[ -n "$url" && -n "$sid" && "$url" != "null" && "$sid" != "null" ]]; then
      if oc_adapter_is_fresh "$ISSUE" 2>/dev/null; then
        printf -- "--url %s --session %s\n" "$url" "$sid"
      fi
    fi
    ;;

  cc-channel-args)
    # Print "--url <U> --transcript <T>" when both are set AND the
    # claude channel server port is reachable and the transcript
    # file exists. Same fallback contract as `oc-attach-args`.
    ISSUE="${1:-}"
    [[ -z "$ISSUE" ]] && { echo "Usage: cc-channel-args <ISSUE>" >&2; exit 2; }
    ISSUE=$(lookup_id "$ISSUE")
    url=$(read_registry_field "$ISSUE" cc_url || true)
    transcript=$(read_registry_field "$ISSUE" cc_transcript || true)
    if [[ -n "$url" && -n "$transcript" && "$url" != "null" && "$transcript" != "null" ]]; then
      if cc_adapter_is_fresh "$ISSUE" 2>/dev/null; then
        printf -- "--url %s --transcript %s\n" "$url" "$transcript"
      fi
    fi
    ;;

  pi-bridge-args)
    # Print "--pid <P> --socket <S>" when both are set AND the bridge
    # is fresh (pid alive, socket exists, protocol matches). Empty
    # stdout when stale or missing — caller falls back to tmux.
    ISSUE="${1:-}"
    [[ -z "$ISSUE" ]] && { echo "Usage: pi-bridge-args <ISSUE>" >&2; exit 2; }
    ISSUE=$(lookup_id "$ISSUE")
    pid=$(read_registry_field "$ISSUE" pi_bridge_pid || true)
    socket=$(read_registry_field "$ISSUE" pi_bridge_socket || true)
    if [[ -n "$pid" && -n "$socket" && "$pid" != "null" && "$socket" != "null" ]]; then
      if pi_bridge_is_fresh "$pid" "$socket" 2>/dev/null; then
        printf -- "--pid %s --socket %s\n" "$pid" "$socket"
      fi
    fi
    ;;

  cx-bridge-args)
    # Print "--url <U> --thread <T>" when both are set AND the codex
    # app-server port is reachable. Same fallback contract as the other
    # adapter args (cross-harness review finding #2).
    ISSUE="${1:-}"
    [[ -z "$ISSUE" ]] && { echo "Usage: cx-bridge-args <ISSUE>" >&2; exit 2; }
    ISSUE=$(lookup_id "$ISSUE")
    url=$(read_registry_field "$ISSUE" cx_ws || true)
    thread=$(read_registry_field "$ISSUE" cx_thread_id || true)
    if [[ -n "$url" && -n "$thread" && "$url" != "null" && "$thread" != "null" ]]; then
      if cx_adapter_is_fresh "$ISSUE" 2>/dev/null; then
        printf -- "--url %s --thread %s\n" "$url" "$thread"
      fi
    fi
    ;;

  find-by-pane)
    # Print stable JSON for the tracked entry matching pane_target or pane_id.
    # The normalized read path covers both .entries and legacy .issues rows.
    PANE_TARGET="${1:-}"
    [[ -z "$PANE_TARGET" ]] && { echo "Usage: find-by-pane <pane-target-or-pane-id>" >&2; exit 2; }
    match=$("$FD_STATE" tracked-entries 2>/dev/null | jq -c --arg target "$PANE_TARGET" '
      to_entries
      | map(select(.value.pane_target == $target or .value.pane_id == $target))
      | .[0] // empty
      | {id: (.value.id // .key), kind: (.value.kind // "issue"), pane_id: (.value.pane_id // null), pane_target: (.value.pane_target // null)}
    ' 2>/dev/null | head -n1)
    if [[ -z "$match" ]]; then
      exit 1
    fi
    match_pane_id=$(jq -r '.pane_id // ""' <<< "$match")
    match_pane_target=$(jq -r '.pane_target // ""' <<< "$match")
    if ! pane_match_is_live "$match_pane_id" "$match_pane_target"; then
      warn_stale_pane_match "$match_pane_id" "$match_pane_target"
      exit 1
    fi
    jq -c '{id, kind}' <<< "$match"
    ;;

  remove-merged)
    # Drop registry entries for issues in terminal state (merged|aborted|dead)
    # whose tmux panes are gone. NOT called by terminate.md anymore: doing so
    # erased the entire merged-issue history (decisions_log, pr_number,
    # merge_commit) from the archive that pi-flightdeck depends on for the
    # post-completion view (issue #17). Kept as a callable subcommand for
    # ad-hoc registry cleanup outside the terminate workflow. Primary
    # liveness key is the immutable
    # tmux pane_id (`%N`); window_name is only a fallback for legacy
    # entries written before #3 fix and for entries whose init-time
    # pane_id resolution failed.
    LIVE_PANES=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | sort -u || true)
    SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo unknown)
    LIVE_WINDOWS=$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | sort -u || true)
    # Single read of .issues (perf review finding #6): the previous loop
    # called `flightdeck-state get` 3 times per issue (state, pane_id,
    # window), so N issues =>= 3N bash+jq subprocess launches. Snapshot the
    # map once and let jq filters run in-process over the cached JSON.
    ISSUES_JSON=$("$FD_STATE" get '.issues // {}' 2>/dev/null || echo '{}')
    REGISTERED=$(jq -r 'keys[]?' <<< "$ISSUES_JSON")
    DROPPED=()
    while IFS= read -r issue; do
      [[ -z "$issue" ]] && continue
      fields=$(jq -r --arg k "$issue" '
        .[$k] // {} | [(.state // ""), (.pane_id // ""), (.window // "")] | @tsv
      ' <<< "$ISSUES_JSON")
      state=$(awk -F'\t' '{print $1}' <<< "$fields")
      pane_id=$(awk -F'\t' '{print $2}' <<< "$fields")
      window=$(awk -F'\t' '{print $3}' <<< "$fields")
      case "$state" in
        merged|aborted|dead) ;;
        *) continue ;;
      esac
      alive=1
      if [[ -n "$pane_id" ]]; then
        grep -qx "$pane_id" <<< "$LIVE_PANES" || alive=0
      else
        if [[ -n "$window" ]] && ! grep -qx "$window" <<< "$LIVE_WINDOWS"; then alive=0; fi
      fi
      if (( alive == 0 )); then
        "$FD_STATE" set ".issues" "(.issues | del(.[\"$issue\"]))"
        DROPPED+=("$issue:$state")
      fi
    done <<< "$REGISTERED"
    if [[ ${#DROPPED[@]} -gt 0 ]]; then
      printf 'remove-merged: dropped %d entr%s (%s)\n' \
        "${#DROPPED[@]}" \
        "$([ ${#DROPPED[@]} -eq 1 ] && echo y || echo ies)" \
        "$(IFS=,; echo "${DROPPED[*]}")"
    fi
    ;;

  reconcile)
    # Reconcile registry against live tmux. Three things happen per entry:
    #
    #   1. Liveness check. If `pane_id` is recorded and tmux still lists
    #      it, the entry survives. If `pane_id` is recorded but tmux no
    #      longer lists it, the original pane is definitively gone and
    #      the entry is dropped — this is the only deterministic case.
    #
    #   2. Opportunistic backfill (legacy entries: pane_target but no
    #      pane_id). Backfilling from a stale pane_target is the #16
    #      footgun: tmux reuses indices after windows are destroyed, so
    #      session:idx.pidx may now point to an unrelated window. The
    #      backfill needs a proof-of-identity strong enough to survive
    #      window-name collisions (tmux allows duplicate names) and
    #      rename races (pi/codex auto-rename their window post-spawn).
    #
    #      The invariant is the AND of two checks:
    #        a. `#{window_name}` at the current pane_target == recorded
    #           `window`.
    #        b. `#{pane_current_path}` at the current pane_target is
    #           prefixed by the recorded `worktree` (cwd-anchor proof).
    #
    #      If both checks pass with non-empty data: adopt pane_id.
    #      If either check fails with non-empty data: emit drift and
    #      LEAVE the entry untouched (no backfill, no drop) so a human
    #      can investigate. The previous round-1 fix used window_name
    #      alone and could (i) be defeated by name collision and (ii)
    #      drop live entries silently when only the name mismatched.
    #      If neither check has enough data to disprove identity, fall
    #      through to backfill (conservative — a window-name collision
    #      with an identical worktree path is vanishingly unlikely; a
    #      cwd-changed-by-user pane will fail check (b) and route to
    #      drift instead of adoption).
    #
    #   3. pane_target-only entries that survived (2): the window_name
    #      liveness fallback used to drop them on rename mismatch. With
    #      the drift gate in place that pathway is no longer reachable
    #      without explicit operator intent; we keep the entry untouched
    #      and let a future reconcile try again once pane_id is resolved.
    LIVE_PANES=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | sort -u || true)
    SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo unknown)
    LIVE_WINDOWS=$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | sort -u || true)
    # Single read of .issues (perf review finding #6). See remove-merged
    # above for the rationale.
    ISSUES_JSON=$("$FD_STATE" get '.issues // {}' 2>/dev/null || echo '{}')
    REGISTERED=$(jq -r 'keys[]?' <<< "$ISSUES_JSON")
    DROPPED=()
    BACKFILLED=()
    DRIFT=()
    while IFS= read -r issue; do
      [[ -z "$issue" ]] && continue
      fields=$(jq -r --arg k "$issue" '
        .[$k] // {} | [(.pane_id // ""), (.pane_target // ""), (.window // ""), (.worktree // "")] | @tsv
      ' <<< "$ISSUES_JSON")
      pane_id=$(awk -F'\t' '{print $1}' <<< "$fields")
      pane_target=$(awk -F'\t' '{print $2}' <<< "$fields")
      window=$(awk -F'\t' '{print $3}' <<< "$fields")
      worktree=$(awk -F'\t' '{print $4}' <<< "$fields")
      drift_this=0
      if [[ -z "$pane_id" && -n "$pane_target" ]]; then
        if tmux list-panes -t "$pane_target" >/dev/null 2>&1; then
          current_window=$(tmux display-message -t "$pane_target" -p '#{window_name}' 2>/dev/null || echo "")
          current_path=$(tmux display-message -t "$pane_target" -p '#{pane_current_path}' 2>/dev/null || echo "")
          window_mismatch=0
          path_mismatch=0
          if [[ -n "$window" && -n "$current_window" && "$current_window" != "$window" ]]; then
            window_mismatch=1
          fi
          if [[ -n "$worktree" && -n "$current_path" ]]; then
            case "$current_path" in
              "$worktree"|"$worktree"/*) ;;
              *) path_mismatch=1 ;;
            esac
          fi
          if (( window_mismatch == 1 || path_mismatch == 1 )); then
            # Strong evidence of identity mismatch. Do NOT adopt; do NOT
            # drop. Leave the entry untouched and emit drift so a human
            # can decide. This is the #16 safety net.
            DRIFT+=("$issue (window:'$window'→'$current_window' worktree:'$worktree'→'$current_path')")
            drift_this=1
          else
            resolved=$(tmux display-message -t "$pane_target" -p '#{pane_id}' 2>/dev/null || echo "")
            if [[ -n "$resolved" ]]; then
              "$FD_STATE" set ".issues[\"$issue\"].pane_id" "\"$resolved\""
              pane_id="$resolved"
              BACKFILLED+=("$issue")
            fi
          fi
        fi
      fi
      if (( drift_this == 1 )); then
        continue
      fi
      alive=1
      if [[ -n "$pane_id" ]]; then
        grep -qx "$pane_id" <<< "$LIVE_PANES" || alive=0
      else
        # No stable pane_id — pane_target alone is not trustworthy
        # (#16 index reuse), so use window_name liveness as the only
        # fallback. If the window name is gone the entry is dropped;
        # if it happens to still exist, the entry survives this pass
        # and a future reconcile will retry pane_id resolution.
        if [[ -n "$window" ]] && ! grep -qx "$window" <<< "$LIVE_WINDOWS"; then alive=0; fi
      fi
      if (( alive == 0 )); then
        "$FD_STATE" set ".issues" "(.issues | del(.[\"$issue\"]))"
        DROPPED+=("$issue")
      fi
    done <<< "$REGISTERED"
    if [[ ${#DROPPED[@]} -gt 0 ]]; then
      printf 'reconciled: dropped %d stale entr%s (%s)\n' \
        "${#DROPPED[@]}" \
        "$([ ${#DROPPED[@]} -eq 1 ] && echo y || echo ies)" \
        "$(IFS=,; echo "${DROPPED[*]}")"
    fi
    if [[ ${#BACKFILLED[@]} -gt 0 ]]; then
      printf 'reconciled: backfilled pane_id for %d entr%s (%s)\n' \
        "${#BACKFILLED[@]}" \
        "$([ ${#BACKFILLED[@]} -eq 1 ] && echo y || echo ies)" \
        "$(IFS=,; echo "${BACKFILLED[*]}")"
    fi
    if [[ ${#DRIFT[@]} -gt 0 ]]; then
      printf 'reconciled: drift detected for %d entr%s, left untouched (%s)\n' \
        "${#DRIFT[@]}" \
        "$([ ${#DRIFT[@]} -eq 1 ] && echo y || echo ies)" \
        "$(IFS='|'; echo "${DRIFT[*]}")" >&2
    fi
    ;;

  teardown-window|teardown-entry)
    # Parity: lib/flightdeck-core/src/bin/pane-registry.ts cmdTeardownWindow
    # (see tests/parity/pane-registry.test.ts).
    #
    # Safely tear down the tmux window/pane for an issue using the
    # stable `pane_id` (`%N`) recorded at init time. Never derives a
    # kill target from the human-readable `pane_target`
    # (`session:window.index`) — tmux reuses window indices after the
    # original window is destroyed, so a stale `pane_target` may now
    # point to an unrelated window (the daemon, the user's editor,
    # etc.). Killing that would destroy the wrong workload (#16).
    #
    # `teardown-entry` is an alias anticipating the TrackedEntry schema
    # in docs/plans/flightdeck-session-management-reframe.md; both names
    # call the same code path so callers can migrate gradually.
    #
    # Behavior:
    #   1. pane_id alive + state ∈ {merged,aborted,dead}: kill the
    #      window when it has exactly one pane, otherwise kill only the
    #      pane. Single-pane-window kill matches the historical
    #      contract from close-issue.md § 4.
    #   2. pane_id alive + state NOT terminal:
    #        - default: refuse with exit 4 (policy guard — callers must
    #          set the issue to a terminal state before tearing down).
    #        - with --force: kill anyway. close-issue.md's normal path
    #          sets state before invoking, so --force is the explicit
    #          escape hatch for operator-driven cleanup.
    #   3. pane_id gone + state terminal: treat as already closed and
    #      exit success. No fallback to pane_target.
    #   4. pane_id gone + state non-terminal: exit 3 (registry drift).
    #
    # Every destructive tmux call captures exit status and stderr; if
    # the kill exits non-zero AND the pane is still listed afterwards,
    # the helper exits 5 with the captured diagnostic instead of
    # falsely reporting success.
    #
    # Registry-read errors (flightdeck-state failure) propagate as exit
    # 6 with stderr forwarded — close-issue.md must not confuse them
    # with an idempotent "already removed" outcome (exit 1).
    #
    # Exit codes:
    #   0 - window/pane killed, or already closed (terminal + dead pane)
    #   1 - issue not registered (caller may treat as idempotent no-op)
    #   2 - bad arguments
    #   3 - registry drift: pane_id gone but state not terminal
    #   4 - policy: pane_id alive but state non-terminal (rerun with --force)
    #   5 - tmux kill failed: pane still alive after kill attempt
    #   6 - registry read failure
    ISSUE=""
    FORCE=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --force) FORCE=1; shift ;;
        --) shift; break ;;
        -*) echo "teardown-window: unknown flag: $1" >&2; exit 2 ;;
        *) [[ -z "$ISSUE" ]] && ISSUE="$1" || { echo "teardown-window: extra argument: $1" >&2; exit 2; }; shift ;;
      esac
    done
    [[ -z "$ISSUE" ]] && { echo "Usage: $ACTION <ISSUE> [--force]" >&2; exit 2; }
    # Separate stdout / stderr / status from flightdeck-state so we can
    # distinguish read-failures (→ exit 6) from a successful empty
    # lookup (→ exit 1). The previous body collapsed both with
    # `2>/dev/null || echo ""`, which is exactly the failure mode
    # called out as BLOCK #2.
    fd_stderr_file=$(mktemp -t fd-teardown-stderr.XXXXXX)
    trap 'rm -f "$fd_stderr_file"' EXIT
    # `flightdeck-state get` returns:
    #   exit 0 + empty stdout — state file present, lookup miss (idempotent)
    #   exit 1                — state file does not exist (registry never initialized; idempotent)
    #   exit >= 2             — usage error or genuine read failure
    # Treat 0+empty and 1 as "not found"; only exit >= 2 escalates to
    # exit 6 (registry read failure) per BLOCK #2.
    entry=$("$FD_STATE" get ".issues[\"$ISSUE\"] // .entries[\"$ISSUE\"] // empty" 2>"$fd_stderr_file")
    fd_status=$?
    if (( fd_status >= 2 )); then
      printf 'teardown-window: registry read failed (flightdeck-state exit=%s): ' "$fd_status" >&2
      cat "$fd_stderr_file" >&2
      echo >&2
      exit 6
    fi
    entry_trim="${entry//[[:space:]]/}"
    if (( fd_status == 1 )) || [[ -z "$entry_trim" || "$entry_trim" == "null" ]]; then
      echo "teardown-window: issue '$ISSUE' not found in registry" >&2
      exit 1
    fi
    fields=$(jq -r '[(.state // ""), (.pane_id // ""), (.window // "")] | @tsv' <<< "$entry")
    state=$(awk -F'\t' '{print $1}' <<< "$fields")
    pane_id=$(awk -F'\t' '{print $2}' <<< "$fields")
    window=$(awk -F'\t' '{print $3}' <<< "$fields")
    pane_alive=0
    if [[ -n "$pane_id" ]]; then
      if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qFx "$pane_id"; then
        pane_alive=1
      fi
    fi
    if (( pane_alive == 1 )); then
      case "$state" in
        merged|aborted|dead) ;;
        *)
          if (( FORCE != 1 )); then
            echo "teardown-window: policy refusal — pane_id '$pane_id' is alive but state is '$state' (not merged|aborted|dead); set a terminal state first or rerun with --force" >&2
            exit 4
          fi
          ;;
      esac
      window_id=$(tmux display-message -t "$pane_id" -p '#{window_id}' 2>/dev/null || echo "")
      pane_count=0
      if [[ -n "$window_id" ]]; then
        pane_count=$(tmux list-panes -t "$window_id" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')
      fi
      kill_stderr=$(mktemp -t fd-teardown-kill-stderr.XXXXXX)
      if [[ -n "$window_id" && "$pane_count" == "1" ]]; then
        tmux kill-window -t "$window_id" 2>"$kill_stderr"
        kill_status=$?
        kind="window $window_id"
      else
        tmux kill-pane -t "$pane_id" 2>"$kill_stderr"
        kill_status=$?
        kind="pane $pane_id"
      fi
      # Verify by re-checking the live pane list. tmux can return
      # non-zero for benign reasons (e.g. the pane vanished between
      # the alive-check and the kill), so the post-kill liveness
      # check is authoritative — not the exit code.
      if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qFx "$pane_id"; then
        printf 'teardown-window: kill of %s failed (status=%s, pane_id=%s still alive): ' "$kind" "$kill_status" "$pane_id" >&2
        cat "$kill_stderr" >&2
        echo >&2
        rm -f "$kill_stderr"
        exit 5
      fi
      rm -f "$kill_stderr"
      printf 'teardown-window: killed %s (pane_id=%s, window=%s, force=%s)\n' "$kind" "$pane_id" "$window" "$FORCE"
      exit 0
    fi
    # pane_id missing or already dead — gate teardown on terminal state.
    case "$state" in
      merged|aborted|dead)
        printf 'teardown-window: window already closed (pane_id=%s gone, state=%s)\n' "${pane_id:-<none>}" "$state"
        exit 0
        ;;
      *)
        echo "teardown-window: registry drift — pane_id '${pane_id:-<none>}' is gone but state is '${state}' (not merged|aborted|dead); refusing to derive kill target from pane_target (#16)" >&2
        exit 3
        ;;
    esac
    ;;

  *)
    echo "Unknown action: $ACTION" >&2
    echo "Actions: init-entry | init | list | get | set-state | set-substate | set | log-decision | remove | remove-merged | reconcile | teardown-window | teardown-entry | oc-attach-args | cc-channel-args | pi-bridge-args | cx-bridge-args | find-by-pane" >&2
    exit 2
    ;;
esac
