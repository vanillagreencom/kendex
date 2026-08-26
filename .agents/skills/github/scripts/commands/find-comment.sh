#!/bin/bash
# GitHub API - Find a PR comment by pattern and author
# Usage: find-comment.sh <PR-number> --pattern <regex> [--author <login>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
Find PR Comment

Usage: find-comment.sh <PR-number> [--pattern <regex>] [--review-summary] [--author <login>]

Arguments:
  PR-number          PR number (required)

Options:
  --pattern <regex>  Regex pattern to match in comment body
  --review-summary   Pick the most representative review-summary comment
                     ("View job" sticky → review-section comment → first
                     comment by author). Mutually exclusive with --pattern;
                     usually combined with --author.
  --author <login>   Filter by author login

Exactly one of --pattern or --review-summary is required.

Output:
{
  "id": 12345678,
  "author": "username",
  "body": "comment text...",
  "created_at": "2025-01-01T00:00:00Z",
  "updated_at": "2025-01-01T00:00:00Z",
  "url": "https://github.com/..."
}

Returns last matching comment for --pattern (or the picked one for
--review-summary). Empty object {} if no match.

Examples:
  # Summary comment by current user
  find-comment.sh 23 --pattern "Recommendations.*Processed" --author "\$(gh api user -q .login)"

  # Pull a review bot's summary (no pattern needed)
  find-comment.sh 23 --author "review-bot[bot]" --review-summary
EOF
}

find_comment() {
    local pr_num=""
    local pattern=""
    local author=""
    local review_summary="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --pattern)
                pattern="$2"
                shift 2
                ;;
            --pattern=*)
                pattern="${1#--pattern=}"
                shift
                ;;
            --author)
                author="$2"
                shift 2
                ;;
            --author=*)
                author="${1#--author=}"
                shift
                ;;
            --review-summary)
                review_summary="true"
                shift
                ;;
            *)
                if [ -z "$pr_num" ]; then
                    pr_num="$1"
                else
                    echo "{\"error\": \"Unexpected argument: $1\"}" >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [ -z "$pr_num" ]; then
        echo '{"error": "PR number required"}' >&2
        exit 1
    fi

    if [ -z "$pattern" ] && [ "$review_summary" != "true" ]; then
        echo '{"error": "--pattern or --review-summary required"}' >&2
        exit 1
    fi
    if [ -n "$pattern" ] && [ "$review_summary" = "true" ]; then
        echo '{"error": "--pattern and --review-summary are mutually exclusive"}' >&2
        exit 1
    fi

    # Get repo info
    local repo_info
    repo_info=$(get_repo_info) || exit 1
    local owner repo
    owner=$(get_owner "$repo_info")
    repo=$(get_repo "$repo_info")

    # Fetch comments
    local comments
    comments=$(gh_rest "repos/$owner/$repo/issues/$pr_num/comments") || exit 1

    if [ "$review_summary" = "true" ]; then
        # Selection priority lives in github-api.sh so sticky-comment and
        # find-comment stay aligned as review bot formats evolve:
        #   1. Sticky bearing the "View job" / "Claude finished" marker
        #   2. Comment with a shared review-signal marker
        #   3. The author's earliest comment (Codex-style submission comment)
        # Returns {} if no comment by author exists.
        local summary
        summary=$(select_review_summary_comment_from_comments "$comments" "$author" false true)
        if [[ -z "$summary" || "$summary" == "null" ]]; then
            echo '{}'
        else
            echo "$summary" | jq -c '{id: .id, author: .user.login, body: .body, created_at: .created_at, updated_at: .updated_at, url: .html_url}'
        fi
        return
    fi

    # Author and pattern cross the boundary as jq values, never as program text:
    # interpolating them builds a new program, so a `"` or a regex escape such as
    # `5\.00` is a jq syntax error rather than a match.
    jq -c --arg author "$author" --arg pattern "$pattern" '
        [ .[]
          | select($author == "" or (.user.login // "") == $author)
          | select((.body // "") | test($pattern))
        ]
        | last
        | if . then {id, author: .user.login, body, created_at, updated_at, url: .html_url} else {} end
    ' <<<"$comments"
}

# Main
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

find_comment "$@"
