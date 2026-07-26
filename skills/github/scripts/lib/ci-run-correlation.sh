#!/usr/bin/env bash
# Shared CI check-rollup scoping for the PR merge/wait path.
#
# `gh pr checks` returns the whole check rollup for a PR's head, which can hold
# several workflow runs from several dispatch events on that SAME head. Deciding
# CI status means picking the authoritative run per workflow first — otherwise a
# superseded or degenerate duplicate dispatch is read as a current failure.
#
# This lived in TWO places: orch `ci-wait` and github `pr-merge.sh`, each with a
# comment saying it must stay aligned with the other "byte-for-byte". Nothing
# enforced that, and they drifted: `ci-wait` grew substantive-run selection and
# stale-status rewriting (vstack#607) while `pr-merge.sh` kept the original
# max-run-id version (vstack#492). The two then disagreed on the same PR —
# `ci-wait` reported pass for the substantive run while `pr-merge --check`
# reported `can_merge=false` from a second same-head run's zero-second
# failures — which is vstack#876.
#
# One implementation, sourced by both. `ci-run-correlation-alignment.test.sh`
# fails if either script grows a local copy again.

# Scope a `gh pr checks` array to the current authoritative substantive run per
# workflow so stale checks from a SUPERSEDED workflow run don't leak into the
# current PR/head status (vstack#492, vstack#607). `gh pr checks` is already the
# check rollup for the PR's current head; the run IDs in each Actions link let us
# correlate duplicate contexts on that head.
#
# A later workflow dispatch is not always authoritative. Approval-gated CI can
# receive a COMMENTED review event after the APPROVED event; that later run is an
# intentional all-SKIPPED no-op while the earlier approved run is still active.
# Therefore, per workflow, choose the latest run containing at least one
# non-skipped check. Only fall back to the latest all-skipped run when no
# substantive run exists at all.
#
# Custom commit statuses such as `CI Required` link to an Actions run but have
# an empty `workflow` in `gh pr checks`. If such a status still points at an old
# run while a newer substantive run from the same workflow is pending or has no
# failures, rewrite the stale status to EXPECTED. It stays pending until that
# newer run publishes its own status. A newer failed/cancelled run remains a
# terminal failure, and a missing replacement status eventually hits the normal
# waiter timeout, preserving fail-closed behavior.
#
# Checks with no parseable run in `link` (external contexts, default-setup
# `.../runs/<CHECK_RUN_ID>` links, or older gh output with no link) are always
# kept, deduped by name keeping the latest `startedAt`.
scope_current_run() {
  jq -c '
    def runid:
      (.link // "")
      | ((capture("/actions/runs/(?<r>[0-9]+)")? | .r) // null)
      | (if . == null then null else tonumber end);
    def bucket:
      (.bucket // (
        if (.state == "SUCCESS") then "pass"
        elif (.state == "SKIPPED") then "skipping"
        elif ((.state // "") | IN("PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "EXPECTED")) then "pending"
        elif (.state == "CANCELLED") then "cancel"
        else "fail"
        end
      ));
    def status_target:
      ((.link // "") | test("/actions/runs/[0-9]+/?$"));
    map(. + {
      "_runid": runid,
      "_bucket": bucket,
      "_status_target": status_target
    })
    | ([.[] | select(._runid == null)]) as $norun
    | ([.[] | select(._runid != null and ((.workflow // "") != ""))]) as $jobs
    | ([.[] | select(._runid != null and ((.workflow // "") == ""))]) as $run_statuses
    | ($jobs
        | group_by(.workflow)
        | map(
            group_by(._runid)
            | map({
                workflow: (.[0].workflow // ""),
                runid: .[0]._runid,
                checks: .,
                substantive: any(.[]; ._bucket != "skipping"),
                failed: ([.[] | select((._bucket != "pass") and (._bucket != "skipping") and (._bucket != "pending"))] | length)
              })
            | (map(select(.substantive))) as $substantive
            | if ($substantive | length) > 0 then
                ($substantive | max_by(.runid))
              else
                max_by(.runid)
              end
          )) as $selected_runs
    | ($selected_runs | map(.checks) | add // []) as $scoped_jobs
    | ($run_statuses
        | group_by(.name)
        | map(max_by(._runid))) as $latest_statuses
    | ($latest_statuses
        | map(
            . as $status
            | ([$jobs[]
                | select(._runid == $status._runid)
                | .workflow]
                | unique
                | .[0] // "") as $source_workflow
            | ([$selected_runs[]
                | select(.workflow == $source_workflow and .runid > $status._runid)]
                | max_by(.runid)?) as $newer_run
            | if ($status._status_target
                  and $source_workflow != ""
                  and $newer_run != null
                  and $newer_run.failed == 0) then
                .state = "EXPECTED"
                | .bucket = "pending"
                | ._bucket = "pending"
              else
                .
              end
          )) as $scoped_statuses
    | ($norun | group_by(.name) | map(sort_by(.startedAt // "") | last)) as $norun_deduped
    | ($scoped_jobs + $scoped_statuses + $norun_deduped)
    | map(del(._runid, ._bucket, ._status_target))
  '
}
