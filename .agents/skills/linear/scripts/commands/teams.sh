#!/bin/bash
# Linear GraphQL API - Team Operations
# Usage: teams.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

show_help() {
    cat << 'EOF'
Team Operations

Usage: teams.sh <action> [options]

Actions:
  list    List teams
  get     Get a single team by ID or name

List Options:
  --limit <n>           Max results (default: 50)

Get:
  teams.sh get <id-or-name>

Examples:
  teams.sh list
  teams.sh get "<team-name>"
EOF
}

list_teams() {
    local first=75
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
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

    local query='
    query ListTeams($first: Int) {
        teams(first: $first) {
            nodes {
                id
                name
                key
                description
                members { nodes { name email } }
                createdAt
            }
        }
    }'

    local variables="{\"first\": $first}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply output format
    case "$FORMAT" in
        raw)
            echo "$result"
            ;;
        safe|*)
            format_teams_list "$result"
            ;;
    esac
}

get_team() {
    local team_ref=""
    FORMAT="${DEFAULT_FORMAT}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) FORMAT="$2"; shift 2 ;;
            --format=*) FORMAT="${1#--format=}"; shift ;;
            *) team_ref="$1"; shift ;;
        esac
    done

    if [ -z "$team_ref" ]; then
        echo '{"error": "Team ID or name required"}' >&2
        return 1
    fi

    # Check if it's a UUID or a name - resolve name to ID if needed
    local team_id="$team_ref"
    if ! [[ "$team_ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        # Look up by name
        local lookup_query='query GetTeamByName($name: String!) { teams(filter: {name: {eq: $name}}) { nodes { id } } }'
        local lookup_result
        lookup_result=$(graphql_query "$lookup_query" "{\"name\": \"$team_ref\"}")
        team_id=$(echo "$lookup_result" | jq -r '.teams.nodes[0].id // empty')
        if [ -z "$team_id" ]; then
            echo "{\"error\": \"Team not found: $team_ref\"}" >&2
            return 1
        fi
    fi

    local query='
    query GetTeam($id: String!) {
        team(id: $id) {
            id
            name
            key
            description
            members { nodes { name email } }
            labels { nodes { name color } }
            states { nodes { name type position } }
            createdAt
            updatedAt
        }
    }'

    local variables="{\"id\": \"$team_id\"}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply output format
    case "$FORMAT" in
        raw)
            echo "$result"
            ;;
        safe|*)
            format_team_single "$result"
            ;;
    esac
}

# Main routing
action="${1:-help}"
shift || true

case "$action" in
    list)
        list_teams "$@"
        ;;
    get)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: teams.sh get <id-or-name>"}' >&2
            exit 1
        fi
        get_team "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'teams.sh --help' for usage." >&2
        exit 1
        ;;
esac
