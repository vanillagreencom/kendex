#!/bin/bash
# Linear GraphQL API - Label Operations
# Usage: labels.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    cat << 'EOF'
Label Operations

Usage: labels.sh <action> [options]

Actions:
  list    List labels
  create  Create a new label
  update  Update an existing label
  delete  Delete a label
  audit   List labels on the team's open issues that the taxonomy does not
          declare, and team labels whose name a workspace label also uses
  declared <a,b>  Split a label list into {kept, dropped} by the taxonomy, in
          list order; with no taxonomy every name is kept. Sends no request.

List Options:
  --team <ref>          Filter by team key or name (workspace labels if omitted)
  --limit <n>           Max results (default: 75); a larger value spans pages
  --max                 Read every page; a chain that fails partway refuses

Create Options:
  --name <text>         Label name (required)
  --color <hex>         Color hex code (e.g., "#FF6B35")
  --description <text>  Label description
  --team <ref>          Team key or name (workspace label if omitted)
  --parent <name>       Parent label group name (e.g., "Agent", "Stack")
  --group               Create as a group label (can have children)

  Where the repository declares a label taxonomy (project-management
  references/labels.md, plus LINEAR_AGENT_LABELS), create refuses a name it
  does not declare, and a --team create a name a workspace label uses.
  update --name refuses an undeclared name, and a name another workspace
  label uses.

Audit Options:
  --team <ref>          Team key or name (default: LINEAR_TEAM)

Update Options:
  --name <text>         New name
  --color <hex>         New color
  --description <text>  New description

Examples:
  labels.sh list
  labels.sh list
  labels.sh create --name "backend" --color "#E74C3C"
  labels.sh update <id> --name "new-name" --color "#FF0000"
  labels.sh delete <id>
  labels.sh audit
EOF
}
case "${1:-help}" in help|--help|-h) show_help; exit 0 ;; esac

source "$SCRIPT_DIR/../lib/common.sh"

list_labels() {
    local team=""
    linear_list_reset
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --team)
                linear_require_team_value "$@" || return 1
                team="$2"
                shift 2
                ;;
            --limit)
                linear_list_option "$@" || return 1
                shift 2
                ;;
            --max)
                linear_list_option --max
                shift
                ;;
            --format) FORMAT="$2"; shift 2 ;;
            --format=*) FORMAT="${1#--format=}"; shift ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    local filter_json="{}"
    if [ -n "$team" ]; then
        local team_id
        team_id=$(resolve_team_id "$team") || return 1
        filter_json=$(jq -cn --arg id "$team_id" '{team: {id: {eq: $id}}}')
    fi

    local query='
    query ListLabels($filter: IssueLabelFilter, $first: Int, $after: String) {
        issueLabels(filter: $filter, first: $first, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
                id
                name
                color
                description
                isGroup
                team { name }
                parent { name }
                createdAt
            }
        }
    }'

    local variables="{\"filter\": $filter_json}"
    local result
    result=$(linear_list_read "$query" "$variables" issueLabels) || return 1

    # Apply output format
    case "$FORMAT" in
        raw)
            linear_public_result "$result"
            ;;
        safe|*)
            format_labels_list "$result"
            ;;
    esac
}

create_label() {
    local name=""
    local color=""
    local description=""
    local team=""
    local parent=""
    local is_group="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --color) color="$2"; shift 2 ;;
            --description) description="$2"; shift 2 ;;
            --team) team="$2"; shift 2 ;;
            --parent) parent="$2"; shift 2 ;;
            --group) is_group="true"; shift ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    # Resolve the team target; creating a label without one is refused here,
    # before any API call. --team stays optional as a scope selector: it narrows
    # a workspace label to one team, and the configured target satisfies the
    # requirement when it is omitted.
    linear_set_team_target "$team"
    linear_require_team_target || return 1

    if [ -z "$name" ]; then
        echo '{"error": "Required: --name"}' >&2
        return 1
    fi
    linear_require_declared_labels --name "$name" || return 1

    # Build input object with proper escaping
    local escaped_name
    escaped_name=$(printf '%s' "$name" | jq -Rs '.')
    local input_parts=("\"name\": $escaped_name")

    [ -n "$color" ] && input_parts+=("\"color\": \"$color\"")
    if [ -n "$description" ]; then
        local escaped_desc
        escaped_desc=$(printf '%s' "$description" | jq -Rs '.')
        input_parts+=("\"description\": $escaped_desc")
    fi
    [ "$is_group" = "true" ] && input_parts+=("\"isGroup\": true")

    # Get team ID if specified
    if [ -n "$team" ]; then
        local team_id
        team_id=$(resolve_team_id "$team") || return 1
        input_parts+=("\"teamId\": \"$team_id\"")
    fi

    if [ -n "$team" ]; then
        refuse_workspace_name "$name" || return 1
    fi

    # Get parent label group ID if specified
    if [ -n "$parent" ]; then
        local parent_query='query GetParentLabel($name: String!) { issueLabels(filter: {name: {eq: $name}}) { nodes { id isGroup } } }'
        local parent_result
        parent_result=$(graphql_query "$parent_query" "{\"name\": \"$parent\"}")
        local parent_id
        parent_id=$(echo "$parent_result" | jq -r '.issueLabels.nodes[0].id // empty')
        if [ -z "$parent_id" ]; then
            echo "{\"error\": \"Parent label group not found: $parent\"}" >&2
            return 1
        fi
        input_parts+=("\"parentId\": \"$parent_id\"")
    fi

    local input_json
    input_json=$(IFS=,; echo "{${input_parts[*]}}")

    local mutation='
    mutation CreateLabel($input: IssueLabelCreateInput!) {
        issueLabelCreate(input: $input) {
            success
            issueLabel {
                id
                name
                color
                isGroup
                parent { name }
            }
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"input\": $input_json}")
    normalize_mutation_response "$result" "issueLabelCreate" "issueLabel"
}

# Under a declared taxonomy, refuse a label name a workspace label already
# uses: a second label of one name beside a workspace label makes every name
# lookup ambiguous. LABEL_ID, on a rename, is the label itself, which keeps
# its own name. With no taxonomy it sends no request.
# Usage: refuse_workspace_name NAME [LABEL_ID]
refuse_workspace_name() {
    local name="$1" label_id="${2:-}" declared
    declared=$(linear_declared_labels) || return 1
    [ -n "$declared" ] || return 0
    local workspace_query='query WorkspaceLabel($name: String!) { issueLabels(filter: {name: {eq: $name}, team: {null: true}}) { nodes { id } } }'
    local workspace_vars workspace_result workspace_count
    workspace_vars=$(jq -cn --arg name "$name" '{name: $name}') || return 1
    workspace_result=$(graphql_query "$workspace_query" "$workspace_vars") || return 1
    workspace_count=$(jq -r --arg self "$label_id" '[.issueLabels.nodes[] | select(.id != $self)] | length' <<<"$workspace_result") || return 1
    if [ "$workspace_count" != 0 ]; then
        linear_label_message workspace-duplicate "$name" >&2
        return 1
    fi
}

update_label() {
    local label_id="$1"
    shift

    local name=""
    local color=""
    local description=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --color) color="$2"; shift 2 ;;
            --description) description="$2"; shift 2 ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    local input_parts=()

    if [ -n "$name" ]; then
        # A rename applies a label name, so the create rules hold for it: a
        # declared name, and no second label beside a workspace one of one name.
        linear_require_declared_labels --name "$name" || return 1
        refuse_workspace_name "$name" "$label_id" || return 1
        local escaped_name
        escaped_name=$(printf '%s' "$name" | jq -Rs '.')
        input_parts+=("\"name\": $escaped_name")
    fi
    [ -n "$color" ] && input_parts+=("\"color\": \"$color\"")
    if [ -n "$description" ]; then
        local escaped_desc
        escaped_desc=$(printf '%s' "$description" | jq -Rs '.')
        input_parts+=("\"description\": $escaped_desc")
    fi

    if [ ${#input_parts[@]} -eq 0 ]; then
        echo '{"error": "No update options provided"}' >&2
        return 1
    fi

    local input_json
    input_json=$(IFS=,; echo "{${input_parts[*]}}")

    local mutation='
    mutation UpdateLabel($id: String!, $input: IssueLabelUpdateInput!) {
        issueLabelUpdate(id: $id, input: $input) {
            success
            issueLabel {
                id
                name
                color
                isGroup
                parent { name }
            }
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$label_id\", \"input\": $input_json}")
    normalize_mutation_response "$result" "issueLabelUpdate" "issueLabel"
}

delete_label() {
    local label_id="$1"

    local mutation='
    mutation DeleteLabel($id: String!) {
        issueLabelDelete(id: $id) {
            success
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$label_id\"}")
    normalize_mutation_response "$result" "issueLabelDelete" "issueLabel"
}

# Drift against the declared taxonomy, read live: each undeclared label on the
# team's open issues with the issues carrying it, and each name both a team
# label and a workspace label use. Read-only; it reports and never relabels.
audit_labels() {
    local team=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --team)
                linear_require_team_value "$@" || return 1
                team="$2"
                shift 2
                ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    linear_set_team_target "$team"
    if [ -z "$LINEAR_TEAM_TARGET" ]; then
        linear_label_message no-team "" >&2
        return 1
    fi
    local declared
    declared=$(linear_declared_labels) || return 1
    if [ -z "$declared" ]; then
        linear_label_message absent "$LINEAR_TAXONOMY_FILE" >&2
        return 1
    fi

    # Every page of both connections, and of each issue's labels (lib/pages.sh
    # follows an open one by the issue's id): a partial read would report a
    # clean team it never finished reading, so it fails with no output.
    local team_id variables issues labels
    team_id=$(resolve_team_id "$LINEAR_TEAM_TARGET") || return 1
    variables=$(jq -cn --arg teamId "$team_id" '{teamId: $teamId}') || return 1
    issues=$(graphql_pages 'query AuditIssues($teamId: ID!, $after: String) { issues(filter: {team: {id: {eq: $teamId}}, state: {type: {nin: ["completed", "canceled"]}}}, first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id identifier labels(first: 100) { pageInfo { hasNextPage endCursor } nodes { name } } } } }' \
        "$variables" issues) || return 1
    issues=$(jq -c '.issues.nodes' <<<"$issues") || return 1
    labels=$(graphql_pages 'query AuditLabels($teamId: ID!, $after: String) { issueLabels(filter: {or: [{team: {id: {eq: $teamId}}}, {team: {null: true}}]}, first: 250, after: $after) { pageInfo { hasNextPage endCursor } nodes { id name team { id } } } }' \
        "$variables" issueLabels) || return 1
    labels=$(jq -c '.issueLabels.nodes' <<<"$labels") || return 1

    jq -s --arg team "$LINEAR_TEAM_TARGET" --arg taxonomy "$LINEAR_TAXONOMY_FILE" '
        .[0] as $declared | .[1] as $issues | .[2] as $labels |
        {team: $team, taxonomy: $taxonomy,
         undeclared: ([$issues[] | .identifier as $issue | .labels.nodes[].name
                | select(IN($declared[]) | not) | {label: ., issue: $issue}]
            | group_by(.label) | map({label: .[0].label, issues: map(.issue)})),
         same_name: ($labels | group_by(.name)
            | map(select(any(.[]; .team == null) and any(.[]; .team != null))
                | {name: .[0].name,
                   workspace_label: (map(select(.team == null)) | .[0].id),
                   team_label: (map(select(.team != null)) | .[0].id)}))}' \
        <<<"$declared"$'\n'"$issues"$'\n'"$labels"
}

declared_labels() {
    local declared
    declared=$(linear_declared_labels) || return 1
    jq -cn --arg list "${1-}" --argjson declared "${declared:-null}" '$list | split(",")
        | map(gsub("^ +| +$"; "") | select(length > 0)) | map(select($declared == null or IN($declared[]))) as $kept
        | {kept: $kept, dropped: (. - $kept)}'
}

# Main routing
action="${1:-help}"
shift || true

# Fail closed: a write needs a resolved team target before any API call.
linear_guard_write_action "$action" "update delete" "$@" || exit 1

case "$action" in
    list)
        list_labels "$@"
        ;;
    create)
        create_label "$@"
        ;;
    audit)
        audit_labels "$@"
        ;;
    declared)
        declared_labels "$@"
        ;;
    update)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: labels.sh update <id> [options]"}' >&2
            exit 1
        fi
        update_label "$@"
        ;;
    delete)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: labels.sh delete <id>"}' >&2
            exit 1
        fi
        delete_label "$1"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'labels.sh --help' for usage." >&2
        exit 1
        ;;
esac
