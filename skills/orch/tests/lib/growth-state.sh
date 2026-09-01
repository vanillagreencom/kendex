#!/usr/bin/env bash

init_growth_state() {
  local state="$1" worktree="$2" issue="$3" round_id="$4" lines="${5:-}"
  local commit common record

  "$state" --state-dir "$worktree/tmp" init "$issue" --worktree "$worktree" --branch test >/dev/null
  "$state" --state-dir "$worktree/tmp" set "$issue" dev_round_id "$round_id" >/dev/null
  [[ -n "$lines" ]] || return 0
  commit="$(git -C "$worktree" rev-parse HEAD)"
  common="$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir)"
  record="$common/kendex/branch-baselines/$issue.json"
  mkdir -p "${record%/*}"
  jq -n --argjson schema_version 1 --arg issue "$issue" --arg round_id "$round_id" \
    --arg commit "$commit" --argjson lines "$lines" --arg source first-fix \
    '{schema_version: $schema_version, issue: $issue, round_id: $round_id,
      commit: $commit, lines: $lines, source: $source}' > "$record"
  "$state" --state-dir "$worktree/tmp" set "$issue" pr \
    "{\"baseline_lines\":$lines,\"baseline_round_id\":\"$round_id\",\"baseline_commit\":\"$commit\",\"baseline_source\":\"first-fix\"}" >/dev/null
}
