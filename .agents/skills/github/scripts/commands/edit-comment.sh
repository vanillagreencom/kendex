#!/bin/bash
# GitHub API - Edit an existing PR comment
# Usage: edit-comment.sh <comment-id> <body>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
Edit PR Comment

Usage: edit-comment.sh <comment-id> [body | --body-file PATH]

Arguments:
  comment-id   Numeric comment ID (from find-comment or URL)
  body         New comment text (inline; unsafe for Markdown with backticks)

Options:
  --body-file PATH  Read new body from a file (preferred for Markdown
                    with backticks, code fences, or shell metachars).
  --dry-run         Show what would be edited without executing

Output:
{
  "success": true,
  "url": "https://github.com/..."
}

Examples:
  # Plain string — safe inline
  edit-comment.sh 12345678 "Updated content"

  # Markdown — use --body-file
  edit-comment.sh 12345678 --body-file tmp/edit.md

  # Dry run
  edit-comment.sh 12345678 "New text" --dry-run

Note: Get comment ID from find-comment or from GitHub URL (#issuecomment-<ID>)
EOF
}

edit_comment() {
    local comment_id=""
    local body=""
    local body_file=""
    local body_set=false body_file_set=false
    local comment_id_set=false
    local dry_run="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --body)
                body="$2"; body_set=true; shift 2
                ;;
            --body-file)
                body_file="$2"; body_file_set=true; shift 2
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            *)
                if [ "$comment_id_set" = false ]; then
                    comment_id="$1"; comment_id_set=true
                elif [ "$body_set" = false ]; then
                    body="$1"; body_set=true
                else
                    echo "{\"error\": \"Unexpected argument: $1\"}" >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [ -z "$comment_id" ]; then
        echo '{"error": "Comment ID required"}' >&2
        exit 1
    fi

    if [ "$body_set" = true ] && [ "$body_file_set" = true ]; then
        echo '{"error": "--body and --body-file are mutually exclusive"}' >&2
        exit 1
    fi
    if [ "$body_file_set" = true ]; then
        if [ -z "$body_file" ]; then
            echo '{"error": "--body-file requires a non-empty path argument"}' >&2
            exit 1
        fi
        if [ ! -r "$body_file" ]; then
            echo "{\"error\": \"--body-file path not readable: $body_file\"}" >&2
            exit 1
        fi
        body=$(cat -- "$body_file")
    fi

    if [ -z "$body" ]; then
        echo '{"error": "Comment body required (positional, --body, or --body-file)"}' >&2
        exit 1
    fi

    # Validate comment ID is numeric
    if ! [[ "$comment_id" =~ ^[0-9]+$ ]]; then
        echo "{\"error\": \"Comment ID must be numeric: $comment_id\"}" >&2
        exit 1
    fi

    # Get repo info
    local repo_info
    repo_info=$(get_repo_info) || exit 1
    local owner repo
    owner=$(get_owner "$repo_info")
    repo=$(get_repo "$repo_info")

    # Dry run
    if [ "$dry_run" = "true" ]; then
        echo "{\"dry_run\": true, \"comment_id\": $comment_id, \"body_preview\": $(echo "$body" | head -c 100 | jq -Rs .)}"
        exit 0
    fi

    # Edit comment via REST API
    local result
    result=$(gh api -X PATCH "repos/$owner/$repo/issues/comments/$comment_id" \
        -f body="$body" 2>&1) || {
        jq -nc --arg detail "$result" '{error: ("Failed to edit comment: " + $detail)}' >&2
        exit 1
    }

    # Extract URL from response
    local url
    url=$(echo "$result" | jq -r '.html_url // .url // ""')

    jq -nc --arg url "$url" '{success: true, url: (if $url == "" then null else $url end)}'
}

# Main
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

edit_comment "$@"
