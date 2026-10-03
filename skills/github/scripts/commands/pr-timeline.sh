#!/bin/bash
# GitHub API - One pull request's phase stamps and CI wall times
# Usage: pr-timeline.sh <PR-number> [--repo OWNER/REPO] [--gate-context NAME]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/github-api.sh"
# shellcheck source=../lib/ci-run-correlation.sh
source "$SCRIPT_DIR/../lib/ci-run-correlation.sh"

show_help() {
    cat << 'EOF'
One pull request's phase stamps and CI wall times

Usage: pr-timeline.sh <PR-number> [--repo OWNER/REPO] [--gate-context NAME]

Arguments:
  PR-number             The pull request to read

Options:
  --repo OWNER/REPO     The repository; default GH_REPO, else this checkout's
  --gate-context NAME   Historical review-status context; default `Review gate`

Output, one JSON object on stdout:
{
  "pr": 42, "repo": "owner/repo", "state": "MERGED",
  "head": "<final head oid>", "merge_commit": "<oid>" | null,
  "stamps": {
    "first_commit":     author date of the PR's first commit,
    "created":          the PR opened,
    "last_push":        the later of the final head's push and the last force
                        push,
    "first_bot_review": the first review a Bot account other than the PR's
                        author submitted: a lane that opens its PR as an app
                        answers its threads in reviews of its own, which are
                        no bot's review of the PR,
    "first_gate_met":   the first approval submitted on any head the PR
                        carried, one dismissed since included: a ruleset
                        that dismisses stale approvals on push turns every
                        approval on a pushed-over head into a dismissed
                        review; where none was submitted, the first success
                        the gate context posted on any head the PR carried,
                        force-pushed-over heads included, read from each
                        head's whole status history, since a later status on
                        that head replaces the earlier one,
    "gate_met":         the first approval submitted on the final head;
                        where none was submitted, the gate context's
                        success on the final head,
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
  "bot_reviews":         reviews submitted by Bot accounts other than the
                         PR's author,
  "push_times":          each push to the PR's head branch, ascending and
                         unique, as the repository's activity log records it:
                         a push a later rebase rewrote keeps its time, and a
                         commit counts from its push, not its committer date.
                         The log is read for the branch's life that holds the
                         PR's opening, between the deletions around it. Null
                         where the PR names no head repository or branch, or
                         the log records no push in that life,
  "bot_review_times":    each of those Bot reviews' submission, ascending,
  "rounds": [           the review stage, ordered by start (a round with no
                         start by its end), a review before a fix at one time:
    {"kind": "review", "head": <oid>, "start": the head's push,
     "end": the first review submitted on that head, "secs": end - start},
    {"kind": "fix", "head": <the reviewed oid>, "start": that review,
     "end": the first push after it, "secs": end - start}
  ]
}

A review round is one per head that carries a review; a fix round follows a
review round only where a push came after its review. A review by the PR's
own author is a thread reply and never a review round. A head's push is the
creation of its first check suite, which GitHub makes when the push arrives:
a head's committer date predates its push by any wait before the push, the
pull request's timeline keeps a push time only for a forced push, and
push_times names no head. A head with no check suite is no push, and a round
starting at one has a null start and secs; the final head's push falls back
to its committer date only for last_push.

Every stamp is ISO 8601 UTC, and every stamp and duration is null where the
PR never reached it. The gate is a commit status, not a check run, so no CI
figure counts it. Every CI figure reads only the checks of the current
authoritative run of each workflow, as lib/ci-run-correlation.sh scopes a
`gh pr checks` rollup, and the latest check run per name within a suite, as
GitHub's own rollup does.

Errors: {"error": "..."} on stderr and exit 1. A connection longer than one
page (more than 100 commits, reviews or marked timeline events) refuses as
`truncated: <connection>` rather than printing a stamp read from part of the
history. Each commit's check suites and each suite's check runs are read
through every page with the GraphQL cursor, up to 20 pages of 50 suites per
commit and 10 pages of 100 runs per suite; a connection still open at that
cap refuses the same way, as `truncated: check-suites` or
`truncated: check-runs`. Each head's status history is read through every
page of the REST commit statuses endpoint, read only for a PR with no
approval, and the head branch's pushes through every page of the REST
repository activity endpoint.

Examples:
  pr-timeline.sh 42
  pr-timeline.sh 42 --repo owner/repo
EOF
}

# The pages past the first of one commit's check suites and of one suite's
# check runs, each read at the cursor the page before ended on. The two
# suite queries share the suite node's selection and all three the run
# node's, so a page carries what the first page carried. Each query defines
# only the fragments it spreads: GitHub refuses one defined and unused.
RUN_PAGE_FRAGMENT='fragment runPage on CheckRunConnection {
  pageInfo { hasNextPage endCursor }
  nodes { name status conclusion startedAt completedAt detailsUrl }
}'
SUITE_PAGE_FRAGMENTS='fragment suitePage on CheckSuiteConnection {
  pageInfo { hasNextPage endCursor }
  nodes { id workflowRun { event url workflow { name } } checkRuns(first: 100, filterBy: { checkType: LATEST }) { ...runPage } }
}
'"$RUN_PAGE_FRAGMENT"
SUITES_PAGE_QUERY='query suitesPage($owner: String!, $name: String!, $oid: GitObjectID!, $cursor: String!) {
  repository(owner: $owner, name: $name) {
    object(oid: $oid) { ... on Commit { checkSuites(first: 50, after: $cursor) { ...suitePage } } }
  }
}
'"$SUITE_PAGE_FRAGMENTS"
RUNS_PAGE_QUERY='query runsPage($id: ID!, $cursor: String!) {
  node(id: $id) { ... on CheckSuite { checkRuns(first: 100, after: $cursor, filterBy: { checkType: LATEST }) { ...runPage } } }
}
'"$RUN_PAGE_FRAGMENT"
QUERY='query($owner: String!, $name: String!, $number: Int!, $gate: String!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number state createdAt mergedAt author { login } headRefName headRepository { nameWithOwner }
      mergeCommit { oid ...suites }
      firstCommit: commits(first: 1) { nodes { commit { authoredDate } } }
      headCommit: commits(last: 1) { nodes { commit { oid committedDate ...gate ...suites } } }
      commits(last: 100) { totalCount nodes { commit { oid committedDate ...pushed } } }
      reviews(first: 100) { totalCount nodes { state submittedAt author { __typename login } commit { oid ...pushed } } }
      timelineItems(first: 100, itemTypes: [HEAD_REF_FORCE_PUSHED_EVENT, AUTO_MERGE_ENABLED_EVENT, ADDED_TO_MERGE_QUEUE_EVENT, REVIEW_DISMISSED_EVENT]) {
        pageInfo { hasNextPage }
        nodes {
          __typename
          ... on HeadRefForcePushedEvent { createdAt beforeCommit { oid ...pushed } }
          ... on AutoMergeEnabledEvent { createdAt }
          ... on AddedToMergeQueueEvent { createdAt }
          ... on ReviewDismissedEvent { previousReviewState review { submittedAt } }
        }
      }
    }
  }
}
fragment gate on Commit { status { context(name: $gate) { state createdAt } } }
fragment suites on Commit { checkSuites(first: 50) { ...suitePage } }
fragment pushed on Commit { firstSuite: checkSuites(first: 1) { nodes { createdAt } } }
'"$SUITE_PAGE_FRAGMENTS"

# The page caps the help states: 20 pages of 50 suites per commit, 10 pages
# of 100 runs per suite. A merge-queue commit carries one suite per workflow
# run, so a repository with many workflows passes 50 on one commit.
SUITE_PAGES=20
RUN_PAGES=10
HEAD_PATH='.repository.pullRequest.headCommit.nodes[0].commit'
MERGE_PATH='.repository.pullRequest.mergeCommit'

# The response on stdin, printed with the connection at jq path CONN read to
# its end: each further page is QUERY under GH_ARGS plus the cursor the last
# page ended on, its connection at PAGE_CONN in the page. The walk stops at
# CAP pages, the first page counted, and leaves hasNextPage true for FILTER
# to refuse. LABEL names the connection in each refusal: which walk, of
# which commit or suite, since every page fails with gh_graphql's one text.
#   page_to_end CONN PAGE_CONN QUERY CAP LABEL [GH_ARGS...]
page_to_end() {
    local conn="$1" page_conn="$2" query="$3" cap="$4" label="$5" data cursor page inner pages=1
    shift 5
    data=$(cat)
    while jq -e "$conn | . != null and .pageInfo.hasNextPage == true" >/dev/null <<<"$data"; do
        [ "$pages" -lt "$cap" ] || break
        cursor=$(jq -r "$conn.pageInfo.endCursor // empty" <<<"$data") || return 1
        [ -n "$cursor" ] || { github_error "pr-timeline: $label page past the first names no cursor"; return 1; }
        # stderr rides along: a failed call prints nothing on stdout and one
        # error object on stderr, which folds into this one refusal, so the
        # caller reads a single object rather than two.
        if ! page=$(gh_graphql "$query" "$@" -f cursor="$cursor" 2>&1); then
            inner=$(jq -rs 'map(.error // empty) | first // empty' <<<"$page" 2>/dev/null) || inner=""
            github_error "pr-timeline: $label page after $cursor unreadable: ${inner:-$page}"
            return 1
        fi
        # A page with no connection where one was asked for: node(id:) and
        # object(oid:) answer null for a suite or commit the token cannot
        # read, and gh_graphql prints null for a response with no data.
        # Merging that would close the walk over part of the history.
        jq -e "$page_conn | type == \"object\" and has(\"pageInfo\")" >/dev/null <<<"$page" \
            || { github_error "pr-timeline: $label page after $cursor carries no connection"; return 1; }
        # Both values reach jq on stdin: a page of check runs can exceed
        # ARG_MAX as an argument.
        data=$(printf '%s\n%s\n' "$data" "$page" | jq -sc "(.[1] | $page_conn) as \$next | .[0]
            | $conn |= (.nodes += \$next.nodes | .pageInfo = \$next.pageInfo)") || return 1
        pages=$((pages + 1))
    done
    printf '%s\n' "$data"
}

# The response on stdin, printed with the check suites of the commit at jq
# path PATH and each suite's check runs read to their end.
#   page_commit_checks PATH OWNER NAME
page_commit_checks() {
    local path="$1" owner="$2" name="$3" data oid i id
    data=$(cat)
    oid=$(jq -r "$path.oid // empty" <<<"$data") || return 1
    data=$(page_to_end "$path.checkSuites" '.repository.object.checkSuites' "$SUITES_PAGE_QUERY" "$SUITE_PAGES" \
        "check-suites of $oid" -f owner="$owner" -f name="$name" -f oid="$oid" <<<"$data") || return 1
    for i in $(jq -r "[$path.checkSuites.nodes[]?] | to_entries[] | select(.value.checkRuns.pageInfo.hasNextPage == true) | .key" <<<"$data"); do
        id=$(jq -r "$path.checkSuites.nodes[$i].id" <<<"$data") || return 1
        data=$(page_to_end "$path.checkSuites.nodes[$i].checkRuns" '.node.checkRuns' "$RUNS_PAGE_QUERY" "$RUN_PAGES" \
            "check-runs of suite $id" -f id="$id" <<<"$data") || return 1
    done
    printf '%s\n' "$data"
}

# The response is read in one place: a truncated connection first, since a
# stamp taken from part of a history is a wrong answer, then the stamps. A
# check-suites or check-runs connection is still open here only past the
# page cap, since page_commit_checks read it to its end before that.
# Timestamps are GitHub's fixed `YYYY-MM-DDThh:mm:ssZ`, so min and max over
# the strings order them.
FILTER='
def suites($c): [$c.checkSuites.nodes[]?];
# Each check run in the shape a `gh pr checks` rollup row has, which
# scope_current_run reads: the run it belongs to through its workflow run
# link, its state the conclusion once completed and the status before, a
# neutral conclusion reading as skipped as gh buckets it.
def rollup($s): [$s[] | . as $suite | .checkRuns.nodes[]
  | {name, workflow: ($suite.workflowRun.workflow.name // ""),
     link: ($suite.workflowRun.url // .detailsUrl // ""),
     state: (if .status != "COMPLETED" then .status
             elif .conclusion == "NEUTRAL" then "SKIPPED" else .conclusion end),
     startedAt, completedAt}];
def gate($c): $c.status.context // null | select(. != null and .state == "SUCCESS") | .createdAt;
def secs($a; $b): if $a == null or $b == null then null else ($b | fromdate) - ($a | fromdate) end;
# A commit connection lists its check suites oldest first.
def pushed($c): $c.firstSuite.nodes[0].createdAt // null;
# The review stage: per reviewed head, its push to its first review, then
# that review to the next push. $pushed maps each known head to its push.
# The rounds are ordered once built: a review on an older head can be
# submitted after the review of a newer head.
def rounds($reviews; $pushed):
  ([$pushed[] | select(. != null)] | unique) as $push_times
  | [$reviews | group_by(.commit.oid) | map(min_by(.submittedAt)) | .[]
     | . as $r | $pushed[$r.commit.oid] as $start
     | {kind: "review", head: $r.commit.oid, start: $start, end: $r.submittedAt, secs: secs($start; $r.submittedAt)},
       (([$push_times[] | select(. > $r.submittedAt)] | min) as $next
        | if $next == null then empty
          else {kind: "fix", head: $r.commit.oid, start: $r.submittedAt, end: $next, secs: secs($r.submittedAt; $next)} end)]
  | sort_by([.start // .end, (if .kind == "review" then 0 else 1 end)]);
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
  | ([$p.commits.nodes[].commit, ($pushes[] | .beforeCommit // empty), ($p.reviews.nodes[] | .commit // empty)]
     | map({key: .oid, value: pushed(.)}) | from_entries) as $pushed
  | [$p.reviews.nodes[] | select(.state == "APPROVED" and .submittedAt != null)] as $approvals
  # A dismissed review reports DISMISSED, its approval kept only on the
  # dismissal event.
  | [$p.timelineItems.nodes[] | select(.__typename == "ReviewDismissedEvent")
     | select(.previousReviewState == "APPROVED") | .review.submittedAt // empty] as $dismissed_approvals
  | [$p.reviews.nodes[] | select(.author.__typename == "Bot" and .submittedAt != null
      and .author.login != $p.author.login)] as $bot
  | {
      first_commit: ($p.firstCommit.nodes[0].commit.authoredDate // null),
      created: $p.createdAt,
      last_push: ([($pushed[$head.oid] // $head.committedDate), ($pushes[] | .createdAt)] | map(select(. != null)) | max),
      first_bot_review: ($bot | map(.submittedAt) | min),
      first_gate_met: ($approvals | map(.submittedAt) + $dismissed_approvals | min),
      gate_met: (([$approvals[] | select(.commit.oid == $head.oid) | .submittedAt] | min)
                 // ([gate($head)] | first // null)),
      ci_green: null,
      armed: ([$p.timelineItems.nodes[] | select(.__typename == "AutoMergeEnabledEvent") | .createdAt] | max),
      queued: ([$p.timelineItems.nodes[] | select(.__typename == "AddedToMergeQueueEvent") | .createdAt] | max),
      merged: $p.mergedAt
    } as $stamps
  | {
      pr: $p.number, repo: $repo, state: $p.state,
      head: $head.oid, merge_commit: ($p.mergeCommit.oid // null),
      stamps: $stamps,
      ci_head_secs: null,
      ci_merge_group_secs: null,
      _checks: {head: rollup($head_suites), group: rollup($group_suites)},
      open_secs: secs($stamps.created; $stamps.merged),
      bot_reviews: ($bot | length),
      push_times: null,
      bot_review_times: ($bot | map(.submittedAt) | sort),
      rounds: rounds(
        [$p.reviews.nodes[] | select(.submittedAt != null and .commit != null)
         | select($p.author == null or .author.login != $p.author.login)];
        $pushed)
    }
  end'

pr_timeline() {
    local pr_num="" repo_arg="" gate="Review gate"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) show_help; exit 0 ;;
            --repo)
                [ -n "${2:-}" ] || { github_error '--repo requires OWNER/REPO'; exit 1; }
                repo_arg="$2"; shift 2 ;;
            --gate-context)
                [ -n "${2:-}" ] || { github_error '--gate-context requires a name'; exit 1; }
                gate="$2"; shift 2 ;;
            -*) github_error "Unknown option: $1"; exit 1 ;;
            *)
                [ -z "$pr_num" ] || { github_error "Unexpected argument: $1"; exit 1; }
                pr_num="$1"; shift ;;
        esac
    done
    [[ "$pr_num" =~ ^[1-9][0-9]*$ ]] || { github_error 'pr-timeline needs a PR number'; exit 1; }

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
        || { github_error "No PR found: $pr_num"; exit 1; }
    data=$(page_commit_checks "$HEAD_PATH" "$owner" "$name" <<<"$data") || exit 1
    data=$(page_commit_checks "$MERGE_PATH" "$owner" "$name" <<<"$data") || exit 1
    result=$(jq -c --arg repo "$owner/$name" "$FILTER" <<<"$data") || { github_error 'pr-timeline: unreadable response'; exit 1; }
    if jq -e 'has("truncated")' >/dev/null <<<"$result"; then
        jq -c '{error: ("truncated: " + .truncated)}' <<<"$result" >&2
        exit 1
    fi
    # The CI figures, over the checks scope_current_run keeps of each set.
    local head_checks group_checks
    head_checks=$(jq -c '._checks.head' <<<"$result" | scope_current_run) \
        || { github_error 'pr-timeline: head checks unscoped'; exit 1; }
    group_checks=$(jq -c '._checks.group' <<<"$result" | scope_current_run) \
        || { github_error 'pr-timeline: merge-group checks unscoped'; exit 1; }
    result=$(jq -c --argjson head "$head_checks" --argjson group "$group_checks" "$CI_RUN_JQ_DEFS"'
        def span($r): [$r[] | select(.startedAt != null and .completedAt != null)]
          | if length == 0 then null
            else (map(.completedAt | fromdate) | max) - (map(.startedAt | fromdate) | min) end;
        def green($r): if ($r | length) > 0 and all($r[]; bucket | IN("pass", "skipping"))
          then ($r | map(.completedAt) | max) else null end;
        del(._checks) | .stamps.ci_green = green($head)
        | .ci_head_secs = span($head) | .ci_merge_group_secs = span($group)' <<<"$result") \
        || { github_error 'pr-timeline: unreadable checks'; exit 1; }

    # first_gate_met, where no approval set it, from the status history of
    # every head the PR carried: the GraphQL status names only each head's
    # latest, and the review writer posts success, then failure or pending
    # when a late thread opens, then success again on one head.
    local approved heads sha statuses first="" earliest
    approved=$(jq -r '.stamps.first_gate_met // empty' <<<"$result") || { github_error 'pr-timeline: unreadable response'; exit 1; }
    if [ -z "$approved" ]; then
        heads=$(jq -r '.repository.pullRequest | [.commits.nodes[].commit.oid,
            (.timelineItems.nodes[] | select(.__typename == "HeadRefForcePushedEvent") | .beforeCommit.oid // empty)]
            | unique[]' <<<"$data") || { github_error 'pr-timeline: unreadable response'; exit 1; }
        for sha in $heads; do
            statuses=$(gh_rest "repos/$owner/$name/commits/$sha/statuses?per_page=100" --paginate) || exit 1
            if ! earliest=$(jq -rs --arg gate "$gate" \
                '[.[][] | select(.context == $gate and .state == "success") | .created_at] | min // empty' <<<"$statuses"); then
                github_error "pr-timeline: unreadable statuses for $sha"
                exit 1
            fi
            if [[ -n "$earliest" && ( -z "$first" || "$earliest" < "$first" ) ]]; then
                first="$earliest"
            fi
        done
        result=$(jq -c --arg first "$first" '.stamps.first_gate_met = (if $first == "" then null else $first end)' <<<"$result") \
            || { github_error 'pr-timeline: unreadable response'; exit 1; }
    fi

    # push_times, from the head branch's activity log: GitHub records no plain
    # push on the pull request, and a commit's committer date is when it was
    # made, which a rebase rewrites. A branch name comes back after a
    # deletion, so the pushes read are the ones of the branch's life the PR
    # opened in: after the last deletion before the opening, up to the first
    # deletion after it.
    local head_repo head_ref ref_query activity pushes=null
    if ! head_repo=$(jq -r '.repository.pullRequest.headRepository.nameWithOwner // empty' <<<"$data") \
        || ! head_ref=$(jq -r '.repository.pullRequest.headRefName // empty' <<<"$data") \
        || ! ref_query=$(jq -rn --arg ref "refs/heads/$head_ref" '$ref | @uri'); then
        github_error 'pr-timeline: unreadable response'
        exit 1
    fi
    if [[ -n "$head_repo" && -n "$head_ref" ]]; then
        activity=$(gh_rest "repos/$head_repo/activity?ref=$ref_query&per_page=100" --paginate) || exit 1
        if ! pushes=$(jq -cs --arg opened "$(jq -r '.repository.pullRequest.createdAt' <<<"$data")" '
            [.[][]] as $a
            | ([$a[] | select(.activity_type == "branch_deletion" and .timestamp < $opened) | .timestamp] | max) as $from
            | ([$a[] | select(.activity_type == "branch_deletion" and .timestamp >= $opened) | .timestamp] | min) as $to
            | [$a[] | select(.activity_type | IN("branch_creation", "push", "force_push"))
                    | select(($from == null or .timestamp > $from) and ($to == null or .timestamp <= $to))
                    | .timestamp] | unique
            | if length == 0 then null else . end' <<<"$activity"); then
            github_error "pr-timeline: unreadable activity for $head_repo $head_ref"
            exit 1
        fi
    fi
    jq -c --argjson pushes "$pushes" '.push_times = $pushes' <<<"$result"
}

pr_timeline "$@"
