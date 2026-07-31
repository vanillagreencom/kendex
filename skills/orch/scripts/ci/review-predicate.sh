#!/usr/bin/env bash
# Review-gate predicate — the single source of truth for "is this PR head
# reviewed?". Canonical copy: vstack skills/orch/scripts/ci/; consumers
# VENDOR both this file and approval-refire.sh into .github/scripts/ and
# keep them in lockstep (see orch DEVELOPMENT.md § CI Triggering Patterns,
# "Review-gate reference scripts"). Callers: the repo's CI classifier job
# (posts the merge-blocking gate commit status from the verdict) and
# approval-refire.sh (converges the status and re-fires CI when the verdict
# flips to approved).
#
# Predicate: review evidence present for the CURRENT head (any non-author
# non-dismissed review, OR a `success` of the trusted reviewer's check-run
# or commit status, OR the trusted reviewer-outage attestation status) AND
# no changes-requested against the head AND zero unresolved review threads.
#
# Env (required): GH_TOKEN (or ambient gh auth), GH_REPO, PR_NUMBER, HEAD_SHA
# Env (optional):
#   PR_AUTHOR          resolved from the PR when empty.
#   REVIEW_CHECK_NAME  trusted reviewer check-run name / status context
#                      (default "Devin Review"; empty disables both clean-
#                      analysis evidence surfaces).
#   OUTAGE_CONTEXT     reviewer-outage attestation context (default
#                      "vstack-reviewer-outage"; empty disables it).
#
# Output: one machine-readable line on stdout:
#   verdict=approved|awaiting|threads-open|changes-requested detail=<human text>
# (diagnostic detail also echoed for logs). Exit codes:
#   0 — evaluated (verdict line is authoritative)
#   2 — evidence read failed; NO verdict was reached. Callers must treat this
#       as "take no action", never as awaiting: acting on a transient API
#       failure could flip a healthy PR's merge state.
set -u

REVIEW_CHECK_NAME="${REVIEW_CHECK_NAME-Devin Review}"
OUTAGE_CONTEXT="${OUTAGE_CONTEXT-vstack-reviewer-outage}"

for required in GH_REPO PR_NUMBER HEAD_SHA; do
  if [ -z "$(eval "echo \${$required:-}")" ]; then
    echo "::error::review-predicate: $required is required" >&2
    exit 2
  fi
done

if [ -z "${PR_AUTHOR:-}" ]; then
  PR_AUTHOR="$(gh api "repos/$GH_REPO/pulls/$PR_NUMBER" --jq .user.login)" || {
    echo "::error::could not resolve PR #$PR_NUMBER author" >&2
    exit 2
  }
fi

# Two steps, not a pipe: `--paginate` emits ONE ARRAY PER PAGE, which the
# count filters below would evaluate per-array (multi-line counts that can
# never equal "0" past 100 reviews), and a mid-pipe gh failure must fail
# loudly rather than hand jq a truncated page set.
raw_reviews="$(gh api "repos/$GH_REPO/pulls/$PR_NUMBER/reviews" --paginate)" || {
  echo "::error::could not read reviews for PR #$PR_NUMBER" >&2
  exit 2
}
reviews="$(jq -s 'add // []' <<<"$raw_reviews")" || {
  echo "::error::could not parse reviews for PR #$PR_NUMBER" >&2
  exit 2
}
# Changes-requested counts only each reviewer's LATEST non-dismissed review on
# the head, so a superseded CR that the same reviewer later cleared can't pin
# the PR red forever.
cr="$(jq --arg sha "$HEAD_SHA" '[.[] | select(.commit_id == $sha and .state != "DISMISSED")] | group_by(.user.login) | map(.[-1]) | map(select(.state == "CHANGES_REQUESTED")) | length' <<<"$reviews")"
got="$(jq --arg sha "$HEAD_SHA" --arg author "$PR_AUTHOR" '[.[] | select(.commit_id == $sha and .state != "DISMISSED" and .user.login != $author)] | length' <<<"$reviews")"

# Clean-analysis evidence (vstack#654): review bots like Devin submit a review
# OBJECT only when they have findings — a clean re-analysis passes their
# check but posts no review, so "review at head" would be forever
# unsatisfiable after a push that fixes everything. Accept the trusted name
# succeeding on THIS head as equivalent review evidence (exact-name match;
# the same user-configured trust model as orch's PR_REVIEW_CHECK). Evidence
# lives in EITHER API: some bots post a check-run, others a legacy commit
# STATUS (vstack#681). Query both; either counts.
# A read FAILURE here must fail LOUDLY: treating it as absent evidence could
# flip a healthy PR's merge state on a transient API hiccup.
check=0
if [ -n "$REVIEW_CHECK_NAME" ]; then
  # Two steps here too — the trusted name is data, so it reaches jq via
  # --arg, never by splicing it into the program text.
  raw_check_runs="$(gh api -X GET "repos/$GH_REPO/commits/$HEAD_SHA/check-runs" \
    -f check_name="$REVIEW_CHECK_NAME" -F per_page=10)" || {
    echo "::error::could not read $REVIEW_CHECK_NAME check-runs" >&2
    exit 2
  }
  check_runs="$(jq --arg name "$REVIEW_CHECK_NAME" \
    '[.check_runs[] | select(.name == $name and .conclusion == "success")] | length' \
    <<<"$raw_check_runs")" || {
    echo "::error::could not parse $REVIEW_CHECK_NAME check-runs" >&2
    exit 2
  }
  raw_combined="$(gh api "repos/$GH_REPO/commits/$HEAD_SHA/status")" || {
    echo "::error::could not read $REVIEW_CHECK_NAME commit status" >&2
    exit 2
  }
  check_status="$(jq --arg ctx "$REVIEW_CHECK_NAME" \
    '[.statuses[] | select(.context == $ctx and .state == "success")] | length' \
    <<<"$raw_combined")" || {
    echo "::error::could not parse $REVIEW_CHECK_NAME commit status" >&2
    exit 2
  }
  check=$((check_runs + check_status))
fi

# Reviewer-outage attestation (vstack#795): orch's approval-wait posts this
# trusted context on the head ONLY on genuine total reviewer silence (zero
# unresolved threads, no review/check/status engagement, head re-confirmed
# at emit). It substitutes for MISSING review evidence only —
# changes-requested and unresolved threads still fail closed. SECURITY:
# deliberate, bounded relaxation; trusted-publisher model identical to the
# clean-analysis status above. See orch DEVELOPMENT.md "Reviewer-outage
# recognition".
outageok=0
if [ -n "$OUTAGE_CONTEXT" ]; then
  raw_outage="$(gh api "repos/$GH_REPO/commits/$HEAD_SHA/status")" || {
    echo "::error::could not read reviewer-outage status" >&2
    exit 2
  }
  outageok="$(jq --arg ctx "$OUTAGE_CONTEXT" \
    '[.statuses[] | select(.context == $ctx and .state == "success")] | length' \
    <<<"$raw_outage")" || {
    echo "::error::could not parse reviewer-outage status" >&2
    exit 2
  }
fi

# A genuine GraphQL failure must NOT fall through as unresolved threads — fail
# loudly instead. `pageInfo.hasNextPage` (>100 threads) is a SUCCESSFUL read
# we cannot fully verify, so it reports "overflow" and fails closed to
# threads-open.
unresolved="$(gh api graphql \
  -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved}}}}}' \
  -F owner="${GH_REPO%/*}" -F repo="${GH_REPO#*/}" -F number="$PR_NUMBER" \
  --jq 'if .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage then "overflow" else ([.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length) end')" || {
  echo "::error::could not read review threads" >&2
  exit 2
}

echo "PR #$PR_NUMBER head $HEAD_SHA: reviews=$got clean-analysis=$check outage-marker=$outageok changes-requested=$cr unresolved-threads=$unresolved" >&2

if [ "$cr" != "0" ]; then
  echo "verdict=changes-requested detail=review changes requested on the current head"
elif [ "$got" = "0" ] && [ "$check" = "0" ] && [ "$outageok" = "0" ]; then
  echo "verdict=awaiting detail=awaiting a non-author review for $HEAD_SHA"
elif [ "$unresolved" != "0" ]; then
  echo "verdict=threads-open detail=$unresolved unresolved review thread(s)"
else
  echo "verdict=approved detail=reviewed at head with no unresolved threads"
fi
