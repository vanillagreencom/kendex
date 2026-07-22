#!/bin/bash
# GitHub API - Get PR review threads
# Usage: pr-threads.sh [PR-number] [--unresolved] [--format=safe|raw]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
Get PR Review Threads

Usage: pr-threads.sh [PR-number|branch] [options]

Arguments:
  PR-number|branch    PR number or branch name (default: current branch's PR)

Options:
  --unresolved        Only show unresolved threads
  --resolved          Only show resolved threads
  --format=safe       Normalized structure with count (DEFAULT)
  --format=raw        Original GitHub API structure

Output (safe format):
{
  "count": 3,
  "unresolved_count": 2,
  "threads": [{
    "id": "PRRT_...",
    "is_resolved": false,
    "is_outdated": false,
    "path": "src/file.rs",
    "line": 42,
    "author": "reviewer",
    "body": "First comment text"
  }]
}

Examples:
  pr-threads.sh 23
  pr-threads.sh 23 --unresolved
  pr-threads.sh --format=raw
EOF
}

get_pr_threads() {
    local pr_ref=""
    local filter_unresolved="false"
    local filter_resolved="false"
    FORMAT="${DEFAULT_FORMAT}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --unresolved)
                filter_unresolved="true"
                shift
                ;;
            --resolved)
                filter_resolved="true"
                shift
                ;;
            --format=*)
                FORMAT="${1#--format=}"
                shift
                ;;
            --format)
                FORMAT="$2"
                shift 2
                ;;
            *)
                pr_ref="$1"
                shift
                ;;
        esac
    done

    # Resolve PR number
    local pr_num
    pr_num=$(resolve_pr_number "$pr_ref") || exit 1

    # Get repo info
    local repo_info
    repo_info=$(get_repo_info) || exit 1
    local owner repo
    owner=$(get_owner "$repo_info")
    repo=$(get_repo "$repo_info")

    # GitHub caps one reviewThreads connection page at 100 nodes. Fetch every
    # page before emitting anything so merge callers cannot mistake a partial
    # result for a clean review state.
    local initial_query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 1) {
            nodes {
              author { login }
              body
            }
          }
        }
      }
    }
  }
}'

    local page_query='
query($owner: String!, $repo: String!, $number: Int!, $cursor: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 1) {
            nodes {
              author { login }
              body
            }
          }
        }
      }
    }
  }
}'

    local all_nodes='[]'
    local cursor="" page_count=0
    while :; do
        page_count=$((page_count + 1))
        if [ "$page_count" -gt 1000 ]; then
            echo '{"error": "Review thread pagination exceeded safety limit"}' >&2
            exit 1
        fi

        local page_result
        if [ -z "$cursor" ]; then
            page_result=$(gh_graphql "$initial_query" -F owner="$owner" -F repo="$repo" -F number="$pr_num") || exit 1
        else
            page_result=$(gh_graphql "$page_query" -F owner="$owner" -F repo="$repo" -F number="$pr_num" -F cursor="$cursor") || exit 1
        fi

        # Fail closed on a missing PR, malformed nodes, or a next-page flag
        # without a usable cursor. No partial list is printed on failure.
        if ! jq -e '
            .repository.pullRequest.reviewThreads as $threads |
            ($threads | type == "object") and
            ($threads.nodes | type == "array") and
            ($threads.pageInfo.hasNextPage | type == "boolean") and
            (($threads.pageInfo.hasNextPage == false) or
             (($threads.pageInfo.endCursor | type) == "string" and
              ($threads.pageInfo.endCursor | length) > 0))
        ' >/dev/null 2>&1 <<<"$page_result"; then
            echo '{"error": "GitHub returned malformed review thread pagination data"}' >&2
            exit 1
        fi

        local page_nodes has_next next_cursor
        page_nodes=$(jq -c '.repository.pullRequest.reviewThreads.nodes' <<<"$page_result") || exit 1
        # Keep review bodies out of exec arguments: a handful of maximum-size
        # comments can exceed macOS ARG_MAX even though the API response is
        # valid. Two compact JSON values on stdin let jq merge without an OS
        # argument-size ceiling.
        all_nodes=$(printf '%s\n%s\n' "$all_nodes" "$page_nodes" | jq -sc '.[0] + .[1]') || exit 1
        has_next=$(jq -r '.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$page_result") || exit 1

        if [ "$has_next" = "false" ]; then
            break
        fi

        next_cursor=$(jq -r '.repository.pullRequest.reviewThreads.pageInfo.endCursor' <<<"$page_result") || exit 1
        if [ "$next_cursor" = "$cursor" ]; then
            echo '{"error": "GitHub review thread pagination cursor did not advance"}' >&2
            exit 1
        fi
        cursor="$next_cursor"
    done

    local result
    # The complete multi-page result can be larger still; wrap stdin rather
    # than copying it into jq's argv.
    result=$(printf '%s\n' "$all_nodes" | jq -c '{
        repository: {
            pullRequest: {
                reviewThreads: {
                    nodes: .,
                    pageInfo: {hasNextPage: false, endCursor: null}
                }
            }
        }
    }') || exit 1

    # Apply format and filters
    case "$FORMAT" in
        raw)
            echo "$result"
            ;;
        safe|*)
            local jq_filter
            if [ "$filter_unresolved" = "true" ]; then
                jq_filter='select(.isResolved == false)'
            elif [ "$filter_resolved" = "true" ]; then
                jq_filter='select(.isResolved == true)'
            else
                jq_filter='.'
            fi

            echo "$result" | jq --arg filter "$jq_filter" '{
                count: ([.repository.pullRequest.reviewThreads.nodes[] | '"$jq_filter"'] | length),
                unresolved_count: ([.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length),
                threads: [.repository.pullRequest.reviewThreads.nodes[] | '"$jq_filter"' | {
                    id: .id,
                    is_resolved: .isResolved,
                    is_outdated: .isOutdated,
                    path: (.path // ""),
                    line: (.line // null),
                    author: (.comments.nodes[0].author.login // ""),
                    body: (.comments.nodes[0].body // "")
                }]
            }'
            ;;
    esac
}

# Main
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

get_pr_threads "$@"
