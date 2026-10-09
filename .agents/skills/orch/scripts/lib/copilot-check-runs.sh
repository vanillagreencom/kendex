#!/usr/bin/env bash
# Sourced reader for the live commit's Copilot work. The caller selects gh's
# token and owns polling and diagnostics. A failed read never means no work.

# Prints a JSON array of {id, started_at} for queued or in-progress Copilot
# runs. GitHub queues runs with started_at=null. Reads all pages and attempts,
# since the default latest filter can hide an earlier run still in progress.
orch_copilot_check_runs() { # OWNER/REPO FULL_HEAD_SHA
  gh api "repos/$1/commits/$2/check-runs?filter=all&per_page=100" --paginate --slurp |
    jq -ces '
      if length != 1 or (.[0] | type) != "array" or (.[0] | length) == 0
      then error("check-runs response is empty or repeated") else .[0] end |
      map(if (.check_runs | type) == "array" then .check_runs
          else error("check_runs is not an array") end) | add |
      map(select(.name == "copilot-pull-request-reviewer") |
        if (.status | type) != "string" then error("Copilot check status is unreadable")
        else . end |
        select(.status == "queued" or .status == "in_progress") |
        if (.id | type) != "number" or .id <= 0 or (.id | floor) != .id
           or (.started_at != null and (.started_at | type) != "string")
        then error("Copilot check identity is unreadable")
        else {id, started_at} end)'
}
