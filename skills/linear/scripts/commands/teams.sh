#!/bin/bash
# Linear GraphQL API - Team Operations
# Usage: teams.sh <action> [options]
# `keys` prints {urlKey: string, keys: string[]} for Slack's outbound linker.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    cat << 'EOF'
Team Operations

Usage: teams.sh <action> [options]

Actions:
  list    List teams
  get     Get a single team by ID, key or name
  keys    Read the workspace URL key and all team keys

List Options:
  --limit <n>           Max results (default: 75); a larger value spans pages
  --max                 Read every page; a chain that fails partway refuses

Get:
  teams.sh get <id-or-name>

Examples:
  teams.sh list
  teams.sh get "<team-name>"
EOF
}
case "${1:-help}" in help|--help|-h) show_help; exit 0 ;; esac

source "$SCRIPT_DIR/../lib/common.sh"

list_teams() {
    linear_list_reset
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
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

    local query='
    query ListTeams($first: Int, $after: String) {
        teams(first: $first, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
                id
                name
                key
                description
                members { pageInfo { hasNextPage endCursor } nodes { name email } }
                createdAt
            }
        }
    }'

    local variables='{}'
    local result
    result=$(linear_list_read "$query" "$variables" teams) || return 1

    # Apply output format
    case "$FORMAT" in
        raw)
            linear_public_result "$result"
            ;;
        safe|*)
            format_teams_list "$result"
            ;;
    esac
}

team_keys() {
    local result
    result=$(graphql_query 'query TeamKeys { organization { urlKey teams { pageInfo { hasNextPage endCursor } nodes { key } } } }' '{}') || return $?
    jq -e '{urlKey: .organization.urlKey, keys: [.organization.teams.nodes[].key]}' <<<"$result"
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
        echo '{"error": "Team ID, key or name required"}' >&2
        return 1
    fi

    local team_id
    team_id=$(resolve_team_id "$team_ref") || return 1

    local query='
    query GetTeam($id: String!) {
        team(id: $id) {
            id
            name
            key
            description
            members { pageInfo { hasNextPage endCursor } nodes { name email } }
            labels { pageInfo { hasNextPage endCursor } nodes { name color } }
            states { pageInfo { hasNextPage endCursor } nodes { name type position } }
            createdAt
            updatedAt
        }
    }'

    local variables="{\"id\": \"$team_id\"}"
    local result
    result=$(graphql_query "$query" "$variables") || return 1

    # Apply output format
    case "$FORMAT" in
        raw)
            linear_public_result "$result"
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
    keys)
        team_keys "$@"
        ;;
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
