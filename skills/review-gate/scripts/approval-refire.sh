#!/usr/bin/env bash
# Review-gate convergence for ONE pull request head — the single source of
# truth for how review-state transitions reach the merge-blocking gate commit
# status and the CI runs behind it. Shipped by the vstack review-gate skill;
# vendored into consumers at .agents/skills/review-gate/scripts/.
#
# Model: the repo's CI gate job evaluates review-predicate.sh and posts the
# gate commit status (context: REVIEW_GATE_CONTEXT) on the PR head —
# `pending` until review evidence exists (blocks merge without a false red),
# `failure` only on changes-requested, `success` only from a run attempt that
# executed with the gate open (heavy jobs skip while it is closed). This
# script converges the status when review state changes between runs:
#
#   verdict != approved   → POST the pending/failure status directly. No
#                           reruns: pending blocks merge on its own, so a
#                           dismissed review or reopened thread needs no
#                           check-run churn.
#   verdict == approved   → the status may read `success` ONLY in two ways:
#     (a) a PRIOR gate success exists on this same sha — proof an approved
#         attempt already executed its jobs here (a red build from that
#         attempt stays blocked by its own red required contexts) — then
#         post success directly, sparing a pointless full re-run;
#     (b) otherwise RERUN the head's completed pull_request runs: the new
#         attempt's gate job re-evaluates, posts success, and the heavy
#         jobs actually run. Never post success without (a): pre-review
#         attempts SKIP the heavy jobs, and skipped required checks satisfy
#         rulesets, so a directly-posted success would merge untested code.
#
# Callers (see the skill's templates/):
#   - approval-rerun.yml (event-driven)                       ALL_OPEN_PRS=1
#     EVERY executing run converges every open PR: it evicted whatever
#     writer was pending in the shared concurrency group, and the
#     workflow's own token-authored status posts cannot re-trigger it
#     (GitHub suppresses token-authored events), so no later pass exists to
#     recover the evicted work — the evictor does everything (#1039).
#   - approval-sweep.yml (scheduled backstop)                 ALL_OPEN_PRS=1
#     Backstop for transitions that emit no usable workflow event at all
#     (thread resolution fires no trigger; dismissal residue coalesced away
#     by pending-slot replacement). NOT an eviction-recovery path: a run the
#     job-level trust guards skip never claims the job-level writer group,
#     so it evicts nothing and there is nothing to recover.
#   Single-PR mode (PR_NUMBER/HEAD_SHA) remains for direct invocation.
#
# Env (required): GH_TOKEN (or ambient gh auth), GH_REPO; PR_NUMBER and
# HEAD_SHA unless ALL_OPEN_PRS=1.
# Env (optional):
#   PR_AUTHOR     resolved from the PR when empty.
#   QUIESCE       "1" (default in single-PR mode): wait (bounded) for
#                 in-progress runs on the head to complete before a rerun
#                 decision. "0" (default under ALL_OPEN_PRS=1): act on
#                 completed runs only (the next scheduled pass catches
#                 stragglers) — a serialized writer must not camp the shared
#                 concurrency slot polling one head.
#   ALL_OPEN_PRS  "1": ignore PR_NUMBER/HEAD_SHA and converge EVERY open PR
#                 (the sweep's enumeration, owned here so event-driven
#                 callers reuse it instead of duplicating it). A failure for
#                 one PR is reported (::error) and the pass continues to the
#                 rest, then exits non-zero.
# Settings (lib/settings.sh — env > vstack.settings.toml > default):
#   REVIEW_GATE_CONTEXT             gate commit-status context (default "Review gate")
#   REVIEW_GATE_MAX_RERUN_ATTEMPTS  rerun backstop (default 5): runs at/above
#                 the cap are left alone (gh run rerun retries manually).
#                 Attempts only grow on the first awaiting→approved flip per
#                 head, so the cap exists for pathological ping-pong, not
#                 normal review cycles. Legacy MAX_ATTEMPTS env is honored.
#   REVIEW_GATE_API_ATTEMPTS / REVIEW_GATE_API_RETRY_DELAY_SECONDS
#                 bounded retry budget for THROTTLED rerun POSTs (default 1 =
#                 no retry). Only throttles retry; refusals and server errors
#                 never do.
#
# CONVERGENCE PROPERTIES (VST-36; consumer-proven, earned through production
# incidents on the archetype-C reference implementation):
#   1. NEVER WRITE ON A FAILURE PATH. A failed read leaves the head exactly
#      as found — no defensive pending posts (once a sweep runs per open
#      head, one transient outage would de-green every open PR, each
#      recovery a full in-place rerun). The scheduled sweep is the universal
#      retry. In all-PRs mode a failed head is reported (::error) and the
#      pass continues; the failure reddens the run without touching the head.
#   2. STUCK vs MALFUNCTION are distinct outcomes. "This head cannot be
#      advanced by convergence" (GitHub refuses the rerun with an
#      unqualified 4xx; or the head has no completed pull_request run at
#      all, so nothing can re-run) WARNS and keeps the run green;
#      "convergence malfunctioned" (read/projection failure, rerun 5xx,
#      throttled through the budget) REDDENS the run so escalation can fire.
#      Folding them either reddens the health signal forever on one
#      long-lived PR, or hides a repository-wide fault behind a warning.
#   3. THROTTLE vs REFUSAL on the rerun POST. GitHub answers 403 for a run
#      refusal AND for the secondary rate limit; classifying by code alone
#      fails open (a throttled 403 read as "stuck" leaves the sweep green
#      while convergence has stopped for every head). The discriminator
#      reads the RESPONSE (gh api -i): a retry-after header, an exhausted
#      x-ratelimit-remaining, or HTTP 429 is a throttle — retried to the
#      REVIEW_GATE_API_ATTEMPTS bound, then escalated as malfunction. The
#      first non-throttle 4xx stops retrying (each retry feeds the same
#      limit) and is a refusal (stuck).
#
# Read errors fail LOUDLY (exit 1) without taking any action: treating a
# transient API failure as absent evidence could flip a healthy PR's state.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/lib/settings.sh"

ALL_OPEN_PRS="${ALL_OPEN_PRS:-0}"
if [ "$ALL_OPEN_PRS" = "1" ]; then
  QUIESCE="${QUIESCE:-0}"
else
  QUIESCE="${QUIESCE:-1}"
fi
# `|| exit 1`: rg_setting fails on a present-but-unparseable assignment, and
# that is a configuration error to surface, never an empty value to act on.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-$(rg_setting REVIEW_GATE_MAX_RERUN_ATTEMPTS "5")}" || exit 1
GATE_CONTEXT="$(rg_setting REVIEW_GATE_CONTEXT "Review gate")" || exit 1
API_ATTEMPTS="$(rg_setting REVIEW_GATE_API_ATTEMPTS "1")" || exit 1
API_RETRY_DELAY="$(rg_setting REVIEW_GATE_API_RETRY_DELAY_SECONDS "2")" || exit 1

case "$MAX_ATTEMPTS" in
  ''|*[!0-9]*)
    echo "::error::approval-refire: REVIEW_GATE_MAX_RERUN_ATTEMPTS must be an integer, got '$MAX_ATTEMPTS'"
    exit 1
    ;;
esac
case "$API_ATTEMPTS" in
  ''|*[!0-9]*|0)
    echo "::error::approval-refire: REVIEW_GATE_API_ATTEMPTS must be an integer >= 1, got '$API_ATTEMPTS'"
    exit 1
    ;;
esac
case "$API_RETRY_DELAY" in
  ''|*[!0-9]*)
    echo "::error::approval-refire: REVIEW_GATE_API_RETRY_DELAY_SECONDS must be a non-negative integer, got '$API_RETRY_DELAY'"
    exit 1
    ;;
esac
if [ -z "$GATE_CONTEXT" ]; then
  echo "::error::approval-refire: REVIEW_GATE_CONTEXT must not be empty"
  exit 1
fi

if [ "$ALL_OPEN_PRS" = "1" ]; then
  if [ -z "${GH_REPO:-}" ]; then
    echo "::error::approval-refire: GH_REPO is required"
    exit 1
  fi
  # Full pagination (one array per page, slurped flat) — a fixed page limit
  # would silently leave PRs beyond it unconverged forever.
  raw_prs="$(gh api "repos/$GH_REPO/pulls?state=open&per_page=100" --paginate)" || {
    echo "::error::could not list open PRs"
    exit 1
  }
  prs="$(jq -s '[add // [] | .[] | {number, headRefOid: .head.sha, author: {login: (.user.login // "")}}]' <<<"$raw_prs")" || {
    echo "::error::could not parse the open-PR list"
    exit 1
  }
  count="$(jq length <<<"$prs")"
  echo "converging $count open PR(s)"
  self="$script_dir/$(basename "${BASH_SOURCE[0]}")"
  failed=0
  while read -r number head author; do
    [ -z "$number" ] && continue
    if ! ALL_OPEN_PRS=0 PR_NUMBER="$number" HEAD_SHA="$head" PR_AUTHOR="$author" \
        QUIESCE="$QUIESCE" bash "$self" </dev/null; then
      echo "::error::convergence failed for PR #$number (see log above)"
      failed=1
    fi
  done < <(jq -r '.[] | "\(.number) \(.headRefOid) \(.author.login // "")"' <<<"$prs")
  exit "$failed"
fi

for required in GH_REPO PR_NUMBER HEAD_SHA; do
  if [ -z "$(eval "echo \${$required:-}")" ]; then
    echo "::error::approval-refire: $required is required"
    exit 1
  fi
done

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
# to finish — its own gate job reads the CURRENT review state live.
runs="[]"
polls=1
[ "$QUIESCE" = "1" ] && polls=60
attempt=0
while [ "$attempt" -lt "$polls" ]; do
  attempt=$((attempt + 1))
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
  echo "::warning::run(s) still in progress on $HEAD_SHA; leaving them to finish (their gate job evaluates the current review state)"
  exit 0
fi

total="$(jq length <<<"$runs")"
if [ "$total" -eq 0 ]; then
  echo "::warning::no completed pull_request runs exist on head $HEAD_SHA (Actions dispatch failure?); cannot open the gate - push a new commit or dispatch CI manually"
  exit 0
fi

# Rerun POST with outcome classification (header properties 2 and 3). The
# response is read with `gh api -i` so the throttle discriminator can see
# the headers: retry-after / exhausted x-ratelimit-remaining / HTTP 429 is a
# THROTTLE (retried to the REVIEW_GATE_API_ATTEMPTS bound); any other 4xx is
# a REFUSAL — the first one stops retrying (each retry feeds the same
# limit); anything else (5xx/transport) is a malfunction with NO in-process
# retry — the sweep is the universal retry.
rerun_run() { # run id -> 0 ok; 1 throttled through the budget; 2 refusal; 3 malfunction
  rr_id="$1"
  rr_attempt=1
  while :; do
    if rr_out="$(gh api -i -X POST "repos/$GH_REPO/actions/runs/$rr_id/rerun" 2>&1)"; then
      return 0
    fi
    rr_resp="$(printf '%s\n' "$rr_out" | tr -d '\r')"
    rr_code="$(printf '%s\n' "$rr_resp" | sed -n 's|^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*|\1|p' | head -n 1)"
    rr_throttle=0
    [ "$rr_code" = "429" ] && rr_throttle=1
    printf '%s\n' "$rr_resp" | grep -qi '^retry-after:' && rr_throttle=1
    printf '%s\n' "$rr_resp" | grep -qi '^x-ratelimit-remaining:[[:space:]]*0[[:space:]]*$' && rr_throttle=1
    if [ "$rr_throttle" = "1" ]; then
      if [ "$rr_attempt" -ge "$API_ATTEMPTS" ]; then
        return 1
      fi
      rr_attempt=$((rr_attempt + 1))
      echo "::warning::rerun POST for run $rr_id throttled; retry $rr_attempt/$API_ATTEMPTS after ${API_RETRY_DELAY}s"
      sleep "$API_RETRY_DELAY"
      continue
    fi
    case "$rr_code" in
      4[0-9][0-9]) return 2 ;;
    esac
    return 3
  done
}

exit_code=0
# `name` reads last: run names contain spaces.
while read -r id run_attempt name; do
  [ -z "$id" ] && continue
  if [ "$run_attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "::warning::run $id ($name) is at attempt $run_attempt (cap $MAX_ATTEMPTS); leaving it alone - gh run rerun to retry manually"
    continue
  fi
  echo "rerun (open the review gate): run $id ($name)"
  rerun_run "$id"
  case "$?" in
    0) ;;
    2)
      # STUCK, not malfunction: GitHub refuses this rerun (unqualified 4xx —
      # e.g. the run is no longer re-runnable). Convergence cannot advance
      # this head; the head is left as found and the run stays green so one
      # long-lived PR cannot redden the health signal forever.
      echo "::warning::GitHub refused the rerun of run $id ($name): this head cannot be advanced by convergence (stuck, not malfunction) - gh run rerun to retry manually"
      ;;
    1)
      # Throttled through the retry budget: convergence has STOPPED for
      # every head, not just this one — malfunction, never "stuck".
      echo "::error::rerun POST for run $id ($name) rate-limited through the retry budget ($API_ATTEMPTS attempt(s)): convergence is throttled"
      exit_code=1
      ;;
    *)
      echo "::error::rerun POST for run $id ($name) failed (server/transport): convergence malfunction; the scheduled sweep is the retry"
      exit_code=1
      ;;
  esac
done < <(jq -r '.[] | "\(.id) \(.run_attempt) \(.name)"' <<<"$runs")
exit "$exit_code"
