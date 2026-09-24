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

Reaches both comment kinds: a PR-level comment (#issuecomment-<ID>) and a
comment inside a review thread (#discussion_r<ID>). The issue-comments
endpoint is asked first; a 404 there sends the id to the review-comments
endpoint, and any other failure is reported as that endpoint gave it.

A 404 from both endpoints is refused with one keyed line, never a bare 404:

  github: comment-kind=unknown id=<ID> use=find-comment|comment-url
    (both endpoints answered 404 for <owner>/<repo>: no such comment, or
     the token cannot see the repository)

Every refusal is one JSON shape on stderr, {error, detail}: `detail` is one
entry per endpoint asked, carrying that endpoint and gh's own text, so no
response is lost behind the message.

Note: a PR-level comment ID comes from find-comment. A review-thread comment
ID comes from its comment URL, the number after #discussion_r; pr-threads
returns PRRT_ thread IDs, which post-reply takes and this command does not.
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

    # A comment id carries no marker of which endpoint owns it. A PR-level
    # comment is an ISSUE comment; a comment inside a review thread is a REVIEW
    # comment and lives under `pulls/comments`. Each endpoint answers 404 for
    # the other's ids, so a 404 is the signal to ask the next endpoint rather
    # than a verdict on the id. Every other failure is that endpoint's own
    # answer about an id it owns, and is reported instead of retried.
    local kind path result status=0 attempts='[]'
    for kind in issues pulls; do
        status=0
        path="repos/$owner/$repo/$kind/comments/$comment_id"
        result=$(gh api -X PATCH "$path" -f body="$body" 2>&1) || status=$?
        if [ "$status" -eq 0 ]; then
            break
        fi
        attempts=$(jq -c --arg endpoint "$kind" --arg response "$result" \
            '. + [{endpoint: $endpoint, response: $response}]' <<<"$attempts")
        if ! gh_error_is_not_found "$result"; then
            break
        fi
    done

    if [ "$status" -ne 0 ]; then
        # A 404 from both endpoints does not say the comment is absent: GitHub
        # answers 404 for a resource the token cannot see and for a repository
        # that is not the one the caller meant. The refusal names what the two
        # answers prove, hands back both responses, and names where each kind
        # of id is read, because a bare 404 sent the caller back to guessing.
        if gh_error_is_not_found "$result"; then
            jq -nc --arg id "$comment_id" --arg slug "$owner/$repo" \
                --argjson attempts "$attempts" \
                '{error: ("github: comment-kind=unknown id=" + $id
                    + " use=find-comment|comment-url (both endpoints answered 404 for "
                    + $slug + ": no such comment, or the token cannot see the repository)"),
                  detail: $attempts}' >&2
            exit 1
        fi
        # Every refusal is one shape, {error, detail}: the endpoint that gave
        # this answer is named in the message, and every response collected on
        # the way here is in detail, so a 404 at the first endpoint is not lost
        # when the second fails some other way.
        jq -nc --arg path "$path" --arg detail "$result" --argjson attempts "$attempts" \
            '{error: ("Failed to edit comment at " + $path + ": " + $detail),
              detail: $attempts}' >&2
        exit 1
    fi

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
