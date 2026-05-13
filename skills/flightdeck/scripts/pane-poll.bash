#!/usr/bin/env bash
# Poll tracked panes — read bell/activity flags, capture/classify, and emit JSON.
#
# Outputs one JSON object per observed pane. Legacy mode emits one object;
# batch mode emits JSONL, one object per registry row.
#
# Usage:
#   pane-poll <window-target|%pane_id> [<pane-index>] [--harness <h>] [--worktree <path>] [--pr <N>]
#   pane-poll --batch -        # stdin: JSON array from `pane-registry list --format json`
#   pane-poll --batch <json>   # direct JSON array (or a file path containing it)
#
# Examples:
#   pane-poll HT:cc-463
#   pane-poll HT:cc-463 0 --harness opencode
#   pane-poll %403 --harness pi
#   pane-poll HT:cc-463 0 --harness opencode --worktree trees/cc-463 --pr 463
#   pane-registry list --format json | pane-poll --batch -
#
# Batch input rows should contain:
#   {"issue":"CC-123","pane_id":"%403","pane_target":"HT:cc-123.0","harness":"pi","worktree":"/repo/trees/cc-123","pr_number":123}
#
# When --worktree and --pr are both passed (or present in batch input) and
# the worktree directory is gone AND `gh pr view <PR>` returns MERGED, the
# tag is forced to terminal-state-reached even if the classifier didn't
# recognize the orchestrator's end-of-flow text. Defense-in-depth for the
# lifecycle.
#
# JSON fields:
#   {
#     "issue": "CC-123",              # batch mode only (legacy mode omits it)
#     "window": "HT:cc-463",
#     "pane_target": "HT:cc-463.0" | "%403",
#     "dead": true,                   # only when pane/window no longer exists
#     "bell": true|false,
#     "activity": true|false,
#     "silence": true|false,
#     "tag": "rebase-multi-choice" | "rendering" | "idle" | ...,
#     "capture_hash": "sha256:...",
#     "fingerprint_match": true|false,    # registered pane still hosts the orchestrator
#     "pane_index_suggest": null|<idx>     # if mismatch, sibling pane that matched
#   }
#
# Exit codes:
#   0 - success (pane exists or dead JSON emitted)
#   1 - unused by normal polling (kept for compatibility)
#   2 - bad arguments / not in tmux / bad batch JSON
set -euo pipefail

usage() {
  local code="${1:-2}"
  cat >&2 <<'EOF'
Usage:
  pane-poll <window-target|%pane_id> [<pane-index>] [--harness <h>] [--worktree <path>] [--pr <N>]
  pane-poll --batch -
  pane-poll --batch <json-or-file>
EOF
  exit "$code"
}

if [[ -z "${TMUX:-}" ]]; then
  echo "Error: not inside a tmux session" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANE_REGISTRY="$SCRIPT_DIR/pane-registry"

# shellcheck source=lib/oc-paths.sh
source "$SCRIPT_DIR/lib/oc-paths.sh"
# shellcheck source=lib/cc-channel-paths.sh
source "$SCRIPT_DIR/lib/cc-channel-paths.sh"
# shellcheck source=lib/pi-bridge-paths.sh
source "$SCRIPT_DIR/lib/pi-bridge-paths.sh"
# shellcheck source=lib/codex-paths.sh
source "$SCRIPT_DIR/lib/codex-paths.sh"

# jq filter that extracts the last assistant message text from a claude
# JSONL transcript. JSONL lines vary slightly across versions; defensive
# across the common shapes:
#   { "type": "...", "message": { "role": "assistant", "content": [
#     {"type":"text","text":"..."}, ... ], "stop_reason": "..." } }
# Also handles top-level role + content (no .message wrapper).
CC_LAST_ASSISTANT_JQ='
  [ inputs | select(((.message.role // .role // "") == "assistant")) ]
  | last
  | if . == null then ""
    else
      ( .message.content // .content // [] )
      | (if type == "array" then map(select(.type == "text") | .text // "") | join("") else . end)
    end
'

CAPTURE_ARGS=(-p -S -200)

declare -A META_WINDOW=() META_LIST_TARGET=() META_INDEX=() META_BELL=() META_ACTIVITY=() META_SILENCE=() PANE_ID_BY_TARGET=()

refresh_tmux_metadata() {
  META_WINDOW=()
  META_LIST_TARGET=()
  META_INDEX=()
  META_BELL=()
  META_ACTIVITY=()
  META_SILENCE=()
  PANE_ID_BY_TARGET=()

  local pid sess wname wid pidx bell activity silence window human_target
  while IFS=$'\t' read -r pid sess wname wid pidx bell activity silence; do
    [[ -z "$pid" || "$pid" != %* ]] && continue
    window="${sess}:${wname}"
    human_target="${window}.${pidx}"
    META_WINDOW[$pid]="$window"
    META_LIST_TARGET[$pid]="${wid:-$window}"
    META_INDEX[$pid]="${pidx:-0}"
    META_BELL[$pid]="${bell:-0}"
    META_ACTIVITY[$pid]="${activity:-0}"
    META_SILENCE[$pid]="${silence:-0}"
    PANE_ID_BY_TARGET[$human_target]="$pid"
  done < <(tmux list-panes -a -F '#{pane_id}	#{session_name}	#{window_name}	#{window_id}	#{pane_index}	#{window_bell_flag}	#{window_activity_flag}	#{window_silence_flag}' 2>/dev/null)
}

json_dead() {
  local issue="$1" window="$2" pane="$3"
  jq -nc --arg issue "$issue" --arg w "$window" --arg p "$pane" '
    {window:$w, pane_target:$p, dead:true, tag:"dead"}
    | if $issue != "" then {issue:$issue} + . else . end
  '
}

json_result() {
  local issue="$1" window="$2" pane="$3" bell="$4" activity="$5" silence="$6" tag="$7" capture_hash="$8" fingerprint_match="$9" pane_index_suggest="${10}"
  jq -nc \
    --arg issue "$issue" \
    --arg window "$window" \
    --arg pane "$pane" \
    --argjson bell "$([ "${bell:-0}" = "1" ] && echo true || echo false)" \
    --argjson activity "$([ "${activity:-0}" = "1" ] && echo true || echo false)" \
    --argjson silence "$([ "${silence:-0}" = "1" ] && echo true || echo false)" \
    --arg tag "$tag" \
    --arg capture_hash "$capture_hash" \
    --argjson fingerprint_match "$fingerprint_match" \
    --argjson pane_index_suggest "$pane_index_suggest" \
    '{
      window: $window,
      pane_target: $pane,
      bell: $bell,
      activity: $activity,
      silence: $silence,
      tag: $tag,
      capture_hash: $capture_hash,
      fingerprint_match: $fingerprint_match,
      pane_index_suggest: $pane_index_suggest
    } | if $issue != "" then {issue:$issue} + . else . end'
}

split_target_and_index() {
  local raw_target="$1" explicit_index="$2"
  if [[ -n "$explicit_index" ]]; then
    printf '%s\t%s\t%s\n' "$raw_target" "${raw_target}.${explicit_index}" "$explicit_index"
    return
  fi
  if [[ "$raw_target" =~ ^(.+)\.([0-9]+)$ ]]; then
    printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "$raw_target" "${BASH_REMATCH[2]}"
  else
    printf '%s\t%s\t%s\n' "$raw_target" "${raw_target}.0" "0"
  fi
}

registry_issue_for_pane() {
  local issue="$1" pane_lookup="$2" raw
  if [[ -n "$issue" ]]; then
    printf '%s' "$issue"
    return 0
  fi
  raw=$("$PANE_REGISTRY" find-by-pane "$pane_lookup" 2>/dev/null || true)
  if [[ "$raw" == \{* ]]; then
    jq -r '.id // empty' <<< "$raw" 2>/dev/null || true
  else
    printf '%s' "$raw"
  fi
}

resolve_oc_args() {
  local issue="$1" pane_lookup="$2" derive_target="$3" row_url="${4:-}" row_sid="${5:-}" from_batch="${6:-0}" adapter_issue args derived_issue
  adapter_issue=$(registry_issue_for_pane "$issue" "$pane_lookup")
  args=""
  if [[ -n "$adapter_issue" && -n "$row_url" && -n "$row_sid" ]]; then
    if oc_adapter_is_fresh "$adapter_issue" 2>/dev/null; then
      args="--url $row_url --session $row_sid"
    fi
  elif [[ -n "$adapter_issue" && "$from_batch" != "1" ]]; then
    args=$("$PANE_REGISTRY" oc-attach-args "$adapter_issue" 2>/dev/null || echo "")
  fi
  if [[ -z "$args" ]]; then
    derived_issue=$(oc_issue_from_pane_target "$derive_target")
    if [[ -n "$derived_issue" ]]; then
      args=$(oc_attach_args_from_spawn "$derived_issue" 2>/dev/null || echo "")
    fi
  fi
  printf '%s' "$args"
}

resolve_cc_args() {
  local issue="$1" pane_lookup="$2" derive_target="$3" row_url="${4:-}" row_transcript="${5:-}" from_batch="${6:-0}" adapter_issue args derived_issue cc_spawn cc_url cc_transcript
  adapter_issue=$(registry_issue_for_pane "$issue" "$pane_lookup")
  args=""
  if [[ -n "$adapter_issue" && -n "$row_url" && -n "$row_transcript" ]]; then
    if cc_adapter_is_fresh "$adapter_issue" 2>/dev/null; then
      args="--url $row_url --transcript $row_transcript"
    fi
  elif [[ -n "$adapter_issue" && "$from_batch" != "1" ]]; then
    args=$("$PANE_REGISTRY" cc-channel-args "$adapter_issue" 2>/dev/null || echo "")
  fi
  if [[ -z "$args" ]]; then
    derived_issue=$(oc_issue_from_pane_target "$derive_target")
    if [[ -n "$derived_issue" ]]; then
      cc_spawn="$(cc_spawn_file "$derived_issue")"
      if [[ -f "$cc_spawn" ]] && cc_adapter_is_fresh "$derived_issue" 2>/dev/null; then
        cc_url=$(jq -r '.url // ""' "$cc_spawn" 2>/dev/null || echo "")
        cc_transcript=$(jq -r '.transcript // ""' "$cc_spawn" 2>/dev/null || echo "")
        if [[ -n "$cc_url" && -n "$cc_transcript" ]]; then
          args="--url $cc_url --transcript $cc_transcript"
        fi
      fi
    fi
  fi
  printf '%s' "$args"
}

resolve_pi_args() {
  local issue="$1" pane_lookup="$2" derive_target="$3" row_pid="${4:-}" row_socket="${5:-}" from_batch="${6:-0}" adapter_issue args derived_issue pi_spawn pi_pid_v pi_socket_v
  adapter_issue=$(registry_issue_for_pane "$issue" "$pane_lookup")
  args=""
  if [[ -n "$adapter_issue" && -n "$row_pid" && -n "$row_socket" ]]; then
    if pi_bridge_is_fresh "$row_pid" "$row_socket"; then
      args="--pid $row_pid --socket $row_socket"
    fi
  elif [[ -n "$adapter_issue" && "$from_batch" != "1" ]]; then
    args=$("$PANE_REGISTRY" pi-bridge-args "$adapter_issue" 2>/dev/null || echo "")
  fi
  if [[ -z "$args" ]]; then
    derived_issue=$(oc_issue_from_pane_target "$derive_target")
    if [[ -n "$derived_issue" ]]; then
      pi_spawn="$(pi_spawn_file "$derived_issue")"
      if [[ -f "$pi_spawn" ]]; then
        pi_pid_v=$(jq -r '.pid // ""' "$pi_spawn" 2>/dev/null || echo "")
        pi_socket_v=$(jq -r '.socket // ""' "$pi_spawn" 2>/dev/null || echo "")
        if [[ -n "$pi_pid_v" && -n "$pi_socket_v" ]] && pi_bridge_is_fresh "$pi_pid_v" "$pi_socket_v"; then
          args="--pid $pi_pid_v --socket $pi_socket_v"
        fi
      fi
    fi
  fi
  printf '%s' "$args"
}

resolve_cx_args() {
  local issue="$1" pane_lookup="$2" derive_target="$3" row_url="${4:-}" row_thread="${5:-}" from_batch="${6:-0}" adapter_issue args derived_issue cx_spawn cx_url cx_thread
  adapter_issue=$(registry_issue_for_pane "$issue" "$pane_lookup")
  args=""
  if [[ -n "$adapter_issue" && -n "$row_url" && -n "$row_thread" ]]; then
    if cx_adapter_is_fresh "$adapter_issue" 2>/dev/null; then
      args="--url $row_url --thread $row_thread"
    fi
  elif [[ -n "$adapter_issue" && "$from_batch" != "1" ]]; then
    args=$("$PANE_REGISTRY" cx-bridge-args "$adapter_issue" 2>/dev/null || echo "")
  fi
  if [[ -z "$args" ]]; then
    derived_issue=$(oc_issue_from_pane_target "$derive_target")
    if [[ -n "$derived_issue" ]]; then
      cx_spawn="$(cx_spawn_file "$derived_issue")"
      if [[ -f "$cx_spawn" ]] && cx_adapter_is_fresh "$derived_issue" 2>/dev/null; then
        cx_url=$(jq -r '.url // ""' "$cx_spawn" 2>/dev/null || echo "")
        cx_thread=$(jq -r '.thread_id // ""' "$cx_spawn" 2>/dev/null || echo "")
        if [[ -n "$cx_url" && -n "$cx_thread" ]]; then
          args="--url $cx_url --thread $cx_thread"
        fi
      fi
    fi
  fi
  printf '%s' "$args"
}

poll_one() {
  local issue="$1" raw_target="$2" explicit_index="$3" harness="$4" worktree="$5" pr="$6"
  local row_oc_url="${7:-}" row_oc_session="${8:-}" row_cc_url="${9:-}" row_cc_transcript="${10:-}"
  local row_pi_pid="${11:-}" row_pi_socket="${12:-}" row_cx_url="${13:-}" row_cx_thread="${14:-}"
  local from_batch="${15:-0}"
  local window_target pane_target pane_index pid window_list_target derive_target output_pane
  local bell=0 activity=0 silence=0

  [[ -z "$raw_target" || "$raw_target" == "null" ]] && { json_dead "$issue" "" ""; return 0; }

  if [[ "$raw_target" == %* ]]; then
    pid="$raw_target"
    output_pane="$pid"
    if [[ -z "${META_WINDOW[$pid]:-}" ]]; then
      json_dead "$issue" "$raw_target" "$output_pane"
      return 0
    fi
    window_target="${META_WINDOW[$pid]}"
    window_list_target="${META_LIST_TARGET[$pid]:-$window_target}"
    pane_index="${META_INDEX[$pid]:-0}"
    derive_target="${window_target}.${pane_index}"
    bell="${META_BELL[$pid]:-0}"
    activity="${META_ACTIVITY[$pid]:-0}"
    silence="${META_SILENCE[$pid]:-0}"
  else
    local split
    split=$(split_target_and_index "$raw_target" "$explicit_index")
    IFS=$'\t' read -r window_target pane_target pane_index <<< "$split"
    output_pane="$pane_target"
    pid="${PANE_ID_BY_TARGET[$pane_target]:-}"
    if [[ -z "$pid" ]]; then
      json_dead "$issue" "$window_target" "$output_pane"
      return 0
    fi
    window_target="${META_WINDOW[$pid]:-$window_target}"
    window_list_target="${META_LIST_TARGET[$pid]:-$window_target}"
    pane_index="${META_INDEX[$pid]:-$pane_index}"
    derive_target="${window_target}.${pane_index}"
    bell="${META_BELL[$pid]:-0}"
    activity="${META_ACTIVITY[$pid]:-0}"
    silence="${META_SILENCE[$pid]:-0}"
  fi

  # Capture and classify. For panes with adapter metadata, fetch the
  # latest assistant text via the harness adapter. Tmux capture-pane is
  # only the fallback for panes without fresh bridge metadata.
  local buf="" oc_used=0 cc_used=0 pi_used=0 cx_used=0
  local oc_attach_args oc_url oc_session resp
  if [[ "$harness" == "opencode" ]]; then
    oc_attach_args=$(resolve_oc_args "$issue" "$output_pane" "$derive_target" "$row_oc_url" "$row_oc_session" "$from_batch")
    if [[ -n "$oc_attach_args" ]]; then
      oc_used=1
      oc_url=$(awk '{for(i=1;i<=NF;i++)if($i=="--url"){print $(i+1);exit}}' <<< "$oc_attach_args")
      oc_session=$(awk '{for(i=1;i<=NF;i++)if($i=="--session"){print $(i+1);exit}}' <<< "$oc_attach_args")
      resp=$(curl -s --max-time 5 "$oc_url/session/$oc_session/message" 2>/dev/null || echo "")
      if [[ -n "$resp" ]]; then
        buf=$(jq -r "$OC_LAST_ASSISTANT_JQ" <<< "$resp" 2>/dev/null || echo "")
      fi
    fi
  fi

  local cc_args cc_transcript
  if [[ "$harness" == "claude" && $oc_used -eq 0 ]]; then
    cc_args=$(resolve_cc_args "$issue" "$output_pane" "$derive_target" "$row_cc_url" "$row_cc_transcript" "$from_batch")
    if [[ -n "$cc_args" ]]; then
      cc_used=1
      cc_transcript=$(awk '{for(i=1;i<=NF;i++)if($i=="--transcript"){print $(i+1);exit}}' <<< "$cc_args")
      if [[ -f "$cc_transcript" ]]; then
        buf=$(jq -r "$CC_LAST_ASSISTANT_JQ" "$cc_transcript" 2>/dev/null || echo "")
      fi
    fi
  fi

  local pi_args pi_pid_v pi_socket_v pi_target_args pi_bin hist
  if [[ "$harness" == "pi" && $oc_used -eq 0 && $cc_used -eq 0 ]]; then
    pi_args=$(resolve_pi_args "$issue" "$output_pane" "$derive_target" "$row_pi_pid" "$row_pi_socket" "$from_batch")
    if [[ -n "$pi_args" ]]; then
      pi_used=1
      pi_pid_v=$(awk '{for(i=1;i<=NF;i++)if($i=="--pid"){print $(i+1);exit}}' <<< "$pi_args")
      pi_socket_v=$(awk '{for(i=1;i<=NF;i++)if($i=="--socket"){print $(i+1);exit}}' <<< "$pi_args")
      pi_target_args=()
      if [[ -n "$pi_socket_v" ]]; then
        pi_target_args=(--socket "$pi_socket_v")
      else
        pi_target_args=(--pid "$pi_pid_v")
      fi
      pi_bin=$(pi_resolve_bridge_bin 2>/dev/null || echo "")
      if [[ -n "$pi_bin" ]]; then
        hist=$("$pi_bin" history "${pi_target_args[@]}" 50 2>/dev/null || echo "")
        if [[ -n "$hist" ]]; then
          buf=$(jq -r "$PI_LAST_ASSISTANT_JQ" <<< "$hist" 2>/dev/null || echo "")
        fi
      fi
    fi
  fi

  local cx_args cx_url cx_thread turns
  if [[ "$harness" == "codex" && $oc_used -eq 0 && $cc_used -eq 0 && $pi_used -eq 0 ]]; then
    cx_args=$(resolve_cx_args "$issue" "$output_pane" "$derive_target" "$row_cx_url" "$row_cx_thread" "$from_batch")
    if [[ -n "$cx_args" ]]; then
      cx_used=1
      cx_url=$(awk '{for(i=1;i<=NF;i++)if($i=="--url"){print $(i+1);exit}}' <<< "$cx_args")
      cx_thread=$(awk '{for(i=1;i<=NF;i++)if($i=="--thread"){print $(i+1);exit}}' <<< "$cx_args")
      turns=$(cx_bridge_run turns --url "$cx_url" --thread "$cx_thread" 2>/dev/null || echo "")
      if [[ -n "$turns" ]]; then
        buf=$(jq -r "$CX_LAST_ASSISTANT_JQ" <<< "$turns" 2>/dev/null || echo "")
      fi
    fi
  fi

  if [[ $oc_used -eq 0 && $cc_used -eq 0 && $pi_used -eq 0 && $cx_used -eq 0 ]]; then
    if ! buf=$(tmux capture-pane -t "$output_pane" "${CAPTURE_ARGS[@]}" 2>/dev/null); then
      if ! tmux list-panes -t "$output_pane" >/dev/null 2>&1; then
        json_dead "$issue" "$window_target" "$output_pane"
        return 0
      fi
      buf=""
    fi
  fi

  local capture_hash tag
  capture_hash=$(printf '%s' "$buf" | sha256sum | awk '{print "sha256:"$1}')
  # Adapter-mode input has no TUI footer; skip the footer gate so option-list
  # / merge-now / etc. shapes classify correctly. Tmux-fallback path keeps
  # the footer gate as a buffer-completeness signal.
  if [[ $oc_used -eq 1 || $cc_used -eq 1 || $pi_used -eq 1 || $cx_used -eq 1 ]]; then
    tag=$(printf '%s' "$buf" | "$SCRIPT_DIR/prompt-classify" --no-footer-gate 2>/dev/null || echo "idle")
  else
    tag=$(printf '%s' "$buf" | "$SCRIPT_DIR/prompt-classify" 2>/dev/null || echo "idle")
  fi

  # Orphan cross-check — when caller passes --worktree and --pr, synthesize
  # terminal-state-reached if the worktree directory is gone AND the PR is
  # merged. Defense-in-depth against the classifier missing the orchestrator's
  # end-of-flow text.
  if [[ "$tag" != "terminal-state-reached" && -n "$worktree" && "$worktree" != "null" && -n "$pr" && "$pr" != "null" ]]; then
    if [[ ! -d "$worktree" ]]; then
      if command -v gh >/dev/null 2>&1; then
        local pr_state
        pr_state=$(gh pr view "$pr" --json state --jq '.state' 2>/dev/null || echo "")
        if [[ "$pr_state" == "MERGED" ]]; then
          tag="terminal-state-reached"
        fi
      fi
    fi
  fi

  # Fingerprint check — confirm the registered pane still hosts the
  # orchestrator TUI. Only scans siblings when the registered pane fails
  # the sentinel; adapter modes skip because their data path is bound to
  # the harness session, not tmux layout.
  local fingerprint_match=true pane_index_suggest=null fingerprint_sentinel sib_buf idx sib_pane_id
  if [[ $oc_used -eq 0 && $cc_used -eq 0 && $pi_used -eq 0 && $cx_used -eq 0 ]]; then
    fingerprint_sentinel='❯ |claude code|opencode|codex>|■■■|⠋|⠙|⠸|⠴|⠦|⠧'
    if ! grep -qE "$fingerprint_sentinel" <<< "$buf"; then
      fingerprint_match=false
      while IFS=$'\t' read -r idx sib_pane_id; do
        [[ -z "$idx" || "$idx" == "$pane_index" || "$sib_pane_id" == "$output_pane" ]] && continue
        sib_buf=$(tmux capture-pane -t "$sib_pane_id" -p -S -50 2>/dev/null || echo "")
        if grep -qE "$fingerprint_sentinel" <<< "$sib_buf"; then
          pane_index_suggest="$idx"
          break
        fi
      done < <(tmux list-panes -t "$window_list_target" -F '#{pane_index}	#{pane_id}' 2>/dev/null)
    fi
  fi

  json_result "$issue" "$window_target" "$output_pane" "$bell" "$activity" "$silence" "$tag" "$capture_hash" "$fingerprint_match" "$pane_index_suggest"
}

run_batch() {
  local src="$1" batch_json
  if [[ "$src" == "-" ]]; then
    batch_json=$(cat)
  elif [[ -f "$src" ]]; then
    batch_json=$(cat "$src")
  else
    batch_json="$src"
  fi

  if ! jq -e 'type == "array"' <<< "$batch_json" >/dev/null 2>&1; then
    echo "Error: --batch input must be a JSON array" >&2
    exit 2
  fi

  refresh_tmux_metadata
  local issue target pane_id pane_target harness worktree pr oc_url oc_session cc_url cc_transcript pi_pid pi_socket cx_url cx_thread
  while IFS=$'\t' read -r issue pane_id pane_target harness worktree pr oc_url oc_session cc_url cc_transcript pi_pid pi_socket cx_url cx_thread; do
    [[ -z "$issue$pane_id$pane_target" ]] && continue
    if [[ -n "$pane_id" && "$pane_id" != "null" ]]; then
      target="$pane_id"
    else
      target="$pane_target"
    fi
    poll_one "$issue" "$target" "" "$harness" "$worktree" "$pr" \
      "$oc_url" "$oc_session" "$cc_url" "$cc_transcript" "$pi_pid" "$pi_socket" "$cx_url" "$cx_thread" "1"
  done < <(jq -r '.[] | [
    (.issue // ""),
    (.pane_id // ""),
    (.pane_target // ""),
    (.harness // ""),
    (.worktree // ""),
    (.pr_number // "" | tostring),
    (.oc_url // ""),
    (.oc_session_id // ""),
    (.cc_url // ""),
    (.cc_transcript // ""),
    (.pi_bridge_pid // "" | tostring),
    (.pi_bridge_socket // ""),
    (.cx_ws // ""),
    (.cx_thread_id // "")
  ] | @tsv' <<< "$batch_json")
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage 0
fi

if [[ "${1:-}" == "--batch" ]]; then
  shift
  [[ $# -eq 1 ]] || usage
  run_batch "$1"
  exit 0
fi

TARGET="${1:-}"
[[ -z "$TARGET" ]] && usage
shift || true

# Optional: pinned pane index (default 0). When TARGET is an immutable tmux
# pane id (`%N`), the second positional is ignored unless it is a flag; direct
# pane-id mode resolves the live pane index from tmux metadata below.
PANE_INDEX="0"
if [[ $# -gt 0 && "${1:-}" != --* && "$TARGET" != %* ]]; then
  PANE_INDEX="$1"
  shift || true
fi

HARNESS=""
WORKTREE=""
PR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness) HARNESS="$2"; shift 2 ;;
    --harness=*) HARNESS="${1#--harness=}"; shift ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --worktree=*) WORKTREE="${1#--worktree=}"; shift ;;
    --pr) PR="$2"; shift 2 ;;
    --pr=*) PR="${1#--pr=}"; shift ;;
    -h|--help) usage ;;
    *) shift ;;
  esac
done

refresh_tmux_metadata
poll_one "" "$TARGET" "$PANE_INDEX" "$HARNESS" "$WORKTREE" "$PR"
