#!/bin/bash
# GitHub API - Post a PR-level comment
# Usage: post-comment.sh <PR-number> <body>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
Post PR-Level Comment

Usage: post-comment.sh <PR-number> [body | --body-file PATH]

Arguments:
  PR-number    PR number (or branch name, or empty for current branch)
  body         Comment text (inline; unsafe for Markdown with backticks)

Options:
  --body-file PATH  Read body from a file (preferred for any Markdown
                    with backticks, code fences, or shell metachars).
  --dry-run         Show what would be posted without executing

Output:
{
  "success": true,
  "url": "https://github.com/.../issuecomment-..."
}

Examples:
  # Plain string only — safe inline
  post-comment.sh 23 "Addressed all feedback"

  # Markdown with backticks/code — use --body-file
  cat > tmp/comment.md <<'EOF'
  ## Summary
  - Fixed `WindowKind` enum.
  EOF
  post-comment.sh 23 --body-file tmp/comment.md

  # Current branch's PR
  post-comment.sh "" "Changes pushed"

  # Dry run
  post-comment.sh 23 "Comment text" --dry-run

Note: PR-level comments appear in the Conversation tab, not as review thread replies.
EOF
}

post_comment() {
    local pr_ref=""
    local body=""
    local body_file=""
    local body_set=false body_file_set=false
    local pr_ref_set=false
    local dry_run="false"

    # Parse arguments. Positional body is kept for backward compatibility,
    # but new orch callers should use --body-file.
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
                if [ "$pr_ref_set" = false ]; then
                    pr_ref="$1"; pr_ref_set=true
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

    # Resolve body source: --body-file wins when set, else positional/--body.
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

    # Resolve PR number
    local pr_num
    pr_num=$(resolve_pr_number "$pr_ref") || exit 1

    # Get repo info
    local repo_info
    repo_info=$(get_repo_info) || exit 1
    local owner repo
    owner=$(get_owner "$repo_info")
    repo=$(get_repo "$repo_info")

    # Dry run
    if [ "$dry_run" = "true" ]; then
        echo "{\"dry_run\": true, \"pr\": $pr_num, \"body\": $(echo "$body" | jq -Rs .)}"
        exit 0
    fi

    # Post comment via REST API (issues endpoint works for PRs)
    local result
    result=$(gh_rest "repos/$owner/$repo/issues/$pr_num/comments" \
        -f body="$body") || exit 1

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

post_comment "$@"
