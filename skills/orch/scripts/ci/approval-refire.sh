#!/usr/bin/env bash
# Review-gate convergence for ONE pull request head — the single source of
# truth for how review-state transitions reach the merge-blocking gate
# commit status and the CI runs behind it. Canonical copy: vstack
# skills/orch/scripts/ci/; consumers VENDOR both this file and
# review-predicate.sh into .github/scripts/ and keep them in lockstep (see
# orch DEVELOPMENT.md § CI Triggering Patterns, "Review-gate reference
# scripts").
#
# Model (pending-status gate; replaces the fail-red per-job gate steps): the
# repo's CI classifier job evaluates review-predicate.sh and posts the gate
# commit status on the PR head — `pending` until review evidence exists
# (blocks merge without a false red), `failure` only on changes-requested,
# `success` only from a run attempt that executed with the gate open (heavy
# jobs skip while it is closed). This script converges the status when
# review state changes between runs:
#
#   verdict != approved   → POST the pending/failure status directly. No
#                           reruns: pending blocks merge on its own, so a
#                           dismissed review or reopened thread needs no
#                           check-run churn (the old re-gate reruns existed
#                           only because a required JOB had to go red).
#   verdict == approved   → the status may read `success` ONLY in two ways:
#     (a) a PRIOR gate-context success exists on this same sha — proof an
#         approved attempt already executed its jobs here (a red build from
#         that attempt stays blocked by its own red required contexts) — then
#         post success directly, sparing a pointless full re-run;
#     (b) otherwise RERUN the head's completed pull_request runs: the new
#         attempt's classifier job re-evaluates, posts success, and the heavy
#         jobs actually run. Never post success without (a): pre-review
#         attempts SKIP the heavy jobs, and skipped required checks satisfy
#         rulesets, so a directly-posted success would merge untested code.
#
# Callers (repo-side wiring):
#   - an event-driven workflow (review submitted/dismissed, the trusted
#     reviewer's check_run/status events, the outage status)        QUIESCE=1
#   - a scheduled sweep for transitions that emit no usable Actions event,
#     chiefly resolving the last review thread                      QUIESCE=0
#
# Env (required): GH_TOKEN (or ambient gh auth), GH_REPO, PR_NUMBER, HEAD_SHA
# Env (optional):
#   PR_AUTHOR     resolved from the PR when empty (predicate input).
#   GATE_CONTEXT  the merge-blocking commit-status context this script
#                 converges (default "Review gate").
#   QUIESCE       "1" (default): wait (bounded) for in-progress runs on the
#                 head to complete before a rerun decision. "0": act on
#                 completed runs only (the next scheduled pass catches
#                 stragglers).
#   MAX_ATTEMPTS  rerun backstop (default 5): runs at/above the cap are left
#                 alone (gh run rerun retries manually). Attempts only grow on
#                 the first awaiting→approved flip per head, so the cap exists
#                 for pathological ping-pong, not normal review cycles.
#
# Read errors fail LOUDLY (exit 1) without taking any action: treating a
# transient API failure as absent evidence could flip a healthy PR's state.
set -u

QUIESCE="${QUIESCE:-1}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
GATE_CONTEXT="${GATE_CONTEXT:-Review gate}"

for required in GH_REPO PR_NUMBER HEAD_SHA; do
  if [ -z "$(eval "echo \${$required:-}")" ]; then
    echo "::error::approval-refire: $required is required"
    exit 1
  fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

verdict_line="$("$script_dir/review-predicate.sh")" || {
  echo "::error::review predicate evaluation failed for PR #$PR_NUMBER; taking no action - re-review (or gh run rerun) to retry"
  exit 1
}
verdict="$(sed -n 's/^verdict=\([a-z-]*\) .*/\1/p' <<<"$verdict_line")"
detail="$(sed -n 's/^verdict=[a-z-]* detail=//p' <<<"$verdict_line")"
if [ -z "$verdict" ]; then
  echo "::error::could not parse predicate output: $verdict_line"
  exit 1
fi
echo "PR #$PR_NUMBER: verdict=$verdict ($detail)"

case "$verdict" in
  approved)              desired="success" ;;
  changes-requested)     desired="failure" ;;
  awaiting|threads-open) desired="pending" ;;
  *)
    echo "::error::unknown verdict '$verdict'"
    exit 1
    ;;
esac

# Full status history for the sha (newest first): the latest gate-context
# entry is the current state; ANY success entry is the approved-attempt proof
# for the direct-success fast path.
raw_statuses="$(gh api "repos/$GH_REPO/commits/$HEAD_SHA/statuses" --paginate)" || {
  echo "::error::could not read commit statuses for $HEAD_SHA; taking no action"
  exit 1
}
gate_statuses="$(jq -s --arg ctx "$GATE_CONTEXT" '[add // [] | .[] | select(.context == $ctx)]' <<<"$raw_statuses")" || {
  echo "::error::could not parse commit statuses for $HEAD_SHA; taking no action"
  exit 1
}
current_state="$(jq -r '.[0].state // "absent"' <<<"$gate_statuses")"
current_desc="$(jq -r '.[0].description // ""' <<<"$gate_statuses")"
ever_succeeded="$(jq '[.[] | select(.state == "success")] | length' <<<"$gate_statuses")"

post_status() {
  # 140-char API limit on description.
  gh api -X POST "repos/$GH_REPO/statuses/$HEAD_SHA" \
    -f state="$1" -f context="$GATE_CONTEXT" \
    -f description="${2:0:140}" \
    -f target_url="https://github.com/$GH_REPO/pull/$PR_NUMBER" >/dev/null || {
    echo "::error::could not post $GATE_CONTEXT=$1 on $HEAD_SHA"
    exit 1
  }
  echo "posted $GATE_CONTEXT=$1 on $HEAD_SHA ($2)"
}

if [ "$desired" != "success" ]; then
  if [ "$current_state" = "$desired" ] && [ "$current_desc" = "${detail:0:140}" ]; then
    echo "PR #$PR_NUMBER: $GATE_CONTEXT already $desired; nothing to do"
    exit 0
  fi
  post_status "$desired" "$detail"
  exit 0
fi

# desired == success from here on.
if [ "$current_state" = "success" ]; then
  echo "PR #$PR_NUMBER: $GATE_CONTEXT already success; nothing to do"
  exit 0
fi
if [ "$ever_succeeded" -gt 0 ]; then
  # An approved attempt already executed on this exact sha; its required
  # contexts stand on their own merits. Skip the redundant full re-run.
  post_status success "re-approved: an approved CI attempt already ran for this head"
  exit 0
fi

# First awaiting→approved flip for this head: rerun its completed
# pull_request runs so the new attempt opens the gate and executes the jobs.
# A run cannot be rerun while in progress; in QUIESCE mode wait (bounded) for
# the head to settle. QUIESCE=0 snapshots once: in-progress runs are left for
# the next scheduled pass. An attempt still running at decision time is left
# to finish — its own classifier job reads the CURRENT review state live.
runs="[]"
polls=1
[ "$QUIESCE" = "1" ] && polls=60
for attempt in $(seq 1 "$polls"); do
  # Paginated + slurped like every other list read: repeated reopen/ready
  # transitions can push a head past one page of runs.
  raw_runs="$(gh api "repos/$GH_REPO/actions/runs?head_sha=$HEAD_SHA&per_page=100" --paginate)" || {
    echo "::error::could not read workflow runs for head $HEAD_SHA"
    exit 1
  }
  runs="$(jq -s '[.[].workflow_runs[]? | select(.event == "pull_request") | {id, name, status, conclusion, run_attempt}]' <<<"$raw_runs")" || {
    echo "::error::could not parse workflow runs for head $HEAD_SHA"
    exit 1
  }
  in_progress="$(jq '[.[] | select(.status != "completed")] | length' <<<"$runs")"
  [ "$in_progress" -eq 0 ] && break
  [ "$QUIESCE" = "1" ] || break
  [ "$attempt" -eq "$polls" ] && break
  echo "waiting: $in_progress run(s) still in progress on $HEAD_SHA (poll $attempt)"
  sleep 30
done
if [ "${in_progress:-0}" -ne 0 ]; then
  echo "::warning::run(s) still in progress on $HEAD_SHA; leaving them to finish (their classifier job evaluates the current review state)"
  exit 0
fi

total="$(jq length <<<"$runs")"
if [ "$total" -eq 0 ]; then
  echo "::warning::no completed pull_request runs exist on head $HEAD_SHA (Actions dispatch failure?); cannot open the gate - push a new commit or dispatch CI manually"
  exit 0
fi

exit_code=0
# `name` reads last: run names contain spaces.
while read -r id run_attempt name; do
  [ -z "$id" ] && continue
  if [ "$run_attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "::warning::run $id ($name) is at attempt $run_attempt (cap $MAX_ATTEMPTS); leaving it alone - gh run rerun to retry manually"
    continue
  fi
  echo "rerun (open the review gate): run $id ($name)"
  gh api -X POST "repos/$GH_REPO/actions/runs/$id/rerun" || {
    echo "::warning::could not rerun run $id"
    exit_code=1
  }
done < <(jq -r '.[] | "\(.id) \(.run_attempt) \(.name)"' <<<"$runs")
exit "$exit_code"
