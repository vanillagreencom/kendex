#!/bin/bash
# Linear GraphQL API - Project Operations
# Usage: projects.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/cache.sh"

# Shared project fields for mutation responses — matches list query for cache parity
PROJECT_RETURN_FIELDS='
    id name description content state progress health
    priority sortOrder targetDate startDate
    lead { name }
    teams { nodes { name } }
    labels { nodes { name } }
    url createdAt updatedAt
'

show_help() {
    cat <<'EOF'
Project Operations

Usage: projects.sh <action> [options]

Actions:
  list             List projects with filters
  get              Get a single project by ID or name
  create           Create a new project
  update           Update an existing project
  delete           Delete a project
  list-dependencies List project dependencies (blocking/blocked-by)
  add-dependency   Create a dependency between projects
  remove-dependency Remove a project dependency
  post-update      Post a project update with health status
  list-updates     List project updates
  reorder          Analyze and reorder backlog projects
  set-sort-order   Set sortOrder for a specific project

List Options:
  --state <name>        Filter by state (e.g., "started", "completed")
  --team <name>         Filter by team name
  --limit <n>           Max results (default: 50)
  --first               Output just the first project's name (useful for scripts)
  --include-archived    Include archived projects

Get:
  projects.sh get <id-or-name>

Create Options:
  --name <text>         Project name (required)
  --team <name>         Team name (required)
  --description <text>  Short summary (max 255 chars, shows as subtitle)
  --content <text>      Long description (markdown, shows in body)
  --state <name>        Initial state (backlog, planned, started, paused, completed)
  --priority <n>        Priority: 1=urgent, 2=high, 3=normal, 4=low, 0=none
  --labels <list>       Comma-separated project label names (e.g., "phase-1,area:backend")

Update Options:
  --name <text>         New name
  --description <text>  Short summary (max 255 chars)
  --content <text>      Long description (markdown)
  --state <name>        New state (backlog, planned, started, paused, completed)
  --priority <n>        Priority: 1=urgent, 2=high, 3=normal, 4=low, 0=none
  --labels <list>       Comma-separated project label names

Dependency Options (add-dependency):
  --blocked-by <id>     This project is blocked by another
  --blocks <id>         This project blocks another

Post-Update Options:
  --health <status>     Health status: on-track, at-risk, off-track
  --body <text>         Update message body

Reorder Options:
  --dry-run             Show changes without applying
  --include <id>        Include specific project in reorder (for newly created)

Set-Sort-Order:
  projects.sh set-sort-order <id> --after <other-id>
  projects.sh set-sort-order <id> --before <other-id>
  projects.sh set-sort-order <id> --position <n>   (absolute sortOrder value)

Examples:
  # Basic operations
  projects.sh list --state started
  projects.sh list --state started --first     # Just the name of first active project
  projects.sh get "Market Data Pipeline"
  projects.sh create --name "New Project"
  projects.sh update <id> --state completed
  projects.sh delete <id>

  # Project dependencies
  projects.sh list-dependencies <id-or-name>
  projects.sh add-dependency <project-id> --blocked-by <other-id>
  projects.sh add-dependency <project-id> --blocks <other-id>
  projects.sh remove-dependency <relation-id>

  # Project updates
  projects.sh post-update <project-id> --health on-track --body "Cycle progressing well"
  projects.sh post-update <project-id> --health at-risk --body "Blocked on external dependency"
  projects.sh list-updates <project-id>

  # Reordering
  projects.sh reorder                           # Analyze and apply optimal order
  projects.sh reorder --dry-run                 # Preview changes only
  projects.sh set-sort-order <id> --after <id>  # Position project after another
EOF
}

list_projects() {
    local filter_parts=()
    local first=75
    local include_archived="false"
    local first_only="false"
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --state)
            # Use status.type filter (state filter is broken in Linear API)
            filter_parts+=("\"status\": {\"type\": {\"eq\": \"$2\"}}")
            shift 2
            ;;
        --team)
            filter_parts+=("\"accessibleTeams\": {\"some\": {\"name\": {\"eq\": \"$2\"}}}")
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
        --first)
            first_only="true"
            first=1
            shift
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *) break ;;
        esac
    done

    local filter_json
    if [ ${#filter_parts[@]} -gt 0 ]; then
        filter_json=$(
            IFS=,
            echo "{${filter_parts[*]}}"
        )
    else
        filter_json="{}"
    fi

    local query='
    query ListProjects($filter: ProjectFilter, $first: Int, $includeArchived: Boolean) {
        projects(filter: $filter, first: $first, includeArchived: $includeArchived) {
            nodes {
                id
                name
                description
                content
                state
                progress
                health
                priority
                sortOrder
                targetDate
                startDate
                lead { name }
                teams { nodes { name } }
                labels { nodes { name } }
                url
                createdAt
                updatedAt
            }
        }
    }'

    local variables="{\"filter\": $filter_json, \"first\": $first, \"includeArchived\": $include_archived}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Handle --first: output just the name of first project
    if [ "$first_only" = "true" ]; then
        local name
        name=$(echo "$result" | jq -r '.projects.nodes[0].name // "Backlog"')
        echo "$name"
        return
    fi

    # Apply output format
    case "$FORMAT" in
    raw)
        echo "$result"
        ;;
    ids)
        format_projects_ids "$result"
        ;;
    safe | *)
        format_projects_list "$result"
        ;;
    esac
}

get_project() {
    local project_ref=""
    FORMAT="${DEFAULT_FORMAT}"

    # Parse arguments
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
            project_ref="$1"
            shift
            ;;
        esac
    done

    if [ -z "$project_ref" ]; then
        echo '{"error": "Project ID or name required"}' >&2
        return 1
    fi

    # Resolve name to ID if not a UUID
    local project_id
    if ! project_id=$(resolve_project_id "$project_ref"); then
        return 1
    fi

    local query='
    query GetProject($id: String!) {
        project(id: $id) {
            id
            name
            description
            content
            state
            progress
            health
            healthUpdatedAt
            priority
            sortOrder
            startDate
            targetDate
            url
            teams { nodes { name } }
            labels { nodes { name } }
            lead { name email }
            createdAt
            updatedAt
            lastUpdate {
                id
                body
                health
                createdAt
            }
            relations {
                nodes {
                    id
                    type
                    anchorType
                    relatedAnchorType
                    relatedProject { id name state progress }
                }
            }
            inverseRelations {
                nodes {
                    id
                    type
                    anchorType
                    relatedAnchorType
                    project { id name state progress }
                }
            }
        }
    }'

    local variables="{\"id\": \"$project_id\"}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply output format
    case "$FORMAT" in
    raw)
        echo "$result"
        ;;
    safe | *)
        format_project_single "$result"
        ;;
    esac
}

create_project() {
    local name=""
    local team=""
    local description=""
    local content=""
    local state=""
    local priority=""
    local labels=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --name)
            name="$2"
            shift 2
            ;;
        --team)
            team="$2"
            shift 2
            ;;
        --description)
            description="$2"
            shift 2
            ;;
        --content)
            content="$2"
            shift 2
            ;;
        --state)
            state="$2"
            shift 2
            ;;
        --priority)
            priority="$2"
            shift 2
            ;;
        --labels)
            labels="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *) break ;;
        esac
    done

    # Apply team default if not specified
    team=$(apply_team_default "$team")

    if [ -z "$name" ]; then
        echo '{"error": "Required: --name"}' >&2
        return 1
    fi

    # Validate field lengths
    if [ -n "$description" ]; then
        validate_length "description" "$description" $LINEAR_LIMIT_SHORT_DESC || return 1
    fi

    # Build input object with proper escaping
    local escaped_name
    escaped_name=$(echo -n "$name" | jq -Rs '.')
    local input_parts=("\"name\": $escaped_name")

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
    input_parts+=("\"teamIds\": [\"$team_id\"]")

    if [ -n "$description" ]; then
        local escaped_desc
        escaped_desc=$(echo -n "$description" | jq -Rs '.')
        input_parts+=("\"description\": $escaped_desc")
    fi
    if [ -n "$content" ]; then
        local escaped_content
        escaped_content=$(echo -n "$content" | jq -Rs '.')
        input_parts+=("\"content\": $escaped_content")
    fi
    [ -n "$state" ] && input_parts+=("\"state\": \"$state\"")
    [ -n "$priority" ] && input_parts+=("\"priority\": $priority")

    # Resolve project label names to IDs
    if [ -n "$labels" ]; then
        local label_ids=()
        IFS=',' read -ra label_names <<<"$labels"
        for label_name in "${label_names[@]}"; do
            label_name=$(echo "$label_name" | xargs) # trim whitespace
            local label_query='query GetProjectLabel($name: String!) { projectLabels(filter: {name: {eq: $name}}) { nodes { id } } }'
            local label_result
            label_result=$(graphql_query "$label_query" "{\"name\": \"$label_name\"}")
            local label_id
            label_id=$(echo "$label_result" | jq -r '.projectLabels.nodes[0].id // empty')
            if [ -z "$label_id" ]; then
                echo "{\"error\": \"Project label not found: $label_name\"}" >&2
                return 1
            fi
            label_ids+=("\"$label_id\"")
        done
        local label_ids_json
        label_ids_json=$(
            IFS=,
            echo "[${label_ids[*]}]"
        )
        input_parts+=("\"labelIds\": $label_ids_json")
    fi

    local input_json
    input_json=$(
        IFS=,
        echo "{${input_parts[*]}}"
    )

    local mutation="
    mutation CreateProject(\$input: ProjectCreateInput!) {
        projectCreate(input: \$input) {
            success
            project {
                $PROJECT_RETURN_FIELDS
            }
        }
    }"

    local result
    result=$(graphql_query "$mutation" "{\"input\": $input_json}")
    # Write-through: upsert new project into cache
    local created_project
    created_project=$(echo "$result" | jq '.projectCreate.project // empty')
    [[ -n "$created_project" && "$created_project" != "null" ]] && cache_upsert_project "$created_project" 2>/dev/null || true
    normalize_mutation_response "$result" "projectCreate" "project"
}

update_project() {
    local project_id="$1"
    shift

    local name=""
    local description=""
    local content=""
    local state=""
    local priority=""
    local labels=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --name)
            name="$2"
            shift 2
            ;;
        --description)
            description="$2"
            shift 2
            ;;
        --content)
            content="$2"
            shift 2
            ;;
        --state)
            state="$2"
            shift 2
            ;;
        --priority)
            priority="$2"
            shift 2
            ;;
        --labels)
            labels="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
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
    if [ -n "$content" ]; then
        local escaped_content
        escaped_content=$(echo -n "$content" | jq -Rs '.')
        input_parts+=("\"content\": $escaped_content")
    fi
    [ -n "$state" ] && input_parts+=("\"state\": \"$state\"")
    [ -n "$priority" ] && input_parts+=("\"priority\": $priority")

    # Resolve project label names to IDs
    if [ -n "$labels" ]; then
        local label_ids=()
        IFS=',' read -ra label_names <<<"$labels"
        for label_name in "${label_names[@]}"; do
            label_name=$(echo "$label_name" | xargs) # trim whitespace
            local label_query='query GetProjectLabel($name: String!) { projectLabels(filter: {name: {eq: $name}}) { nodes { id } } }'
            local label_result
            label_result=$(graphql_query "$label_query" "{\"name\": \"$label_name\"}")
            local label_id
            label_id=$(echo "$label_result" | jq -r '.projectLabels.nodes[0].id // empty')
            if [ -z "$label_id" ]; then
                echo "{\"error\": \"Project label not found: $label_name\"}" >&2
                return 1
            fi
            label_ids+=("\"$label_id\"")
        done
        local label_ids_json
        label_ids_json=$(
            IFS=,
            echo "[${label_ids[*]}]"
        )
        input_parts+=("\"labelIds\": $label_ids_json")
    fi

    if [ ${#input_parts[@]} -eq 0 ]; then
        echo '{"error": "No update options provided"}' >&2
        return 1
    fi

    local input_json
    input_json=$(
        IFS=,
        echo "{${input_parts[*]}}"
    )

    local mutation="
    mutation UpdateProject(\$id: String!, \$input: ProjectUpdateInput!) {
        projectUpdate(id: \$id, input: \$input) {
            success
            project {
                $PROJECT_RETURN_FIELDS
            }
        }
    }"

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$project_id\", \"input\": $input_json}")
    # Write-through: upsert updated project into cache
    local updated_project
    updated_project=$(echo "$result" | jq '.projectUpdate.project // empty')
    [[ -n "$updated_project" && "$updated_project" != "null" ]] && cache_upsert_project "$updated_project" 2>/dev/null || true
    normalize_mutation_response "$result" "projectUpdate" "project"
}

delete_project() {
    local project_id="$1"

    local mutation='
    mutation DeleteProject($id: String!) {
        projectDelete(id: $id) {
            success
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$project_id\"}")
    # Write-through: remove project from cache
    local success
    success=$(echo "$result" | jq -r '.projectDelete.success // "false"')
    [[ "$success" == "true" ]] && cache_remove_project "$project_id" 2>/dev/null || true
    normalize_mutation_response "$result" "projectDelete" "project"
}

list_dependencies() {
    local project_id=""
    FORMAT="raw"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --format)
            if [ -z "${2:-}" ]; then
                echo '{"error": "Missing value for --format"}' >&2
                return 1
            fi
            FORMAT="$2"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        *)
            if [ -z "$project_id" ]; then
                project_id="$1"
                shift
            else
                echo "{\"error\": \"Unexpected argument: $1\"}" >&2
                return 1
            fi
            ;;
        esac
    done

    if [ -z "$project_id" ]; then
        echo '{"error": "Project ID or name required"}' >&2
        return 1
    fi

    local resolved_project_id
    if ! resolved_project_id=$(resolve_project_id "$project_id"); then
        return 1
    fi

    local query='
    query GetProjectDependencies($id: String!) {
        project(id: $id) {
            id
            name
            relations {
                nodes {
                    id
                    type
                    anchorType
                    relatedAnchorType
                    relatedProject { id name state progress }
                }
            }
            inverseRelations {
                nodes {
                    id
                    type
                    anchorType
                    relatedAnchorType
                    project { id name state progress }
                }
            }
        }
    }'

    local variables="{\"id\": \"$resolved_project_id\"}"
    local result
    result=$(graphql_query "$query" "$variables")

    case "$FORMAT" in
    raw)
        echo "$result"
        ;;
    safe | *)
        format_project_dependencies "$result"
        ;;
    esac
}

add_dependency() {
    local project_id="$1"
    shift

    local blocked_by=""
    local blocks=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --blocked-by)
            blocked_by="$2"
            shift 2
            ;;
        --blocks)
            blocks="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *) break ;;
        esac
    done

    local type="dependency"
    local anchor_type="start"
    local related_anchor_type="end"
    local related_project_id=""

    if [ -n "$blocked_by" ]; then
        # This project depends on (blocked by) another
        # The blocked project's start depends on the blocker's end
        # projectId = this project (blocked), relatedProjectId = blocker
        related_project_id="$blocked_by"
    elif [ -n "$blocks" ]; then
        # This project blocks another
        # The other project's start depends on this project's end
        # Swap: projectId = other (blocked), relatedProjectId = this (blocker)
        related_project_id="$project_id"
        project_id="$blocks"
    else
        echo '{"error": "Required: --blocked-by or --blocks"}' >&2
        return 1
    fi

    local mutation='
    mutation CreateProjectRelation($input: ProjectRelationCreateInput!) {
        projectRelationCreate(input: $input) {
            success
            projectRelation {
                id
                type
                project { name }
                relatedProject { name }
            }
        }
    }'

    local input="{\"type\": \"$type\", \"projectId\": \"$project_id\", \"anchorType\": \"$anchor_type\", \"relatedProjectId\": \"$related_project_id\", \"relatedAnchorType\": \"$related_anchor_type\"}"
    local result
    result=$(graphql_query "$mutation" "{\"input\": $input}")
    normalize_mutation_response "$result" "projectRelationCreate" "projectRelation"
}

remove_dependency() {
    local relation_id="$1"

    local mutation='
    mutation DeleteProjectRelation($id: String!) {
        projectRelationDelete(id: $id) {
            success
        }
    }'

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$relation_id\"}")
    normalize_mutation_response "$result" "projectRelationDelete" "projectRelation"
}

post_update() {
    local project_id="$1"
    shift

    local health=""
    local body=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --health)
            health="$2"
            shift 2
            ;;
        --body)
            body="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *) break ;;
        esac
    done

    # Map user-friendly health values to API enum
    local health_enum=""
    case "$health" in
    on-track | onTrack) health_enum="onTrack" ;;
    at-risk | atRisk) health_enum="atRisk" ;;
    off-track | offTrack) health_enum="offTrack" ;;
    "")
        echo '{"error": "Required: --health (on-track, at-risk, off-track)"}' >&2
        return 1
        ;;
    *)
        echo "{\"error\": \"Invalid health value: $health. Use: on-track, at-risk, off-track\"}" >&2
        return 1
        ;;
    esac

    local input_parts=("\"projectId\": \"$project_id\"" "\"health\": \"$health_enum\"")
    if [ -n "$body" ]; then
        local escaped_body
        escaped_body=$(echo -n "$body" | jq -Rs '.')
        input_parts+=("\"body\": $escaped_body")
    fi

    local input_json
    input_json=$(
        IFS=,
        echo "{${input_parts[*]}}"
    )

    local mutation="
    mutation CreateProjectUpdate(\$input: ProjectUpdateCreateInput!) {
        projectUpdateCreate(input: \$input) {
            success
            projectUpdate {
                id
                health
                body
                createdAt
                project {
                    $PROJECT_RETURN_FIELDS
                }
            }
        }
    }"

    local result
    result=$(graphql_query "$mutation" "{\"input\": $input_json}")
    # Write-through: upsert the parent project with updated health
    local updated_project
    updated_project=$(echo "$result" | jq '.projectUpdateCreate.projectUpdate.project // empty')
    [[ -n "$updated_project" && "$updated_project" != "null" ]] && cache_upsert_project "$updated_project" 2>/dev/null || true
    normalize_mutation_response "$result" "projectUpdateCreate" "projectUpdate"
}

list_updates() {
    local project_id="$1"

    local query='
    query GetProjectUpdates($id: String!) {
        project(id: $id) {
            name
            health
            projectUpdates(first: 10) {
                nodes {
                    id
                    health
                    body
                    createdAt
                    user { name }
                }
            }
        }
    }'

    local variables="{\"id\": \"$project_id\"}"
    graphql_query "$query" "$variables"
}

reorder_projects() {
    local dry_run=false
    local include_ids=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
        -h | --help)
            show_help
            return 0
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --include)
            include_ids+=("$2")
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1\"}" >&2
            return 1
            ;;
        *) break ;;
        esac
    done

    # Query all backlog/planned projects with dependencies and sortOrder
    # Note: graphql_query escapes double quotes, so use raw quotes here
    # Using first: 25 to stay within API complexity limits
    local query='
    query {
        projects(filter: {status: {type: {in: ["backlog", "planned"]}}}, first: 25) {
            nodes {
                id
                name
                state
                priority
                sortOrder
                relations {
                    nodes {
                        type
                        relatedProject { id name state }
                    }
                }
                inverseRelations {
                    nodes {
                        type
                        project { id name state }
                    }
                }
            }
        }
    }'

    local result
    result=$(graphql_query "$query" "{}")

    # If --include specified, fetch those projects and merge (ensures they're included even with limit)
    if [ ${#include_ids[@]} -gt 0 ]; then
        for include_id in "${include_ids[@]}"; do
            local include_query='
            query($id: String!) {
                project(id: $id) {
                    id
                    name
                    state
                    priority
                    sortOrder
                    relations {
                        nodes {
                            type
                            relatedProject { id name state }
                        }
                    }
                    inverseRelations {
                        nodes {
                            type
                            project { id name state }
                        }
                    }
                }
            }'
            local include_result
            include_result=$(graphql_query "$include_query" "{\"id\": \"$include_id\"}")
            # Merge: add to nodes if not already present
            result=$(echo "$result" "$include_result" | jq -s '
                .[0] as $main | .[1] as $add |
                if $add.project == null then $main
                else
                    ($main.projects.nodes | map(.id)) as $existing_ids |
                    if ($existing_ids | any(. == $add.project.id)) then $main
                    else $main | .projects.nodes += [$add.project]
                    end
                end
            ')
        done
    fi

    # Process with jq: topological sort + priority + critical path
    # Returns: array of {id, name, current_order, new_order, sortOrder, needs_update, reason}
    local reorder_plan
    reorder_plan=$(echo "$result" | jq '
        # Build dependency graph and compute optimal order
        .projects.nodes as $projects |
        [$projects[].id] as $project_ids |

        # Helper: priority score (1=urgent->4, 2=high->3, etc)
        def priority_score:
            if . == 1 then 4
            elif . == 2 then 3
            elif . == 3 then 2
            elif . == 4 then 1
            else 0 end;

        # Enrich projects with computed fields
        [$projects[] |
            # Get all incomplete blockers
            [(.relations.nodes // [])[] |
             select(.type == "dependency") |
             .relatedProject |
             select(.state != "completed" and .state != "canceled")] as $all_blockers |
            # Split into in-query vs external
            [$all_blockers[] | select(.id as $bid | $project_ids | any(. == $bid)) | .id] as $blockers_in |
            [$all_blockers[] | select(.id as $bid | $project_ids | any(. == $bid) | not)] as $blockers_ext |
            {
                id: .id,
                name: .name,
                state: .state,
                priority: (.priority // 0),
                priority_score: ((.priority // 0) | priority_score),
                current_sortOrder: .sortOrder,
                blockers_in_query: $blockers_in,
                external_blockers: [$blockers_ext[].state],
                has_external_blockers: ($blockers_ext | length > 0),
                unblocks: ([(.inverseRelations.nodes // [])[] | select(.type == "dependency")] | length)
            }
        ] |

        # Compute depth: external blockers = 999, otherwise based on in-query deps
        # Simplified: just use has_external_blockers and blockers_in_query length
        . as $enriched |
        [$enriched[] | {
            id: .id,
            name: .name,
            state: .state,
            priority: .priority,
            priority_score: .priority_score,
            current_sortOrder: .current_sortOrder,
            has_external_blockers: .has_external_blockers,
            unblocks: .unblocks,
            # Depth: 999 if blocked externally, else count of in-query blockers (simplified)
            depth: (if .has_external_blockers then 999 else (.blockers_in_query | length) end)
        }] |

        # Sort by: depth ASC, unblocks DESC (critical path), priority_score DESC, name ASC
        sort_by([.depth, -.unblocks, -.priority_score, .name]) |

        # Assign new sortOrder values (spacing of 1000 for easy insertion)
        # Lower (more negative) sortOrder appears at TOP in Linear UI
        . as $sorted | ($sorted | length) as $len |
        [range($len) | . as $i | $sorted[$i] + {
            new_position: ($i + 1),
            new_sortOrder: (($len - $i) * -1000),
            needs_update: ($sorted[$i].current_sortOrder != (($len - $i) * -1000)),
            reason: (
                (if $sorted[$i].has_external_blockers then "Blocked"
                 else "Tier " + ($sorted[$i].depth | tostring) end) +
                (if $sorted[$i].unblocks > 0 then " (unblocks " + ($sorted[$i].unblocks | tostring) + ")" else "" end) +
                (if $sorted[$i].priority > 0 then " P" + ($sorted[$i].priority | tostring) else "" end)
            )
        }]
    ')

    if [ "$dry_run" = true ]; then
        # Output the plan as JSON
        echo "$reorder_plan" | jq '{
            dry_run: true,
            changes: [.[] | select(.needs_update) | {
                id: .id,
                name: .name,
                current_sortOrder: .current_sortOrder,
                new_sortOrder: .new_sortOrder,
                new_position: .new_position,
                reason: .reason
            }],
            final_order: [.[] | {position: .new_position, name: .name, reason: .reason}]
        }'
    else
        # Apply changes
        local changes_made=0
        local update_mutation="
        mutation UpdateProjectSortOrder(\$id: String!, \$input: ProjectUpdateInput!) {
            projectUpdate(id: \$id, input: \$input) {
                success
                project {
                    $PROJECT_RETURN_FIELDS
                }
            }
        }"

        # Iterate through projects needing updates
        while IFS= read -r project_json; do
            local proj_id proj_name new_sort
            proj_id=$(echo "$project_json" | jq -r '.id')
            proj_name=$(echo "$project_json" | jq -r '.name')
            new_sort=$(echo "$project_json" | jq -r '.new_sortOrder')

            local update_result
            update_result=$(graphql_query "$update_mutation" "{\"id\": \"$proj_id\", \"input\": {\"sortOrder\": $new_sort}}")

            if echo "$update_result" | jq -e '.projectUpdate.success' >/dev/null 2>&1; then
                changes_made=$((changes_made + 1))
                # Write-through: upsert updated project into cache
                local updated_proj
                updated_proj=$(echo "$update_result" | jq '.projectUpdate.project // empty')
                [[ -n "$updated_proj" && "$updated_proj" != "null" ]] && cache_upsert_project "$updated_proj" 2>/dev/null || true
            fi
        done < <(echo "$reorder_plan" | jq -c '.[] | select(.needs_update)')

        # Output summary
        echo "$reorder_plan" | jq --arg changes "$changes_made" '{
            dry_run: false,
            changes_applied: ($changes | tonumber),
            final_order: [.[] | {position: .new_position, name: .name, reason: .reason}]
        }'
    fi
}

set_sort_order() {
    local project_id="$1"
    shift

    local after_id=""
    local before_id=""
    local position=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        -h | --help)
            show_help
            return 0
            ;;
        --after)
            after_id="$2"
            shift 2
            ;;
        --before)
            before_id="$2"
            shift 2
            ;;
        --position)
            position="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1\"}" >&2
            return 1
            ;;
        *) break ;;
        esac
    done

    local new_sort_order=""

    if [ -n "$position" ]; then
        # Direct position value
        new_sort_order="$position"
    elif [ -n "$after_id" ]; then
        # Get sortOrder of target project and place after it
        local target_sort
        target_sort=$(graphql_query 'query($id:String!){project(id:$id){sortOrder}}' "{\"id\":\"$after_id\"}" | jq -r '.project.sortOrder')
        if [ "$target_sort" = "null" ] || [ -z "$target_sort" ]; then
            echo '{"error": "Could not get sortOrder of target project"}' >&2
            return 1
        fi
        # Place slightly after (higher sortOrder = later in list for negative values)
        new_sort_order=$(echo "$target_sort + 500" | bc)
    elif [ -n "$before_id" ]; then
        # Get sortOrder of target project and place before it
        local target_sort
        target_sort=$(graphql_query 'query($id:String!){project(id:$id){sortOrder}}' "{\"id\":\"$before_id\"}" | jq -r '.project.sortOrder')
        if [ "$target_sort" = "null" ] || [ -z "$target_sort" ]; then
            echo '{"error": "Could not get sortOrder of target project"}' >&2
            return 1
        fi
        # Place slightly before (lower sortOrder = earlier)
        new_sort_order=$(echo "$target_sort - 500" | bc)
    else
        echo '{"error": "Required: --after, --before, or --position"}' >&2
        return 1
    fi

    # Update the project
    local mutation="
    mutation UpdateProjectSortOrder(\$id: String!, \$input: ProjectUpdateInput!) {
        projectUpdate(id: \$id, input: \$input) {
            success
            project {
                $PROJECT_RETURN_FIELDS
            }
        }
    }"

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$project_id\", \"input\": {\"sortOrder\": $new_sort_order}}")
    # Write-through: upsert updated project into cache
    local updated_project
    updated_project=$(echo "$result" | jq '.projectUpdate.project // empty')
    [[ -n "$updated_project" && "$updated_project" != "null" ]] && cache_upsert_project "$updated_project" 2>/dev/null || true
    normalize_mutation_response "$result" "projectUpdate" "project"
}

# Main routing
action="${1:-help}"
shift || true

case "$action" in
list)
    list_projects "$@"
    ;;
get)
    if [ -z "${1:-}" ]; then
        echo '{"error": "Usage: projects.sh get <id-or-name>"}' >&2
        exit 1
    fi
    get_project "$@"
    ;;
create)
    create_project "$@"
    ;;
update)
    if [ -z "${1:-}" ]; then
        echo '{"error": "Usage: projects.sh update <id> [options]"}' >&2
        exit 1
    fi
    update_project "$@"
    ;;
delete)
    if [ -z "${1:-}" ]; then
        echo '{"error": "Usage: projects.sh delete <id>"}' >&2
        exit 1
    fi
    delete_project "$1"
    ;;
list-dependencies | dependencies)
    if [ -z "${1:-}" ]; then
        echo '{"error": "Usage: projects.sh list-dependencies <id>"}' >&2
        exit 1
    fi
    list_dependencies "$@"
    ;;
add-dependency)
    if [ -z "${1:-}" ]; then
        echo '{"error": "Usage: projects.sh add-dependency <id> --blocked-by|--blocks <other-id>"}' >&2
        exit 1
    fi
    add_dependency "$@"
    ;;
remove-dependency)
    if [ -z "${1:-}" ]; then
        echo '{"error": "Usage: projects.sh remove-dependency <relation-id>"}' >&2
        exit 1
    fi
    remove_dependency "$1"
    ;;
post-update)
    if [ -z "${1:-}" ]; then
        echo '{"error": "Usage: projects.sh post-update <id> --health <status> [--body <text>]"}' >&2
        exit 1
    fi
    post_update "$@"
    ;;
list-updates)
    if [ -z "${1:-}" ]; then
        echo '{"error": "Usage: projects.sh list-updates <id>"}' >&2
        exit 1
    fi
    list_updates "$1"
    ;;
reorder)
    reorder_projects "$@"
    ;;
set-sort-order)
    if [ -z "${1:-}" ]; then
        echo '{"error": "Usage: projects.sh set-sort-order <id> --after|--before|--position <value>"}' >&2
        exit 1
    fi
    set_sort_order "$@"
    ;;
help | --help | -h)
    show_help
    ;;
*)
    echo "Error: Unknown action '$action'" >&2
    echo "Run 'projects.sh --help' for usage." >&2
    exit 1
    ;;
esac
