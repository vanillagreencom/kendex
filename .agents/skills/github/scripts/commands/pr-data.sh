#!/bin/bash
# GitHub API - Get PR with threads, comments, and files
# Usage: pr-data.sh [PR-number|branch] [--format=safe|raw]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
Get PR Data

Usage: pr-data.sh [PR-number|branch] [options]

Arguments:
  PR-number|branch    PR number or branch name (default: current branch's PR)

Options:
  --format=safe       Normalized flat structure (DEFAULT)
  --format=raw        Original GitHub API structure
  --actionable        Only unresolved non-outdated threads, exclude bot comments

Output (safe format):
{
  "number": 23,
  "title": "PR title",
  "branch": "feature-branch",
  "files": ["path/to/file.rs"],
  "threads": [{
    "id": "PRRT_...",
    "is_resolved": false,
    "is_outdated": false,
    "path": "src/file.rs",
    "line": 42,
    "comments": [{
      "author": "reviewer",
      "body": "Comment text",
      "url": "https://..."
    }]
  }],
  "comments": [{
    "id": "IC_...",
    "author": "reviewer",
    "body": "PR-level comment",
    "url": "https://...",
    "created_at": "2025-01-01T00:00:00Z"
  }]
}

Examples:
  pr-data.sh 23
  pr-data.sh feature-branch
  pr-data.sh --format=raw
EOF
}

get_pr_data() {
    local pr_ref=""
    local pr_ref_set=false
    local actionable="false"
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --actionable)
                actionable="true"
                shift
                ;;
            --format=*)
                FORMAT="${1#--format=}"
                shift
                ;;
            --format)
                if [ -z "${2:-}" ]; then
                    github_error '--format requires an argument (safe or raw)'
                    exit 1
                fi
                FORMAT="$2"
                shift 2
                ;;
            -*)
                github_error "Unknown option: $1"
                exit 1
                ;;
            *)
                if [ "$pr_ref_set" = false ]; then
                    pr_ref="$1"; pr_ref_set=true
                else
                    github_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    case "$FORMAT" in
        safe|raw) ;;
        *)
            github_error "Invalid format: $FORMAT. Use: safe, raw"
            exit 1
            ;;
    esac

    # Resolve PR number
    local pr_num
    pr_num=$(resolve_pr_number "$pr_ref") || exit 1

    # Get repo info
    local repo_info
    repo_info=$(get_repo_info) || exit 1
    local owner repo
    owner=$(get_owner "$repo_info")
    repo=$(get_repo "$repo_info")

    local query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      number
      title
      headRefName
    }
  }
}'

    local result
    result=$(gh_graphql "$query" -F owner="$owner" -F repo="$repo" -F pr="$pr_num") || exit 1

    # Files, PR-level comments, review threads and each thread's comments are
    # every one paged to completeness: a caller reads this output as the whole
    # PR, so a file, comment or reply on a later page must not go missing.
    local files_query='
query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      files(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { path }
      }
    }
  }
}'
    local files
    files=$(gh_graphql_connection "$files_query" '.repository.pullRequest.files' 'PR file' '' \
        -F owner="$owner" -F repo="$repo" -F pr="$pr_num") || exit 1

    local comments_query='
query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      comments(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          author { login }
          body
          url
          createdAt
        }
      }
    }
  }
}'
    local comments
    comments=$(gh_graphql_connection "$comments_query" '.repository.pullRequest.comments' 'PR comment' '' \
        -F owner="$owner" -F repo="$repo" -F pr="$pr_num") || exit 1

    local threads
    threads=$(gh_graphql_threads "$owner" "$repo" "$pr_num" '
                          id
                          isResolved
                          isOutdated
                          path
                          line
                          comments(first: 10) {
                            pageInfo { hasNextPage endCursor }
                            nodes { author { login } body url }
                          }') || exit 1

    # A thread's first comment page arrives with the thread; one that says
    # more follow is walked on from its cursor.
    if ! jq -e 'all(.[];
            (.comments | type) == "object"
            and (.comments.nodes | type) == "array"
            and (.comments.pageInfo.hasNextPage | type) == "boolean"
            and ((.comments.pageInfo.hasNextPage | not)
                 or (((.comments.pageInfo.endCursor | type) == "string")
                     and ((.comments.pageInfo.endCursor | length) > 0))))
        ' >/dev/null 2>&1 <<<"$threads"; then
        github_error 'GitHub returned malformed review thread comment pagination data'
        exit 1
    fi
    local thread_comments_query='
query($id: ID!, $cursor: String) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { author { login } body url }
      }
    }
  }
}'
    local pending idx thread_id start_cursor rest
    pending=$(jq -r 'to_entries[]
        | select(.value.comments.pageInfo.hasNextPage)
        | "\(.key)\t\(.value.id)\t\(.value.comments.pageInfo.endCursor)"' <<<"$threads") || exit 1
    while IFS=$'\t' read -r idx thread_id start_cursor; do
        [ -n "$idx" ] || continue
        rest=$(gh_graphql_connection "$thread_comments_query" '.node.comments' 'review thread comment' \
            "$start_cursor" -F id="$thread_id") || exit 1
        threads=$(printf '%s\n%s\n' "$threads" "$rest" | jq -sc --argjson i "$idx" \
            '.[0][$i].comments.nodes += .[1] | .[0]') || exit 1
    done <<<"$pending"
    threads=$(jq -c 'map(.comments = {nodes: .comments.nodes})' <<<"$threads") || exit 1

    # The merged nodes are grafted onto the shape callers walk.
    result=$(printf '%s\n%s\n%s\n%s\n' "$result" "$files" "$comments" "$threads" | jq -sc '
        .[0].repository.pullRequest.files = {nodes: .[1]}
        | .[0].repository.pullRequest.comments = {nodes: .[2]}
        | .[0].repository.pullRequest.reviewThreads = {
            nodes: .[3],
            pageInfo: {hasNextPage: false, endCursor: null}
        }
        | .[0]') || exit 1

    # Apply format
    local output
    case "$FORMAT" in
        raw)
            output="$result"
            ;;
        safe)
            output=$(echo "$result" | jq '{
                number: .repository.pullRequest.number,
                title: (.repository.pullRequest.title // ""),
                branch: (.repository.pullRequest.headRefName // ""),
                files: [.repository.pullRequest.files.nodes[].path],
                threads: [.repository.pullRequest.reviewThreads.nodes[] | {
                    id: .id,
                    is_resolved: .isResolved,
                    is_outdated: .isOutdated,
                    path: (.path // ""),
                    line: (.line // null),
                    source: "inline",
                    comments: [.comments.nodes[] | {
                        author: (.author.login // ""),
                        body: (.body // ""),
                        url: (.url // ""),
                        # Extract numeric ID from URL for post-reply
                        reply_id: ((.url // "") | capture("r(?<id>[0-9]+)$") | .id // null)
                    }]
                }],
                comments: [.repository.pullRequest.comments.nodes[] | {
                    id: .id,
                    author: (.author.login // ""),
                    body: (.body // ""),
                    url: (.url // ""),
                    created_at: (.createdAt // ""),
                    source: "pr-level"
                }]
            }')
            ;;
    esac

    # Apply actionable filter (unresolved non-outdated threads, no bot comments).
    if [ "$actionable" = "true" ] && [ "$FORMAT" != "raw" ]; then
        output=$(echo "$output" | jq --arg bot_user "${GH_BOT_USERNAME:-review-bot[bot]}" '{
            number,
            title,
            branch,
            files,
            threads: [.threads[] | select(.is_resolved == false and .is_outdated == false) | {
                id, path, line, source,
                comments: [.comments[] | select(.author | IN("github-actions", "github-actions[bot]", "dependabot", "dependabot[bot]", "codecov", "codecov[bot]", $bot_user) | not)]
            } | select(.comments | length > 0)],
            comments: [.comments[] | select(.author | IN("github-actions", "github-actions[bot]", "dependabot", "dependabot[bot]", "codecov", "codecov[bot]", $bot_user) | not)]
        }')
    fi

    echo "$output"
}

# Main
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

get_pr_data "$@"
