#!/bin/bash
# GitHub API - One pull request's phase stamps and CI wall times
# Usage: pr-timeline.sh <PR-number> [--repo OWNER/REPO] [--gate-context NAME]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
One pull request's phase stamps and CI wall times

Usage: pr-timeline.sh <PR-number> [--repo OWNER/REPO] [--gate-context NAME]

Arguments:
  PR-number             The pull request to read

Options:
  --repo OWNER/REPO     The repository; default GH_REPO, else this checkout's
  --gate-context NAME   The review gate's commit-status context; default
                        REVIEW_GATE_CONTEXT, else `Review gate`, the review-gate
                        skill's own default

Output, one JSON object on stdout:
{
  "pr": 42, "repo": "owner/repo", "state": "MERGED",
  "head": "<final head oid>", "merge_commit": "<oid>" | null,
  "stamps": {
    "first_commit":     author date of the PR's first commit,
    "created":          the PR opened,
    "last_push":        the later of the final head's committer date and the
                        last force push,
    "first_bot_review": the first review a Bot account submitted,
    "first_gate_met":   the first success of the gate context on any head the
                        PR carried, force-pushed-over heads included,
    "gate_met":         the gate context's success on the final head,
    "ci_green":         the last check run on the final head completed, when
                        every one concluded success, neutral or skipped,
    "armed":            the last time auto-merge was enabled,
    "queued":           the last time the PR joined a merge queue,
    "merged":           the merge
  },
  "ci_head_secs":        first check-run start to last check-run end on the
                         final head,
  "ci_merge_group_secs": the same over the merge commit's merge_group runs,
  "open_secs":           created to merged,
  "bot_reviews":         reviews submitted by Bot accounts
}

Every stamp is ISO 8601 UTC, and every stamp and duration is null where the
PR never reached it. The gate is a commit status, not a check run, so no CI
figure counts it.

Errors: {"error": "..."} on stderr and exit 1. A connection longer than one
page (more than 100 commits, reviews, marked timeline events or check runs, or
50 check suites on one commit) refuses as `truncated: <connection>` rather
than printing a stamp read from part of the history.

Examples:
  pr-timeline.sh 42
  pr-timeline.sh 42 --repo owner/repo
EOF
}

QUERY='query($owner: String!, $name: String!, $number: Int!, $gate: String!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number state createdAt mergedAt
      mergeCommit { oid ...suites }
      firstCommit: commits(first: 1) { nodes { commit { authoredDate } } }
      headCommit: commits(last: 1) { nodes { commit { oid committedDate ...gate ...suites } } }
      commits(last: 100) { totalCount nodes { commit { ...gate } } }
      reviews(first: 100) { totalCount nodes { submittedAt author { __typename } } }
      timelineItems(first: 100, itemTypes: [HEAD_REF_FORCE_PUSHED_EVENT, AUTO_MERGE_ENABLED_EVENT, ADDED_TO_MERGE_QUEUE_EVENT]) {
        pageInfo { hasNextPage }
        nodes {
          __typename
          ... on HeadRefForcePushedEvent { createdAt beforeCommit { ...gate } }
          ... on AutoMergeEnabledEvent { createdAt }
          ... on AddedToMergeQueueEvent { createdAt }
        }
      }
    }
  }
}
fragment gate on Commit { status { context(name: $gate) { state createdAt } } }
fragment suites on Commit {
  checkSuites(first: 50) {
    pageInfo { hasNextPage }
    nodes {
      workflowRun { event }
      checkRuns(first: 100) { pageInfo { hasNextPage } nodes { status conclusion startedAt completedAt } }
    }
  }
}'

# The response is read in one place: a truncated connection first, since a
# stamp taken from part of a history is a wrong answer, then the stamps.
# Timestamps are GitHub's fixed `YYYY-MM-DDThh:mm:ssZ`, so min and max over
# the strings order them.
FILTER='
def suites($c): [$c.checkSuites.nodes[]?];
def runs($s): [$s[] | .checkRuns.nodes[]];
def span($r): [$r[] | select(.startedAt != null and .completedAt != null)]
  | if length == 0 then null
    else (map(.completedAt | fromdate) | max) - (map(.startedAt | fromdate) | min) end;
def green($r): if ($r | length) > 0
    and all($r[]; .status == "COMPLETED" and (.conclusion | IN("SUCCESS", "NEUTRAL", "SKIPPED")))
  then ($r | map(.completedAt) | max) else null end;
def gate($c): $c.status.context // null | select(. != null and .state == "SUCCESS") | .createdAt;
def secs($a; $b): if $a == null or $b == null then null else ($b | fromdate) - ($a | fromdate) end;
.repository.pullRequest as $p
| ($p.headCommit.nodes[0].commit) as $head
| ([$head, $p.mergeCommit] | map(select(. != null)) | map(suites(.)) | add // []) as $all_suites
| [ (if $p.commits.totalCount > 100 then "commits" else empty end),
    (if $p.reviews.totalCount > 100 then "reviews" else empty end),
    (if $p.timelineItems.pageInfo.hasNextPage then "timeline" else empty end),
    ([$head, $p.mergeCommit][] | select(. != null) | select(.checkSuites.pageInfo.hasNextPage) | "check-suites"),
    ($all_suites[] | select(.checkRuns.pageInfo.hasNextPage) | "check-runs")
  ] as $truncated
| if ($truncated | length) > 0 then {truncated: $truncated[0]} else
  suites($head) as $head_suites
  | [if $p.mergeCommit == null then empty else suites($p.mergeCommit)[] | select(.workflowRun.event == "merge_group") end] as $group_suites
  | [$p.timelineItems.nodes[] | select(.__typename == "HeadRefForcePushedEvent")] as $pushes
  | [$p.reviews.nodes[] | select(.author.__typename == "Bot" and .submittedAt != null)] as $bot
  | {
      first_commit: ($p.firstCommit.nodes[0].commit.authoredDate // null),
      created: $p.createdAt,
      last_push: ([$head.committedDate, ($pushes[] | .createdAt)] | map(select(. != null)) | max),
      first_bot_review: ($bot | map(.submittedAt) | min),
      first_gate_met: ([($p.commits.nodes[] | gate(.commit)), ($pushes[] | .beforeCommit // null | select(. != null) | gate(.))] | min),
      gate_met: ([gate($head)] | first // null),
      ci_green: green(runs($head_suites)),
      armed: ([$p.timelineItems.nodes[] | select(.__typename == "AutoMergeEnabledEvent") | .createdAt] | max),
      queued: ([$p.timelineItems.nodes[] | select(.__typename == "AddedToMergeQueueEvent") | .createdAt] | max),
      merged: $p.mergedAt
    } as $stamps
  | {
      pr: $p.number, repo: $repo, state: $p.state,
      head: $head.oid, merge_commit: ($p.mergeCommit.oid // null),
      stamps: $stamps,
      ci_head_secs: span(runs($head_suites)),
      ci_merge_group_secs: span(runs($group_suites)),
      open_secs: secs($stamps.created; $stamps.merged),
      bot_reviews: ($bot | length)
    }
  end'

pr_timeline() {
    local pr_num="" repo_arg="" gate="${REVIEW_GATE_CONTEXT:-Review gate}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) show_help; exit 0 ;;
            --repo)
                [ -n "${2:-}" ] || { echo '{"error": "--repo requires OWNER/REPO"}' >&2; exit 1; }
                repo_arg="$2"; shift 2 ;;
            --gate-context)
                [ -n "${2:-}" ] || { echo '{"error": "--gate-context requires a name"}' >&2; exit 1; }
                gate="$2"; shift 2 ;;
            -*) jq -nc --arg a "$1" '{error: ("Unknown option: " + $a)}' >&2; exit 1 ;;
            *)
                [ -z "$pr_num" ] || { jq -nc --arg a "$1" '{error: ("Unexpected argument: " + $a)}' >&2; exit 1; }
                pr_num="$1"; shift ;;
        esac
    done
    [[ "$pr_num" =~ ^[1-9][0-9]*$ ]] || { echo '{"error": "pr-timeline needs a PR number"}' >&2; exit 1; }

    local repo_info owner name data result
    if [ -n "$repo_arg" ]; then
        repo_info=$(GH_REPO="$repo_arg" get_repo_info) || exit 1
    else
        repo_info=$(get_repo_info) || exit 1
    fi
    owner=$(get_owner "$repo_info") || exit 1
    name=$(get_repo "$repo_info") || exit 1

    data=$(gh_graphql "$QUERY" -f owner="$owner" -f name="$name" -F number="$pr_num" -f gate="$gate") || exit 1
    jq -e '.repository.pullRequest != null' >/dev/null <<<"$data" \
        || { jq -nc --arg n "$pr_num" '{error: ("No PR found: " + $n)}' >&2; exit 1; }
    result=$(jq -c --arg repo "$owner/$name" "$FILTER" <<<"$data") || { echo '{"error": "pr-timeline: unreadable response"}' >&2; exit 1; }
    if jq -e 'has("truncated")' >/dev/null <<<"$result"; then
        jq -c '{error: ("truncated: " + .truncated)}' <<<"$result" >&2
        exit 1
    fi
    printf '%s\n' "$result"
}

pr_timeline "$@"
