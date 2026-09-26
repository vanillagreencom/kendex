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
    "author_type": "User",
    "body": "First comment text",
    "comment_count": 2,
    "comments": [{"author": "reviewer", "author_type": "User", "body": "..."}]
  }]
}

author, author_type and body describe the first comment. author_type is
GitHub's actor type: Bot for an app such as Copilot's reviewer, whose login
carries no [bot] suffix here, User for a person, and empty where GitHub names
no author. comments holds the thread's first 100 comments in order, each
typed the same way, and comment_count is the thread's whole count, so a
caller can tell a thread it read in full from one it did not.

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
                if [ -z "${2:-}" ]; then
                    github_error '--format requires an argument (safe or raw)'
                    exit 1
                fi
                FORMAT="$2"
                shift 2
                ;;
            -*)
# Unknown flags must not fall through to the positional branch and
                # be resolved as a PR ref, turning a typo into a confusing
                # "No PR found for: --typo".
                github_error "Unknown option: $1"
                exit 1
                ;;
            *)
                if [ -n "$pr_ref" ]; then
                    github_error "Unexpected argument: $1"
                    exit 1
                fi
                pr_ref="$1"
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
    local owner repo threads
    owner=$(get_owner "$repo_info")
    repo=$(get_repo "$repo_info")

    threads=$(gh_graphql_threads "$owner" "$repo" "$pr_num" '
                          id
                          isResolved
                          isOutdated
                          path
                          line
                          comments(first: 100) { totalCount nodes { author { login __typename } body } }') || exit 1

    local result
    # The complete multi-page result can be large; wrap stdin rather than
    # copying it into jq's argv.
    result=$(printf '%s\n' "$threads" | jq -c '{
        repository: {
            pullRequest: {
                reviewThreads: {
                    nodes: .,
                    pageInfo: {hasNextPage: false, endCursor: null}
                }
            }
        }
    }') || exit 1

    # Resolution filter is format-independent: a filter that applied to one
    # output shape only would report resolved threads as still outstanding.
    local jq_filter
    if [ "$filter_unresolved" = "true" ]; then
        jq_filter='select(.isResolved == false)'
    elif [ "$filter_resolved" = "true" ]; then
        jq_filter='select(.isResolved == true)'
    else
        jq_filter='.'
    fi

    # Apply format and filters
    case "$FORMAT" in
        raw)
            if [ "$filter_unresolved" = "true" ] || [ "$filter_resolved" = "true" ]; then
                # Filter the thread nodes in place. Raw callers walk the GitHub
                # response shape, and it carries no count field to keep in sync.
                echo "$result" | jq -c '
                    .repository.pullRequest.reviewThreads.nodes |= [.[] | '"$jq_filter"']
                '
            else
                echo "$result"
            fi
            ;;
        safe)
            echo "$result" | jq '{
                count: ([.repository.pullRequest.reviewThreads.nodes[] | '"$jq_filter"'] | length),
                unresolved_count: ([.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length),
                threads: [.repository.pullRequest.reviewThreads.nodes[] | '"$jq_filter"' | {
                    id: .id,
                    is_resolved: .isResolved,
                    is_outdated: .isOutdated,
                    path: (.path // ""),
                    line: (.line // null),
                    author: (.comments.nodes[0].author.login // ""),
                    author_type: (.comments.nodes[0].author.__typename // ""),
                    body: (.comments.nodes[0].body // ""),
                    comment_count: (.comments.totalCount // null),
                    comments: [(.comments.nodes // [])[] | {
                        author: (.author.login // ""),
                        author_type: (.author.__typename // ""),
                        body: (.body // "")
                    }]
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
