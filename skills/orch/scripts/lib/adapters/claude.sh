# shellcheck shell=bash
#
# The Claude Code adapter: the context a session has used and the window it has,
# read from the transcript Claude Code writes. The launch word that keeps the
# harness from compacting a session on its own is the claude row of the
# launch-choice table in lib/lane-launch.sh.
#
# Sourced by lib/lane-context.sh, never run.

# The rows and the default are the runtime's one capacity table,
# `Harness::context_capacity` in skills/agent-runtime/runtime/src/harness.rs,
# spelled as patterns, first match wins, so the hook and the launcher judge on
# it before the runtime is built; a test row there reads this file and refuses
# a figure the two do not share. An id with a measured window comes before its
# family word, which matches every spelling of the family, alias included, at
# the family's budget; a model matching no row reads the default. Only launch
# callers request the notice.
LANE_ADAPTER_CLAUDE_WINDOWS='claude-sonnet-5-5=1000000 claude-sonnet-5=1000000 *fable*=1000000 *opus*=1000000 *sonnet*=200000 *haiku*=200000'
LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW=200000

lane_adapter_claude_window() { # MODEL [notice]
  local model pair
  local -a pairs=()
  model=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]') || return 1
  read -r -a pairs <<<"$LANE_ADAPTER_CLAUDE_WINDOWS"
  for pair in "${pairs[@]}"; do
    # shellcheck disable=SC2254 # the row is a pattern
    case "$model" in
      ${pair%=*}) printf '%s\n' "${pair##*=}"; return 0 ;;
    esac
  done
  if [[ "${2:-}" == notice && "${LANE_ADAPTER_CLAUDE_WINDOW_NOTICED:-false}" != true ]]; then
    printf 'claude-window-default model=%s window=%s\n' "${1:-default}" "$LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW" >&2
    LANE_ADAPTER_CLAUDE_WINDOW_NOTICED=true
  fi
  printf '%s\n' "$LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW"
}

# Claude owns family overrides and provider selection. Aliases remain launch
# intent in arguments and records. A concrete observation matches an alias
# only in its own family; explicit IDs retain every version field.
lane_adapter_claude_model_id() { # MODEL [launch|resolved|recorded] [RECORDED_SELECTOR]
  local model recorded
  model="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" || return 1
  case "${2:-}" in launch | resolved | recorded) model=${model%\[1m\]} ;; esac
  if [[ "${2:-}" != resolved ]]; then
    case "$model" in
      sonnet | haiku | opus | fable)
        [[ "${2:-}" != launch ]] || model=${1:-}
        printf '%s\n' "$model"; return 0 ;;
    esac
  fi
  case "$model" in
    fable-[0-9]* | opus-[0-9]* | sonnet-[0-9]* | haiku-[0-9]*) model="claude-$model" ;;
  esac
  # PostModelSwitch.to_model is the event target model ID. These strict forms
  # normalize supported Claude IDs and version spellings. An unresolved
  # alias cannot establish equality. A launch record retains its actual word
  # when unresolved, so ordinary recovery still has the launch evidence.
  if [[ "${2:-}" == launch || "${2:-}" == resolved || "${2:-}" == recorded ]]; then
    case "$model" in
      claude-*[0-9]*) [[ "$model" != *[[:space:]]* ]] || model="" ;;
      *) model="" ;;
    esac
    if [[ -z "$model" ]]; then
      [[ "${2:-}" == launch ]] || return 0
      model=${1:-}
    fi
  elif [[ -z "$model" ]]; then
    model=${1:-}
  fi
  if [[ -n "${3:-}" ]]; then
    recorded=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]') || return 1
    recorded=${recorded%\[1m\]}
    case "$recorded" in
      sonnet | haiku | opus | fable)
        case "$model" in claude-"$recorded"-[0-9]*) model=$recorded ;; esac ;;
    esac
  fi
  printf '%s\n' "${model}"
}
