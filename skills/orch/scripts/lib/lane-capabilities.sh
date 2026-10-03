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
  LANE_CAPABILITIES="$(cd -- "${3:-.}" && ORCH_LANE_HOST="$2" "$1" capabilities)"
}

# OUT_VAR, the value LANE_CAPABILITIES gives KEY.
lane_capability() { # OUT_VAR KEY
  local _lc_field _lc_fields=()
  printf -v "$1" '%s' ""
  IFS=$'\t' read -r -a _lc_fields <<<"$LANE_CAPABILITIES"
  for _lc_field in ${_lc_fields[@]+"${_lc_fields[@]}"}; do
    [[ "${_lc_field%%=*}" != "$2" ]] || printf -v "$1" '%s' "${_lc_field#*=}"
  done
}
