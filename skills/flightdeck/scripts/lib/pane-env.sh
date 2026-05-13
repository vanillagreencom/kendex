#!/usr/bin/env bash
# Shared environment prefixes for panes launched by Flightdeck.
# Source from launchers; do not execute directly.

# Canonical cross-harness managed-mode signal. The Pi variant retains the
# legacy child-pane signal consumed by pi-flightdeck to suppress owner UI in
# child sessions.
FLIGHTDECK_PANE_ENV=(env FLIGHTDECK_MANAGED=1)
FLIGHTDECK_PI_PANE_ENV=(env FLIGHTDECK_MANAGED=1 FLIGHTDECK_CHILD_PANE=1)
FLIGHTDECK_CHILD_PANE_ENV=(env FLIGHTDECK_MANAGED=1 FLIGHTDECK_CHILD_PANE=1)

flightdeck_shell_join() {
  local out="" arg quoted
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    if [[ -z "$out" ]]; then
      out="$quoted"
    else
      out+=" $quoted"
    fi
  done
  printf '%s' "$out"
}

flightdeck_pane_env_str() {
  # Shell-escaped string form of FLIGHTDECK_PANE_ENV, suitable for
  # prefixing tmux send-keys / printf command lines.
  flightdeck_shell_join "${FLIGHTDECK_PANE_ENV[@]}"
}

flightdeck_child_pane_env_str() {
  # Generic child-pane prefix for first-class Flightdeck sessions.
  flightdeck_shell_join "${FLIGHTDECK_CHILD_PANE_ENV[@]}"
}

flightdeck_pi_pane_env_str() {
  flightdeck_shell_join "${FLIGHTDECK_PI_PANE_ENV[@]}"
}
