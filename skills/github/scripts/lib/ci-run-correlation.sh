#!/usr/bin/env bash
# Shared CI check-rollup scoping for the PR merge/wait path.
#
# One implementation, sourced by both github `pr-merge.sh` and orch `ci-wait`,
# so the merge gate and the waiter cannot disagree about which run is current.
# `ci-run-correlation.test.sh` fails if either script grows a local copy.

# Scope a `gh pr checks` array to the current authoritative substantive run per
# workflow, so checks from a SUPERSEDED run are not read as current failures.
# `gh pr checks` is already the rollup for the PR's current head; the run ids in
# each Actions link correlate duplicate contexts on that head.
#
# A later dispatch is not automatically authoritative. Approval-gated CI can
# receive a COMMENTED review event after the APPROVED one, and that later run is
# an intentional all-SKIPPED no-op while the earlier approved run is still live.
# So per workflow, select the latest run holding at least one non-skipped check,
# falling back to the latest all-skipped run only when no substantive run exists.
#
# "Latest" is NOT run-id order: a rerun starts a new attempt under the ORIGINAL
# run id, so a re-executed attempt can carry a LOWER run id than a run dispatched
# between the original attempt and the rerun. Order instead by when the checks
# actually RAN — greatest [latest check `startedAt`, run id]. Time ordering
# applies ONLY when every run in the workflow group is settled (no pending check)
# and carries a usable `startedAt`; otherwise ordering falls back to run id.
# That keeps the in-flight case — a queued newer run with no timestamps yet, which
# must not lose to a completed older one — on the fail-closed path.
#
# Custom commit statuses (for example `CI Required`) link to an Actions run but
# have an empty `workflow`. When such a status points at a run ranking BEFORE the
# authoritative one for its workflow, and that authoritative run has no failures,
# rewrite the stale status to EXPECTED: it stays pending until the newer run
# publishes its own. A newer failed/cancelled run stays a terminal failure, and a
# replacement status that never arrives hits the normal waiter timeout. The
# comparison reuses the run-selection ordering, so "stale" and "not
# authoritative" cannot drift apart.
#
# Checks with no parseable run id in `link` (external contexts, default-setup
# `.../runs/<CHECK_RUN_ID>` links, older gh output with no link) are always kept,
# deduped by name keeping the latest `startedAt`.
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
    # Go renders a missing timestamp as its zero value; treat that as unknown.
    def started:
      (.startedAt // "")
      | if . == "0001-01-01T00:00:00Z" then "" else . end;
    map(. + {
      "_runid": runid,
      "_bucket": bucket,
      "_status_target": status_target,
      "_started": started
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
                pending: any(.[]; ._bucket == "pending"),
                last_start: ([.[] | ._started] | max // ""),
                failed: ([.[] | select((._bucket != "pass") and (._bucket != "skipping") and (._bucket != "pending"))] | length)
              })
            # Rank by when the run last executed, tiebroken by run id — but only
            # when every run here is settled and timestamped. Otherwise rank by
            # run id alone, which is the previous behaviour.
            | (if all(.[]; (.pending | not) and (.last_start != ""))
               then map(.rank = [.last_start, .runid])
               else map(.rank = ["", .runid])
               end)
          )) as $ranked_groups
    | ($ranked_groups
        | map(
            (map(select(.substantive))) as $substantive
            | if ($substantive | length) > 0 then
                ($substantive | max_by(.rank))
              else
                max_by(.rank)
              end
          )) as $selected_runs
    | ($ranked_groups | add // []) as $all_runs
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
            | ([$all_runs[]
                | select(.workflow == $source_workflow and .runid == $status._runid)]
                | .[0]) as $status_run
            | ([$selected_runs[]
                | select(.workflow == $source_workflow
                         and $status_run != null
                         and .rank > $status_run.rank)]
                | .[0]) as $newer_run
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
    | map(del(._runid, ._bucket, ._status_target, ._started))
  '
}
