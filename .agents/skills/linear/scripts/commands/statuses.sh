#!/bin/bash
# Linear GraphQL API - Workflow State Operations
# Usage: statuses.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

show_help() {
    cat << 'EOF'
Workflow State Operations

Usage: statuses.sh <action> [options]

Actions:
  list    List workflow states for a team
  get     Get a single state by name

List Options:
  --team <name>         Team name (default: $LINEAR_TEAM; unset = all teams)

Get Options:
  --team <name>         Team name (default: $LINEAR_TEAM; unset = all teams)
  --name <name>         State name (required)

Examples:
  statuses.sh list
  statuses.sh get --name "In Progress"
EOF
}

list_statuses() {
    local team=""
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --team)
                team="$2"
                shift 2
                ;;
            --format) FORMAT="$2"; shift 2 ;;
            --format=*) FORMAT="${1#--format=}"; shift ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    linear_set_team_target "$team"
    team="$LINEAR_TEAM_TARGET"

    # No configured team means no team filter, never a guessed one.
    local filter_json="{}"
    if [ -n "$team" ]; then
        filter_json="{\"team\": {\"name\": {\"eq\": \"$team\"}}}"
    fi

    local query='
    query ListStates($filter: WorkflowStateFilter) {
        workflowStates(filter: $filter) {
            nodes {
                id
                name
                type
                color
                position
                team { name }
            }
        }
    }'

    local variables="{\"filter\": $filter_json}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply output format
    case "$FORMAT" in
        raw)
            echo "$result"
            ;;
        safe|*)
            format_states_list "$result"
            ;;
    esac
}

get_status() {
    local team=""
    local name=""
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --team)
                team="$2"
                shift 2
                ;;
            --name)
                name="$2"
                shift 2
                ;;
            --format) FORMAT="$2"; shift 2 ;;
            --format=*) FORMAT="${1#--format=}"; shift ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    linear_set_team_target "$team"
    team="$LINEAR_TEAM_TARGET"

    if [ -z "$name" ]; then
        echo '{"error": "Required: --name"}' >&2
        return 1
    fi

    local filter_json="{\"name\": {\"eq\": \"$name\"}}"
    if [ -n "$team" ]; then
        filter_json="{\"team\": {\"name\": {\"eq\": \"$team\"}}, \"name\": {\"eq\": \"$name\"}}"
    fi

    local query='
    query GetState($filter: WorkflowStateFilter) {
        workflowStates(filter: $filter) {
            nodes {
                id
                name
                type
                color
                position
                description
                team { name }
            }
        }
    }'

    local variables="{\"filter\": $filter_json}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply output format - returns first matching state as single object
    case "$FORMAT" in
        raw)
            echo "$result"
            ;;
        safe|*)
            # Return first matching state as flat object
            echo "$result" | jq '.workflowStates.nodes[0] | {
                id: .id,
                name: (.name // ""),
                type: (.type // ""),
                color: (.color // ""),
                position: (.position // 0),
                description: (.description // "")
            }'
            ;;
    esac
}

# Main routing
action="${1:-help}"
shift || true

case "$action" in
    list)
        list_statuses "$@"
        ;;
    get)
        get_status "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'statuses.sh --help' for usage." >&2
        exit 1
        ;;
esac
