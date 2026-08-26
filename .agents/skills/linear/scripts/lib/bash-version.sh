#!/usr/bin/env bash
# Shared runtime preflight for the Linear CLI.

linear_require_supported_bash() {
  local major="${BASH_VERSINFO[0]:-0}"

  if [ "$major" -lt 4 ]; then
    printf 'Error: Linear CLI requires Bash 4.0 or newer; found Bash %s. Install Bash 4+ and invoke linear.sh with that executable.\n' \
      "${BASH_VERSION:-unknown}" >&2
    return 1
  fi
}
