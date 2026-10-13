# shellcheck shell=bash
#
# The Claude Code adapter: the context a session has used and the window it has,
# read from the transcript Claude Code writes. The launch word that keeps the
# harness from compacting a session on its own is the claude row of the
# launch-choice table in lib/lane-launch.sh.
#
# Sourced by lib/lane-context.sh, never run.

# The window a Claude model runs on, as `PATTERN=WINDOW` rows matched in order
# against the whole lowercased model name. The transcript names the model on
# every assistant line (`claude-opus-5-5`) and never the window. The fable and
# opus rows are the window this fleet has measured for any model of that tier.
# The Sonnet 5 and Haiku 4.5 rows are the windows Claude Code's own model
# registry and the model docs give: Sonnet 5 runs 1M with no 200K variant,
# Haiku 4.5 runs 200K. Those rows name exact ids because an older Sonnet runs
# 200K unless its `[1m]` variant was chosen, and the transcript names the same
# model either way; a bare `sonnet` or `haiku` names none, since an
# ANTHROPIC_DEFAULT_*_MODEL pin can move it, and a launch writes the id in its
# place (lane_adapter_claude_model_id). A
# model no row names has no window, and its sessions are reported unmeasured
# rather than judged against a guess: too small a figure hands a session off
# early, too large one lets it run into its wall.
LANE_ADAPTER_CLAUDE_WINDOWS='*fable*=1000000 *opus*=1000000 claude-sonnet-5=1000000 claude-sonnet-5-5=1000000 claude-haiku-4-5=200000 claude-haiku-4-5-20251001=200000'

# lane_adapter_claude_window MODEL — the window MODEL runs (`claude-opus-5-5`,
# `opus[1m]`), empty where no row matches it. The one rule both a
# reading and a launch ask, so a model a launch refuses is exactly one whose
# sessions would read unmeasured. read -a, not `for pair in $TABLE`, so a row's
# pattern is never globbed against the working directory.
lane_adapter_claude_window() { # MODEL
  local model pair
  local -a pairs=()
  model=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  read -r -a pairs <<<"$LANE_ADAPTER_CLAUDE_WINDOWS"
  for pair in "${pairs[@]}"; do
    # shellcheck disable=SC2254 # the row is a pattern
    case "$model" in
      ${pair%=*}) printf '%s\n' "${pair##*=}"; return 0 ;;
    esac
  done
}

# lane_adapter_claude_model_id MODEL — the model id a launch writes for MODEL:
# Aliases use their launch-time family override. Explicit versions retain all
# their version fields. The recorded form never resolves a historical family
# alias through the current environment.
lane_adapter_claude_model_id() { # MODEL [launch|resolved|recorded]
  local model fallback="" provider_unknown=false provider_flag
  model="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" || return 1
  case "${2:-}" in launch | resolved | recorded) model=${model%\[1m\]} ;; esac
  # Historical records cannot recover the environment that resolved an alias.
  # Only launch writers may consult family overrides.
  if [[ "${2:-}" == recorded ]]; then
    case "$model" in sonnet | haiku | opus | fable) return 0 ;; esac
  fi
  case "$model" in
    sonnet) model=${ANTHROPIC_DEFAULT_SONNET_MODEL:-}; fallback=claude-sonnet-5-5 ;;
    haiku) model=${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}; fallback=claude-haiku-4-5 ;;
    opus) model=${ANTHROPIC_DEFAULT_OPUS_MODEL:-}; fallback=claude-opus-5-5 ;;
    fable) model=${ANTHROPIC_DEFAULT_FABLE_MODEL:-}; fallback=claude-fable-5-1 ;;
    fable-[0-9]* | opus-[0-9]* | sonnet-[0-9]* | haiku-[0-9]*) model="claude-$model" ;;
  esac
  if [[ -z "$model" && -n "$fallback" ]]; then
    # Pin first-party launches before native fallback can change the session.
    # Provider and gateway aliases have different defaults and need an
    # explicit family override: https://code.claude.com/docs/en/model-config.
    for provider_flag in "${CLAUDE_CODE_USE_BEDROCK:-}" "${CLAUDE_CODE_USE_VERTEX:-}" \
      "${CLAUDE_CODE_USE_FOUNDRY:-}" "${CLAUDE_CODE_USE_MANTLE:-}" "${CLAUDE_CODE_USE_ANTHROPIC_AWS:-}"; do
      provider_flag="$(printf '%s' "$provider_flag" | tr '[:upper:]' '[:lower:]')" || return 1
      case "$provider_flag" in '' | 0 | false | no | off) ;; *) provider_unknown=true ;; esac
    done
    if [[ "$provider_unknown" == false && -z "${CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST:-}" && -z "${ANTHROPIC_BASE_URL:-}" ]]; then
      model=$fallback
    fi
  fi
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
  printf '%s\n' "$model"
}

# One reading from a Claude Code transcript on stdin: `<tokens>\t<window>\t<model>`
# for the last assistant line carrying a usage object, `$1` where that usage
# object carries none of Claude Code's field names, and nothing where no line
# carries usage at all. The context is the prompt that line was billed for, its
# input tokens plus the two cache counts, and the response it wrote, which the
# next request sends back. `fromjson?` skips the partial line a
# byte window opens on and the line the harness is still appending. The window
# is the model window only when inherited launch settings disable compaction.
#
# A `<synthetic>` line is the harness recording an API error, with every count
# zero and no model a window belongs to, so it is no reading of the session.
lane_adapter_claude_reading() { # UNREAD
  local reading tokens model window=""
  reading=$(jq -Rnr --arg unread "$1" '
    [inputs | fromjson? | .message? | objects
     | select((.usage | type) == "object" and .model != "<synthetic>")
     | .model as $model | .usage
     | if has("input_tokens") or has("cache_read_input_tokens")
          or has("cache_creation_input_tokens") or has("output_tokens")
       then "\((.input_tokens // 0) + (.cache_read_input_tokens // 0)
               + (.cache_creation_input_tokens // 0) + (.output_tokens // 0))\t\($model // "")"
       else $unread end]
    | last // empty') || return 1
  case "$reading" in
    '' | "$1") [ -z "$reading" ] || printf '%s\n' "$reading"; return 0 ;;
  esac
  tokens=${reading%%$'\t'*}
  model=${reading#*$'\t'}
  # The managed launch inherits this exact disabling value into the hook.
  # Enabled compaction has other runtime inputs, so its point is unresolved.
  if [ "${DISABLE_AUTO_COMPACT:-}" = 1 ] || [ "${DISABLE_COMPACT:-}" = 1 ]; then
    window=$(lane_adapter_claude_window "$model") || return 1
  fi
  printf '%s\t%s\t%s\n' "$tokens" "$window" "$model"
}

# lane_adapter_claude_transcript_owned PATH SESSION HOME — whether PATH is the
# transcript Claude Code writes for the session SESSION under the config
# directory HOME: `HOME/projects/<project slug>/SESSION.jsonl`, the one file
# the harness appends that session to and the path its Stop payload names as
# `transcript_path`. 0 where it is; 1 with `session-mismatch` in
# LANE_ADAPTER_OWNED_REASON where the file is not named for SESSION, and
# `home-mismatch` where it sits outside HOME's projects tree. A subagent's
# transcript lives under `<session>/subagents/` and is named for the agent, so
# it never passes as the lead's.
lane_adapter_claude_transcript_owned() { # PATH SESSION HOME
  LANE_ADAPTER_OWNED_REASON=""
  case "$1" in
    */"$2".jsonl) ;;
    *) LANE_ADAPTER_OWNED_REASON=session-mismatch; return 1 ;;
  esac
  case "$1" in
    "${3%/}"/projects/*/"$2".jsonl) ;;
    *) LANE_ADAPTER_OWNED_REASON=home-mismatch; return 1 ;;
  esac
}
