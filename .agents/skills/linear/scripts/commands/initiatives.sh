#!/bin/bash
# Linear GraphQL API - Initiative Operations
# Usage: initiatives.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    cat << 'EOF'
Initiative Operations

Usage: initiatives.sh <action> [options]

Actions:
  list           List all initiatives
  get            Get a single initiative by ID
  create         Create a new initiative
  update         Update an existing initiative
  delete         Delete an initiative
  add-project    Add a project to an initiative
  remove-project Remove a project from an initiative

List Options:
  --status <status>  Filter by status (Planned, Active, Completed)
  --limit <n>        Max results (default: 50)

Create Options:
  --name <text>         Initiative name (required)
  --description <text>  Short summary (max 255 chars, shows as subtitle)
  --content <text>      Long description (markdown, shows in body)
  --target-date <date>  Target date (YYYY-MM-DD)
  --status <status>     Status: Planned, Active, Completed (default: Planned)

Update Options:
  --name <text>         New name
  --description <text>  Short summary (max 255 chars)
  --content <text>      Long description (markdown)
  --target-date <date>  New target date
  --status <status>     New status

Add/Remove Project Options:
  --project <id-or-name>  Project ID or name (required)

Examples:
  initiatives.sh list
  initiatives.sh list --status Active
  initiatives.sh get <initiative-id>
  initiatives.sh create --name "Phase 1: Linux Foundation" --target-date 2025-03-31
  initiatives.sh update <id> --status Active
  initiatives.sh add-project <initiative-id> --project "Market Data Pipeline"
  initiatives.sh remove-project <initiative-id> --project "Market Data Pipeline"
  initiatives.sh delete <id>
EOF
}
case "${1:-help}" in help|--help|-h) show_help; exit 0 ;; esac

source "$SCRIPT_DIR/../lib/common.sh"

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

list_initiatives() {
    local status=""
    local first=75
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status) status="$2"; shift 2 ;;
            --limit) first="$2"; shift 2 ;;
            --format) FORMAT="$2"; shift 2 ;;
            --format=*) FORMAT="${1#--format=}"; shift ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    local filter_json="{}"
    if [ -n "$status" ]; then
        filter_json="{\"status\": {\"eq\": \"$status\"}}"
    fi

    local query='
    query ListInitiatives($filter: InitiativeFilter, $first: Int) {
        initiatives(filter: $filter, first: $first) {
            nodes {
                id
                name
                description
                content
                status
                health
                targetDate
                projects { nodes { id name state } }
                createdAt
                updatedAt
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
            format_initiatives_list "$result"
            ;;
    esac
}

get_initiative() {
    local initiative_id=""
    FORMAT="${DEFAULT_FORMAT}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) FORMAT="$2"; shift 2 ;;
            --format=*) FORMAT="${1#--format=}"; shift ;;
            *) initiative_id="$1"; shift ;;
        esac
    done

    if [ -z "$initiative_id" ]; then
        echo '{"error": "Initiative ID required"}' >&2
        return 1
    fi

    local query='
    query GetInitiative($id: String!) {
        initiative(id: $id) {
            id
            name
            description
            content
            status
            health
            healthUpdatedAt
            targetDate
            url
            owner { name email }
            lastUpdate {
                id
                body
                health
                createdAt
            }
            projects {
                nodes {
                    id
                    name
                    state
                    progress
                    health
                }
            }
            createdAt
            updatedAt
        }
    }'

    local variables="{\"id\": \"$initiative_id\"}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply output format
    case "$FORMAT" in
        raw)
            echo "$result"
            ;;
        safe|*)
            format_initiative_single "$result"
            ;;
    esac
}

create_initiative() {
    local name=""
    local description=""
    local content=""
    local target_date=""
    local status="Planned"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --description) description="$2"; shift 2 ;;
            --content) content="$2"; shift 2 ;;
            --target-date) target_date="$2"; shift 2 ;;
            --status) status="$2"; shift 2 ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    if [ -z "$name" ]; then
        echo '{"error": "Required: --name"}' >&2
        return 1
    fi

    # Validate field lengths (description is short summary, content is long body)
    if [ -n "$description" ]; then
        validate_length "description" "$description" $LINEAR_LIMIT_SHORT_DESC || return 1
    fi

    # Build input JSON using jq for proper escaping
    local input_json
    input_json=$(jq -n --arg name "$name" '{name: $name}')
    [ -n "$description" ] && input_json=$(echo "$input_json" | jq --arg v "$description" '. + {description: $v}')
    [ -n "$content" ] && input_json=$(echo "$input_json" | jq --arg v "$content" '. + {content: $v}')
    [ -n "$target_date" ] && input_json=$(echo "$input_json" | jq --arg v "$target_date" '. + {targetDate: $v}')
    [ -n "$status" ] && input_json=$(echo "$input_json" | jq --arg v "$status" '. + {status: $v}')

    local mutation='
    mutation CreateInitiative($input: InitiativeCreateInput!) {
        initiativeCreate(input: $input) {
            success
            initiative {
                id
                name
                status
                url
            }
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"input\": $input_json}")
    normalize_mutation_response "$result" "initiativeCreate" "initiative"
}

update_initiative() {
    local initiative_id="$1"
    shift

    local name=""
    local description=""
    local content=""
    local target_date=""
    local status=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --description) description="$2"; shift 2 ;;
            --content) content="$2"; shift 2 ;;
            --target-date) target_date="$2"; shift 2 ;;
            --status) status="$2"; shift 2 ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    # Validate field lengths (description is short summary, content is long body)
    if [ -n "$description" ]; then
        validate_length "description" "$description" $LINEAR_LIMIT_SHORT_DESC || return 1
    fi

    # Build input JSON using jq for proper escaping
    local input_json="{}"
    [ -n "$name" ] && input_json=$(echo "$input_json" | jq --arg v "$name" '. + {name: $v}')
    [ -n "$description" ] && input_json=$(echo "$input_json" | jq --arg v "$description" '. + {description: $v}')
    [ -n "$content" ] && input_json=$(echo "$input_json" | jq --arg v "$content" '. + {content: $v}')
    [ -n "$target_date" ] && input_json=$(echo "$input_json" | jq --arg v "$target_date" '. + {targetDate: $v}')
    [ -n "$status" ] && input_json=$(echo "$input_json" | jq --arg v "$status" '. + {status: $v}')

    if [ "$input_json" = "{}" ]; then
        echo '{"error": "No update options provided"}' >&2
        return 1
    fi

    local mutation='
    mutation UpdateInitiative($id: String!, $input: InitiativeUpdateInput!) {
        initiativeUpdate(id: $id, input: $input) {
            success
            initiative {
                id
                name
                status
            }
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$initiative_id\", \"input\": $input_json}")
    normalize_mutation_response "$result" "initiativeUpdate" "initiative"
}

delete_initiative() {
    local initiative_id="$1"

    local mutation='
    mutation DeleteInitiative($id: String!) {
        initiativeDelete(id: $id) {
            success
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$initiative_id\"}")
    normalize_mutation_response "$result" "initiativeDelete" "initiative"
}

add_project() {
    local initiative_id="$1"
    shift

    local project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) project="$2"; shift 2 ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    if [ -z "$project" ]; then
        echo '{"error": "Required: --project"}' >&2
        return 1
    fi

    local project_id
    project_id=$(resolve_project_id "$project")
    if [ -z "$project_id" ]; then
        echo "{\"error\": \"Project not found: $project\"}" >&2
        return 1
    fi

    local mutation='
    mutation AddProjectToInitiative($input: InitiativeToProjectCreateInput!) {
        initiativeToProjectCreate(input: $input) {
            success
            initiativeToProject {
                id
                initiative { name }
                project { name }
            }
        }
    }'

    local input="{\"initiativeId\": \"$initiative_id\", \"projectId\": \"$project_id\"}"
    local result
    result=$(graphql_query "$mutation" "{\"input\": $input}")
    normalize_mutation_response "$result" "initiativeToProjectCreate" "initiativeToProject"
}

remove_project() {
    local initiative_id="$1"
    shift

    local project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) project="$2"; shift 2 ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    if [ -z "$project" ]; then
        echo '{"error": "Required: --project"}' >&2
        return 1
    fi

    local project_id
    project_id=$(resolve_project_id "$project")
    if [ -z "$project_id" ]; then
        echo "{\"error\": \"Project not found: $project\"}" >&2
        return 1
    fi

    # Find the InitiativeToProject link ID via top-level query
    local link_query='
    query GetInitiativeLinks {
        initiativeToProjects(first: 250) {
            nodes { id initiative { id } project { id } }
        }
    }'

    local link_result
    link_result=$(graphql_query "$link_query" "{}")
    local link_id
    link_id=$(echo "$link_result" | jq -r --arg iid "$initiative_id" --arg pid "$project_id" '.initiativeToProjects.nodes[] | select(.initiative.id == $iid and .project.id == $pid) | .id')

    if [ -z "$link_id" ]; then
        echo "{\"error\": \"Project not linked to this initiative\"}" >&2
        return 1
    fi

    # Delete by link entity ID
    local mutation='
    mutation RemoveProjectFromInitiative($id: String!) {
        initiativeToProjectDelete(id: $id) {
            success
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$link_id\"}")
    normalize_mutation_response "$result" "initiativeToProjectDelete" "initiativeToProject"
}

# Main routing
action="${1:-help}"
shift || true

# Fail closed: a write needs a resolved team target before any API call.
linear_guard_write_action "$action" "create update delete add-project remove-project" "$@" || exit 1

case "$action" in
    list)
        list_initiatives "$@"
        ;;
    get)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: initiatives.sh get <id>"}' >&2
            exit 1
        fi
        get_initiative "$1"
        ;;
    create)
        create_initiative "$@"
        ;;
    update)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: initiatives.sh update <id> [options]"}' >&2
            exit 1
        fi
        update_initiative "$@"
        ;;
    delete)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: initiatives.sh delete <id>"}' >&2
            exit 1
        fi
        delete_initiative "$1"
        ;;
    add-project)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: initiatives.sh add-project <initiative-id> --project <project-id-or-name>"}' >&2
            exit 1
        fi
        add_project "$@"
        ;;
    remove-project)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: initiatives.sh remove-project <initiative-id> --project <project-id-or-name>"}' >&2
            exit 1
        fi
        remove_project "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'initiatives.sh --help' for usage." >&2
        exit 1
        ;;
esac
