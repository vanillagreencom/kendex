#!/bin/bash
# Linear GraphQL API - Cycle Operations
# Usage: cycles.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

show_help() {
    cat << 'EOF'
Cycle Operations

Usage: cycles.sh <action> [options]

Actions:
  list    List cycles for a team
  create  Create a new cycle
  update  Update a cycle (name, dates)

List Options:
  --team <name>         Team name (default: $LINEAR_TEAM; unset = all teams)
  --type <type>         Filter: current, previous, next, or all (default: all)
  --limit <n>           Max results (default: 50)

Create Options:
  --name <text>         Cycle name (optional, defaults to "Cycle N")
  --team <name>         Team name (default: $LINEAR_TEAM; required when unset)
  --start <date>        Start date (YYYY-MM-DD, required)
  --end <date>          End date (YYYY-MM-DD, required)

Update Options:
  --id <uuid>           Cycle ID (required)
  --name <text>         New name (use "" to clear)
  --start <date>        New start date (YYYY-MM-DD)
  --end <date>          New end date (YYYY-MM-DD)

Examples:
  cycles.sh list
  cycles.sh list --type current
  cycles.sh list --type previous
  cycles.sh create --start 2025-11-27 --end 2025-12-11
  cycles.sh update --id <uuid> --name ""
EOF
}

list_cycles() {
    local team=""
    local cycle_type=""
    local first=75
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --team)
                team="$2"
                shift 2
                ;;
            --type)
                cycle_type="$2"
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

    linear_set_team_target "$team"
    team="$LINEAR_TEAM_TARGET"

    # No configured team means no team filter, never a guessed one.
    local filter_parts=()
    if [ -n "$team" ]; then
        # Get team ID
        local team_query='query GetTeam($name: String!) { teams(filter: {name: {eq: $name}}) { nodes { id } } }'
        local team_result
        team_result=$(graphql_query "$team_query" "{\"name\": \"$team\"}")
        local team_id
        team_id=$(echo "$team_result" | jq -r '.teams.nodes[0].id // empty')
        if [ -z "$team_id" ]; then
            echo "{\"error\": \"Team not found: $team\"}" >&2
            return 1
        fi
        filter_parts+=("\"team\": {\"id\": {\"eq\": \"$team_id\"}}")
    fi

    # Add cycle type filter
    case "$cycle_type" in
        current)
            filter_parts+=("\"isActive\": {\"eq\": true}")
            ;;
        previous)
            filter_parts+=("\"isPast\": {\"eq\": true}")
            ;;
        next)
            filter_parts+=("\"isNext\": {\"eq\": true}")
            ;;
    esac

    local filter_json="{}"
    if [ ${#filter_parts[@]} -gt 0 ]; then
        filter_json=$(IFS=,; echo "{${filter_parts[*]}}")
    fi

    local query='
    query ListCycles($filter: CycleFilter, $first: Int) {
        cycles(filter: $filter, first: $first) {
            nodes {
                id
                number
                name
                startsAt
                endsAt
                progress
                issueCountHistory
                completedIssueCountHistory
                team { name }
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
            format_cycles_list "$result"
            ;;
    esac
}

create_cycle() {
    local team=""
    local name=""
    local start_date=""
    local end_date=""

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
            --start)
                start_date="$2"
                shift 2
                ;;
            --end)
                end_date="$2"
                shift 2
                ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    # Resolve the team target and validate required fields
    linear_set_team_target "$team"
    linear_require_team_target || return 1
    team="$LINEAR_TEAM_TARGET"
    if [ -z "$start_date" ]; then
        echo '{"error": "Required: --start (YYYY-MM-DD)"}' >&2
        return 1
    fi
    if [ -z "$end_date" ]; then
        echo '{"error": "Required: --end (YYYY-MM-DD)"}' >&2
        return 1
    fi

    # Get team ID
    local team_query='query GetTeam($name: String!) { teams(filter: {name: {eq: $name}}) { nodes { id } } }'
    local team_result
    team_result=$(graphql_query "$team_query" "{\"name\": \"$team\"}")
    local team_id
    team_id=$(echo "$team_result" | jq -r '.teams.nodes[0].id // empty')
    if [ -z "$team_id" ]; then
        echo "{\"error\": \"Team not found: $team\"}" >&2
        return 1
    fi

    # Build input object
    local input_parts=()
    input_parts+=("\"teamId\": \"$team_id\"")
    input_parts+=("\"startsAt\": \"${start_date}T00:00:00.000Z\"")
    input_parts+=("\"endsAt\": \"${end_date}T23:59:59.999Z\"")

    if [ -n "$name" ]; then
        # Escape name for JSON
        local escaped_name
        escaped_name=$(echo "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')
        input_parts+=("\"name\": \"$escaped_name\"")
    fi

    local input_json
    input_json=$(IFS=,; echo "{${input_parts[*]}}")

    local query='
    mutation CreateCycle($input: CycleCreateInput!) {
        cycleCreate(input: $input) {
            success
            cycle {
                id
                number
                name
                startsAt
                endsAt
                team { name }
            }
        }
    }'

    local variables="{\"input\": $input_json}"
    graphql_query "$query" "$variables"
}

update_cycle() {
    local cycle_id=""
    local name=""
    local name_set=false
    local start_date=""
    local end_date=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id)
                cycle_id="$2"
                shift 2
                ;;
            --name)
                name="$2"
                name_set=true
                shift 2
                ;;
            --start)
                start_date="$2"
                shift 2
                ;;
            --end)
                end_date="$2"
                shift 2
                ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    if [ -z "$cycle_id" ]; then
        echo '{"error": "Required: --id <cycle-uuid>"}' >&2
        return 1
    fi

    # Build input object
    local input_parts=()

    if [ "$name_set" = true ]; then
        if [ -z "$name" ]; then
            input_parts+=("\"name\": null")
        else
            local escaped_name
            escaped_name=$(echo "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')
            input_parts+=("\"name\": \"$escaped_name\"")
        fi
    fi

    if [ -n "$start_date" ]; then
        input_parts+=("\"startsAt\": \"${start_date}T00:00:00.000Z\"")
    fi

    if [ -n "$end_date" ]; then
        input_parts+=("\"endsAt\": \"${end_date}T23:59:59.999Z\"")
    fi

    if [ ${#input_parts[@]} -eq 0 ]; then
        echo '{"error": "No fields to update. Use --name, --start, or --end"}' >&2
        return 1
    fi

    local input_json
    input_json=$(IFS=,; echo "{${input_parts[*]}}")

    local query='
    mutation UpdateCycle($id: String!, $input: CycleUpdateInput!) {
        cycleUpdate(id: $id, input: $input) {
            success
            cycle {
                id
                number
                name
                startsAt
                endsAt
            }
        }
    }'

    local variables="{\"id\": \"$cycle_id\", \"input\": $input_json}"
    graphql_query "$query" "$variables"
}

# Main routing
action="${1:-help}"
shift || true

# Fail closed: a write needs a resolved team target before any API call.
linear_guard_write_action "$action" "create update" "$@" || exit 1

case "$action" in
    list)
        list_cycles "$@"
        ;;
    create)
        create_cycle "$@"
        ;;
    update)
        update_cycle "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'cycles.sh --help' for usage." >&2
        exit 1
        ;;
esac
