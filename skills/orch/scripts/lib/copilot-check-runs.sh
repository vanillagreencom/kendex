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
  # Requests have no head field. Retain unresolved cycles instead of replacing
  # the old cycle with the newest request. A known current-head completion can
  # settle current work. An old-head completion can consume only one uniquely
  # unassigned cycle, once per head. Ambiguous cycles remain pending.
  # Push boundaries identify the new tip; committed rows use commit dates.
  timeline=$(gh api "repos/$1/issues/$3/timeline?per_page=100" --paginate --slurp) || return $?
  jq -ce --arg head "$2" --argjson checks "$checks" '
    def copilot: . == "copilot-pull-request-reviewer[bot]" or . == "Copilot";
    if type != "array" or length == 0 or any(.[]; type != "array")
    then error("timeline pages are unreadable") else add end |
    reduce .[] as $event ({tip: null, cycles: [], completed: []};
      if ($event.event == "review_requested" and ($event.requested_reviewer.login | copilot)) or
         $event.event == "copilot_work_started"
      then if ($event.id | type) != "number" or ($event.created_at | type) != "string"
           then error("Copilot timeline identity is unreadable")
           else .cycles += [{id: $event.id, started_at: $event.created_at,
                             owner: (if .tip == $head then $head else null end), pending: true}] end
      elif $event.event == "review_request_removed" and ($event.requested_reviewer.login | copilot)
      # Keep cancelled unknown cycles as possible owners of a late completion.
      then .cycles |= map(.pending = false)
      elif $event.event == "reviewed" and ($event.user.login | copilot)
      then if ($event.commit_id | type) != "string" or ($event.submitted_at | type) != "string"
           then error("Copilot completion identity is unreadable")
           elif $event.commit_id == $head
           then .cycles |= map(select(.started_at > $event.submitted_at)) |
                .completed |= (. + [$event.commit_id] | unique)
           else [.cycles[] | select(.owner == null and .started_at <= $event.submitted_at)] as $unassigned |
             if ($unassigned | length) == 1 and (.completed | index($event.commit_id)) == null
             then .cycles |= map(select(.id != $unassigned[0].id)) else . end |
             .completed |= (. + [$event.commit_id] | unique)
           end
      elif $event.event == "head_ref_force_pushed" or
           ($event.event == "review_dismissed" and $event.dismissed_review.dismissal_commit_id != null)
      then ($event | if .event == "head_ref_force_pushed" then .commit_id
                     else .dismissed_review.dismissal_commit_id end) as $tip |
           if ($tip | type) != "string" or ($tip | test("^[0-9a-fA-F]{40}$") | not) or
              ($event.created_at | type) != "string"
           then error("Copilot head boundary is unreadable") else .tip = $tip end
      else . end) |
    [.cycles[] | select(.pending)] |
    if length == 0 then [] else last as $request |
      if any($checks[]; .status == "completed" and .started_at != null and .started_at >= $request.started_at)
      then [] else [$request | {id, started_at}] end end' <<<"$timeline"
}
