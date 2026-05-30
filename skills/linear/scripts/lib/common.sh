#!/bin/bash
# Linear GraphQL API - Common functions
# Source this file in command scripts

set -euo pipefail

# Configuration
LINEAR_API="https://api.linear.app/graphql"

# Default values - can be overridden in .env.local
# LINEAR_TEAM, LINEAR_FORMAT, LINEAR_TEAM_PREFIX set in .env.local take precedence
DEFAULT_TEAM="${LINEAR_TEAM:-Claude}"
DEFAULT_FORMAT="${LINEAR_FORMAT:-safe}"    # safe, raw, ids, table
DEFAULT_PREFIX="${LINEAR_TEAM_PREFIX:-PROJ}" # Issue identifier prefix (e.g., PROJ-123)

# Linear API field limits (discovered through testing)
LINEAR_LIMIT_SHORT_DESC=255    # Initiatives, projects, milestones, labels
LINEAR_LIMIT_ISSUE_DESC=100000 # Issues have no practical limit

# Internal lib directory (underscore prefix avoids overwriting caller's SCRIPT_DIR)
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"

# Source formatters
source "$_LIB_DIR/formatters.sh"

# Load API key from .env.local or .env if not already set
if [ -z "${LINEAR_API_KEY:-}" ]; then
    if [ -f "$PROJECT_ROOT/.env.local" ]; then
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/.env.local"
    elif [ -f "$PROJECT_ROOT/.env" ]; then
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/.env"
    fi
fi

# Resolve 1Password references when the env file contains op:// secrets.
resolve_linear_api_key() {
    local token="${LINEAR_API_KEY:-}"

    if [[ -z "$token" ]]; then
        return 0
    fi

    if [[ "$token" == op://* ]]; then
        if command -v op &>/dev/null; then
            local resolved
            if resolved=$(op read "$token" 2>/dev/null); then
                LINEAR_API_KEY="$resolved"
                export LINEAR_API_KEY
            else
                echo '{"error": "Failed to resolve LINEAR_API_KEY from 1Password. Run: op signin"}' >&2
                return 1
            fi
        else
            echo '{"error": "LINEAR_API_KEY is a 1Password reference but the op CLI is not installed"}' >&2
            return 1
        fi
    fi

    return 0
}

# Most commands hit the Linear API and should resolve op:// references during
# startup so authentication failures surface before any mutation/read work.
# Local-cache commands source this file only for shared formatters/defaults; they
# must not require API auth for documented cache-only reads.
if [[ "${LINEAR_SKIP_API_KEY_RESOLUTION:-}" != "1" ]]; then
    resolve_linear_api_key || exit 1
fi

# Validate API key
check_api_key() {
    if [ -z "${LINEAR_API_KEY:-}" ]; then
        echo '{"error": "LINEAR_API_KEY not set. Add it to .env.local or export it."}' >&2
        exit 1
    fi
}

json_or_default() {
    local fallback="$1"
    local expected_type="$2"
    shift 2

    local output=""
    if ! output=$("$@" 2>/dev/null); then
        :
    fi

    if ! jq -e --arg type "$expected_type" 'type == $type' >/dev/null 2>&1 <<<"$output"; then
        output="$fallback"
    fi

    printf '%s' "$output"
}

curl_config_quote() {
    printf '%s' "$1" | jq -Rs .
}

# Validate field length and return error if exceeded
# Usage: validate_length "field_name" "$value" $max_length
validate_length() {
    local field="$1"
    local value="$2"
    local max="$3"
    local len=${#value}

    if [ $len -gt $max ]; then
        echo "{\"error\": \"$field exceeds max length ($len > $max chars)\"}" >&2
        return 1
    fi
    return 0
}

# Make GraphQL request with error handling and retry
# Usage: graphql_query "query string" '{"var": "value"}'
graphql_query() {
    local query="$1"
    local variables="$2"
    if [ -z "$variables" ]; then
        variables='{}'
    fi
    local max_retries=3
    local retry_delay=1
    local attempt=1

    check_api_key

    while [ $attempt -le $max_retries ]; do
        local response
        local http_code
        local payload

        # Use unique delimiter to separate response from HTTP code
        # This handles JSON with literal newlines in string values
        local delimiter="___HTTP_CODE___"
        local raw_output
        if ! payload=$(jq -cn --arg query "$(echo "$query" | tr '\n' ' ')" --argjson variables "$variables" \
            '{query: $query, variables: $variables}'); then
            echo '{"error": "Invalid GraphQL variables JSON"}' >&2
            return 1
        fi

        if ! raw_output=$(
            printf '%s\n' \
                "url = $(curl_config_quote "$LINEAR_API")" \
                'request = "POST"' \
                "header = $(curl_config_quote "Content-Type: application/json")" \
                "header = $(curl_config_quote "Authorization: $LINEAR_API_KEY")" \
                "data = $(curl_config_quote "$payload")" \
            | curl -s -w "${delimiter}%{http_code}" -K -
        ); then
            raw_output="${delimiter}000"
        fi

        http_code="${raw_output##*${delimiter}}"
        response="${raw_output%${delimiter}*}"

        # Handle HTTP errors
        case "$http_code" in
        200)
            # Check for GraphQL errors
            local errors
            errors=$(echo "$response" | jq -r '.errors // empty')
            if [ -n "$errors" ] && [ "$errors" != "null" ]; then
                local error_msg
                error_msg=$(echo "$response" | jq -r '.errors[0].message')
                # Translate common errors to actionable messages
                case "$error_msg" in
                *"labelIds not exclusive"*)
                    echo '{"error": "Label conflict: Mutually exclusive label groups detected. Check --labels for conflicting group labels"}' >&2
                    ;;
                *"Issue not found"*)
                    echo '{"error": "Issue not found. Check the identifier (e.g., PROJ-42)"}' >&2
                    ;;
                *"Project not found"*)
                    echo '{"error": "Project not found. Use exact name or UUID"}' >&2
                    ;;
                *"relation"*"exist"* | *"already exist"* | *"duplicate"*"relation"*)
                    # Idempotent: relation/dependency already exists — not an error
                    echo '{"already_exists": true}' >&2
                    echo '{"already_exists": true}'
                    return 0
                    ;;
                *)
                    echo "$response" | jq -c '{error: .errors[0].message}' >&2
                    ;;
                esac
                return 1
            fi
            # Success - return data
            echo "$response" | jq -c '.data'
            return 0
            ;;
        401)
            echo '{"error": "Authentication failed. Check your LINEAR_API_KEY."}' >&2
            return 1
            ;;
        429)
            if [ $attempt -lt $max_retries ]; then
                sleep $retry_delay
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
                continue
            fi
            echo '{"error": "Rate limited. Try again later."}' >&2
            return 1
            ;;
        *)
            if [ $attempt -lt $max_retries ]; then
                sleep $retry_delay
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
                continue
            fi
            echo "{\"error\": \"HTTP error: $http_code\"}" >&2
            return 1
            ;;
        esac
    done
}

# Parse common CLI arguments into GraphQL filter
# Usage: parse_filter "$@"
# Sets global FILTER_JSON variable
parse_filter() {
    local filter_parts=()
    local first=75
    local include_archived="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --label)
            filter_parts+=("\"labels\": {\"name\": {\"eq\": \"$2\"}}")
            shift 2
            ;;
        --state | --status)
            # Handle comma-separated states
            IFS=',' read -ra states <<<"$2"
            if [ ${#states[@]} -eq 1 ]; then
                filter_parts+=("\"state\": {\"name\": {\"eq\": \"$2\"}}")
            else
                local state_json
                state_json=$(printf '"%s",' "${states[@]}" | sed 's/,$//')
                filter_parts+=("\"state\": {\"name\": {\"in\": [$state_json]}}")
            fi
            shift 2
            ;;
        --project)
            filter_parts+=("\"project\": {\"name\": {\"eq\": \"$2\"}}")
            shift 2
            ;;
        --project-id)
            filter_parts+=("\"project\": {\"id\": {\"eq\": \"$2\"}}")
            shift 2
            ;;
        --team)
            filter_parts+=("\"team\": {\"name\": {\"eq\": \"$2\"}}")
            shift 2
            ;;
        --assignee)
            if [ "$2" = "me" ]; then
                filter_parts+=("\"assignee\": {\"isMe\": {\"eq\": true}}")
            else
                filter_parts+=("\"assignee\": {\"name\": {\"eq\": \"$2\"}}")
            fi
            shift 2
            ;;
        --updated-since)
            # Convert "7d" format to ISO date
            local days="${2%d}"
            local date
            date=$(date -d "-$days days" -Iseconds 2>/dev/null || date -v-"${days}"d -Iseconds)
            filter_parts+=("\"updatedAt\": {\"gte\": \"$date\"}")
            shift 2
            ;;
        --created-since)
            local days="${2%d}"
            local date
            date=$(date -d "-$days days" -Iseconds 2>/dev/null || date -v-"${days}"d -Iseconds)
            filter_parts+=("\"createdAt\": {\"gte\": \"$date\"}")
            shift 2
            ;;
        --limit)
            first="$2"
            shift 2
            ;;
        --include-archived)
            include_archived="true"
            shift
            ;;
        --*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *)
            # Positional argument - skip
            shift
            ;;
        esac
    done

    # Build filter JSON
    if [ ${#filter_parts[@]} -gt 0 ]; then
        FILTER_JSON=$(
            IFS=,
            echo "{${filter_parts[*]}}"
        )
    else
        FILTER_JSON="{}"
    fi
    FIRST_JSON="$first"
    INCLUDE_ARCHIVED_JSON="$include_archived"
}

# Resolve issue identifier (CC-XXX) or UUID to UUID
# Usage: resolve_issue_id "PROJ-42" or resolve_issue_id "uuid-here"
resolve_issue_id() {
    local issue_ref="$1"

    # Check if it's already a UUID
    if [[ "$issue_ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$issue_ref"
        return 0
    fi

    # Look up by identifier (e.g., PROJ-42)
    local query='query GetIssue($id: String!) { issue(id: $id) { id } }'
    local result
    result=$(graphql_query "$query" "{\"id\": \"$issue_ref\"}")
    local issue_id
    issue_id=$(echo "$result" | jq -r '.issue.id // empty')

    if [ -z "$issue_id" ]; then
        echo "" >&2
        return 1
    fi

    echo "$issue_id"
}

# Normalize mutation response to consistent structure
# Usage: normalize_mutation_response "$result" "issueCreate" "issue"
# Returns: {"success": bool, "identifier": "CC-XXX", "url": "...", "data": {...}}
normalize_mutation_response() {
    local result="$1"
    local operation="$2"
    local entity="$3"

    echo "$result" | jq --arg op "$operation" --arg ent "$entity" '{
        success: .[$op].success,
        identifier: .[$op][$ent].identifier,
        url: (.[$op][$ent].url // null),
        data: .[$op]
    }'
}

# Normalize query response - maps GraphQL field names to resource names
# Usage: normalize_query_response "$result" "issueLabels" "labels"
# Adds aliased key so both .issueLabels.nodes[] and .labels.nodes[] work
normalize_query_response() {
    local result="$1"
    local graphql_key="$2"
    local resource_key="$3"

    echo "$result" | jq --arg gql "$graphql_key" --arg res "$resource_key" \
        '. + {($res): .[$gql]}'
}

# Output formatting helpers (legacy, kept for compatibility)
format_issues() {
    jq -r '.issues.nodes[] | "\(.identifier)\t\(.title)\t\(.state.name)"' 2>/dev/null || echo "No issues found"
}

format_json() {
    jq '.' 2>/dev/null || cat
}

# Parse --format argument from args
# Usage: parse_format_arg "$@"
# Sets FORMAT global variable, returns remaining args
# Example: parse_format_arg --format ids --label foo → FORMAT=ids, returns "--label foo"
parse_format_arg() {
    FORMAT="${DEFAULT_FORMAT}"
    local remaining_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        *)
            remaining_args+=("$1")
            shift
            ;;
        esac
    done

    # Validate format
    case "$FORMAT" in
    safe | raw | ids | table) ;;
    *)
        echo "{\"error\": \"Invalid format: $FORMAT. Use: safe, raw, ids, table\"}" >&2
        return 1
        ;;
    esac

    # Return remaining args
    echo "${remaining_args[@]:-}"
}

# Apply team default if not specified
# Usage: team=$(apply_team_default "$team")
apply_team_default() {
    local team="${1:-}"
    echo "${team:-${DEFAULT_TEAM}}"
}

# Resolve project name or UUID to UUID
# Usage: resolve_project_id "Phase 1" or resolve_project_id "uuid-here"
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
        echo "{\"error\": \"Project not found: $project_ref\"}" >&2
        return 1
    fi

    echo "$project_id"
}

# Resolve team name to UUID
# Usage: resolve_team_id "claude"
resolve_team_id() {
    local team_ref="$1"

    # Check if it's already a UUID
    if [[ "$team_ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$team_ref"
        return 0
    fi

    # Look up by name
    local query='query GetTeam($name: String!) { teams(filter: {name: {eq: $name}}) { nodes { id } } }'
    local result
    result=$(graphql_query "$query" "{\"name\": \"$team_ref\"}")
    local team_id
    team_id=$(echo "$result" | jq -r '.teams.nodes[0].id // empty')

    if [ -z "$team_id" ]; then
        echo "{\"error\": \"Team not found: $team_ref\"}" >&2
        return 1
    fi

    echo "$team_id"
}

# Resolve workflow state name to UUID for a specific team
# Usage: resolve_state_id "In Progress" "team-uuid-or-name"
# Second arg can be team UUID or team name (will resolve)
resolve_state_id() {
    local state_name="$1"
    local team_ref="$2"

    # Resolve team to ID if needed (resolve_team_id handles UUID pass-through)
    local team_id
    team_id=$(resolve_team_id "$team_ref")
    if [ -z "$team_id" ]; then
        return 1
    fi

    # Look up state by name + team
    local query='query GetState($name: String!, $teamId: ID!) { workflowStates(filter: {name: {eq: $name}, team: {id: {eq: $teamId}}}) { nodes { id } } }'
    local result
    result=$(graphql_query "$query" "{\"name\": \"$state_name\", \"teamId\": \"$team_id\"}")
    local state_id
    state_id=$(echo "$result" | jq -r '.workflowStates.nodes[0].id // empty')

    if [ -z "$state_id" ]; then
        # Fetch available states for helpful error
        local all_query='query GetStates($teamId: ID!) { workflowStates(filter: {team: {id: {eq: $teamId}}}) { nodes { name } } }'
        local all_result
        all_result=$(graphql_query "$all_query" "{\"teamId\": \"$team_id\"}")
        local available
        available=$(echo "$all_result" | jq -r '[.workflowStates.nodes[].name] | join(", ")')
        echo "{\"error\": \"State not found: '$state_name'. Available: $available\"}" >&2
        return 1
    fi

    echo "$state_id"
}

# Resolve label name to UUID
# Usage: resolve_label_id "backend"
# Warns on miss (non-fatal for callers that handle multiple labels)
resolve_label_id() {
    local label_name="$1"

    local query='query GetLabel($name: String!) { issueLabels(filter: {name: {eq: $name}}) { nodes { id } } }'
    local result
    result=$(graphql_query "$query" "{\"name\": \"$label_name\"}")
    local label_id
    label_id=$(echo "$result" | jq -r '.issueLabels.nodes[0].id // empty')

    if [ -z "$label_id" ]; then
        echo "Warning: Label not found: '$label_name' (skipped)" >&2
        return 1
    fi

    echo "$label_id"
}

# Resolve milestone name or UUID to UUID
# Usage: resolve_milestone_id "Alpha" or resolve_milestone_id "uuid-here"
resolve_milestone_id() {
    local milestone_ref="$1"

    # Check if it's already a UUID
    if [[ "$milestone_ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$milestone_ref"
        return 0
    fi

    # Look up by name
    local query='query GetMilestone($name: String!) { projectMilestones(filter: {name: {eq: $name}}) { nodes { id } } }'
    local result
    result=$(graphql_query "$query" "{\"name\": \"$milestone_ref\"}")
    local milestone_id
    milestone_id=$(echo "$result" | jq -r '.projectMilestones.nodes[0].id // empty')

    if [ -z "$milestone_id" ]; then
        echo "{\"error\": \"Milestone not found: $milestone_ref\"}" >&2
        return 1
    fi

    echo "$milestone_id"
}
