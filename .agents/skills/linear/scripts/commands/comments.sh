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
  list       List comments on an issue
  bulk-list  List the comments of several issues in one read
  create     Create a new comment
  update  Update an existing comment
  delete  Delete a comment

List:
  comments.sh list <issue-id>

Bulk List:
  comments.sh bulk-list <ID1> <ID2> ... [--stdin] [--format=safe|raw]
                        One object keyed by identifier, each value that
                        issue's comment list ([] when it has none). Issues
                        are read 50 to a request; an issue whose comments
                        run past one page, or an identifier that request
                        leaves unanswered, takes further requests. An
                        identifier Linear has no issue for refuses the whole
                        read with a `missing` list; a lookup that fails any
                        other way (a quota, a 5xx) fails it with no
                        `missing`. --stdin reads one identifier per line.

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
            id
            comments {
                pageInfo { hasNextPage endCursor }
                nodes {
                    id
                    body
                    createdAt
                    updatedAt
                    user { name email }
                }
            }
        }
    }'

    local variables
    variables=$(jq -cn --arg id "$issue_id" '{issueId: $id}') || return 1
    local result
    result=$(graphql_query "$query" "$variables") || return 1

    # Apply output format
    case "$FORMAT" in
        raw)
            linear_public_result "$result"
            ;;
        safe|*)
            format_comments_list "$result"
            ;;
    esac
}

# The comments of several issues, keyed by identifier, read 50 issues to a
# request; archived issues are included, since their comments still answer a
# history read.
bulk_list_comments() {
    local identifiers=() line
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --stdin)
            while IFS= read -r line || [[ -n "$line" ]]; do [[ -n "$line" ]] && identifiers+=("$line"); done
            shift
            ;;
        --format)
            linear_require_option_value "$@" || return 1
            FORMAT="$2"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *)
            [[ -n "$1" ]] && identifiers+=("$1")
            shift
            ;;
        esac
    done

    linear_require_format "$FORMAT" safe raw || return 1

    # The output is keyed by identifier, so a UUID refuses too.
    local id_json
    id_json=$(linear_issue_refs identifiers ${identifiers[@]+"${identifiers[@]}"}) || return 1

    local fields='
                id
                identifier
                comments {
                    pageInfo { hasNextPage endCursor }
                    nodes {
                        id
                        body
                        createdAt
                        updatedAt
                        user { name email }
                    }
                }'
    local result
    result=$(linear_issue_refs_read "$fields" "$id_json") || return 1

    jq -s --arg format "$FORMAT" "$COMMENT_SAFE_JQ"'
        .[0] as $ids | .[1].refs as $refs
        | (.[1].nodes | map({key: .identifier, value: .comments.nodes}) | from_entries) as $read
        | reduce $ids[] as $i ({}; .[$i] = $read[$refs[$i]])
        | if $format == "raw" then . else map_values(map(comment_safe)) end' <<<"$id_json"$'\n'"$result"
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

    local comment_issue_id="$issue_id"
    # An unresolved issue would strand uploaded files without a comment.
    if [ ${#attach_paths[@]} -gt 0 ]; then
        attach_preflight_files "${attach_paths[@]}" || return 1
        local issue_result
        issue_result=$(bash "$SCRIPT_DIR/issues.sh" get "$issue_id" --format=raw) || return 1
        comment_issue_id=$(jq -r '.issue.id' <<<"$issue_result") || return 1
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

    local input_parts=("\"issueId\": \"$comment_issue_id\"" "\"body\": $escaped_body")

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
                user { name email }
                issue { identifier updatedAt }
            }
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"input\": $input_json}")
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
                user { name email }
                issue { identifier updatedAt }
            }
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$comment_id\", \"input\": {\"body\": $escaped_body}}")
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
    normalize_mutation_response "$result" "commentDelete" "comment"
}

# Main routing
action="${1:-help}"
shift || true

# Comment creation routes by the issue identifier.
linear_guard_write_action "$action" "update delete" "$@" || exit 1

case "$action" in
    list)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: comments.sh list <issue-id>"}' >&2
            exit 1
        fi
        list_comments "$@"
        ;;
    bulk-list)
        bulk_list_comments "$@"
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
