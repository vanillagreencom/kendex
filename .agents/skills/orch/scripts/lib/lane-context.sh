#!/usr/bin/env bash
# The context record's file name and a Copilot session's account, the two
# reads lane-marker and copilot-statusline share. A session's reading lives in
# its mailbox directory under LANE_CONTEXT_RECORD; the runtime's watch and its
# `marks` judge read that record (`orch-runtime marks`).
set -euo pipefail

# The file a session's reading is recorded in, inside its mailbox directory:
# `tmp/lane-mail/<item>/` for a lane and `tmp/lane-mail/overseer/` for the
# overseer. A hosted lane's mailbox is already read through its host, so the
# record reaches the overseer by the same road.
LANE_CONTEXT_RECORD=context.json

# lane_context_caller_cfg copilot — the config root a Copilot session runs its
# credential out of: COPILOT_HOME, the whole root, else `.copilot` under
# LANES_HOME or HOME, the root Copilot itself defaults to. A Copilot launch
# builds no private home under it, so the value is the account. Exit 1,
# printing nothing, for any other shape.
lane_context_caller_cfg() { # SHAPE
  local home="${LANES_HOME:-$HOME}"
  case "${1:-}" in
    copilot) printf '%s\n' "${COPILOT_HOME:-$home/.copilot}" ;;
    *) return 1 ;;
  esac
}
