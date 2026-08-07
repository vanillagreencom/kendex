#!/usr/bin/env bash
# Review-gate v2 SINGLE WRITER — one default-branch-defined orchestration for
# every gate write (review-gate v2 single-writer plan, Change 1/1b;
# vanillagreencom/vstack#1099).
# Shipped by the vstack review-gate skill; vendored into consumers at
# .agents/skills/review-gate/scripts/. Invoked only by the writer workflow
# (templates/review-gate-writer.yml); it composes the review-predicate.sh
# evaluation with the status write and the bounded approval rerun that used
# to live in approval-refire.sh.
#
# CONVERGE-ALL, EVERY LEG (plan binding finding F2): except for the
# merge_group leg and the fork read-only no-op, EVERY invocation enumerates
# and converges EVERY open PR — event legs included, exactly like the old
# rerun workflow ("every executing run converges every open PR"). The
# writer's one concurrency group means bursts evict pending runs; because
# whichever run survives converges everyone, eviction is harmless instead of
# silently stranding the evicted events' heads until the cron. Per-head
# work happens in a recursive single-head invocation (PR_NUMBER + HEAD_SHA
# set), which is an internal contract, not a workflow input.
#
# Model per head: evaluate review-predicate.sh and converge the gate commit
# status (context: REVIEW_GATE_CONTEXT):
#
#   verdict != approved   → POST the pending/failure status directly.
#                           Downward posts NEVER defer — overwriting toward
#                           closed is the safe direction.
#   verdict == approved   → the status may read `success` ONLY these ways:
#     (a) a PRIOR gate success exists on this same sha — proof an approved
#         attempt already executed its jobs here — post success directly
#         (through the VST-65 ordering guard), sparing a re-run;
#     (b) the PROOF-ATTEMPT PROVENANCE MARKER is the current gate status and
#         a completed pull_request attempt ABOVE the marker's recorded floor
#         exists. The marker is posted only after this writer re-ran EVERY
#         candidate run, and it carries the highest attempt those reruns
#         started from, so a completion above the floor is necessarily one
#         of them — not a manual pre-approval rerun and not a sibling lane
#         that never re-ran (binding finding F3, hardened by review). ANY
#         leg can post this — the marker, not the triggering event, is what
#         certifies the completion (a missed workflow_run event converges on
#         the next cron tick);
#     (c) the ORDERING FAST PATH (binding finding F1): with no marker, post
#         success directly iff a completed pull_request attempt STARTED
#         after the evaluated evidence was created AND that attempt SKIPPED
#         NO JOBS. The skipped-jobs proof is the load-bearing half: an
#         attempt whose live gate read refused is exactly an attempt whose
#         gated jobs skipped, and thread resolution / changes-requested
#         dismissal are undatable, so no timestamp can rule that out. Zero
#         skipped jobs means nothing was withheld from that attempt however
#         the gate read went. This is what keeps a carry-forward push at
#         exactly ONE heavy CI bill;
#     (d) EVENT_NAME=merge_group: unconditional success on the ephemeral
#         merge-group sha — queue entries are post-approval by construction
#         (no predicate read at all). This is EVENT_NAME's ONLY role: every
#         other leg behaves identically and is driven by observed state,
#         never by which event fired.
#   Otherwise (approved, no marker, no fast path) the writer RERUNS the
#   head's completed pull_request runs (bounded by
#   REVIEW_GATE_MAX_RERUN_ATTEMPTS) and posts the provenance marker, NOT
#   success: pre-approval attempts SKIP the heavy jobs, and skipped required
#   checks satisfy rulesets, so a direct success would merge untested code
#   (success-needs-proof). The rerun's completion re-triggers the writer
#   (workflow_run leg — spike-proven that a GITHUB_TOKEN-issued rerun still
#   delivers workflow_run: completed) and path (b) posts the first success.
#
# WRITE DISCIPLINE (VST-65 + plan finding 8): two writer runs can still
# interleave on one head, so before ANY success post the current gate
# status is RE-READ and the post is DEFERRED when a non-success entry was
# created at/after this run's evaluation instant (that writer saw newer
# review state); a failed re-read also defers — withholding success is the
# fail-safe side. Downward posts never defer. Writes are idempotent: when
# the current gate entry already matches state + description the writer
# no-ops, so idle cron ticks append nothing.
#
# NO FORK SPECIAL CASES: every leg of the writer workflow holds a
# write-capable default-branch token, so fork heads take the same path as
# same-repo heads (the #1094/#1095 convergence patches die with the second
# writer; the #1095 direct-post was itself the unsafe thing — see the plan's
# production-evidence section). The one exception is pull_request_review
# fired by a FORK PR, whose token GitHub downgrades to read-only (plan
# finding 2): the workflow flags that case with WRITER_READ_ONLY=1 and this
# script exits GREEN as a no-op before touching anything — fork review
# evidence converges on the cron floor.
#
# Env (required): GH_TOKEN (or ambient gh auth), GH_REPO.
# Env (leg selection):
#   EVENT_NAME    the triggering event name. "merge_group" posts the
#                 unconditional queue success (HEAD_SHA required, no PR
#                 identifiers); every other value — including empty — is
#                 equivalent (converge-all; see the model above).
#   WRITER_READ_ONLY  "1": exit 0 immediately, posting and reading nothing
#                 (the fork pull_request_review no-op above).
#   PR_NUMBER / HEAD_SHA / PR_AUTHOR  the INTERNAL single-head contract used
#                 by the enumeration's recursive per-PR invocation (both
#                 identifiers required; PR_AUTHOR resolved by the predicate
#                 when empty). Top-level invocations leave PR_NUMBER unset
#                 and converge every open PR.
# Settings (lib/settings.sh — env > vstack.settings.toml > default):
#   REVIEW_GATE_CONTEXT             gate commit-status context (default "Review gate")
#                 (REVIEW_GATE_OVERRIDE_CONTEXT — the v2 name for the
#                 operator override status, plan Change 2 — is resolved by
#                 review-predicate.sh itself, so EVERY live gate read honors
#                 it, not just this writer.)
#   REVIEW_GATE_MAX_RERUN_ATTEMPTS  rerun backstop (default 5): runs at/above
#                 the cap are left alone. Resolved through rg_setting like
#                 every other key (env > settings file > default) — the
#                 refire's bare MAX_ATTEMPTS env escape hatch is deliberately
#                 NOT carried over: it bypassed settings precedence.
#   REVIEW_GATE_API_ATTEMPTS / REVIEW_GATE_API_RETRY_DELAY_SECONDS
#                 bounded retry budget for THROTTLED rerun POSTs (default 1 =
#                 no retry). Only throttles retry; refusals and server errors
#                 never do.
#
# STUCK vs MALFUNCTION (VST-36, ported from the refire/sweep — plan Change
# 1b's disposition, exactly): "GitHub refuses the rerun" (unqualified 4xx)
# WARNS without redding the run — the head cannot be advanced and stays
# visibly pending; "no completed run exists to re-run" is not even stuck
# under the workflow_run mechanism — it WARNS and simply waits for the
# completion leg. Read failures, a rerun 401 or 5xx, and throttles
# exhausted through the REVIEW_GATE_API_ATTEMPTS budget RED the run so the
# workflow's VST-36 sustained-failure escalation sees a malfunctioning
# writer. Either way the gate context on the head stays non-success —
# pending with the disposition in the run log — never silently open.
#
# Read errors fail LOUDLY (exit 1) without taking any action: treating a
# transient API failure as absent evidence could flip a healthy PR's state.
set -u

# The fork pull_request_review no-op precedes everything, including settings
# resolution: a read-only run must exit green even under a broken settings
# file it could not have acted on anyway.
if [ "${WRITER_READ_ONLY:-0}" = "1" ]; then
  echo "read-only token (fork pull_request_review); no-op — the scheduled writer pass converges this head"
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/lib/settings.sh"

EVENT_NAME="${EVENT_NAME:-}"

# `|| exit 1`: rg_setting fails on a present-but-unparseable assignment, and
# that is a configuration error to surface, never an empty value to act on.
MAX_ATTEMPTS="$(rg_setting REVIEW_GATE_MAX_RERUN_ATTEMPTS "5")" || exit 1
GATE_CONTEXT="$(rg_setting REVIEW_GATE_CONTEXT "Review gate")" || exit 1
API_ATTEMPTS="$(rg_setting REVIEW_GATE_API_ATTEMPTS "1")" || exit 1
API_RETRY_DELAY="$(rg_setting REVIEW_GATE_API_RETRY_DELAY_SECONDS "2")" || exit 1

case "$MAX_ATTEMPTS" in
  ''|*[!0-9]*)
    echo "::error::review-writer: REVIEW_GATE_MAX_RERUN_ATTEMPTS must be an integer, got '$MAX_ATTEMPTS'"
    exit 1
    ;;
esac
case "$API_ATTEMPTS" in
  ''|*[!0-9]*|0)
    echo "::error::review-writer: REVIEW_GATE_API_ATTEMPTS must be an integer >= 1, got '$API_ATTEMPTS'"
    exit 1
    ;;
esac
case "$API_RETRY_DELAY" in
  ''|*[!0-9]*)
    echo "::error::review-writer: REVIEW_GATE_API_RETRY_DELAY_SECONDS must be a non-negative integer, got '$API_RETRY_DELAY'"
    exit 1
    ;;
esac
if [ -z "$GATE_CONTEXT" ]; then
  echo "::error::review-writer: REVIEW_GATE_CONTEXT must not be empty"
  exit 1
fi

if [ -z "${GH_REPO:-}" ]; then
  echo "::error::review-writer: GH_REPO is required"
  exit 1
fi

# --- merge-queue leg (plan finding 4; ported from review-gate-queue.yml) ---
# Queue entries are POST-APPROVAL BY CONSTRUCTION: a PR only enters the
# queue after its own head satisfied the required gate status, so the
# ephemeral merge-group sha gets an unconditional success for the same
# context — no predicate read, no ordering guard (nothing else ever writes
# on a merge-group sha).
if [ "$EVENT_NAME" = "merge_group" ]; then
  if [ -z "${HEAD_SHA:-}" ]; then
    echo "::error::review-writer: HEAD_SHA is required on the merge_group leg"
    exit 1
  fi
  gh api -X POST "repos/$GH_REPO/statuses/$HEAD_SHA" \
    -f state=success -f context="$GATE_CONTEXT" \
    -f description="merge-queue entry: post-approval by construction" >/dev/null || {
    echo "::error::could not post $GATE_CONTEXT on merge-group sha $HEAD_SHA"
    exit 1
  }
  echo "posted $GATE_CONTEXT=success on merge-group sha $HEAD_SHA"
  exit 0
fi

self="$script_dir/$(basename "${BASH_SOURCE[0]}")"

# --- converge-all enumeration: every leg (binding finding F2; the old
# sweep's ALL_OPEN_PRS mode, now the writer's only top-level mode) ---
if [ -z "${PR_NUMBER:-}" ]; then
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
  failed=0
  while read -r number head author; do
    [ -z "$number" ] && continue
    if ! EVENT_NAME="$EVENT_NAME" PR_NUMBER="$number" \
        HEAD_SHA="$head" PR_AUTHOR="$author" bash "$self" </dev/null; then
      echo "::error::convergence failed for PR #$number (see log above)"
      failed=1
    fi
  done < <(jq -r '.[] | "\(.number) \(.headRefOid) \(.author.login // "")"' <<<"$prs")
  exit "$failed"
fi

# --- single-head evaluation (the enumeration's recursive contract) ---
if [ -z "${HEAD_SHA:-}" ]; then
  echo "::error::review-writer: HEAD_SHA is required alongside PR_NUMBER"
  exit 1
fi

# Stamped BEFORE the predicate reads (VST-65): any gate status created at or
# after this instant may reflect newer review state than this evaluation —
# the success-post ordering guard below compares against it.
evaluated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The predicate's stdout contract is ONE line and stays that way (consumers
# parse `detail=` positionally); the evidence instant for the F1 ordering
# fast path comes back through a per-invocation FILE seam instead.
evidence_at_file="$(mktemp)" || {
  echo "::error::could not create a temp file for the evidence instant"
  exit 1
}
trap 'rm -f "$evidence_at_file"' EXIT
verdict_line="$(REVIEW_GATE_EVIDENCE_AT_FILE="$evidence_at_file" "$script_dir/review-predicate.sh")" || {
  echo "::error::review predicate evaluation failed for PR #$PR_NUMBER; taking no action - the next writer pass retries"
  exit 1
}
verdict="$(sed -n 's/^verdict=\([a-z-]*\) .*/\1/p' <<<"$verdict_line")"
detail="$(sed -n 's/^verdict=[a-z-]* detail=//p' <<<"$verdict_line")"
# Absent or empty means "evidence cannot be ordered against CI attempts" —
# the ordering fast path is simply skipped, never guessed.
evidence_at="$(head -n 1 "$evidence_at_file" 2>/dev/null)"
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
# for the direct-success fast path; and the F1 ordering fast path checks the
# non-success entries against evidence_at.
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

# POST-ORDERING GUARD (VST-65, ported from the old gate pair's post job).
# Before posting SUCCESS, re-read the current gate status and DEFER when a
# non-success entry was created at/after this run's evaluation — that writer
# run saw newer review state (e.g. a changes-requested post landed in the
# evaluate→post gap), and overwriting it with a stale approved would open
# the gate until the next pass. Deferring is self-healing: the next event or
# cron tick re-reads live state. Fetch and filter are SEPARATE steps: a pipe
# would replace gh's exit status with jq's, so a failed or truncated re-read
# could slurp to an empty array and report newer=0 — the exact stale-success
# fail-open this guard closes. A failed re-read defers too: withholding
# success is the fail-safe side. And `>=`, not `>`: both timestamps have
# one-second resolution, so a non-success write landing later within the
# evaluation second compares EQUAL — deferring on equality self-heals.
post_success_guarded() {
  guard_newer=""
  if guard_pages="$(gh api "repos/$GH_REPO/commits/$HEAD_SHA/statuses?per_page=100" --paginate)" \
     && [ -n "$guard_pages" ]; then
    guard_newer="$(jq -rs --arg ctx "$GATE_CONTEXT" --arg since "$evaluated_at" \
        '[add // [] | .[] | select(.context == $ctx and .state != "success"
          and (($since | length) > 0) and ((.created_at // "") >= $since))] | length' \
        <<<"$guard_pages")" || guard_newer=""
  fi
  if [ "$guard_newer" != "0" ]; then
    echo "::warning::deferring the success post: $GATE_CONTEXT was re-written (or unreadable) after this run's evaluation at $evaluated_at — a newer writer run's verdict stands; the next pass converges"
    exit 0
  fi
  post_status success "$1"
}

if [ "$desired" != "success" ]; then
  # Idempotent no-op (plan finding 8): idle passes append nothing.
  if [ "$current_state" = "$desired" ] && [ "$current_desc" = "${detail:0:140}" ]; then
    echo "PR #$PR_NUMBER: $GATE_CONTEXT already $desired; nothing to do"
    exit 0
  fi
  # Downward posts never defer — toward closed is the safe direction.
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
  post_success_guarded "re-approved: an approved CI attempt already ran for this head"
  exit 0
fi
# PROOF-ATTEMPT PROVENANCE (plan Change 1b; scenarios 10a/10c). A completed
# attempt is only success-proof when THIS writer issued it post-approval:
# an attempt that started with the gate closed SKIPPED the heavy jobs, and
# posting success on its completion would green the gate with the heavy CI
# never having run — exactly the 10a approval-mid-CI timing. Provenance is
# the gate status itself: after issuing the proof rerun the writer posts a
# distinctive pending marker on the head, and the first success posts only
# when that marker is present and the attempt has completed. Keying on the
# MARKER (not on the triggering event) also keeps the cron leg a true
# floor: a missed completion event converges on the next tick.
MARKER_PREFIX="approved: proof CI attempt re-running"
MARKER_SUFFIX="; success posts on its completion"

# One runs read serves every branch. Paginated + slurped like every other
# list read: repeated reopen/ready transitions can push a head past one
# page of runs. run_started_at rides along for the F1 ordering fast path.
raw_runs="$(gh api "repos/$GH_REPO/actions/runs?head_sha=$HEAD_SHA&per_page=100" --paginate)" || {
  echo "::error::could not read workflow runs for head $HEAD_SHA"
  exit 1
}
runs="$(jq -s '[.[].workflow_runs[]? | select(.event == "pull_request") | {id, name, status, conclusion, run_attempt, run_started_at}]' <<<"$raw_runs")" || {
  echo "::error::could not parse workflow runs for head $HEAD_SHA"
  exit 1
}
in_progress="$(jq '[.[] | select(.status != "completed")] | length' <<<"$runs")"
total="$(jq length <<<"$runs")"
completed=$((total - in_progress))

case "$current_state:$current_desc" in
  "pending:$MARKER_PREFIX"*) marker_present=1 ;;
  *) marker_present=0 ;;
esac
if [ "$marker_present" = "1" ]; then
  # Marker present: the proof attempt was issued post-approval.
  if [ "$in_progress" -ne 0 ]; then
    echo "proof attempt still in progress on $HEAD_SHA; its completion re-triggers the writer (workflow_run leg)"
    exit 0
  fi
  # The proof completion must be an attempt this writer's rerun created, so
  # it must sit ABOVE the attempt floor the marker recorded — the highest
  # attempt that already existed when the rerun was issued (binding finding
  # F3, hardened per the pre-PR review). Keying on run_attempt >= 2 alone is
  # not enough: a MANUAL pre-approval rerun (routine on flaky CI) leaves a
  # completed attempt 2 that ran gate-closed, which a concurrent pass on a
  # stale runs read would certify. Timestamps cannot substitute here — the
  # rerun is issued a moment BEFORE the marker is posted, so the legitimate
  # proof attempt can start before the marker's own created_at.
  #
  # A marker without a parsable floor is a pre-hardening marker (or a
  # truncated description): fall back to the >= 2 rule rather than wedge.
  marker_floor="$(sed -n 's/^'"$MARKER_PREFIX"' (above attempt \([0-9][0-9]*\)).*/\1/p' <<<"$current_desc")"
  [ -z "$marker_floor" ] && marker_floor=1
  proof_completed="$(jq --argjson floor "$marker_floor" \
    '[.[] | select(.status == "completed" and ((.run_attempt // 0) > $floor) and ((.run_attempt // 0) >= 2))] | length' <<<"$runs")"
  if [ "$proof_completed" -gt 0 ]; then
    # The approved attempt has RUN (red or green — 10b: a red required
    # check blocks merge on its own; gate red means reviewer objection,
    # never build failure). First success posts here and only here.
    post_success_guarded "$detail"
    exit 0
  fi
  if [ "$completed" -gt 0 ]; then
    echo "proof marker present (floor: attempt $marker_floor) but no completion above the floor is visible yet (the issued rerun is not yet listed); waiting — the proof attempt's completion converges this head"
    exit 0
  fi
  echo "::warning::proof marker present but no pull_request runs visible on $HEAD_SHA (deleted or expired runs?); leaving the gate pending — the cron floor re-examines"
  exit 0
fi

# No marker: first awaiting→approved handling for this head. A run cannot
# be rerun while in progress — in-flight attempts are left to finish (their
# completion fires the writer, whose marker-less pass lands HERE — the 10a
# face; no polling, unlike the old refire's QUIESCE loop).
if [ "$in_progress" -ne 0 ]; then
  echo "::warning::$in_progress run(s) still in progress on $HEAD_SHA; leaving them to finish — their completion re-triggers the writer, which then issues the proof rerun"
  exit 0
fi

if [ "$total" -eq 0 ]; then
  # Not stuck under the workflow_run mechanism: when a run appears and
  # completes, the writer converges this head (Change 1b).
  echo "::warning::no completed pull_request runs exist on head $HEAD_SHA; nothing to re-run yet — the workflow_run completion leg converges when one completes"
  exit 0
fi

# THE ORDERING FAST PATH (binding finding F1). A completed attempt that
# STARTED strictly after the evaluated evidence was created executed its own
# live gate read with that evidence visible — it approved and ran the heavy
# jobs (the gate job's enumerated fail-open paths run them too) — so success
# can post directly, sparing the redundant rerun. This is what keeps a
# carry-forward push at ONE heavy CI bill (the owner's trivial-push cost
# requirement) and removes the redundant rerun when a review lands just
# before an unrelated push.
#
# TIMESTAMPS ALONE CANNOT CERTIFY AN ATTEMPT (pre-PR review, reproduced
# twice). "Evidence predates the attempt" only implies the attempt's live
# read approved when evidence was the ONLY thing that could have closed the
# gate. Unresolved threads and a standing changes-requested close it for
# reasons carrying NO timestamp anywhere in the API — thread resolution and
# review dismissal are both eventless — so an attempt can start well after
# the evidence and still have run gate-closed. Nor can the writer's own
# posted history stand in for that: its idempotent no-op suppresses the
# re-post of an unchanged closed verdict, and an evicted pending run may
# never have posted the blocker at all (the heavy jobs skip on the CI job's
# OWN live read, which the writer never sees).
#
# So the proof is taken from the attempt itself: an attempt whose live gate
# read refused is exactly an attempt whose gated jobs SKIPPED. If a completed
# attempt skipped NO jobs, nothing was withheld from it — however its gate
# read went, the heavy jobs ran, which is the whole invariant. Both
# conjuncts:
#   1. a completed pull_request attempt with run_started_at > evidence_at
#      (strict: equal seconds cannot be ordered);
#   2. that same attempt's job list contains ZERO `skipped` conclusions.
# Unrelated skips (path filters, matrix conditionals) merely refuse the fast
# path, and every failure mode here — an unreadable jobs list included —
# falls through to the rerun path, which is always sound. Cost: one extra
# jobs read per candidate attempt, only on the approved-without-marker pass.
#
# Residual, deliberately not addressed: on a fork PR the pull_request
# workflow set is fork-defined, so the attempt can be a workflow the fork
# authored. That is inherent to PR-defined CI (a fork can neuter its own
# heavy jobs on any path, marker included) — the required heavy contexts are
# what actually gate the merge.
if [ -n "$evidence_at" ]; then
  ordered_ids="$(jq -r --arg ev "$evidence_at" \
    '[.[] | select(.status == "completed" and ((.run_started_at // "") != "") and (.run_started_at > $ev))]
     | sort_by(.run_started_at) | reverse | .[] | .id' <<<"$runs")"
  for candidate_id in $ordered_ids; do
    # Fetch and filter separately, and require the jobs array: a failed or
    # malformed read must refuse the fast path, never read as "no skips".
    jobs_pages="$(gh api "repos/$GH_REPO/actions/runs/$candidate_id/jobs?per_page=100" --paginate)" || continue
    [ -n "$jobs_pages" ] || continue
    skipped="$(jq -s 'if (length > 0) and all(type == "object" and ((.jobs | type) == "array"))
                      then [.[].jobs[] | select(.conclusion == "skipped")] | length
                      else error("malformed jobs page") end' <<<"$jobs_pages" 2>/dev/null)" || continue
    if [ "$skipped" = "0" ]; then
      echo "ordering fast path: run $candidate_id started after the evidence at $evidence_at and skipped no jobs — its gated jobs ran"
      post_success_guarded "$detail"
      exit 0
    fi
  done
fi

# Rerun POST with outcome classification (THROTTLE vs REFUSAL, ported from
# approval-refire.sh). The response is read with `gh api -i` so the throttle
# discriminator can see the headers: retry-after / exhausted
# x-ratelimit-remaining / HTTP 429 is a THROTTLE (retried to the
# REVIEW_GATE_API_ATTEMPTS bound); any other 4xx EXCEPT 401 is a REFUSAL —
# the first one stops retrying (each retry feeds the same limit); a 401 and
# anything else (5xx/transport) is a malfunction with NO in-process retry —
# the cron floor is the universal retry.
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
      # 401 is never a per-run condition: the token itself is bad, so
      # convergence has stopped for EVERY head — malfunction, not "stuck"
      # (a stuck-green 401 would silence the VST-36 escalation exactly
      # when the whole writer is down). 403 stays a refusal: GitHub uses it
      # for per-run non-rerunnable states (expired log retention, "cannot
      # be re-run"), and a genuine repo-wide permission fault also breaks
      # the writer's other reads/writes, which already redden the run.
      401) return 3 ;;
      4[0-9][0-9]) return 2 ;;
    esac
    return 3
  done
}

exit_code=0
issued=0
candidates=0
issued_floor=0
# @tsv, not string interpolation: a workflow display NAME is PR-defined on
# fork PRs, and a newline inside it would split one record into two — the
# synthesized record's first field then feeds a rerun POST for an arbitrary
# run id. @tsv escapes embedded newlines/tabs, keeping one record per line.
while IFS=$'\t' read -r id run_attempt name; do
  [ -z "$id" ] && continue
  candidates=$((candidates + 1))
  if [ "$run_attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "::warning::run $id ($name) is at attempt $run_attempt (cap $MAX_ATTEMPTS); leaving it alone — no proof attempt can be issued for this head, so the gate stays pending until a new push, newer evidence, or a raised REVIEW_GATE_MAX_RERUN_ATTEMPTS"
    continue
  fi
  echo "rerun (open the review gate): run $id ($name)"
  rerun_run "$id"
  case "$?" in
    0)
      issued=$((issued + 1))
      # The floor is the highest attempt among the runs THIS pass actually
      # re-ran — never across every run on the head. A run left alone at the
      # cap would otherwise raise the floor above anything the issued reruns
      # can ever reach, wedging the head at pending forever.
      [ "$run_attempt" -gt "$issued_floor" ] && issued_floor="$run_attempt"
      ;;
    2)
      # STUCK, not malfunction: GitHub refuses this rerun (unqualified 4xx —
      # e.g. the run is no longer re-runnable). The writer cannot advance
      # this head; the head is left as found (gate stays pending) and the
      # run stays green so one long-lived PR cannot redden the health
      # signal forever.
      echo "::warning::GitHub refused the rerun of run $id ($name): this head cannot be advanced by the writer (stuck, not malfunction) - gh run rerun to retry manually"
      ;;
    1)
      # Throttled through the retry budget: convergence has STOPPED for
      # every head, not just this one — malfunction, never "stuck".
      echo "::error::rerun POST for run $id ($name) rate-limited through the retry budget ($API_ATTEMPTS attempt(s)): the writer is throttled"
      exit_code=1
      ;;
    *)
      echo "::error::rerun POST for run $id ($name) failed (server/transport/credentials): writer malfunction; the cron floor is the retry"
      exit_code=1
      ;;
  esac
done < <(jq -r '.[] | [.id, .run_attempt, .name] | @tsv' <<<"$runs")

# The marker certifies "an approved attempt of the head's CI has run", and
# the completion pass accepts ANY completed run above the floor — so it may
# only be posted when EVERY candidate run was re-run. If one workflow's rerun
# was capped, refused, or malfunctioned while a sibling's succeeded, the
# sibling's completion would satisfy the marker and open the gate while the
# unre-run workflow still sits on its pre-approval, heavy-jobs-skipped
# attempt. Partial reruns therefore leave the gate pending with the
# disposition in the log; the next pass (event or cron floor) retries the
# whole set, and a permanently un-rerunnable run is the "stuck" disposition —
# visible, never silently open.
if [ "$issued" -gt 0 ] && [ "$issued" -eq "$candidates" ]; then
  # The marker is a downward-direction post (pending), so it never defers.
  post_status pending "$MARKER_PREFIX (above attempt $issued_floor)$MARKER_SUFFIX"
elif [ "$issued" -gt 0 ]; then
  echo "::warning::only $issued of $candidates pull_request run(s) on $HEAD_SHA could be re-run; NOT posting the proof marker (a sibling completion must not certify a workflow that never re-ran) — the gate stays pending and the next pass retries the whole set"
fi
exit "$exit_code"
