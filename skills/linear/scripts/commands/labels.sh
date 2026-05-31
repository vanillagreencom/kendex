#!/bin/bash
# Linear GraphQL API - Label Operations
# Usage: labels.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

show_help() {
    cat << 'EOF'
Label Operations

Usage: labels.sh <action> [options]

Actions:
  list    List labels
  create  Create a new label
  update  Update an existing label
  delete  Delete a label

List Options:
  --team <name>         Filter by team (workspace labels if omitted)
  --limit <n>           Max results (default: 50)

Create Options:
  --name <text>         Label name (required)
  --color <hex>         Color hex code (e.g., "#FF6B35")
  --description <text>  Label description
  --team <name>         Team name (workspace label if omitted)
  --parent <name>       Parent label group name (e.g., "Agent", "Stack")
  --group               Create as a group label (can have children)

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
EOF
}

list_labels() {
    local filter_parts=()
    local first=75
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --team)
                filter_parts+=("\"team\": {\"name\": {\"eq\": \"$2\"}}")
                shift 2
                ;;
            --limit)
                first="$2"
                shift 2
                ;;
            --format) FORMAT="$2"; shift 2 ;;
            --format=*) FORMAT="${1#--format=}"; shift ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    local filter_json
    if [ ${#filter_parts[@]} -gt 0 ]; then
        filter_json=$(IFS=,; echo "{${filter_parts[*]}}")
    else
        filter_json="{}"
    fi

    local query='
    query ListLabels($filter: IssueLabelFilter, $first: Int) {
        issueLabels(filter: $filter, first: $first) {
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

    local variables="{\"filter\": $filter_json, \"first\": $first}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply output format
    case "$FORMAT" in
        raw)
            echo "$result"
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

    if [ -z "$name" ]; then
        echo '{"error": "Required: --name"}' >&2
        return 1
    fi

    # Build input object with proper escaping
    local escaped_name
    escaped_name=$(echo -n "$name" | jq -Rs '.')
    local input_parts=("\"name\": $escaped_name")

    [ -n "$color" ] && input_parts+=("\"color\": \"$color\"")
    if [ -n "$description" ]; then
        local escaped_desc
        escaped_desc=$(echo -n "$description" | jq -Rs '.')
        input_parts+=("\"description\": $escaped_desc")
    fi
    [ "$is_group" = "true" ] && input_parts+=("\"isGroup\": true")

    # Get team ID if specified
    if [ -n "$team" ]; then
        local team_query='query GetTeam($name: String!) { teams(filter: {name: {eq: $name}}) { nodes { id } } }'
        local team_result
        team_result=$(graphql_query "$team_query" "{\"name\": \"$team\"}")
        local team_id
        team_id=$(echo "$team_result" | jq -r '.teams.nodes[0].id // empty')
        if [ -z "$team_id" ]; then
            echo "{\"error\": \"Team not found: $team\"}" >&2
            return 1
        fi
        input_parts+=("\"teamId\": \"$team_id\"")
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
        local escaped_name
        escaped_name=$(echo -n "$name" | jq -Rs '.')
        input_parts+=("\"name\": $escaped_name")
    fi
    [ -n "$color" ] && input_parts+=("\"color\": \"$color\"")
    if [ -n "$description" ]; then
        local escaped_desc
        escaped_desc=$(echo -n "$description" | jq -Rs '.')
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

# Main routing
action="${1:-help}"
shift || true

case "$action" in
    list)
        list_labels "$@"
        ;;
    create)
        create_label "$@"
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
