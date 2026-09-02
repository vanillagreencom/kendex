#!/usr/bin/env bash

init_growth_state() {
  local state="$1" worktree="$2" issue="$3" round_id="$4" lines="${5:-}"
  local exclude

  exclude="$(git -C "$worktree" rev-parse --path-format=absolute --git-path info/exclude)"
  grep -Fxq 'tmp/' "$exclude" 2>/dev/null || printf 'tmp/\n' >> "$exclude"
  "$state" --state-dir "$worktree/tmp" init "$issue" --worktree "$worktree" --branch test >/dev/null
  "$state" --state-dir "$worktree/tmp" set "$issue" dev_round_id "$round_id" >/dev/null
  if [[ -n "$lines" ]]; then
    "$state" --state-dir "$worktree/tmp" set "$issue" pr "{\"baseline_lines\":$lines}" >/dev/null
  fi
}

growth_round_write() {
  local state="$1" writer="$2" worktree="" issue="" round_id="" arg previous=""
  shift 2
  for arg in "$@"; do
    case "$previous" in
      --worktree) worktree="$arg" ;;
      --issue) issue="$arg" ;;
      --round-id) round_id="$arg" ;;
    esac
    previous="$arg"
  done
  if [[ -n "$worktree" && -n "$issue" && -n "$round_id" && -f "$worktree/tmp/workflow-state-$issue.json" ]]; then
    "$state" --state-dir "$worktree/tmp" set "$issue" dev_round_id "$round_id" >/dev/null
  fi
  env ORCH_STATE_DIR="$worktree/tmp" "$writer" "$@"
}
