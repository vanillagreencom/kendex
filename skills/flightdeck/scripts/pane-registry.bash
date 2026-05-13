#!/usr/bin/env bash
# Issue↔pane registry CRUD. Wraps flightdeck-state for the .issues map.
#
# Usage:
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
#   pane-registry find-by-pane <pane-target>             # prints issue id matching pane_target
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

case "$ACTION" in
  init)
    ISSUE="${1:-}"; shift || true
    [[ -z "$ISSUE" ]] && { echo "Usage: pane-registry init <ISSUE> [flags]" >&2; exit 2; }

    # Default pane index follows tmux's pane-base-index (commonly 0; some
    # configs set 1). Fingerprinting in the watch loop still resolves the
    # actual orchestrator pane when a TUI lays out differently — this just
    # avoids a wasted round-trip when the default-index is correct.
    DEFAULT_PANE_INDEX="$(tmux show-options -g pane-base-index 2>/dev/null | awk '{print $2}')"
    DEFAULT_PANE_INDEX="${DEFAULT_PANE_INDEX:-0}"
    WINDOW=""; HARNESS=""; WORKTREE=""; PANE_INDEX="$DEFAULT_PANE_INDEX"; PR=""
    OC_URL=""; OC_SESSION_ID=""; OC_PORT=""
    CC_URL=""; CC_SESSION_UUID=""; CC_PORT=""; CC_TRANSCRIPT=""
    PI_BRIDGE_PID=""; PI_BRIDGE_SOCKET=""; PI_SESSION_ID=""
    CX_WS=""; CX_THREAD_ID=""
    LAUNCH_MODEL=""; LAUNCH_EFFORT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --window) WINDOW="$2"; shift 2 ;;
        --harness) HARNESS="$2"; shift 2 ;;
        --worktree) WORKTREE="$2"; shift 2 ;;
        --pane-index) PANE_INDEX="$2"; shift 2 ;;
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
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
      esac
    done
    [[ -z "$WINDOW" || -z "$HARNESS" || -z "$WORKTREE" ]] && {
      echo "init requires --window, --harness, --worktree" >&2; exit 2; }

    # Auto-hydrate opencode bridge metadata from the spawn-discovery file
    # written by open-terminal, when caller didn't pass it explicitly.
    if [[ "$HARNESS" == "opencode" && -z "$OC_URL" ]]; then
      _spawn_file="$(oc_spawn_file "$ISSUE")"
      if [[ -f "$_spawn_file" ]]; then
        OC_URL=$(jq -r '.url // ""' "$_spawn_file" 2>/dev/null || echo "")
        OC_SESSION_ID=$(jq -r '.session_id // ""' "$_spawn_file" 2>/dev/null || echo "")
        OC_PORT=$(jq -r '.port // ""' "$_spawn_file" 2>/dev/null || echo "")
        LAUNCH_MODEL=$(jq -r '.launch.model // ""' "$_spawn_file" 2>/dev/null || echo "")
        LAUNCH_EFFORT=$(jq -r '.launch.effort // ""' "$_spawn_file" 2>/dev/null || echo "")
      fi
    fi
    # Auto-hydrate claude channel metadata.
    if [[ "$HARNESS" == "claude" && -z "$CC_URL" ]]; then
      _cc_spawn_file="$(cc_spawn_file "$ISSUE")"
      if [[ -f "$_cc_spawn_file" ]]; then
        CC_URL=$(jq -r '.url // ""' "$_cc_spawn_file" 2>/dev/null || echo "")
        CC_SESSION_UUID=$(jq -r '.session_uuid // ""' "$_cc_spawn_file" 2>/dev/null || echo "")
        CC_PORT=$(jq -r '.port // ""' "$_cc_spawn_file" 2>/dev/null || echo "")
        CC_TRANSCRIPT=$(jq -r '.transcript // ""' "$_cc_spawn_file" 2>/dev/null || echo "")
        LAUNCH_MODEL=$(jq -r '.launch.model // ""' "$_cc_spawn_file" 2>/dev/null || echo "")
        LAUNCH_EFFORT=$(jq -r '.launch.effort // ""' "$_cc_spawn_file" 2>/dev/null || echo "")
      fi
    fi
    # Auto-hydrate pi bridge metadata.
    if [[ "$HARNESS" == "pi" && -z "$PI_BRIDGE_PID" ]]; then
      _pi_spawn_file="$(pi_spawn_file "$ISSUE")"
      if [[ -f "$_pi_spawn_file" ]]; then
        PI_BRIDGE_PID=$(jq -r '.pid // ""' "$_pi_spawn_file" 2>/dev/null || echo "")
        PI_BRIDGE_SOCKET=$(jq -r '.socket // ""' "$_pi_spawn_file" 2>/dev/null || echo "")
        PI_SESSION_ID=$(jq -r '.session_id // ""' "$_pi_spawn_file" 2>/dev/null || echo "")
        LAUNCH_MODEL=$(jq -r '.launch.model // ""' "$_pi_spawn_file" 2>/dev/null || echo "")
        LAUNCH_EFFORT=$(jq -r '.launch.effort // ""' "$_pi_spawn_file" 2>/dev/null || echo "")
      fi
    fi
    # Auto-hydrate codex bridge metadata.
    if [[ "$HARNESS" == "codex" && -z "$CX_WS" ]]; then
      _cx_spawn_file="$(cx_spawn_file "$ISSUE")"
      if [[ -f "$_cx_spawn_file" ]]; then
        CX_WS=$(jq -r '.url // ""' "$_cx_spawn_file" 2>/dev/null || echo "")
        CX_THREAD_ID=$(jq -r '.thread_id // ""' "$_cx_spawn_file" 2>/dev/null || echo "")
        LAUNCH_MODEL=$(jq -r '.launch.model // ""' "$_cx_spawn_file" 2>/dev/null || echo "")
        LAUNCH_EFFORT=$(jq -r '.launch.effort // ""' "$_cx_spawn_file" 2>/dev/null || echo "")
      fi
    fi

    "$FD_STATE" init >/dev/null
    SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo unknown)
    PANE_TARGET="${SESSION}:${WINDOW}.${PANE_INDEX}"

    # Resolve the immutable tmux pane id (`%N`) at init time and store it
    # alongside the human-readable pane_target. Window names are mutable —
    # pi/codex auto-rename their window once the TUI starts, which broke
    # the previous window_name-keyed reconcile path and caused live entries
    # to be silently dropped (#3 finding 3 + #4 finding 4). `allow-rename
    # off` doesn't help: pi invokes `tmux rename-window` directly via IPC,
    # bypassing the OSC-2 gate. pane_id is stable for the life of the
    # pane, regardless of rename / split / harness restart.
    #
    # Validate the target exists before resolving the id. `tmux
    # display-message -t <bogus>` silently returns the active pane's id
    # (footgun: an init call with a typoed window name would store the
    # caller's own pane id and reconcile would never drop it). list-panes
    # exits non-zero for a missing target, so use it as the gate.
    PANE_ID=""
    if tmux list-panes -t "$PANE_TARGET" >/dev/null 2>&1; then
      PANE_ID=$(tmux display-message -t "$PANE_TARGET" -p '#{pane_id}' 2>/dev/null || echo "")
    fi

    issue_obj=$(jq -n \
      --arg window "$WINDOW" \
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
      --arg now "$(now)" \
      '{
        window: $window,
        pane_target: $pane_target,
        pane_id: ($pane_id | if . == "" then null else . end),
        harness: $harness,
        worktree: $worktree,
        pr_number: ($pr | if . == "" then null else (. | tonumber) end),
        oc_url: ($oc_url | if . == "" then null else . end),
        oc_session_id: ($oc_session_id | if . == "" then null else . end),
        oc_port: ($oc_port | if . == "" then null else (. | tonumber) end),
        cc_url: ($cc_url | if . == "" then null else . end),
        cc_session_uuid: ($cc_session_uuid | if . == "" then null else . end),
        cc_port: ($cc_port | if . == "" then null else (. | tonumber) end),
        cc_transcript: ($cc_transcript | if . == "" then null else . end),
        pi_bridge_pid: ($pi_bridge_pid | if . == "" then null else (. | tonumber) end),
        pi_bridge_socket: ($pi_bridge_socket | if . == "" then null else . end),
        pi_session_id: ($pi_session_id | if . == "" then null else . end),
        cx_ws: ($cx_ws | if . == "" then null else . end),
        cx_thread_id: ($cx_thread_id | if . == "" then null else . end),
        launch: (if $launch_model == "" and $launch_effort == "" then null else {
          model: ($launch_model | if . == "" then null else . end),
          effort: ($launch_effort | if . == "" then null else . end)
        } end),
        state: "waiting",
        substate: null,
        unknown_since: null,
        last_capture_hash: null,
        last_response_at: null,
        spawned_at: $now,
        last_polled_at: $now,
        orchestration_started: false,
        scope_files_declared: null,
        scope_files_actual: null,
        decisions_log: []
      }')

    "$FD_STATE" set ".issues[\"$ISSUE\"]" "$issue_obj"
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
        "$FD_STATE" get '.issues // {} | to_entries | map({issue: .key} + .value)'
        ;;
      inner-panes)
        # Comma-separated target list, one per issue, suitable for
        # `flightdeck-daemon start --inner`. Prefer the immutable
        # `pane_id` (`%N`) when the registry recorded one; fall back to
        # `pane_target` for legacy entries that haven't been re-init'd
        # or whose pane_id resolution failed at init. Without preferring
        # pane_id here, daemon start would resolve targets through the
        # current window name and could fail on pi/codex auto-renamed
        # windows even though reconcile keeps the entries alive
        # (cross-harness review finding #4).
        "$FD_STATE" get '.issues // {} | to_entries | map(.value.pane_id // .value.pane_target // empty) | join(",")'
        ;;
      inner-harnesses)
        # Comma-separated harness list in the same issue order as
        # `inner-panes`, suitable for `flightdeck-daemon --inner-harnesses`.
        "$FD_STATE" get '.issues // {} | to_entries | map(.value.harness // "") | join(",")'
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
    line=$("$FD_STATE" get ".issues[\"$ISSUE\"] // {} | [(.oc_url // \"\"), (.oc_session_id // \"\")] | @tsv" 2>/dev/null | tr -d '"')
    url=$(awk -F'\t' '{print $1}' <<< "$line")
    sid=$(awk -F'\t' '{print $2}' <<< "$line")
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
    line=$("$FD_STATE" get ".issues[\"$ISSUE\"] // {} | [(.cc_url // \"\"), (.cc_transcript // \"\")] | @tsv" 2>/dev/null | tr -d '"')
    url=$(awk -F'\t' '{print $1}' <<< "$line")
    transcript=$(awk -F'\t' '{print $2}' <<< "$line")
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
    line=$("$FD_STATE" get ".issues[\"$ISSUE\"] // {} | [(.pi_bridge_pid // \"\"), (.pi_bridge_socket // \"\")] | @tsv" 2>/dev/null | tr -d '"')
    pid=$(awk -F'\t' '{print $1}' <<< "$line")
    socket=$(awk -F'\t' '{print $2}' <<< "$line")
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
    line=$("$FD_STATE" get ".issues[\"$ISSUE\"] // {} | [(.cx_ws // \"\"), (.cx_thread_id // \"\")] | @tsv" 2>/dev/null | tr -d '"')
    url=$(awk -F'\t' '{print $1}' <<< "$line")
    thread=$(awk -F'\t' '{print $2}' <<< "$line")
    if [[ -n "$url" && -n "$thread" && "$url" != "null" && "$thread" != "null" ]]; then
      if cx_adapter_is_fresh "$ISSUE" 2>/dev/null; then
        printf -- "--url %s --thread %s\n" "$url" "$thread"
      fi
    fi
    ;;

  find-by-pane)
    # Print the issue id whose registry entry matches the given target.
    # Accepts either `pane_target` (session:window.pane) or `pane_id`
    # (%N) — needed because `list --format inner-panes` now emits the
    # immutable pane_id when present, so daemon callers pass `%N` to
    # `find-by-pane` and must still resolve back to the issue id. Empty
    # stdout (exit 1) when no match (cross-harness verify follow-up).
    PANE_TARGET="${1:-}"
    [[ -z "$PANE_TARGET" ]] && { echo "Usage: find-by-pane <pane-target-or-pane-id>" >&2; exit 2; }
    issue=$("$FD_STATE" get ".issues // {} | to_entries[] | select(.value.pane_target == \"$PANE_TARGET\" or .value.pane_id == \"$PANE_TARGET\") | .key" 2>/dev/null | tr -d '"' | head -n1)
    if [[ -z "$issue" ]]; then
      exit 1
    fi
    echo "$issue"
    ;;

  remove-merged)
    # Drop registry entries for issues in terminal state (merged|aborted|dead)
    # whose tmux panes are gone. Called by terminate.md § 5 before archive
    # so the archived state file is scoped to actually-tracked issues, not
    # zombie post-merge entries. Primary liveness key is the immutable
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
    entry=$("$FD_STATE" get ".issues[\"$ISSUE\"] // empty" 2>"$fd_stderr_file")
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
    echo "Actions: init | list | get | set-state | set-substate | set | log-decision | remove | remove-merged | reconcile | teardown-window | teardown-entry | oc-attach-args | cc-channel-args | pi-bridge-args | cx-bridge-args | find-by-pane" >&2
    exit 2
    ;;
esac
