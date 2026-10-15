# shellcheck shell=bash
#
# The one reader of a host kind's capability line for the orch callers that
# act on it: `lane-host capabilities` under ORCH_LANE_HOST set to the host a
# launch resolved or a record names (../../schemas/lane-host.md § Host kinds).
# lane-host validates the line against each key's closed set, so a caller
# reads the keys it acts on and matches each value exhaustively.
#
# Sourced, never run. Bash 3.2-safe, like its callers.

# LANE_CAPABILITIES is the line HOST declares, asked from DIR, the checkout
# lane-host reads its settings from (default: here). A failed read returns
# lane-host's status, its words already on stderr.
LANE_CAPABILITIES=""
lane_capabilities_read() { # LANE_HOST_CLI HOST [DIR]
  LANE_CAPABILITIES="$(lane_capabilities_answer "$1" "$2" "${3:-.}")"
}

# A provider declares a cheap key covering code behind an unchanged wrapper.
# This local cache keeps lane-host as the capability validator and uses the
# existing per-host usage store. A cache failure still asks the dispatcher.
lane_capabilities_answer() { # LANE_HOST_CLI HOST [DIR]
  local host="$2" root identity revision sum cache="" tmp="" cleanup key line words="" word rc=0
  cd -- "${3:-.}" || return 1
  case "$host" in
    local|claude-cloud) ORCH_LANE_HOST="$host" "$1" capabilities; return $? ;;
    /*) ;;
    *) host="$PWD/$host" ;;
  esac
  if [[ -f "$host" && -x "$host" ]] &&
     revision="$("$host" capabilities --cache-key 2>/dev/null)" &&
     [[ "$revision" == cache-key=?* && "$revision" != *[$'\t\r\n ']* ]] &&
     identity="$(LC_ALL=C TZ=UTC stat -Lc '%y:%s' -- "$host" 2>/dev/null || LC_ALL=C stat -Lf '%.9Fm:%z' -- "$host" 2>/dev/null)" &&
     sum="$(printf '%s' "$host" | cksum)"; then
    identity="$revision:$identity"
    # Some readers, including lane-mail, do not otherwise need claim helpers.
    declare -F lane_claims_dir >/dev/null || source "${BASH_SOURCE[0]%/*}/lane-claims.sh" || return 1
    root="${PROJECT_ROOT:-}"
    [[ -n "$root" ]] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="$PWD"
    cache="$(lane_claims_dir "$root")" || return 1
    cache="${cache%/claims}/usage/host-capabilities-${sum// /-}"
    # Read one open file so an atomic replacement cannot mix generations.
    if [[ -f "$cache" ]] && {
      IFS= read -r key && IFS= read -r line && [[ "$key" == "$host"$'\t'"$identity" && -n "$line" ]] && {
        while IFS= read -r word; do words+="$word"$'\n'; done
      }
    } < "$cache"; then
      printf '%s' "$words" >&2
      printf '%s\n' "$line"
      return 0
    fi
    if mkdir -p -- "${cache%/*}" 2>/dev/null; then
      tmp="$(mktemp "$cache.XXXXXX" 2>/dev/null)" || cache=""
      if [[ -n "$cache" ]]; then
        # The reader's subshell outlives this function's local variables.
        printf -v cleanup 'rm -f -- %q' "$tmp"
        trap "$cleanup" EXIT
      fi
    else
      cache=""
    fi
  fi
  if [[ -z "$cache" ]]; then
    ORCH_LANE_HOST="$2" "$1" capabilities
    return $?
  fi
  line="$(ORCH_LANE_HOST="$2" "$1" capabilities 2>"$tmp")" || rc=$?
  words="$(<"$tmp")"
  [[ -z "$words" ]] || printf '%s\n' "$words" >&2
  [[ "$rc" -eq 0 ]] || return "$rc"
  if printf '%s\t%s\n%s\n%s' "$host" "$identity" "$line" "${words:+$words$'\n'}" > "$tmp"; then
    # Cache publication is advisory; the validated reply is already available.
    if mv -f -- "$tmp" "$cache" 2>/dev/null; then trap - EXIT; fi
  fi
  printf '%s\n' "$line"
}

# OUT_VAR, the value LANE_CAPABILITIES gives KEY.
lane_capability() { # OUT_VAR KEY
  local _lc_field _lc_fields=()
  if [[ "$2" == pane ]]; then printf -v "$1" '%s' local
  else printf -v "$1" '%s' ""; fi
  IFS=$'\t' read -r -a _lc_fields <<<"$LANE_CAPABILITIES"
  for _lc_field in ${_lc_fields[@]+"${_lc_fields[@]}"}; do
    [[ "${_lc_field%%=*}" != "$2" ]] || printf -v "$1" '%s' "${_lc_field#*=}"
  done
}
