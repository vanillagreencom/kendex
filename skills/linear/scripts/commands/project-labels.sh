#!/bin/bash
# Linear GraphQL API - Project Label Operations
# Usage: project-labels.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

show_help() {
    cat << 'EOF'
Project Label Operations

Usage: project-labels.sh <action> [options]

Actions:
  list    List project labels
  create  Create a new project label
  update  Update an existing project label
  delete  Delete a project label

Common Options:
  --format=safe    Flat, normalized JSON (default)
  --format=raw     Original GraphQL structure

List Options:
  --limit <n>           Max results (default: 50)

Create Options:
  --name <text>         Label name (required)
  --color <hex>         Color hex code (e.g., "#FF6B35")
  --description <text>  Label description
  --parent <name>       Parent label group name (e.g., "Phase", "Area")
  --group               Create as a group label (can have children)

Update Options:
  --name <text>         New name
  --color <hex>         New color
  --description <text>  New description

Examples:
  project-labels.sh list
  project-labels.sh list --format=raw
  project-labels.sh create --name "Phase" --color "#3F51B5" --group
  project-labels.sh create --name "phase-1" --color "#4CAF50" --parent "Phase"
  project-labels.sh update <id> --name "new-name" --color "#FF0000"
  project-labels.sh delete <id>
EOF
}

list_project_labels() {
    local first=75
    local format="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format=*) format="${1#--format=}"; shift ;;
            --format) format="$2"; shift 2 ;;
            --limit)
                first="$2"
                shift 2
                ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    local query='
    query ListProjectLabels($first: Int) {
        projectLabels(first: $first) {
            nodes {
                id
                name
                color
                description
                isGroup
                parent { name }
                createdAt
            }
        }
    }'

    local variables="{\"first\": $first}"
    local result
    result=$(graphql_query "$query" "$variables")

    case "$format" in
        raw) echo "$result" ;;
        safe|*) format_project_labels_list "$result" ;;
    esac
}

create_project_label() {
    local name=""
    local color=""
    local description=""
    local parent=""
    local is_group="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --color) color="$2"; shift 2 ;;
            --description) description="$2"; shift 2 ;;
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
    escaped_name=$(printf '%s' "$name" | jq -Rs '.')
    local input_parts=("\"name\": $escaped_name")

    [ -n "$color" ] && input_parts+=("\"color\": \"$color\"")
    if [ -n "$description" ]; then
        local escaped_desc
        escaped_desc=$(printf '%s' "$description" | jq -Rs '.')
        input_parts+=("\"description\": $escaped_desc")
    fi
    [ "$is_group" = "true" ] && input_parts+=("\"isGroup\": true")

    # Get parent label group ID if specified
    if [ -n "$parent" ]; then
        local parent_query='query GetParentProjectLabel($name: String!) { projectLabels(filter: {name: {eq: $name}}) { nodes { id isGroup } } }'
        local parent_result
        parent_result=$(graphql_query "$parent_query" "{\"name\": \"$parent\"}")
        local parent_id
        parent_id=$(echo "$parent_result" | jq -r '.projectLabels.nodes[0].id // empty')
        if [ -z "$parent_id" ]; then
            echo "{\"error\": \"Parent project label group not found: $parent\"}" >&2
            return 1
        fi
        input_parts+=("\"parentId\": \"$parent_id\"")
    fi

    local input_json
    input_json=$(IFS=,; echo "{${input_parts[*]}}")

    local mutation='
    mutation CreateProjectLabel($input: ProjectLabelCreateInput!) {
        projectLabelCreate(input: $input) {
            success
            projectLabel {
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
    normalize_mutation_response "$result" "projectLabelCreate" "projectLabel"
}

update_project_label() {
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
    mutation UpdateProjectLabel($id: String!, $input: ProjectLabelUpdateInput!) {
        projectLabelUpdate(id: $id, input: $input) {
            success
            projectLabel {
                id
                name
                color
            }
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$label_id\", \"input\": $input_json}")
    normalize_mutation_response "$result" "projectLabelUpdate" "projectLabel"
}

delete_project_label() {
    local label_id="$1"

    local mutation='
    mutation DeleteProjectLabel($id: String!) {
        projectLabelDelete(id: $id) {
            success
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$label_id\"}")
    normalize_mutation_response "$result" "projectLabelDelete" "projectLabel"
}

# Main routing
action="${1:-help}"
shift || true

# Fail closed: a write needs a resolved team target before any API call.
linear_guard_write_action "$action" "create update delete" "$@" || exit 1

case "$action" in
    list)
        list_project_labels "$@"
        ;;
    create)
        create_project_label "$@"
        ;;
    update)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: project-labels.sh update <id> [options]"}' >&2
            exit 1
        fi
        update_project_label "$@"
        ;;
    delete)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: project-labels.sh delete <id>"}' >&2
            exit 1
        fi
        delete_project_label "$1"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'project-labels.sh --help' for usage." >&2
        exit 1
        ;;
esac
