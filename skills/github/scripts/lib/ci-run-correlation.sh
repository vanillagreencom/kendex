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
# "Latest" is NOT run-id order. A rerun starts a new attempt under the ORIGINAL
# run id and creation time, so the re-executed attempt can carry a LOWER run id
# than a run dispatched between the original attempt and the rerun (vstack#699).
# vstack#876 is exactly that shape, confirmed against the reported head:
#
#   run 30201902682  event=pull_request_review  attempt 1  CANCELLED
#                    jobs started 12:21:43-12:21:56
#   run 30201726860  event=pull_request         attempt 2  SUCCESS
#                    jobs started 12:22:07-12:23:31, `CI Required` green 12:28:48
#
# The rerun of the older run cancelled the review-event run by concurrency, and
# that cancellation is what produced the "zero-second failures". Under max-run-id
# the cancelled run wins and its artifacts reach `pr-merge --check`, while orch
# `ci-wait` — which already correlates rerun attempts by `updated_at` in
# `superseding_run_state` (vstack#699) — correctly reports pass. Same rollup, two
# answers.
#
# So order runs by when their checks actually RAN, with the run id as tiebreak:
# per workflow the authoritative run is the one with the greatest
# [latest check `startedAt`, run id]. Time ordering is applied ONLY when every
# run in that workflow group is settled (no pending check) and carries a usable
# `startedAt`; otherwise ordering falls back to run id exactly as before. That
# keeps the in-flight case — where a queued newer run has no timestamps yet and
# must not lose to a completed older one — on the previous fail-closed path.
#
# Custom commit statuses such as `CI Required` link to an Actions run but have
# an empty `workflow` in `gh pr checks`. If such a status still points at a run
# that ranks BEFORE the authoritative one for its workflow, and that
# authoritative run has no failures, rewrite the stale status to EXPECTED. It
# stays pending until that newer run publishes its own status. A newer
# failed/cancelled run remains a terminal failure, and a missing replacement
# status eventually hits the normal waiter timeout, preserving fail-closed
# behavior. The comparison uses the same ordering as run selection, so "stale"
# and "not authoritative" cannot drift apart.
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
            # run id alone, which is the pre-vstack#876 behaviour.
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
