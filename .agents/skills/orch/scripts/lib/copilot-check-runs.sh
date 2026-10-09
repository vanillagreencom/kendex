#!/usr/bin/env bash
# Sourced reader for the live commit's Copilot work. The caller selects gh's
# token and owns polling and diagnostics. A failed read never means no work.

# Prints a JSON array of {id, started_at} for queued or in-progress Copilot
# runs. With PR_NUMBER, also reads pending review requests from the timeline
# when no active check exists. GitHub queues runs with started_at=null. Reads
# all pages and attempts: latest can hide an earlier run still in progress.
orch_copilot_check_runs() { # OWNER/REPO FULL_HEAD_SHA [PR_NUMBER]
  local checks active timeline
  checks=$(gh api "repos/$1/commits/$2/check-runs?filter=all&per_page=100" --paginate --slurp |
    jq -ces '
      if length != 1 or (.[0] | type) != "array" or (.[0] | length) == 0
      then error("check-runs response is empty or repeated") else .[0] end |
      map(if (.check_runs | type) == "array" then .check_runs
          else error("check_runs is not an array") end) | add |
      map(select(.name == "copilot-pull-request-reviewer") |
        if (.status | type) != "string" then error("Copilot check status is unreadable")
        else . end)') || return $?
  active=$(jq -c '
      map(select(.status == "queued" or .status == "in_progress") |
        if (.id | type) != "number" or .id <= 0 or (.id | floor) != .id
           or (.started_at != null and (.started_at | type) != "string")
        then error("Copilot check identity is unreadable")
        else {id, started_at} end)' <<<"$checks") || return $?
  if [[ -z "${3:-}" || "$active" != '[]' ]]; then
    printf '%s\n' "$active"
    return 0
  fi
  # Timeline work remains pending until a later Copilot review or removal.
  # Request and work-start commit fields are null; no head is inferred.
  timeline=$(gh api "repos/$1/issues/$3/timeline?per_page=100" --paginate --slurp) || return $?
  jq -ce --argjson checks "$checks" '
    if type != "array" or length == 0 or any(.[]; type != "array")
    then error("timeline pages are unreadable") else add end |
    reduce .[] as $event (null;
      if ($event.event == "review_requested" and
          ($event.requested_reviewer.login == "copilot-pull-request-reviewer[bot]" or
           $event.requested_reviewer.login == "Copilot")) or
         $event.event == "copilot_work_started"
      then if ($event.id | type) != "number" or ($event.created_at | type) != "string"
           then error("Copilot timeline identity is unreadable")
           else {id: $event.id, started_at: $event.created_at} end
      elif $event.event == "review_request_removed" and
           ($event.requested_reviewer.login == "copilot-pull-request-reviewer[bot]" or
            $event.requested_reviewer.login == "Copilot")
      then null
      elif $event.event == "reviewed" and
           ($event.user.login == "copilot-pull-request-reviewer[bot]" or $event.user.login == "Copilot")
      then if ($event.submitted_at | type) != "string"
           then error("Copilot completion time is unreadable")
           elif . != null and $event.submitted_at >= .started_at
           then null else . end
      else . end) |
    if . == null then [] else . as $request |
      if any($checks[]; .status == "completed" and .started_at != null and .started_at >= $request.started_at)
      then [] else [$request] end end' <<<"$timeline"
}
