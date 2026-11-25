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
  bulk-get   Read comment URLs by comment ID
  owner-requests  Complete owner-mentioned requests in the assigned, labelled view
  owner-questions ISSUE --email EMAIL  Read possible questions awaiting a ruling
  create     Create a new comment
  update  Update an existing comment
  delete  Delete a comment

List:
  comments.sh list <issue-id>
                        Every comment of the issue: a list past one page
                        takes further requests. In the safe format (and
                        bulk-list's) a body reads without the attribution
                        line create opens it with: the body its caller
                        posted. --format=raw keeps the stored body.

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

Bulk Get:
  comments.sh bulk-get <COMMENT_ID> ...
                        One object keyed by comment ID, with a url field in
                        each value. Absent comments have no entry.

Owner Requests:
  comments.sh owner-requests --email EMAIL --label LABEL
                        Jarvis's canonical request projection. Uses the
                        exact-email resolver, existing issues filters and
                        complete comment reader. Preserves every distinct
                        request mentioning that user's canonical profile URL.
                        A successful complete read defines current view
                        membership; failed reads publish no partial result.

Create Options:
  --body <text>         Comment body (required unless --body-file or --attach is set)
  --body-file <path>    Read comment body from file (preferred for markdown)
  --parent <id>         Parent comment ID for replies
  --no-attribution      Post the body as supplied, with no attribution line,
                        so its first line is the caller's: an owner ask
                        opens with the owner's mention
  --id <uuid>           The new comment's own ID, a UUID v4 the caller mints.
                        Linear keeps an ID unique, so a create resent after an
                        unconfirmed answer cannot post a second comment; read
                        `comment(id:)` through `linear.sh graphql` to learn
                        whether the first one landed
  --attach <path>       Upload a file to Linear and reference it in the body
                        (repeatable). Images embed as ![name](assetUrl); other
                        files append a [name](assetUrl) markdown link. Composes
                        with --body/--body-file; missing/unreadable paths
                        refuse before any API call.
  Every created body opens with the line
    > Posted by Agent: NAME, Model: MODEL, Effort: EFFORT
  and a blank line. Each value is what orch's `orch-runtime session` reads
  for the lane session bound at the caller: the agent from its launch, the
  model and effort from the session's own record. A value it does not read
  is unknown. A body that already opens with such a line has it replaced.
  --no-attribution leaves both out.

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

# Ruling UUIDs flip the high bit, outside this reserved question prefix.
readonly OWNER_QUESTION_PREFIX=a54c6f77-50d1
readonly OWNER_RULING_JQ='def comment_uuid:
  type == "string" and test("\\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\z");
def ruling_id:
  if comment_uuid then
    .[0:1] as $first | ("0123456789abcdef" | index($first)) as $at | "89abcdef01234567"[$at:$at+1] + .[1:]
  else null end;
def ruling_body:
  gsub("\r\n"; "\n") | sub("\\n+\\z"; "") | split("\n")
  | if .[0] == "This question closed with no answer." then length == 1
    else .[0] | IN("This question closed on its answer.", "This question closed on your answer.",
      "This question closed at its deadline with no answer, so its recommendation stands.") end;
def owner_ruling:
  (.parent_id | ruling_id) as $id | $id != null and .id == $id and (.body | ruling_body);
def mentions($url): [scan("https?://[^\\s<>\"()\\[\\]]+") | sub("[.,;!?]+$"; "")] | index($url) != null;'

owner_question_id() {
    local hash hash_command=(shasum -a 256)
    if command -v sha256sum >/dev/null 2>&1; then hash_command=(sha256sum); fi
    hash=$(printf '%s' "$1" | "${hash_command[@]}") || return 1
    printf '%s-4%s-8%s-%s\n' "$OWNER_QUESTION_PREFIX" "${hash:0:3}" "${hash:3:3}" "${hash:6:12}"
}

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
                    user { id }
                    parent { id }
                    url
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
                        user { id }
                        parent { id }
                        url
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

bulk_get_comments() {
    if [[ $# -eq 0 ]]; then
        printf '{}\n'
        return
    fi
    local query='query BulkGetComments($filter: CommentFilter!, $first: Int!, $after: String) {
        comments(filter: $filter, first: $first, after: $after, includeArchived: true) {
            pageInfo { hasNextPage endCursor }
            nodes { id url }
        }
    }'
    local variables result
    variables=$(jq -cn --args '{filter: {id: {in: $ARGS.positional}}}' -- "$@") || return 1
    result=$(LINEAR_LIST_BOUND=all linear_list_read "$query" "$variables" comments) || return 1
    jq -c '.comments.nodes | map({key: .id, value: {url}}) | from_entries' <<<"$result"
}

owner_requests() {
    local email="" label="" owner workspace comment_fields variables items
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --email|--label)
                linear_require_option_value "$@" || return 1
                if [[ "$1" == --email ]]; then email="$2"; else label="$2"; fi
                shift 2 ;;
            *) echo '{"error":"owner-requests requires --email and --label"}' >&2; return 1 ;;
        esac
    done
    [[ -n "$email" && -n "$label" ]] || { echo '{"error":"owner-requests requires --email and --label"}' >&2; return 1; }
    owner=$(find_user_by_email "$email") || return 1
    jq -e '.id != null and (.url | type == "string" and startswith("https://"))' <<<"${owner:-null}" >/dev/null || {
        echo '{"error":"owner-profile-unavailable"}' >&2; return 1;
    }
    workspace=$("$BASH" "$SCRIPT_DIR/teams.sh" keys) || return 1
    # Read each issue and its discussion in the same paginated query.
    # The pager uses the same comment fields to complete each open connection.
    linear_list_option --max
    parse_filter --assignee "$email" --label "$label" || return 1
    variables=$(jq -cn --argjson filter "$FILTER_JSON" --argjson archive "$INCLUDE_ARCHIVED_JSON" \
        '{filter: $filter, includeArchived: $archive}') || return 1
    comment_fields=$(linear_connection_fields issue comments) || return 1
    items=$(linear_list_read '
      query ListIssues($filter: IssueFilter, $first: Int, $includeArchived: Boolean, $after: String) {
        issues(filter: $filter, first: $first, includeArchived: $includeArchived, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id identifier
            comments { pageInfo { hasNextPage endCursor } nodes { '"$comment_fields"' } }
          }
        }
      }' "$variables" issues) || return 1
    jq -cs "$COMMENT_SAFE_JQ$OWNER_RULING_JQ"'
      .[0] as $owner | .[1] as $workspace |
      (.[2].issues.nodes | map(.comments |= (.nodes | map(comment_safe)))) as $items |
      {workspace: $workspace.urlKey, owner: $owner.id,
       discussions: ($items | map({key: .id, value: (.comments | map({id, parent_id, user_id,
          ruling: owner_ruling,
          opening: (.body | split("\n")[0] | rtrimstr("\r"))}))}) | from_entries),
       requests: [$items[] | . as $issue | .comments[] | select(.body | mentions($owner.url))
          | if .user_id == "" or .user == "" or .created_at == "" or .url == "" then error("request-metadata-unavailable") else . end
          | {issue: $issue.identifier, issueUuid: $issue.id, comment: ., thread: (.parent_id // .id)}]}' \
      <<<"$owner"$'\n'"$workspace"$'\n'"$items"
}

owner_questions() {
    if [[ "$#" -eq 1 && "$1" == --prefix ]]; then jq -n --arg prefix "$OWNER_QUESTION_PREFIX-" '$prefix'; return; fi
    if [[ "$#" -ne 3 || "$2" != --email || -z "$3" ]]; then
        echo '{"error":"owner-questions requires ISSUE --email EMAIL"}' >&2; return 1
    fi
    local owner comments profile
    owner=$(find_user_by_email "$3") || return 1
    profile=$(jq -er '.url | strings | select(startswith("https://"))' <<<"${owner:-null}") || return 1
    comments=$(list_comments "$1" --format=safe) || return 1
    jq -ce --arg prefix "$OWNER_QUESTION_PREFIX-" --arg profile "$profile" "$OWNER_RULING_JQ"'
        if type == "array" and all(.[]; (.id | type) == "string") then . else error("invalid-owner-comments") end
        | [.[] | select(owner_ruling) | .parent_id] as $ruled
        | [.[] | select(.parent_id == null and (.id as $id | $ruled | index($id) == null))
          | (.id | comment_uuid and startswith($prefix)) as $reserved
          | select($reserved or (.body | mentions($profile)))
          | {id, reserved: $reserved, legacy_asks: [.body | split("\n")[] | select(startswith("ask=")) | ltrimstr("ask=")]}]' <<<"$comments"
}

# The line a new comment opens with, naming who posts it, read once per post
# through orch's `orch-runtime session`: the model and effort of the session
# bound at the caller's lane pane, and the name its launch gave that session,
# in the lines `agent-runtime session model --help` documents. A member stands
# only as that reading names it. A model the launch requested (`source=launch`)
# is no reading of the one the session runs, so it stays unknown; so does
# every member where orch is not installed beside this package, its runtime is
# not built on a computer without cargo, or no lane session is bound at the
# caller (an overseer, Jarvis, a plain shell). With cargo on PATH an unbuilt
# runtime is built at this read, so the post waits on that build. A Claude
# Code subagent shares its lane's pane and session, so
# its comment names the lane session's model.
comment_attribution() {
    local reader="$SCRIPT_DIR/../../../orch/scripts/orch-runtime" lines="" line
    local agent=unknown model=unknown effort=unknown
    if [[ -x "$reader" ]]; then
        # Exit 1 (a member unrecorded) and 2 (no session bound, a read failed)
        # still print the lines that answer.
        lines=$("$reader" session 2>/dev/null) || true
    fi
    while IFS= read -r line; do
        [[ "$line" =~ ^(agent|model|effort)=([^[:space:]]+)\ source=(session|launch)$ ]] || continue
        case "${BASH_REMATCH[1]}:${BASH_REMATCH[3]}" in
            agent:launch) agent="${BASH_REMATCH[2]}" ;;
            model:session) model="${BASH_REMATCH[2]}" ;;
            effort:session) effort="${BASH_REMATCH[2]}" ;;
        esac
    done <<<"$lines"
    printf '> Posted by Agent: %s, Model: %s, Effort: %s' "$agent" "$model" "$effort"
}

create_comment() {
    local issue_id="$1"
    shift

    local body=""
    local body_file=""
    local parent_id=""
    local attributed=1
    local comment_id="" owner_ruling=0 owner_question=""
    local attach_paths=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --body) body="$2"; shift 2 ;;
            --body-file) body_file="$2"; shift 2 ;;
            --parent) parent_id="$2"; shift 2 ;;
            --no-attribution) attributed=0; shift ;;
            --id) comment_id="$2"; shift 2 ;;
            --owner-ruling) owner_ruling=1; shift ;;
            --owner-question) linear_require_option_value "$@" || return 1; owner_question="$2"; shift 2 ;;
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
    if [[ "$owner_ruling" -eq 1 ]]; then
        [[ -z "$comment_id" ]] && comment_id=$(jq -ern --arg parent "$parent_id" "$OWNER_RULING_JQ"' $parent | ruling_id') || {
            echo '{"error":"invalid-owner-ruling-identity"}' >&2; return 1;
        }
    fi
    if [[ -n "$owner_question" ]]; then
        [[ -z "$comment_id" && -z "$parent_id" ]] && comment_id=$(owner_question_id "$owner_question") || {
            echo '{"error":"invalid-owner-question-identity"}' >&2; return 1;
        }
    fi

    local comment_issue_id="$issue_id"
    # An unresolved issue would strand uploaded files without a comment.
    if [ ${#attach_paths[@]} -gt 0 ]; then
        attach_preflight_files "${attach_paths[@]}" || return 1
        local issue_result
        issue_result=$(graphql_query 'query GetIssue($id: String!) { issue(id: $id) { id } }' \
            "$(jq -cn --arg id "$issue_id" '{id: $id}')") || return 1
        comment_issue_id=$(jq -er '.issue.id | strings | select(length > 0)' <<<"$issue_result") || {
            jq -cn --arg id "$issue_id" '{error: ("Issue not found: " + $id)}' >&2
            return 1
        }
    fi

    if [ -z "$body" ] && [ ${#attach_paths[@]} -eq 0 ]; then
        echo '{"error": "Required: --body, --body-file, or --attach"}' >&2
        return 1
    fi

    local attribution=""
    [[ "$attributed" -eq 0 ]] || attribution=$(comment_attribution)

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

    # Escape body for JSON (handle newlines and quotes), under the one
    # attribution line, which replaces any copy the caller wrote.
    local escaped_body
    if [[ "$attributed" -eq 1 ]]; then
        escaped_body=$(echo "$body" | jq -Rs --arg line "$attribution" \
            "$COMMENT_ATTRIBUTION_JQ"'$line + "\n\n" + unattributed')
    else
        escaped_body=$(echo "$body" | jq -Rs '.')
    fi

    local input_parts=("\"issueId\": \"$comment_issue_id\"" "\"body\": $escaped_body")

    [ -n "$parent_id" ] && input_parts+=("\"parentId\": \"$parent_id\"")
    [ -n "$comment_id" ] && input_parts+=("\"id\": $(jq -Rn --arg id "$comment_id" '$id')")

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
    if [[ "$owner_ruling" -eq 0 && -z "$owner_question" ]]; then
        result=$(graphql_query "$mutation" "{\"input\": $input_json}")
    elif ! result=$(graphql_query "$mutation" "{\"input\": $input_json}") ||
        ! jq -e --arg id "$comment_id" '.commentCreate | .success == true and .comment.id == $id' <<<"$result" >/dev/null; then
        local query='query OwnerRuling($id: String!) { comment(id: $id) { id body parent { id } issue { id identifier } } }'
        result=$(graphql_query "$query" "$(jq -cn --arg id "$comment_id" '{id: $id}')") || return 1
        jq -e --arg id "$comment_id" --arg item "$comment_issue_id" --arg parent "$parent_id" --argjson body "$escaped_body" "$COMMENT_ATTRIBUTION_JQ$OWNER_RULING_JQ"'
          def clean: gsub("\r\n"; "\n") | sub("\n+\\z"; "");
          .comment | if .id == $id and (if $parent == "" then .parent == null and
            (.issue.id == $item or .issue.identifier == ($item | ascii_upcase)) and (.body | clean) == ($body | clean)
            else .parent.id == $parent and .issue.id == $item and (.body | unattributed | ruling_body) end)
          then {success: true, data: {comment: {id}}} else error(if $parent == "" then "owner-question-unconfirmed" else "owner-ruling-unconfirmed" end) end' <<<"$result"
        return
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
    bulk-get)
        bulk_get_comments "$@"
        ;;
    owner-requests)
        owner_requests "$@"
        ;;
    owner-questions)
        owner_questions "$@"
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
