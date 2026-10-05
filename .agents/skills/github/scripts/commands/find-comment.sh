#!/bin/bash
# GitHub API - Find a PR comment by pattern and author
# Usage: find-comment.sh <PR-number> --pattern <regex> [--author <login> | --self]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
Find PR Comment

Usage: find-comment.sh <PR-number> [--pattern <regex>] [--review-summary] [--author <login> | --self]

Arguments:
  PR-number          PR number (required)

Options:
  --pattern <regex>  Regex pattern to match in comment body
  --review-summary   Pick the most representative review-summary comment
                     ("View job" sticky → review-section comment → first
                     comment by author). Mutually exclusive with --pattern;
                     usually combined with --author.
  --author <login>   Filter by author login
  --self             Filter to comments by the identity the selected token
                     acts as, matched by account id: a person for a user
                     token, the app's bot account for a GitHub App
                     installation token. Mutually exclusive with --author.

Exactly one of --pattern or --review-summary is required. Every page of the
PR's comments is read. An unreadable comment list or identity is an error,
never an empty result.

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
  # Summary comment this token's identity posted
  find-comment.sh 23 --pattern "Recommendations.*Processed" --self

  # Pull a review bot's summary (no pattern needed)
  find-comment.sh 23 --author "review-bot[bot]" --review-summary
EOF
}

find_comment() {
    local pr_num=""
    local pattern=""
    local author=""
    local review_summary="false"
    local self="false"

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
            --self)
                self="true"
                shift
                ;;
            *)
                if [ -z "$pr_num" ]; then
                    pr_num="$1"
                else
                    github_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [ -z "$pr_num" ]; then
        github_error 'PR number required'
        exit 1
    fi

    if [ -z "$pattern" ] && [ "$review_summary" != "true" ]; then
        github_error '--pattern or --review-summary required'
        exit 1
    fi
    if [ -n "$pattern" ] && [ "$review_summary" = "true" ]; then
        github_error '--pattern and --review-summary are mutually exclusive'
        exit 1
    fi
    if [ -n "$author" ] && [ "$self" = "true" ]; then
        github_error '--author and --self are mutually exclusive'
        exit 1
    fi

    # Get repo info
    local repo_info
    repo_info=$(get_repo_info) || exit 1
    local owner repo
    owner=$(get_owner "$repo_info")
    repo=$(get_repo "$repo_info")

    # Every page: the first page alone is the oldest comments, so a busy PR's
    # latest match would read as no match, or as an older one.
    local comments
    comments=$(gh_rest_all "repos/$owner/$repo/issues/$pr_num/comments?per_page=100") || exit 1

    # Matched by account id: GitHub's REST and GraphQL readers spell an app's
    # login with and without its [bot] suffix.
    if [ "$self" = "true" ]; then
        local viewer viewer_id
        viewer=$(gh_viewer) || exit 1
        viewer_id=$(jq -er '.databaseId | numbers | select(. > 0 and . == floor)' <<<"$viewer" 2>/dev/null) || {
            github_error 'Viewer identity read named no account id'
            exit 1
        }
        comments=$(jq -c --argjson id "$viewer_id" '[.[] | select(.user.id == $id)]' <<<"$comments")
    fi

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
# interpolating them builds a separate program, so a `"` or a regex escape such as
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
