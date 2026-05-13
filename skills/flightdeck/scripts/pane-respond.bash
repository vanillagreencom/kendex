#!/usr/bin/env bash
# Send a response to a pane's per-issue orchestrator UI.
#
# Modes (mutually exclusive):
#   <payload>             Free-text — types the payload into the cursor's current location.
#                         Used for "Type your own answer" flows after navigating to that
#                         option, or for plain text input.
#   --option N            Numeric option pick — navigates to option N (1-indexed) using
#                         the harness's option-list mechanic and submits.
#   --option-multi N1,N2,... Toggle multiple items in a checkbox-tab UI (claude code's
#                         multi-select-tabbed shape). Walks Down to each row, presses
#                         Space to toggle, then Right + Enter to submit. Picks are
#                         sorted ascending; only walks the list once. Use for the
#                         multi-select-tabbed classifier tag.
#   --keys k1,k2,...      Raw key sequence — sends each key name through tmux send-keys.
#                         Use for multi-step forms (e.g., toggle then advance page then
#                         submit). Recognized: Up Down Left Right Enter Tab Space Escape.
#   --question <reqID> --answer <label>          Structured question reply (opencode/pi, one tab).
#   --question <reqID> --answer-multi l1,l2,...  Multi-pick reply (one tab, when question.multiple).
#   --question <reqID> --answer-text <text>       Pi custom/free-type reply (one tab, when allowCustom).
#   --question <reqID> --answers-json '[[...]]'  Full per-tab answer matrix for multi-tab requests.
#   --question <reqID> --reject                  Cancel the question without answering.
#                         Opencode routes to POST <oc_url>/question/<reqID>/{reply,reject}.
#                         Pi routes to `pi-bridge answer|reject`. Daemon subscribers emit
#                         `oc-question` / `pi-question` wake events with the structured
#                         payload (header, options, multiple, allowCustom). No tmux send-keys.
#
# Always targets an explicit pane index. Harness-aware: option-pick mechanics differ
# across harnesses. The --harness flag selects the adapter; default is claude.
#   claude   — (N-1) Down then Enter. Numeric digits are buffered as text.
#   opencode — primary path is `opencode run --attach --format json` over the
#              HTTP-attach adapter (see open-terminal). Modes route as:
#                payload         → message arg
#                --option N      → bare digit "N" (LLM interprets contextually)
#                --option-multi  → comma-spaced digits as text ("1, 3")
#                --keys          → REJECTED unless --keys-allow-tmux
#                --question      → opencode HTTP question API
#              When the pane has no oc-attach metadata in pane-registry
#              (legacy session, opencode unavailable, port exhausted),
#              falls back to generic tmux paste-buffer with a logged
#              `oc-attach-unavailable` notice. --option / --option-multi
#              are unsupported in fallback for opencode (no digit-key
#              adapter; use payload mode instead).
#
# Usage:
#   pane-respond <pane-target> <payload> [--tag <tag>] [--no-enter] [--no-clear]
#   pane-respond <pane-target> --option <N> [--harness <h>] [--no-clear]
#   pane-respond <pane-target> --keys <k1,k2,...> [--no-clear]
#   pane-respond <pane-target> --harness pi --question que_... --answer-text "custom text"
#   pane-respond <pane-target> --harness pi --question que_... --answers-json '[["A"],["custom"]]'
#
# Examples:
#   pane-respond HT:cc-463.0 "Rebase + force push.\n\nPRESERVE: ..." --tag rebase-multi-choice
#   pane-respond HT:cc-463.0 --option 2
#   pane-respond HT:cc-463.0 --keys Space,Right,Enter           # toggle, next page, submit
#
# Flags:
#   --tag <tag>          Classification tag — triggers payload validation for known shapes.
#                        Currently enforced: rebase-multi-choice (must include
#                        PRESERVE/APPLY/VERIFY).
#   --harness <name>     Harness adapter for option-pick mode. Default: claude.
#   --no-enter           Send free-text without trailing Enter (for partial input).
#   --no-clear           Skip bell clearing (for batched sends).
#   --keys-allow-tmux    For adapter-backed harnesses, permit --keys to send via tmux
#                        send-keys instead of erroring. Use only for true modal cases
#                        (TUI dialogs the HTTP-attach adapter can't reach).
#   --confirm-advanced   After sending, poll the pane until the prompt sentinel
#                        is gone (or 8s timeout). Tmux fallback path only —
#                        opencode adapter mode is naturally synchronous.
#                        Returns non-zero on timeout so callers can recover.
#
# Exit codes:
#   0 - sent successfully (and prompt advanced if --confirm-advanced was set)
#   1 - validation failure (bad payload for declared tag, or unsupported harness)
#   2 - bad arguments / not in tmux
#   3 - busy: pane shows active spinner; caller should wait and retry
#   4 - confirm-advanced timed out; prompt sentinel still present after 8s
#   5 - opencode adapter call failed (timeout / non-zero exit / no completion)
set -euo pipefail

if [[ -z "${TMUX:-}" ]]; then
  echo "Error: not inside a tmux session" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source adapter helpers unconditionally (top-level scope) so any
# harness branch below has access to shared utility functions like
# oc_issue_from_pane_target, oc_attach_args_from_spawn, cc_*.
# shellcheck source=lib/oc-paths.sh
source "$SCRIPT_DIR/lib/oc-paths.sh"
# shellcheck source=lib/cc-channel-paths.sh
source "$SCRIPT_DIR/lib/cc-channel-paths.sh"
# shellcheck source=lib/pi-bridge-paths.sh
source "$SCRIPT_DIR/lib/pi-bridge-paths.sh"
# shellcheck source=lib/codex-paths.sh
source "$SCRIPT_DIR/lib/codex-paths.sh"

pane_registry_find_id() {
  local target="$1" raw
  raw=$("$SCRIPT_DIR/pane-registry" find-by-pane "$target" 2>/dev/null || true)
  if [[ "$raw" == \{* ]]; then
    jq -r '.id // empty' <<< "$raw" 2>/dev/null || true
  else
    printf '%s' "$raw"
  fi
}

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "Usage: pane-respond <pane-target> <payload>|--option N|--keys k1,k2,... [flags]" >&2
  exit 2
fi
shift

PAYLOAD=""
MODE="payload"
OPTION_N=""
OPTION_MULTI_CSV=""
KEYS_CSV=""
TAG=""
HARNESS="claude"
SEND_ENTER=1
CLEAR_BELL=1
KEYS_ALLOW_TMUX=0
CONFIRM_ADVANCED=0
QUESTION_ID=""
ANSWER_LABEL=""
ANSWER_MULTI_CSV=""
ANSWER_TEXT=""
ANSWERS_JSON=""
REJECT_QUESTION=0

# Optional positional payload (must precede flags).
if [[ $# -gt 0 && "$1" != --* ]]; then
  PAYLOAD="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --option) MODE="option"; OPTION_N="$2"; shift 2 ;;
    --option=*) MODE="option"; OPTION_N="${1#--option=}"; shift ;;
    --option-multi) MODE="option-multi"; OPTION_MULTI_CSV="$2"; shift 2 ;;
    --option-multi=*) MODE="option-multi"; OPTION_MULTI_CSV="${1#--option-multi=}"; shift ;;
    --keys) MODE="keys"; KEYS_CSV="$2"; shift 2 ;;
    --keys=*) MODE="keys"; KEYS_CSV="${1#--keys=}"; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    --tag=*) TAG="${1#--tag=}"; shift ;;
    --harness) HARNESS="$2"; shift 2 ;;
    --harness=*) HARNESS="${1#--harness=}"; shift ;;
    --no-enter) SEND_ENTER=0; shift ;;
    --no-clear) CLEAR_BELL=0; shift ;;
    --keys-allow-tmux) KEYS_ALLOW_TMUX=1; shift ;;
    --confirm-advanced) CONFIRM_ADVANCED=1; shift ;;
    --question) MODE="question"; QUESTION_ID="$2"; shift 2 ;;
    --question=*) MODE="question"; QUESTION_ID="${1#--question=}"; shift ;;
    --answer) ANSWER_LABEL="$2"; shift 2 ;;
    --answer=*) ANSWER_LABEL="${1#--answer=}"; shift ;;
    --answer-multi) ANSWER_MULTI_CSV="$2"; shift 2 ;;
    --answer-multi=*) ANSWER_MULTI_CSV="${1#--answer-multi=}"; shift ;;
    --answer-text) ANSWER_TEXT="$2"; shift 2 ;;
    --answer-text=*) ANSWER_TEXT="${1#--answer-text=}"; shift ;;
    --answers-json) ANSWERS_JSON="$2"; shift 2 ;;
    --answers-json=*) ANSWERS_JSON="${1#--answers-json=}"; shift ;;
    --reject) REJECT_QUESTION=1; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Mode validation.
case "$MODE" in
  option)
    [[ -z "$OPTION_N" || ! "$OPTION_N" =~ ^[1-9][0-9]*$ ]] && {
      echo "Error: --option requires a positive integer" >&2; exit 2; }
    [[ -n "$PAYLOAD" ]] && {
      echo "Error: --option is mutually exclusive with positional payload" >&2; exit 2; }
    # Tag-aware guardrail: multi-select-tabbed shape needs --option-multi.
    # Sending --option N would walk Down the list and toggle items along
    # the way (Round 4 broke CC-489's checkbox-tabbed prompt this way).
    if [[ "$TAG" == "multi-select-tabbed" ]]; then
      echo "Error: tag 'multi-select-tabbed' requires --option-multi N1,N2,..., not --option N" >&2
      echo "       --option walks the list and toggles items along the path." >&2
      exit 1
    fi
    ;;
  option-multi)
    [[ -z "$OPTION_MULTI_CSV" ]] && {
      echo "Error: --option-multi requires a comma-separated list of integers" >&2; exit 2; }
    if ! [[ "$OPTION_MULTI_CSV" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]]; then
      echo "Error: --option-multi must be CSV of positive integers (e.g. 1,3,4)" >&2; exit 2
    fi
    [[ -n "$PAYLOAD" ]] && {
      echo "Error: --option-multi is mutually exclusive with positional payload" >&2; exit 2; }
    ;;
  keys)
    [[ -z "$KEYS_CSV" ]] && { echo "Error: --keys requires a comma-separated list" >&2; exit 2; }
    [[ -n "$PAYLOAD" ]] && {
      echo "Error: --keys is mutually exclusive with positional payload" >&2; exit 2; }
    ;;
  payload)
    [[ -z "$PAYLOAD" ]] && {
      echo "Usage: pane-respond <pane-target> <payload>|--option N|--keys k1,k2,... [flags]" >&2
      exit 2; }
    ;;
  question)
    [[ -z "$QUESTION_ID" ]] && {
      echo "Error: --question requires a request_id (que_…)" >&2; exit 2; }
    [[ -n "$PAYLOAD" ]] && {
      echo "Error: --question is mutually exclusive with positional payload" >&2; exit 2; }
    if [[ "$REJECT_QUESTION" -eq 0 && -z "$ANSWER_LABEL" && -z "$ANSWER_MULTI_CSV" && -z "$ANSWER_TEXT" && -z "$ANSWERS_JSON" ]]; then
      echo "Error: --question requires --answer <label>, --answer-multi <l1,l2,...>, --answer-text <text>, --answers-json '[[...]]', or --reject" >&2
      exit 2
    fi
    answer_modes=0
    [[ -n "$ANSWER_LABEL" ]] && answer_modes=$((answer_modes + 1))
    [[ -n "$ANSWER_MULTI_CSV" ]] && answer_modes=$((answer_modes + 1))
    [[ -n "$ANSWER_TEXT" ]] && answer_modes=$((answer_modes + 1))
    [[ -n "$ANSWERS_JSON" ]] && answer_modes=$((answer_modes + 1))
    if (( answer_modes > 1 )); then
      echo "Error: --answer, --answer-multi, --answer-text, and --answers-json are mutually exclusive" >&2; exit 2
    fi
    if [[ -n "$ANSWERS_JSON" ]] && ! jq -e 'type == "array" and all(.[]; type == "array")' <<< "$ANSWERS_JSON" >/dev/null 2>&1; then
      echo "Error: --answers-json must be a JSON array of per-tab arrays, e.g. '[[\"A\"],[\"B\"]]'" >&2; exit 2
    fi
    if [[ "$REJECT_QUESTION" -eq 1 && $answer_modes -gt 0 ]]; then
      echo "Error: --reject is mutually exclusive with answer flags" >&2; exit 2
    fi
    if [[ "$HARNESS" != "opencode" && "$HARNESS" != "pi" ]]; then
      echo "Error: --question is only supported for harness=opencode or harness=pi" >&2; exit 1
    fi
    if [[ "$HARNESS" == "opencode" && -n "$ANSWER_TEXT" ]]; then
      echo "Error: --answer-text is only supported for harness=pi questions with allowCustom=true" >&2; exit 1
    fi
    ;;
esac

# Enforce explicit pane index.
if [[ "$TARGET" != *"."* ]]; then
  echo "Error: target must include explicit pane index (e.g., HT:cc-463.0)" >&2
  exit 2
fi

# Tag-specific payload validation (payload mode only).
if [[ "$MODE" == "payload" ]]; then
  case "$TAG" in
    rebase-multi-choice)
      missing=()
      grep -q -F "PRESERVE:" <<< "$PAYLOAD" || missing+=("PRESERVE")
      grep -q -F "APPLY:"    <<< "$PAYLOAD" || missing+=("APPLY")
      grep -q -F "VERIFY:"   <<< "$PAYLOAD" || missing+=("VERIFY")
      if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: rebase-multi-choice payload missing required section(s): ${missing[*]}" >&2
        echo "       Each rebase response must include PRESERVE / APPLY / VERIFY (see patterns/prompt-handlers.md)." >&2
        exit 1
      fi
      ;;
    "" | *) : ;;
  esac
fi

# --- Per-harness option-pick adapters ---------------------------------------
#
# Each harness has its own prompt UX. Numeric digits are NOT shortcuts in
# Claude Code — they're buffered as text. Picking option N requires arrow
# navigation. If your harness uses a different mechanic (number keys,
# vim-style j/k, etc.), add an adapter here.

claude_select_option() {
  local pane="$1" n="$2"
  local steps=$((n - 1))
  if [[ $steps -gt 0 ]]; then
    for _ in $(seq 1 "$steps"); do
      tmux send-keys -t "$pane" Down
    done
  fi
  tmux send-keys -t "$pane" Enter
}

select_option_for_harness() {
  local harness="$1" pane="$2" n="$3"
  case "$harness" in
    claude) claude_select_option "$pane" "$n" ;;
    *)
      echo "Error: --option not supported for harness '$harness' in tmux fallback" >&2
      echo "       Use payload mode (free-text digit) instead, or add an adapter." >&2
      return 1
      ;;
  esac
}

# Multi-select on Claude Code's checkbox-tab UI: cursor starts on row 1
# of the items tab. For each pick (sorted ascending so we only walk Down):
# move Down to the row, Space to toggle. After all toggles, Right advances
# to the Submit tab; Enter confirms. Sorting prevents toggling rows along
# a back-walk path (which Claude Code's UI doesn't support cleanly).
claude_select_option_multi() {
  local pane="$1" csv="$2"
  local IFS=,
  local -a picks
  read -ra picks <<< "$csv"
  # Sort ascending + dedupe; we only walk Down.
  local -a sorted_picks
  while IFS= read -r p; do sorted_picks+=("$p"); done < <(printf '%s\n' "${picks[@]}" | sort -un)

  local prev=1
  local n
  for n in "${sorted_picks[@]}"; do
    local steps=$(( n - prev ))
    if (( steps > 0 )); then
      local _i
      for _i in $(seq 1 "$steps"); do
        tmux send-keys -t "$pane" Down
      done
    fi
    tmux send-keys -t "$pane" Space
    prev=$n
  done
  tmux send-keys -t "$pane" Right
  tmux send-keys -t "$pane" Enter
}

select_option_multi_for_harness() {
  local harness="$1" pane="$2" csv="$3"
  case "$harness" in
    claude) claude_select_option_multi "$pane" "$csv" ;;
    *)
      echo "Error: --option-multi not yet supported for harness '$harness'" >&2
      echo "       Add an adapter in pane-respond before using." >&2
      return 1
      ;;
  esac
}

# Allowed key names for --keys mode. Reject anything else so we don't smuggle
# arbitrary text through this path; multi-character input belongs in payload mode.
KEYS_ALLOWED='^(Up|Down|Left|Right|Enter|Tab|Space|Escape|BSpace)$'

send_keys_sequence() {
  local pane="$1" csv="$2"
  local IFS=,
  local -a keys
  read -ra keys <<< "$csv"
  for k in "${keys[@]}"; do
    if ! [[ "$k" =~ $KEYS_ALLOWED ]]; then
      echo "Error: unrecognized key '$k' (allowed: Up Down Left Right Enter Tab Space Escape BSpace)" >&2
      return 1
    fi
    tmux send-keys -t "$pane" "$k"
  done
}

# Pre-send busy check — refuse if the pane shows an active spinner row.
# Sending into a busy pane is the cause of the 'queued but no advance'
# class of mishaps. Caller waits and retries.
#
# Tmux fallback path only. Adapter-mode opencode bypasses this entirely
# because run --attach is naturally synchronous and queues correctly.
pane_is_busy() {
  local pane="$1" harness="$2"
  case "$harness" in
    claude)
      # Claude's spinner glyphs: ⠋⠙⠸⠴⠦⠧⠇⠏ on the input row.
      local tail
      tail=$(tmux capture-pane -t "$pane" -p 2>/dev/null | tail -n 3)
      if grep -qE '⠋|⠙|⠸|⠴|⠦|⠧|⠇|⠏' <<< "$tail"; then
        return 0
      fi
      return 1
      ;;
    *) return 1 ;;
  esac
}

# Post-send verification — poll the pane until the prompt-footer sentinel
# is gone (indicating the prompt advanced) or 8s elapse. Returns 0 on
# advance, 4 on timeout. Footer pattern matches the same set
# prompt-classify gates on (Enter to select / ↑↓ select / esc dismiss).
verify_prompt_advanced() {
  local pane="$1"
  local deadline=$((SECONDS + 8))
  while (( SECONDS < deadline )); do
    local buf
    buf=$(tmux capture-pane -t "$pane" -p 2>/dev/null | tail -n 12)
    if ! grep -qE '(Enter to (select|toggle|submit)|↑.*↓ (to )?navigate|esc.*dismiss|↑↓ select)' <<< "$buf"; then
      return 0
    fi
    sleep 0.5
  done
  return 4
}

# --- Opencode HTTP-attach adapter (Phase 1) ---------------------------------
# Resolve a real opencode binary, skipping aliases that mangle args.
resolve_opencode_bin() {
  if [[ -x /usr/bin/opencode ]]; then
    echo "/usr/bin/opencode"
    return 0
  fi
  local p
  p=$(type -P opencode 2>/dev/null || true)
  if [[ -n "$p" && -x "$p" ]]; then
    echo "$p"
    return 0
  fi
  return 1
}

# Send a user message to the opencode session and verify it landed.
#
# Production reality: `/orchestration start <issue>` turns can run for
# 15–20 minutes. `opencode run --attach` piggybacks on the session's
# event stream and only emits `step_finish reason=stop` when the
# CURRENT turn finishes — which means waiting for the orchestration
# step to complete. That's the wrong contract for pane-respond, whose
# job is to QUEUE a user message, not block on the assistant reply.
#
# Strategy: snapshot the user-message count → fire `run --attach` as a
# detached background process → poll /session/<id>/message until the
# count grows (the message landed). Return as soon as delivery is
# confirmed; the daemon subscriber will detect the eventual assistant
# reply on its own and wake master then.
#
# Exit 0: user message confirmed in the session. Exit 5: adapter
# unreachable, message did not land, or opencode binary missing.
opencode_run_attach() {
  local url="$1" sid="$2" message="$3"
  local deadline_secs="${FD_ATTACH_TIMEOUT:-30}"
  local bin
  bin=$(resolve_opencode_bin) || {
    echo "Error: opencode binary not found" >&2
    return 5
  }

  # Snapshot user-message count BEFORE sending. If the server is
  # unreachable or the session is gone, this returns 0 / errors out
  # → we'll fail on the post-send delta check too.
  local before_count
  before_count=$(curl -s --max-time 5 "$url/session/$sid/message" 2>/dev/null \
    | jq '[.[] | select(((.info.role // .role // .message.role) // "") == "user")] | length' 2>/dev/null \
    || echo 0)
  before_count=${before_count:-0}

  # Fire `run --attach` detached. Outer FD redirect is critical (same
  # gotcha as start_oc_server): without it, the launcher's $! survives
  # past return because the captured pipe stays open. We don't need
  # the output here; the verification is HTTP-side.
  local log; log="${FD_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/flightdeck}/oc-respond-$$-$(date +%s%N).log"
  ( setsid nohup "$bin" run --attach "$url" \
      --session "$sid" --format json "$message" \
      </dev/null >>"$log" 2>&1 ) </dev/null >/dev/null 2>&1 &
  local attach_pid=$!
  disown "$attach_pid" 2>/dev/null || true

  # Poll until count grows or deadline.
  local deadline=$((SECONDS + deadline_secs))
  local rc=5
  while (( SECONDS < deadline )); do
    local now_count
    now_count=$(curl -s --max-time 3 "$url/session/$sid/message" 2>/dev/null \
      | jq '[.[] | select(((.info.role // .role // .message.role) // "") == "user")] | length' 2>/dev/null \
      || echo 0)
    now_count=${now_count:-0}
    if (( now_count > before_count )); then
      rc=0
      break
    fi
    sleep 0.5
  done

  # Clean up the per-call log file. The detached run --attach process
  # keeps streaming events; we don't reap it (its session-bound stream
  # ends naturally when the assistant turn finishes).
  rm -f "$log" 2>/dev/null || true

  if (( rc != 0 )); then
    echo "Error: user message did not land in /session/$sid/message within ${deadline_secs}s — server unreachable or session gone" >&2
  fi
  return $rc
}

# --- Dispatch ---------------------------------------------------------------

# Opencode adapter path: when the pane has oc-attach metadata in the
# registry, route ALL non-tmux modes through `opencode run --attach`.
# --keys is rejected unless --keys-allow-tmux opts into tmux fallback.
OC_ADAPTER_USED=0
CC_ADAPTER_USED=0
PI_ADAPTER_USED=0
CX_ADAPTER_USED=0

# Structured question-tool reply/reject.
# Opencode routes via HTTP API:
#   POST <oc_url>/question/<requestID>/reply  body {"answers":[[<label>,...]]}
#   POST <oc_url>/question/<requestID>/reject
# Pi routes via pi-session-bridge:
#   pi-bridge answer --pid <PID> --request-id <id> --answers '[[...]]'
#   pi-bridge reject --pid <PID> --request-id <id>
# The request_id disambiguates the pending prompt.
if [[ "$MODE" == "question" && "$HARNESS" == "opencode" ]]; then
  oc_issue=$(pane_registry_find_id "$TARGET")
  oc_attach_args=""
  if [[ -n "$oc_issue" ]]; then
    oc_attach_args=$("$SCRIPT_DIR/pane-registry" oc-attach-args "$oc_issue" 2>/dev/null || echo "")
  fi
  if [[ -z "$oc_attach_args" ]]; then
    derived_issue=$(oc_issue_from_pane_target "$TARGET")
    if [[ -n "$derived_issue" ]]; then
      oc_attach_args=$(oc_attach_args_from_spawn "$derived_issue" 2>/dev/null || echo "")
    fi
  fi
  if [[ -z "$oc_attach_args" ]]; then
    echo "Error: --question requires opencode adapter (no oc-attach metadata for $TARGET)" >&2
    exit 5
  fi
  oc_url=$(awk '{for(i=1;i<=NF;i++)if($i=="--url"){print $(i+1);exit}}' <<< "$oc_attach_args")
  if [[ -z "$oc_url" ]]; then
    echo "Error: could not resolve opencode url for $TARGET" >&2; exit 5
  fi
  if (( REJECT_QUESTION == 1 )); then
    if ! curl -sf -X POST -o /dev/null --max-time 10 "$oc_url/question/$QUESTION_ID/reject"; then
      echo "Error: question reject failed (POST $oc_url/question/$QUESTION_ID/reject)" >&2
      exit 5
    fi
    echo "  oc-question-rejected: $QUESTION_ID"
  else
    if [[ -n "$ANSWERS_JSON" ]]; then
      payload=$(jq -nc --argjson answers "$ANSWERS_JSON" '{answers:$answers}')
    elif [[ -n "$ANSWER_LABEL" ]]; then
      payload=$(jq -nc --arg a "$ANSWER_LABEL" '{answers:[[$a]]}')
    else
      payload=$(jq -nc --arg c "$ANSWER_MULTI_CSV" '{answers:[($c | split(","))]}')
    fi
    resp=$(curl -sf -X POST -H 'Content-Type: application/json' -d "$payload" --max-time 10 "$oc_url/question/$QUESTION_ID/reply" 2>&1)
    if [[ "$resp" != "true" ]]; then
      echo "Error: question reply failed (POST $oc_url/question/$QUESTION_ID/reply): $resp" >&2
      exit 5
    fi
    echo "  oc-question-answered: $QUESTION_ID payload=$payload"
  fi
  OC_ADAPTER_USED=1
fi

if [[ "$MODE" == "question" && "$HARNESS" == "pi" ]]; then
  pi_issue=$(pane_registry_find_id "$TARGET")
  pi_args=""
  if [[ -n "$pi_issue" ]]; then
    pi_args=$("$SCRIPT_DIR/pane-registry" pi-bridge-args "$pi_issue" 2>/dev/null || echo "")
  fi
  if [[ -z "$pi_args" ]]; then
    derived_issue=$(oc_issue_from_pane_target "$TARGET")
    if [[ -n "$derived_issue" ]]; then
      pi_spawn="$(pi_spawn_file "$derived_issue")"
      if [[ -f "$pi_spawn" ]]; then
        pi_pid=$(jq -r '.pid // ""' "$pi_spawn" 2>/dev/null || echo "")
        pi_socket=$(jq -r '.socket // ""' "$pi_spawn" 2>/dev/null || echo "")
        if [[ -n "$pi_pid" && -n "$pi_socket" ]] && pi_bridge_is_fresh "$pi_pid" "$pi_socket"; then
          pi_args="--pid $pi_pid --socket $pi_socket"
        fi
      fi
    fi
  fi
  if [[ -z "$pi_args" ]]; then
    echo "Error: --question requires pi bridge adapter (no pi-bridge metadata for $TARGET)" >&2
    exit 5
  fi
  pi_pid=$(awk '{for(i=1;i<=NF;i++)if($i=="--pid"){print $(i+1);exit}}' <<< "$pi_args")
  pi_socket=$(awk '{for(i=1;i<=NF;i++)if($i=="--socket"){print $(i+1);exit}}' <<< "$pi_args")
  if [[ -z "$pi_pid" && -z "$pi_socket" ]]; then
    echo "Error: could not resolve pi pid/socket for $TARGET" >&2; exit 5
  fi
  pi_target_args=()
  if [[ -n "$pi_socket" ]]; then
    pi_target_args=(--socket "$pi_socket")
  else
    pi_target_args=(--pid "$pi_pid")
  fi
  pi_bin=$(pi_resolve_bridge_bin) || {
    echo "Error: pi-bridge binary not found" >&2; exit 5
  }
  if (( REJECT_QUESTION == 1 )); then
    if ! pi_resp=$("$pi_bin" reject "${pi_target_args[@]}" --request-id "$QUESTION_ID" 2>&1); then
      echo "Error: pi question reject failed: $pi_resp" >&2
      exit 5
    fi
    if ! jq -e '.success == true' <<< "$pi_resp" >/dev/null 2>&1; then
      echo "Error: pi question reject returned non-success: $pi_resp" >&2
      exit 5
    fi
    echo "  pi-question-rejected: $QUESTION_ID"
  else
    if [[ -n "$ANSWERS_JSON" ]]; then
      payload="$ANSWERS_JSON"
    elif [[ -n "$ANSWER_LABEL" ]]; then
      payload=$(jq -nc --arg a "$ANSWER_LABEL" '[[$a]]')
    elif [[ -n "$ANSWER_TEXT" ]]; then
      payload=$(jq -nc --arg a "$ANSWER_TEXT" '[[$a]]')
    else
      payload=$(jq -nc --arg c "$ANSWER_MULTI_CSV" '[($c | split(","))]')
    fi
    if ! pi_resp=$("$pi_bin" answer "${pi_target_args[@]}" --request-id "$QUESTION_ID" --answers "$payload" 2>&1); then
      echo "Error: pi question answer failed: $pi_resp" >&2
      exit 5
    fi
    if ! jq -e '.success == true' <<< "$pi_resp" >/dev/null 2>&1; then
      echo "Error: pi question answer returned non-success: $pi_resp" >&2
      exit 5
    fi
    echo "  pi-question-answered: $QUESTION_ID payload=$payload"
  fi
  PI_ADAPTER_USED=1
fi

if [[ "$HARNESS" == "opencode" && $OC_ADAPTER_USED -eq 0 ]]; then
  oc_issue=$(pane_registry_find_id "$TARGET")
  oc_attach_args=""
  if [[ -n "$oc_issue" ]]; then
    oc_attach_args=$("$SCRIPT_DIR/pane-registry" oc-attach-args "$oc_issue" 2>/dev/null || echo "")
  fi
  # Fallback: registry init may not have run yet (open-terminal ran but
  # watch.md hasn't registered the pane). Derive issue from the window
  # name and read the spawn file directly so adapter mode still engages.
  if [[ -z "$oc_attach_args" ]]; then
    derived_issue=$(oc_issue_from_pane_target "$TARGET")
    if [[ -n "$derived_issue" ]]; then
      oc_attach_args=$(oc_attach_args_from_spawn "$derived_issue" 2>/dev/null || echo "")
    fi
  fi
  if [[ -n "$oc_attach_args" ]]; then
    if [[ "$MODE" == "keys" && $KEYS_ALLOW_TMUX -eq 0 ]]; then
      echo "Error: --keys not supported for opencode adapter." >&2
      echo "       Pass --keys-allow-tmux to send via tmux send-keys (true modal cases only)." >&2
      exit 1
    fi
    if [[ "$MODE" != "keys" ]]; then
      oc_url=$(awk '{for(i=1;i<=NF;i++)if($i=="--url"){print $(i+1);exit}}' <<< "$oc_attach_args")
      oc_session=$(awk '{for(i=1;i<=NF;i++)if($i=="--session"){print $(i+1);exit}}' <<< "$oc_attach_args")
      case "$MODE" in
        payload)      message="$PAYLOAD" ;;
        option)       message="$OPTION_N" ;;
        option-multi) message=$(echo "$OPTION_MULTI_CSV" | sed 's/,/, /g') ;;
      esac
      if ! opencode_run_attach "$oc_url" "$oc_session" "$message"; then
        exit 5
      fi
      OC_ADAPTER_USED=1
    fi
  else
    echo "Note: oc-attach-unavailable for $TARGET (no registry metadata); using tmux fallback" >&2
  fi
fi

# Claude Channels adapter (Phase 2): when the pane has cc-channel
# metadata in the registry, route via HTTP POST to the channel server.
# All non-tmux modes route through the channel; --keys is rejected
# unless --keys-allow-tmux. Symmetric with the opencode block above.
if [[ "$HARNESS" == "claude" && $OC_ADAPTER_USED -eq 0 ]]; then
  cc_issue=$(pane_registry_find_id "$TARGET")
  cc_args=""
  if [[ -n "$cc_issue" ]]; then
    cc_args=$("$SCRIPT_DIR/pane-registry" cc-channel-args "$cc_issue" 2>/dev/null || echo "")
  fi
  # Spawn-file fallback (registry init may not have run yet).
  if [[ -z "$cc_args" ]]; then
    derived_issue=$(oc_issue_from_pane_target "$TARGET")
    if [[ -n "$derived_issue" ]]; then
      cc_spawn="$(cc_spawn_file "$derived_issue")"
      if [[ -f "$cc_spawn" ]]; then
        cc_url=$(jq -r '.url // ""' "$cc_spawn" 2>/dev/null || echo "")
        cc_transcript=$(jq -r '.transcript // ""' "$cc_spawn" 2>/dev/null || echo "")
        if [[ -n "$cc_url" && -n "$cc_transcript" ]]; then
          cc_args="--url $cc_url --transcript $cc_transcript"
        fi
      fi
    fi
  fi
  if [[ -n "$cc_args" ]]; then
    if [[ "$MODE" == "keys" && $KEYS_ALLOW_TMUX -eq 0 ]]; then
      echo "Error: --keys not supported for claude channels adapter." >&2
      echo "       Pass --keys-allow-tmux to send via tmux send-keys (true modal cases only)." >&2
      exit 1
    fi
    if [[ "$MODE" != "keys" ]]; then
      cc_url=$(awk '{for(i=1;i<=NF;i++)if($i=="--url"){print $(i+1);exit}}' <<< "$cc_args")
      case "$MODE" in
        payload)      message="$PAYLOAD" ;;
        option)       message="$OPTION_N" ;;
        option-multi) message=$(echo "$OPTION_MULTI_CSV" | sed 's/,/, /g') ;;
      esac
      # POST to the channel server. The MCP webhook forwards as a
      # `<channel source="webhook" session="<ISSUE>" ...>` notification
      # to claude. POST returns immediately; no completion-wait — the
      # daemon JSONL subscriber detects the eventual assistant turn.
      cc_resp=$(curl -s -m 10 -X POST -d "$message" "$cc_url/" 2>&1)
      cc_rc=$?
      if (( cc_rc != 0 )); then
        echo "Error: claude channel POST failed (rc=$cc_rc): $cc_resp" >&2
        exit 5
      fi
      if ! grep -q '^ok ' <<< "$cc_resp"; then
        echo "Error: claude channel POST returned unexpected body: $cc_resp" >&2
        exit 5
      fi
      CC_ADAPTER_USED=1
    fi
  else
    echo "Note: cc-channel-unavailable for $TARGET (no registry metadata); using tmux fallback" >&2
  fi
fi

# Pi Session Bridge adapter (Phase 3). Routes via the pi-bridge CLI
# over the per-process Unix socket. Symmetric with claude/opencode
# blocks above.
if [[ "$HARNESS" == "pi" && $OC_ADAPTER_USED -eq 0 && $CC_ADAPTER_USED -eq 0 && $PI_ADAPTER_USED -eq 0 ]]; then
  pi_issue=$(pane_registry_find_id "$TARGET")
  pi_args=""
  if [[ -n "$pi_issue" ]]; then
    pi_args=$("$SCRIPT_DIR/pane-registry" pi-bridge-args "$pi_issue" 2>/dev/null || echo "")
  fi
  # Spawn-file fallback when registry init hasn't happened yet.
  if [[ -z "$pi_args" ]]; then
    derived_issue=$(oc_issue_from_pane_target "$TARGET")
    if [[ -n "$derived_issue" ]]; then
      pi_spawn="$(pi_spawn_file "$derived_issue")"
      if [[ -f "$pi_spawn" ]]; then
        pi_pid=$(jq -r '.pid // ""' "$pi_spawn" 2>/dev/null || echo "")
        pi_socket=$(jq -r '.socket // ""' "$pi_spawn" 2>/dev/null || echo "")
        if [[ -n "$pi_pid" && -n "$pi_socket" ]] && pi_bridge_is_fresh "$pi_pid" "$pi_socket"; then
          pi_args="--pid $pi_pid --socket $pi_socket"
        fi
      fi
    fi
  fi
  if [[ -n "$pi_args" ]]; then
    if [[ "$MODE" == "keys" && $KEYS_ALLOW_TMUX -eq 0 ]]; then
      echo "Error: --keys not supported for pi bridge adapter." >&2
      echo "       Pass --keys-allow-tmux to send via tmux send-keys (true modal cases only)." >&2
      exit 1
    fi
    if [[ "$MODE" != "keys" ]]; then
      pi_pid=$(awk '{for(i=1;i<=NF;i++)if($i=="--pid"){print $(i+1);exit}}' <<< "$pi_args")
      pi_socket=$(awk '{for(i=1;i<=NF;i++)if($i=="--socket"){print $(i+1);exit}}' <<< "$pi_args")
      pi_target_args=()
      if [[ -n "$pi_socket" ]]; then
        pi_target_args=(--socket "$pi_socket")
      else
        pi_target_args=(--pid "$pi_pid")
      fi
      case "$MODE" in
        payload)      message="$PAYLOAD" ;;
        option)       message="$OPTION_N" ;;
        option-multi) message=$(echo "$OPTION_MULTI_CSV" | sed 's/,/, /g') ;;
      esac
      pi_bin=$(pi_resolve_bridge_bin) || {
        echo "Error: pi-bridge binary not found" >&2; exit 5
      }
      # `pi-bridge send` enqueues the message. --auto chooses
      # send/steer/follow-up based on session state. Returns
      # quickly; daemon subscriber detects the eventual reply. Prefer
      # the explicit Unix socket when recorded so dispatch does not rely
      # on registry/PID selection heuristics.
      if ! pi_resp=$("$pi_bin" send "${pi_target_args[@]}" --auto "$message" 2>&1); then
        echo "Error: pi-bridge send failed: $pi_resp" >&2
        exit 5
      fi
      PI_ADAPTER_USED=1
    fi
  else
    echo "Note: pi-bridge-unavailable for $TARGET (no registry/spawn metadata or stale bridge); using tmux fallback" >&2
  fi
fi

# Codex bridge adapter (Phase 4). Routes via the vendored bun
# codex-bridge over JSON-RPC/WS to the per-session app-server.
if [[ "$HARNESS" == "codex" && $OC_ADAPTER_USED -eq 0 && $CC_ADAPTER_USED -eq 0 && $PI_ADAPTER_USED -eq 0 ]]; then
  cx_issue=$(pane_registry_find_id "$TARGET")
  cx_args=""
  if [[ -n "$cx_issue" ]]; then
    cx_args=$("$SCRIPT_DIR/pane-registry" cx-bridge-args "$cx_issue" 2>/dev/null || echo "")
  fi
  if [[ -z "$cx_args" ]]; then
    derived_issue=$(oc_issue_from_pane_target "$TARGET")
    if [[ -n "$derived_issue" ]]; then
      cx_spawn="$(cx_spawn_file "$derived_issue")"
      if [[ -f "$cx_spawn" ]]; then
        cx_url=$(jq -r '.url // ""' "$cx_spawn" 2>/dev/null || echo "")
        cx_thread=$(jq -r '.thread_id // ""' "$cx_spawn" 2>/dev/null || echo "")
        if [[ -n "$cx_url" && -n "$cx_thread" ]]; then
          cx_args="--url $cx_url --thread $cx_thread"
        fi
      fi
    fi
  fi
  if [[ -n "$cx_args" ]]; then
    if [[ "$MODE" == "keys" && $KEYS_ALLOW_TMUX -eq 0 ]]; then
      echo "Error: --keys not supported for codex bridge adapter." >&2
      echo "       Pass --keys-allow-tmux to send via tmux send-keys." >&2
      exit 1
    fi
    if [[ "$MODE" != "keys" ]]; then
      cx_url=$(awk '{for(i=1;i<=NF;i++)if($i=="--url"){print $(i+1);exit}}' <<< "$cx_args")
      cx_thread=$(awk '{for(i=1;i<=NF;i++)if($i=="--thread"){print $(i+1);exit}}' <<< "$cx_args")
      case "$MODE" in
        payload)      message="$PAYLOAD" ;;
        option)       message="$OPTION_N" ;;
        option-multi) message=$(echo "$OPTION_MULTI_CSV" | sed 's/,/, /g') ;;
      esac
      if ! cx_resp=$(cx_bridge_run send --url "$cx_url" --thread "$cx_thread" -- "$message" 2>&1); then
        echo "Error: codex-bridge send failed: $cx_resp" >&2
        exit 5
      fi
      CX_ADAPTER_USED=1
    fi
  else
    echo "Note: cx-bridge-unavailable for $TARGET (no registry/spawn metadata); using tmux fallback" >&2
  fi
fi

if [[ $OC_ADAPTER_USED -eq 0 && $CC_ADAPTER_USED -eq 0 && $PI_ADAPTER_USED -eq 0 && $CX_ADAPTER_USED -eq 0 ]]; then
  # Pre-send busy check (claude only; opencode adapter path bypassed above).
  if pane_is_busy "$TARGET" "$HARNESS"; then
    echo "Error: pane $TARGET shows active spinner; refusing to send. Wait and retry." >&2
    exit 3
  fi

  case "$MODE" in
    option)
      select_option_for_harness "$HARNESS" "$TARGET" "$OPTION_N"
      ;;
    option-multi)
      select_option_multi_for_harness "$HARNESS" "$TARGET" "$OPTION_MULTI_CSV"
      ;;
    keys)
      send_keys_sequence "$TARGET" "$KEYS_CSV"
      ;;
    payload)
      buf_name="flightdeck-respond-$$"
      printf '%s' "$PAYLOAD" | tmux load-buffer -b "$buf_name" -
      tmux paste-buffer -b "$buf_name" -t "$TARGET" -p
      tmux delete-buffer -b "$buf_name" 2>/dev/null || true
      if [[ $SEND_ENTER -eq 1 ]]; then
        tmux send-keys -t "$TARGET" Enter
      fi
      ;;
  esac

  # Post-send verification (tmux fallback only): poll the pane until the
  # prompt sentinel is gone. Adapter mode is naturally synchronous so
  # this check is skipped.
  if [[ $CONFIRM_ADVANCED -eq 1 ]]; then
    if ! verify_prompt_advanced "$TARGET"; then
      echo "Error: prompt sentinel still present 8s after send to $TARGET; advance not confirmed." >&2
      exit 4
    fi
  fi
fi

# Clear bell on the window (strip the .pane suffix to get window target).
if [[ $CLEAR_BELL -eq 1 ]]; then
  WINDOW_TARGET="${TARGET%.*}"
  "$SCRIPT_DIR/pane-clear-bell" "$WINDOW_TARGET" || true
fi
