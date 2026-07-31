#!/bin/bash
# Linear GraphQL API - Project Milestone Operations
# Usage: milestones.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

show_help() {
    cat << 'EOF'
Project Milestone Operations

Usage: milestones.sh <action> [options]

Actions:
  list    List milestones for a project
  get     Get a single milestone by ID
  create  Create a new milestone
  update  Update an existing milestone
  delete  Delete a milestone

List Options:
  --project <id-or-name>  Project ID or name (optional, lists all if omitted)

Create Options:
  --project <id-or-name>  Project ID or name (required)
  --name <text>           Milestone name (required)
  --description <text>    Milestone description
  --target-date <date>    Target date (YYYY-MM-DD)

Update Options:
  --name <text>           New name
  --description <text>    New description
  --target-date <date>    New target date (YYYY-MM-DD)

Examples:
  milestones.sh list --project "Market Data Pipeline"
  milestones.sh get <milestone-id>
  milestones.sh create --project "Market Data Pipeline" --name "Alpha" --target-date 2025-02-15
  milestones.sh update <id> --name "Alpha Release"
  milestones.sh delete <id>
EOF
}

resolve_project_id() {
    local project_ref="$1"

    # Check if it's already a UUID
    if [[ "$project_ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$project_ref"
        return 0
    fi

    # Look up by name
    local query='query GetProject($name: String!) { projects(filter: {name: {eq: $name}}) { nodes { id } } }'
    local result
    result=$(graphql_query "$query" "{\"name\": \"$project_ref\"}")
    local project_id
    project_id=$(echo "$result" | jq -r '.projects.nodes[0].id // empty')

    if [ -z "$project_id" ]; then
        echo "" >&2
        return 1
    fi

    echo "$project_id"
}

list_milestones() {
    local project=""
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) project="$2"; shift 2 ;;
            --format) FORMAT="$2"; shift 2 ;;
            --format=*) FORMAT="${1#--format=}"; shift ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    local result
    # If no project specified, list all milestones across all projects
    if [ -z "$project" ]; then
        local query='
        query GetAllMilestones {
            projectMilestones(first: 100) {
                nodes {
                    id
                    name
                    description
                    targetDate
                    progress
                    sortOrder
                    project { id name }
                    createdAt
                }
            }
        }'
        result=$(graphql_query "$query" "{}")
    else
        local project_id
        project_id=$(resolve_project_id "$project")
        if [ -z "$project_id" ]; then
            echo "{\"error\": \"Project not found: $project\"}" >&2
            return 1
        fi

        local query='
        query GetProjectMilestones($projectId: String!) {
            projectMilestones(filter: {project: {id: {eq: $projectId}}}, first: 100) {
                nodes {
                    id
                    name
                    description
                    targetDate
                    progress
                    sortOrder
                    project { id name }
                    createdAt
                }
            }
        }'

        local variables="{\"projectId\": \"$project_id\"}"
        result=$(graphql_query "$query" "$variables")
    fi

    # Apply output format
    case "$FORMAT" in
        raw)
            echo "$result"
            ;;
        safe|*)
            format_milestones_list "$result"
            ;;
    esac
}

get_milestone() {
    local milestone_id=""
    FORMAT="${DEFAULT_FORMAT}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) FORMAT="$2"; shift 2 ;;
            --format=*) FORMAT="${1#--format=}"; shift ;;
            *) milestone_id="$1"; shift ;;
        esac
    done

    if [ -z "$milestone_id" ]; then
        echo '{"error": "Milestone ID required"}' >&2
        return 1
    fi

    local query='
    query GetMilestone($id: String!) {
        projectMilestone(id: $id) {
            id
            name
            description
            targetDate
            progress
            sortOrder
            createdAt
            updatedAt
            project { id name }
            issues(first: 20) {
                nodes {
                    id
                    identifier
                    title
                    state { name }
                }
            }
        }
    }'

    local variables="{\"id\": \"$milestone_id\"}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply output format
    case "$FORMAT" in
        raw)
            echo "$result"
            ;;
        safe|*)
            format_milestone_single "$result"
            ;;
    esac
}

create_milestone() {
    local project=""
    local name=""
    local description=""
    local target_date=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) project="$2"; shift 2 ;;
            --name) name="$2"; shift 2 ;;
            --description) description="$2"; shift 2 ;;
            --target-date) target_date="$2"; shift 2 ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    if [ -z "$project" ] || [ -z "$name" ]; then
        echo '{"error": "Required: --project and --name"}' >&2
        return 1
    fi

    # Validate field lengths
    if [ -n "$description" ]; then
        validate_length "description" "$description" $LINEAR_LIMIT_SHORT_DESC || return 1
    fi

    local project_id
    project_id=$(resolve_project_id "$project")
    if [ -z "$project_id" ]; then
        echo "{\"error\": \"Project not found: $project\"}" >&2
        return 1
    fi

    # Build input object with proper escaping
    local escaped_name
    escaped_name=$(echo -n "$name" | jq -Rs '.')
    local input_parts=("\"projectId\": \"$project_id\"" "\"name\": $escaped_name")
    if [ -n "$description" ]; then
        local escaped_desc
        escaped_desc=$(echo -n "$description" | jq -Rs '.')
        input_parts+=("\"description\": $escaped_desc")
    fi
    [ -n "$target_date" ] && input_parts+=("\"targetDate\": \"$target_date\"")

    local input_json
    input_json=$(IFS=,; echo "{${input_parts[*]}}")

    local mutation='
    mutation CreateMilestone($input: ProjectMilestoneCreateInput!) {
        projectMilestoneCreate(input: $input) {
            success
            projectMilestone {
                id
                name
                targetDate
                project { name }
            }
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"input\": $input_json}")
    normalize_mutation_response "$result" "projectMilestoneCreate" "projectMilestone"
}

update_milestone() {
    local milestone_id="$1"
    shift

    local name=""
    local description=""
    local target_date=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --description) description="$2"; shift 2 ;;
            --target-date) target_date="$2"; shift 2 ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    # Validate field lengths
    if [ -n "$description" ]; then
        validate_length "description" "$description" $LINEAR_LIMIT_SHORT_DESC || return 1
    fi

    local input_parts=()
    if [ -n "$name" ]; then
        local escaped_name
        escaped_name=$(echo -n "$name" | jq -Rs '.')
        input_parts+=("\"name\": $escaped_name")
    fi
    if [ -n "$description" ]; then
        local escaped_desc
        escaped_desc=$(echo -n "$description" | jq -Rs '.')
        input_parts+=("\"description\": $escaped_desc")
    fi
    [ -n "$target_date" ] && input_parts+=("\"targetDate\": \"$target_date\"")

    if [ ${#input_parts[@]} -eq 0 ]; then
        echo '{"error": "No update options provided"}' >&2
        return 1
    fi

    local input_json
    input_json=$(IFS=,; echo "{${input_parts[*]}}")

    local mutation='
    mutation UpdateMilestone($id: String!, $input: ProjectMilestoneUpdateInput!) {
        projectMilestoneUpdate(id: $id, input: $input) {
            success
            projectMilestone {
                id
                name
                targetDate
            }
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$milestone_id\", \"input\": $input_json}")
    normalize_mutation_response "$result" "projectMilestoneUpdate" "projectMilestone"
}

delete_milestone() {
    local milestone_id="$1"

    local mutation='
    mutation DeleteMilestone($id: String!) {
        projectMilestoneDelete(id: $id) {
            success
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$milestone_id\"}")
    normalize_mutation_response "$result" "projectMilestoneDelete" "projectMilestone"
}

# Main routing
action="${1:-help}"
shift || true

# Fail closed: a write needs a resolved team target before any API call.
linear_guard_write_action "$action" "create update delete" "$@" || exit 1

case "$action" in
    list)
        list_milestones "$@"
        ;;
    get)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: milestones.sh get <id>"}' >&2
            exit 1
        fi
        get_milestone "$@"
        ;;
    create)
        create_milestone "$@"
        ;;
    update)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: milestones.sh update <id> [options]"}' >&2
            exit 1
        fi
        update_milestone "$@"
        ;;
    delete)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: milestones.sh delete <id>"}' >&2
            exit 1
        fi
        delete_milestone "$1"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'milestones.sh --help' for usage." >&2
        exit 1
        ;;
esac
