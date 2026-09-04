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
# "Latest" is NOT run-id order: a rerun starts another attempt under the ORIGINAL
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

# Shared jq preamble: the run-id extraction, the check-bucket taxonomy, and
# the run-scope reduction, exported as one string so every consumer (this
# scoping, pr-merge's classification and head_runs, ci-classify-refusal's
# diagnosis, ci-wait's failure classification) prepends the SAME definitions —
# a local `def bucket`/`def runid` copy is the drift this library exists to
# kill, and ci-run-correlation.test.sh rejects one.
# `runid` maps a check to its Actions run id (number) or null. `head_runs`
# (input: a SCOPED check array) names the run ids a classification was scoped
# to: every run the scoped checks link to — authoritative workflow runs and
# custom commit statuses alike, so a status failure on a mixed head names its
# run beside the workflow's instead of vanishing behind it. The one exclusion
# is a status held EXPECTED: its link names the superseded run the rewrite
# just retired, which must not read as current scope.
CI_RUN_JQ_DEFS='
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
  def head_runs:
    [.[]
     | select(((.workflow // "") != "") or ((.state // "") != "EXPECTED"))
     | runid
     | select(. != null)]
    | unique;
'

scope_current_run() {
  jq -c "$CI_RUN_JQ_DEFS"'
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

# Fetch the `gh pr checks` rollup for a PR (arg 1), startedAt included —
# scope_current_run orders runs by it. gh exits 8 while checks are pending
# but still prints usable JSON, so any valid array is authoritative
# regardless of the exit status; a non-array answer returns 1 and prints
# nothing.
fetch_checks_rollup() {
  local out
  out=$(gh pr checks "$1" --json name,state,bucket,link,startedAt,workflow 2>&1) || true
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" || return 1
  printf '%s\n' "$out"
}

# Classify a raw (already-validated) `gh pr checks` rollup in one pass:
# compact the snapshot, scope it, name the run scope, and join the pending/
# failed check names into issue text. Emits one JSON object
#   {checks, head_runs, pending, failed}
# where `checks` is the compacted raw rollup — the single snapshot consumers
# re-scope — and pending/failed are ", "-joined display strings. Names are
# cleaned of newlines: check names are chosen by fork PRs and third-party
# check apps, and a newline inside one would forge a standalone entry in the
# line-oriented output built from these strings.
classify_checks_rollup() {
  local raw scoped
  raw=$(jq -c .) || return 1
  scoped=$(echo "$raw" | scope_current_run) || return 1
  jq -cn --argjson raw "$raw" --argjson scoped "$scoped" "$CI_RUN_JQ_DEFS"'
    def clean: tostring | gsub("[\r\n\t]"; " ");
    {
      checks: $raw,
      head_runs: ($scoped | head_runs),
      pending: ([$scoped[] | select(bucket == "pending") | (.name | clean) + " (" + .state + ")"] | join(", ")),
      failed: ([$scoped[] | select((bucket != "pass") and (bucket != "skipping") and (bucket != "pending")) | (.name | clean) + " (" + .state + ")"] | join(", "))
    }'
}

# The `head-run: <ids>` line for a --check JSON (stdin): the run ids the CI
# classification was scoped to, "none" when no run-correlated checks exist.
CHECK_HEAD_RUN_LINE_JQ='"head-run: " + (.head_runs // [] | if length == 0 then "none" else map(tostring) | join(",") end)'
check_head_run_line() {
  jq -r "$CHECK_HEAD_RUN_LINE_JQ"
}

# Reduce a --check JSON (stdin) to its one-word verdict plus the head-run:
# line — the stderr contract of pr-merge --check. Terminal lifecycle states
# outrank the check answer.
check_verdict_lines() {
  jq -r '
    (if .state == "MERGED" then "merged"
     elif .state == "CLOSED" then "closed"
     elif .can_merge == true then "mergeable"
     else "blocked"
     end),
    '"$CHECK_HEAD_RUN_LINE_JQ"
}
