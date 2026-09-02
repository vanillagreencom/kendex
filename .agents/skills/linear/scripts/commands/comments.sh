#!/bin/bash
# Linear GraphQL API - Comment Operations
# Usage: comments.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    cat << 'EOF'
Comment Operations

Usage: comments.sh <action> [options]

Actions:
  list    List comments on an issue
  create  Create a new comment
  update  Update an existing comment
  delete  Delete a comment

List:
  comments.sh list <issue-id>

Create Options:
  --body <text>         Comment body (required unless --body-file or --attach is set)
  --body-file <path>    Read comment body from file (preferred for markdown)
  --parent <id>         Parent comment ID for replies
  --attach <path>       Upload a file to Linear and reference it in the body
                        (repeatable). Images embed as ![name](assetUrl); other
                        files append a [name](assetUrl) markdown link. Composes
                        with --body/--body-file; missing/unreadable paths
                        refuse before any API call.

Update Options:
  --body <text>         New comment body (required unless --body-file is set)
  --body-file <path>    Read new comment body from file

Examples:
  comments.sh list PROJ-42
  comments.sh create PROJ-42 --body "Starting work on this task"
  comments.sh create PROJ-42 --body-file tmp/comment.md
  comments.sh create PROJ-42 --body "See capture" --attach tmp/screenshot.png
  comments.sh update <comment-id> --body "Updated comment text"
  comments.sh delete <comment-id>
EOF
}
case "${1:-help}" in help|--help|-h) show_help; exit 0 ;; esac

source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/cache.sh"
source "$SCRIPT_DIR/../lib/attachments.sh"

read_body_file() {
    local body_file="$1"
    if [[ -z "$body_file" ]]; then
        echo '{"error": "--body-file requires a non-empty path argument"}' >&2
        return 1
    fi
    if [[ ! -r "$body_file" ]]; then
        echo "{\"error\": \"--body-file path not readable: $body_file\"}" >&2
        return 1
    fi
    body=$(<"$body_file")
}

list_comments() {
    local issue_id=""
    FORMAT="${DEFAULT_FORMAT}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) FORMAT="$2"; shift 2 ;;
            --format=*) FORMAT="${1#--format=}"; shift ;;
            *) issue_id="$1"; shift ;;
        esac
    done

    if [ -z "$issue_id" ]; then
        echo '{"error": "Issue ID required"}' >&2
        return 1
    fi

    local query='
    query ListComments($issueId: String!) {
        issue(id: $issueId) {
            comments {
                nodes {
                    id
                    body
                    createdAt
                    updatedAt
                    user { name }
                }
            }
        }
    }'

    local variables="{\"issueId\": \"$issue_id\"}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Cache-aside: store raw comment nodes for future reads
    local raw_nodes
    raw_nodes=$(echo "$result" | jq '.issue.comments.nodes // []')
    cache_store_comments "$issue_id" "$raw_nodes" 2>/dev/null || true

    # Apply output format
    case "$FORMAT" in
        raw)
            echo "$result"
            ;;
        safe|*)
            format_comments_list "$result"
            ;;
    esac
}

create_comment() {
    local issue_id="$1"
    shift

    local body=""
    local body_file=""
    local parent_id=""
    local attach_paths=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --body) body="$2"; shift 2 ;;
            --body-file) body_file="$2"; shift 2 ;;
            --parent) parent_id="$2"; shift 2 ;;
            --attach)
                if [ -z "${2-}" ]; then
                    echo '{"error": "--attach requires a path argument"}' >&2
                    return 1
                fi
                attach_paths+=("$2")
                shift 2
                ;;
            --attach=*) attach_paths+=("${1#*=}"); shift ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    if [[ -n "$body" && -n "$body_file" ]]; then
        echo '{"error": "--body and --body-file are mutually exclusive"}' >&2
        return 1
    fi
    if [[ -n "$body_file" ]]; then
        read_body_file "$body_file"
    fi

    # --attach: refuse unreadable paths before any API call.
    if [ ${#attach_paths[@]} -gt 0 ]; then
        attach_preflight_files "${attach_paths[@]}" || return 1
    fi

    if [ -z "$body" ] && [ ${#attach_paths[@]} -eq 0 ]; then
        echo '{"error": "Required: --body, --body-file, or --attach"}' >&2
        return 1
    fi

    # Upload --attach files and reference them from the comment body: images
    # embed as markdown, other files get a markdown link (comments have no
    # attachmentCreate surface, so the link IS the attachment). An upload
    # failure refuses here, before the comment exists — nothing partial.
    local attach_path attach_info attach_sep=$'\n\n'
    for attach_path in ${attach_paths[@]+"${attach_paths[@]}"}; do
        attach_info=$(attach_upload_file "$attach_path") || return 1
        local attach_url attach_name attach_type
        attach_url=$(echo "$attach_info" | jq -r '.assetUrl')
        attach_name=$(echo "$attach_info" | jq -r '.filename')
        attach_type=$(echo "$attach_info" | jq -r '.contentType')
        local attach_label
        attach_label="$(attach_markdown_label "$attach_name")"
        if [[ "$attach_type" == image/* ]]; then
            body="${body:+${body}${attach_sep}}![${attach_label}](${attach_url})"
        else
            body="${body:+${body}${attach_sep}}[${attach_label}](${attach_url})"
        fi
    done

    # Escape body for JSON (handle newlines and quotes)
    local escaped_body
    escaped_body=$(echo "$body" | jq -Rs '.')

    local input_parts=("\"issueId\": \"$issue_id\"" "\"body\": $escaped_body")

    [ -n "$parent_id" ] && input_parts+=("\"parentId\": \"$parent_id\"")

    local input_json
    input_json=$(IFS=,; echo "{${input_parts[*]}}")

    local mutation='
    mutation CreateComment($input: CommentCreateInput!) {
        commentCreate(input: $input) {
            success
            comment {
                id
                body
                createdAt
                updatedAt
                user { name }
                issue { identifier updatedAt }
            }
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"input\": $input_json}")
    # Write-through: append comment to cache, touch issue updatedAt
    local created_comment
    created_comment=$(echo "$result" | jq '.commentCreate.comment // empty')
    if [[ -n "$created_comment" && "$created_comment" != "null" ]]; then
        local cache_comment
        cache_comment=$(echo "$created_comment" | jq 'del(.issue)')
        cache_append_comment "$issue_id" "$cache_comment" || true
        local _issue_ts
        _issue_ts=$(echo "$created_comment" | jq -r '.issue.updatedAt // empty')
        [[ -n "$_issue_ts" ]] && cache_touch_issue "$issue_id" "$_issue_ts" 2>/dev/null || true
    fi
    # Download any attachments in the new comment
    if [[ -n "$created_comment" && "$created_comment" != "null" ]]; then
        local _body
        _body=$(echo "$created_comment" | jq -r '.body // empty')
        attach_download_from_text "$_body" "$issue_id" "comment" &
    fi
    normalize_mutation_response "$result" "commentCreate" "comment"
}

update_comment() {
    local comment_id="$1"
    shift

    local body=""
    local body_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --body) body="$2"; shift 2 ;;
            --body-file) body_file="$2"; shift 2 ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    if [[ -n "$body" && -n "$body_file" ]]; then
        echo '{"error": "--body and --body-file are mutually exclusive"}' >&2
        return 1
    fi
    if [[ -n "$body_file" ]]; then
        read_body_file "$body_file"
    fi

    if [ -z "$body" ]; then
        echo '{"error": "Required: --body or --body-file"}' >&2
        return 1
    fi

    local escaped_body
    escaped_body=$(echo "$body" | jq -Rs '.')

    local mutation='
    mutation UpdateComment($id: String!, $input: CommentUpdateInput!) {
        commentUpdate(id: $id, input: $input) {
            success
            comment {
                id
                body
                createdAt
                updatedAt
                user { name }
                issue { identifier updatedAt }
            }
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$comment_id\", \"input\": {\"body\": $escaped_body}}")
    # Write-through: update comment in cache
    local updated_comment issue_id
    updated_comment=$(echo "$result" | jq '.commentUpdate.comment // empty')
    issue_id=$(echo "$updated_comment" | jq -r '.issue.identifier // empty' 2>/dev/null)
    if [[ -n "$issue_id" && -n "$updated_comment" && "$updated_comment" != "null" ]]; then
        local cache_comment
        cache_comment=$(echo "$updated_comment" | jq 'del(.issue)')
        cache_update_comment "$issue_id" "$cache_comment" || true
        local _issue_ts
        _issue_ts=$(echo "$updated_comment" | jq -r '.issue.updatedAt // empty')
        [[ -n "$_issue_ts" ]] && cache_touch_issue "$issue_id" "$_issue_ts" 2>/dev/null || true
        # Download any attachments in the updated comment
        local _body
        _body=$(echo "$updated_comment" | jq -r '.body // empty')
        attach_download_from_text "$_body" "$issue_id" "comment" &
    fi
    normalize_mutation_response "$result" "commentUpdate" "comment"
}

delete_comment() {
    local comment_id="$1"

    local mutation='
    mutation DeleteComment($id: String!) {
        commentDelete(id: $id) {
            success
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$comment_id\"}")
    # Write-through: remove comment from cache
    local success
    success=$(echo "$result" | jq -r '.commentDelete.success // "false"')
    [[ "$success" == "true" ]] && cache_delete_comment "$comment_id" || true
    normalize_mutation_response "$result" "commentDelete" "comment"
}

# Main routing
action="${1:-help}"
shift || true

# Fail closed: a write needs a resolved team target before any API call.
linear_guard_write_action "$action" "create update delete" "$@" || exit 1

case "$action" in
    list)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: comments.sh list <issue-id>"}' >&2
            exit 1
        fi
        list_comments "$@"
        ;;
    create)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: comments.sh create <issue-id> --body \"...\""}' >&2
            exit 1
        fi
        create_comment "$@"
        ;;
    update)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: comments.sh update <comment-id> --body \"...\""}' >&2
            exit 1
        fi
        update_comment "$@"
        ;;
    delete)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: comments.sh delete <comment-id>"}' >&2
            exit 1
        fi
        delete_comment "$1"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'comments.sh --help' for usage." >&2
        exit 1
        ;;
esac
