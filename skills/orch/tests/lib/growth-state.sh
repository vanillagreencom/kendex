#!/usr/bin/env bash

init_growth_state() {
  local state="$1" worktree="$2" issue="$3" lines="${4:-}"

  "$state" --state-dir "$worktree/tmp" init "$issue" --worktree "$worktree" --branch test >/dev/null
  if [[ -n "$lines" ]]; then
    "$state" --state-dir "$worktree/tmp" set "$issue" pr "{\"baseline_lines\":$lines}" >/dev/null
  fi
}
