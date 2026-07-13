#!/bin/bash
# GitHub API - Reply to a review thread or comment
# Usage: post-reply.sh <thread-id|comment-id> <body> [--pr <N>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/github-api.sh"
# shellcheck source=../lib/pr-branch.sh
source "$SCRIPT_DIR/../lib/pr-branch.sh"

show_help() {
    cat << 'EOF'
Reply to Review Thread or Comment

Usage: post-reply.sh <id> [body | --body-file PATH] [options]

Arguments:
  id            Thread ID (PRRT_...) or numeric comment ID
  body          Reply text (inline; unsafe for Markdown with backticks)

Options:
  --body-file PATH  Read reply body from a file (preferred for Markdown).
  --pr <N>          PR number (required for numeric comment ID, ignored for thread ID)
  --dry-run         Show what would be posted without executing

Output:
{
  "success": true,
  "url": "https://github.com/.../discussion_r..."
}

Examples:
  # Plain reply — safe inline
  post-reply.sh PRRT_kwDOQchwXs5n... "Thanks, fixed!"

  # Markdown reply — use --body-file
  post-reply.sh PRRT_kwDOQchwXs5n... --body-file tmp/reply.md

  # Reply to a comment by numeric ID (legacy - uses REST)
  post-reply.sh 2633519824 "Fixed!" --pr 23

  # Dry run
  post-reply.sh PRRT_kwDOQchwXs5n... "Fixed!" --dry-run
EOF
}

# Reply using GraphQL (for thread IDs)
reply_via_graphql() {
    local thread_id="$1"
    local body="$2"

    local query='mutation($threadId: ID!, $body: String!) {
        addPullRequestReviewThreadReply(input: {
            pullRequestReviewThreadId: $threadId
            body: $body
        }) {
            comment {
                id
                url
            }
        }
    }'

    local result
    result=$(gh_graphql "$query" -F threadId="$thread_id" -F body="$body") || return 1

    local url
    url=$(echo "$result" | jq -r '.addPullRequestReviewThreadReply.comment.url // ""')

    if [ -n "$url" ]; then
        echo "{\"success\": true, \"url\": \"$url\"}"
    else
        echo '{"success": true, "url": null}'
    fi
}

# Reply using REST API (for numeric comment IDs)
reply_via_rest() {
    local comment_id="$1"
    local body="$2"
    local pr_num="$3"
    local owner="$4"
    local repo="$5"

    local result
    result=$(gh_rest "repos/$owner/$repo/pulls/$pr_num/comments/$comment_id/replies" \
        -f body="$body") || return 1

    local url
    url=$(echo "$result" | jq -r '.html_url // .url // ""')

    if [ -n "$url" ]; then
        echo "{\"success\": true, \"url\": \"$url\"}"
    else
        echo '{"success": true, "url": null}'
    fi
}

post_reply() {
    local id=""
    local body=""
    local body_file=""
    local body_set=false body_file_set=false
    local id_set=false
    local pr_ref=""
    local dry_run="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --pr)
                pr_ref="$2"
                shift 2
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
                if [ "$id_set" = false ]; then
                    id="$1"; id_set=true
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

    if [ -z "$id" ]; then
        echo '{"error": "Thread/comment ID required"}' >&2
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
        echo '{"error": "Reply body required (positional, --body, or --body-file)"}' >&2
        exit 1
    fi

    # Detect ID type: thread ID starts with PRRT_, numeric is comment ID
    local is_thread_id="false"
    if [[ "$id" == PRRT_* ]]; then
        is_thread_id="true"
    fi

    # Numeric comment IDs use the legacy REST reply path, which requires an
    # explicit target PR. Auto-resolving from the current branch
    # (resolve_pr_number "" -> get_current_pr) silently picked a PR and hit a
    # REST path that collided with the bot's pending review, surfacing an opaque
    # "one pending review per pull request" API error. Fail locally with a clear
    # usage error before any API call, in both --dry-run and real modes. Thread
    # IDs (PRRT_...) do not need --pr and keep their existing behavior.
    if [ "$is_thread_id" = "false" ] && [ -z "$pr_ref" ]; then
        echo '{"error": "Numeric comment ID requires --pr <N> (PRRT_... thread IDs do not). See post-reply --help."}' >&2
        exit 1
    fi

    # Dry run
    if [ "$dry_run" = "true" ]; then
        if [ "$is_thread_id" = "true" ]; then
            echo "{\"dry_run\": true, \"method\": \"graphql\", \"thread_id\": \"$id\", \"body\": $(echo "$body" | jq -Rs .)}"
        else
            local pr_num
            pr_num=$(resolve_pr_number "$pr_ref") || exit 1
            echo "{\"dry_run\": true, \"method\": \"rest\", \"pr\": $pr_num, \"comment_id\": \"$id\", \"body\": $(echo "$body" | jq -Rs .)}"
        fi
        exit 0
    fi

    # Execute based on ID type
    if [ "$is_thread_id" = "true" ]; then
        # GraphQL for thread IDs
        local reply_result reply_url
        reply_result=$(reply_via_graphql "$id" "$body") || return 1
        reply_url=$(echo "$reply_result" | jq -r '.url // ""' 2>/dev/null || true)
        bash "$SCRIPT_DIR/../_activity-emit.sh" pr.comments_left \
            --severity info \
            --importance normal \
            --summary "Reply left on PR review thread" \
            --details-json "$(jq -cn --arg url "$reply_url" --arg thread_id "$id" '{url: $url, thread_id: $thread_id}')" || true
        # Thread-id GraphQL path has no PR number in scope — skip branch lookup.
        echo "$reply_result"
    else
        # REST for numeric comment IDs
        local pr_num
        pr_num=$(resolve_pr_number "$pr_ref") || exit 1

        local repo_info
        repo_info=$(get_repo_info) || exit 1
        local owner repo
        owner=$(get_owner "$repo_info")
        repo=$(get_repo "$repo_info")

        local reply_result reply_url
        reply_result=$(reply_via_rest "$id" "$body" "$pr_num" "$owner" "$repo") || return 1
        reply_url=$(echo "$reply_result" | jq -r '.url // ""' 2>/dev/null || true)
        local pr_branch
        pr_branch=$(pr_branch_name "$pr_num")
        local emit_args=(
            --severity info
            --importance normal
            --summary "Reply left on PR #$pr_num"
            --pr-number "$pr_num"
            --details-json "$(jq -cn --arg url "$reply_url" --arg comment_id "$id" '{url: $url, comment_id: $comment_id}')"
        )
        [ -n "$pr_branch" ] && emit_args+=(--branch "$pr_branch")
        bash "$SCRIPT_DIR/../_activity-emit.sh" pr.comments_left "${emit_args[@]}" || true
        echo "$reply_result"
    fi
}

# Main
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

post_reply "$@"
