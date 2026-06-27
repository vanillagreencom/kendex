#!/bin/bash
# Linear GraphQL API - Issue Operations
# Usage: issues.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/cache.sh"
source "$SCRIPT_DIR/../lib/attachments.sh"
source "$SCRIPT_DIR/../lib/issue-validation.sh"

# Shared issue fields for mutation responses — matches list query for cache parity
ISSUE_RETURN_FIELDS='
    id
    identifier
    title
    description
    state { name type }
    assignee { name }
    project { id name }
    projectMilestone { id name }
    cycle { id name number }
    parent { id identifier title }
    team { name }
    labels { nodes { name } }
    priority
    estimate
    sortOrder
    url
    createdAt
    updatedAt
    archivedAt
    trashed
    relations { nodes { id type relatedIssue { id identifier title state { name type } } } }
    inverseRelations { nodes { id type issue { id identifier title state { name type } } } }
'

linear_mutation_success() {
    local normalized="$1"
    [ "$(echo "$normalized" | jq -r '.success // false' 2>/dev/null || echo false)" = "true" ]
}

emit_linear_issue_activity() { return 0; }

emit_linear_relation_activity() { return 0; }

linear_update_activity_type() {
    local normalized="$1"
    local state state_type
    state=$(echo "$normalized" | jq -r '.data.issue.state.name // empty' 2>/dev/null || true)
    state_type=$(echo "$normalized" | jq -r '.data.issue.state.type // empty' 2>/dev/null || true)
    case "$(printf '%s' "$state_type:$state" | tr '[:upper:]' '[:lower:]')" in
        completed:*|*:done|*:complete|*:completed) printf 'linear.issue_finished success\n' ;;
        canceled:*|cancelled:*|*:canceled|*:cancelled|*:canceled*|*:cancelled*) printf 'linear.issue_cancelled warning\n' ;;
        *) printf 'linear.issue_updated info\n' ;;
    esac
}

show_help() {
    cat <<'EOF'
Issue Operations

Usage: issues.sh <action> [options]

Actions:
  list           List issues with filters
  get            Get a single issue by ID (--with-bundle for recursive children + pending_count)
  bulk-get       Get multiple issues with full relations in one query
  bulk-update    Update multiple issues with the same changes
  create         Create a new issue
  update         Update an existing issue
  archive        Archive an issue (soft delete, restorable via UI)
  trash          Move issue to trash (recoverable for 30 days)
  delete         Alias for trash
  children       List sub-issues of a parent issue (--recursive for nested, --pending to filter)
  list-relations List issue relations (blocking/blocked-by)
  add-relation   Create a relation between issues
  remove-relation Delete an issue relation

Workflow Actions (composite operations for dev):
  activate       Claim issue: set "In Progress"
  block          Block issue: add label + relation + comment
  unblock        Unblock issue: remove label + comment
  complete       Complete issue: set "Done"
  validate-completion  Check state + summary (--include-children-of <ID> for bundles)

Output Formats (all query commands):
  --format=safe         Flat, null-safe array (DEFAULT)
  --format=compact      Minimal fields for workflow routing (no description/url/timestamps)
  --format=ids          Newline-separated identifiers only
  --format=table        Human-readable table
  --format=raw          Original GraphQL structure

List Options:
  --label <name>        Filter by label (e.g., "backend")
  --state <name>        Filter by state (e.g., "Todo", "In Progress,Todo")
  --project <name>      Filter by project name
  --project-id <uuid>   Filter by project ID
  --team <name>         Filter by team name (default: \$LINEAR_TEAM from project config)
  --assignee <name|me>  Filter by assignee
  --updated-since <Nd>  Filter by updated date (e.g., "7d")
  --created-since <Nd>  Filter by created date
  --limit <n>           Max results per page (default: 75)
  --max                 Fetch ALL results (auto-paginates, up to 15000)
  --search <pattern>    Filter by regex on title+description (client-side)
  --include-archived    Include archived issues
  --with-relations      Include blocking info (use --format=raw for analyzed output)

Get:
  issues.sh get <id>    Get by UUID or identifier (PROJ-42)

Bulk Get:
  issues.sh bulk-get <id1> <id2> ...   Get multiple issues with relations
  issues.sh bulk-get --stdin           Read identifiers from stdin (one per line)

Bulk Update:
  issues.sh bulk-update <id1> <id2> ... [update-options]
  issues.sh bulk-update --stdin [update-options]
  (Same update options as 'update' action, applied to all issues)

Create Options:
  --title <text>        Issue title (required)
  --team <name>         Team name (default: $LINEAR_TEAM from project config)
  --description <text>  Issue description
  --label(s) <a,b,c>    Comma-separated label names
  --project <name|uuid> Project (name or UUID, auto-resolved)
  --state <name>        Initial state (case-sensitive, fails with available list)
  --priority <0-4>      Priority: 0=None, 1=Urgent, 2=High, 3=Normal, 4=Low
  --estimate <1-5>      Effort estimate (points)
  --assignee <name|me>  Assignee
  --parent <id>         Parent issue ID (creates sub-issue)
  --milestone <name|uuid> Project milestone (name or UUID)
  --cycle <id>          Cycle (sprint) ID

Update Options:
  --state <name>        New state
  --label(s) <a,b,c>    Replace labels (comma-separated)
  --title <text>        New title
  --description <text>  New description
  --project <name|uuid> Move to project (name or UUID, auto-resolved)
  --priority <0-4>      Priority: 0=None, 1=Urgent, 2=High, 3=Normal, 4=Low
  --estimate <1-5>      Effort estimate (points)
  --assignee <name|me>  Change assignee
  --parent <id>         Set parent issue (convert to sub-issue)
  --remove-parent       Remove parent (convert to top-level issue)
  --milestone <name|uuid> Set project milestone (name or UUID)
  --cycle <id>          Set cycle (sprint) ID
  --clear-cycle         Remove cycle assignment
  --sort-order <float>  Manual sort position (lower = higher; parent/standalone only)

Relation Options (add-relation):
  --blocks <id>         This issue blocks another
  --blocked-by <id>     This issue is blocked by another
  --related <id>        Mark as related
  --duplicate <id>      Mark as duplicate

Examples:
  # Basic operations
  issues.sh list --label "backend" --state "Todo"
  issues.sh get PROJ-42
  issues.sh create --title "New task" --labels "backend,priority:high"
  issues.sh update PROJ-42 --state "In Progress"
  issues.sh archive PROJ-42

  # Parent/sub-issues
  issues.sh create --title "Sub-task" --parent PROJ-42
  issues.sh children PROJ-42                    # Direct children only
  issues.sh children PROJ-42 --recursive        # All descendants (3 levels deep)
  issues.sh children PROJ-42 --recursive --pending  # Pending only (excludes completed/canceled)
  issues.sh update PROJ-43 --parent PROJ-42
  issues.sh update PROJ-43 --remove-parent

  # Issue relations
  issues.sh list-relations PROJ-42
  issues.sh add-relation PROJ-42 --blocks PROJ-43
  issues.sh add-relation PROJ-42 --blocked-by PROJ-41
  issues.sh remove-relation PROJ-42 --blocks PROJ-43      # By issue + flag (mirrors add-relation)
  issues.sh remove-relation <relation-uuid>             # By UUID

  # Cycle (sprint) assignment
  issues.sh update PROJ-42 --cycle 864d7ea0-2347-4048-80cd-5be977d904e4
  issues.sh update PROJ-42 --clear-cycle

  # Bulk operations (reduces API calls)
  issues.sh list --project-id <uuid> --with-relations   # Single query with all relations
  issues.sh bulk-get PROJ-184 PROJ-185 PROJ-186 PROJ-187    # Multiple issues with full details

  # Workflow actions (dev shortcuts)
  issues.sh activate PROJ-42 --agent rust        # Claim issue for work
  issues.sh block PROJ-42 --by PROJ-41 --reason "Need market data types first"
  issues.sh unblock PROJ-42                      # Resume after blocker resolved
  issues.sh complete PROJ-42                     # Mark done
  issues.sh validate-completion PROJ-42 --include-children-of PROJ-42  # Bundle validation

  # Bundle operations (single API call)
  issues.sh get PROJ-42 --with-bundle            # Issue + recursive children + pending_count

  # Search/filter
  issues.sh list --state Todo --search "market_data|order_book"  # Regex on title+description
EOF
}

list_issues() {
    local with_relations="false"
    local paginate_all="false"
    local search_pattern=""
    local args=()
    FORMAT="${DEFAULT_FORMAT}"

    for arg in "$@"; do
        if [ "$arg" = "--with-relations" ]; then
            with_relations="true"
        elif [ "$arg" = "--max" ]; then
            paginate_all="true"
        elif [ "$arg" = "--format" ]; then
            # Next arg is the format value - handled by shift below
            :
        elif [[ "$arg" == --format=* ]]; then
            FORMAT="${arg#--format=}"
        elif [[ "$arg" == --search=* ]]; then
            search_pattern="${arg#--search=}"
        elif [ "$arg" = "--search" ]; then
            # Next iteration will capture the value
            :
        else
            args+=("$arg")
        fi
    done

    # Parse --format and --search with values from args
    local new_args=()
    local skip_next=""
    for arg in ${args[@]+"${args[@]}"}; do
        if [ -n "$skip_next" ]; then
            if [ "$skip_next" = "format" ]; then
                FORMAT="$arg"
            elif [ "$skip_next" = "search" ]; then
                search_pattern="$arg"
            fi
            skip_next=""
        elif [ "$arg" = "--format" ]; then
            skip_next="format"
        elif [ "$arg" = "--search" ]; then
            skip_next="search"
        else
            new_args+=("$arg")
        fi
    done
    args=(${new_args[@]+"${new_args[@]}"})

    parse_filter ${args[@]+"${args[@]}"}

    local query
    # Both queries now include full fields for cache compatibility
    # Added: project.id, projectMilestone, cycle, parent, archivedAt, trashed
    query='
    query ListIssues($filter: IssueFilter, $first: Int, $includeArchived: Boolean, $after: String) {
        issues(filter: $filter, first: $first, includeArchived: $includeArchived, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
                id
                identifier
                title
                description
                state { name type }
                assignee { name }
                project { id name }
                projectMilestone { id name }
                cycle { id name number }
                parent { id identifier title }
                labels { nodes { name } }
                priority
                estimate
                sortOrder
                url
                createdAt
                updatedAt
                archivedAt
                trashed
                relations { nodes { id type relatedIssue { id identifier title state { name } } } }
                inverseRelations { nodes { id type issue { id identifier title state { name } } } }
            }
        }
    }'

    local result
    local all_nodes="[]"
    local cursor="null"
    local page_count=0
    local max_pages=200 # Safety limit: 200 pages * 75 = 15000 issues max

    if [ "$paginate_all" = "true" ]; then
        # Pagination mode: fetch all pages
        while true; do
            local variables="{\"filter\": $FILTER_JSON, \"first\": $FIRST_JSON, \"includeArchived\": $INCLUDE_ARCHIVED_JSON, \"after\": $cursor}"
            result=$(graphql_query "$query" "$variables")

            # Extract nodes and merge
            local nodes
            nodes=$(echo "$result" | jq '.issues.nodes')
            all_nodes=$(echo "$all_nodes" "$nodes" | jq -s 'add')

            # Check for next page
            local has_next
            has_next=$(echo "$result" | jq -r '.issues.pageInfo.hasNextPage')

            page_count=$((page_count + 1))

            if [ "$has_next" != "true" ] || [ $page_count -ge $max_pages ]; then
                break
            fi

            cursor=$(echo "$result" | jq '.issues.pageInfo.endCursor')
        done

        # Reconstruct result structure with all nodes
        result=$(echo "$all_nodes" | jq '{issues: {nodes: .}}')
    else
        # Single query mode (default)
        local variables="{\"filter\": $FILTER_JSON, \"first\": $FIRST_JSON, \"includeArchived\": $INCLUDE_ARCHIVED_JSON, \"after\": null}"
        result=$(graphql_query "$query" "$variables")

        # Check for truncation and warn if results may be incomplete
        local result_count
        result_count=$(echo "$result" | jq '.issues.nodes | length')
        if [ "$result_count" -ge "$FIRST_JSON" ]; then
            echo "⚠️  Returned $result_count issues (limit: $FIRST_JSON). Results may be truncated. Use --max for all results." >&2
        fi
    fi

    # Apply search filter if specified (client-side regex on title+description)
    if [ -n "$search_pattern" ]; then
        result=$(echo "$result" | jq --arg pattern "$search_pattern" '{
            issues: {
                nodes: [.issues.nodes[] | select((.title + " " + (.description // "")) | test($pattern; "i"))]
            }
        }')
    fi

    # Apply output format
    case "$FORMAT" in
    compact)
        format_issues_list_compact "$result"
        ;;
    raw)
        # --with-relations with raw outputs analyzed format (legacy behavior)
        if [ "$with_relations" = "true" ]; then
            echo "$result" | jq '{
                    unblocked: [.issues.nodes[] |
                        select([.inverseRelations.nodes[] | select(.type == "blocks" and .issue.state.name != "Done")] | length == 0) |
                        {id: .identifier, title, agent: ([.labels.nodes[].name | select(startswith("agent:"))] | first // "none"), priority}
                    ],
                    blocked: [.issues.nodes[] |
                        select([.inverseRelations.nodes[] | select(.type == "blocks" and .issue.state.name != "Done")] | length > 0) |
                        {id: .identifier, title, agent: ([.labels.nodes[].name | select(startswith("agent:"))] | first // "none"), priority,
                         blocked_by: [.inverseRelations.nodes[] | select(.type == "blocks" and .issue.state.name != "Done") | .issue.identifier]}
                    ]
                }'
        else
            echo "$result"
        fi
        ;;
    ids)
        format_issues_ids "$result"
        ;;
    table)
        format_issues_table "$result"
        ;;
    safe | *)
        format_issues_list "$result"
        ;;
    esac
}

bulk_get_issues() {
    local identifiers=()
    local from_stdin="false"
    FORMAT="${DEFAULT_FORMAT}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --stdin)
            from_stdin="true"
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
        *)
            identifiers+=("$1")
            shift
            ;;
        esac
    done

    # Read from stdin if requested
    if [ "$from_stdin" = "true" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && identifiers+=("$line")
        done
    fi

    if [ ${#identifiers[@]} -eq 0 ]; then
        echo '{"error": "No issue identifiers provided"}' >&2
        return 1
    fi

    # Resolve identifiers to UUIDs (Linear API requires UUIDs for filtering)
    local uuids=()
    for id in "${identifiers[@]}"; do
        local uuid
        uuid=$(resolve_issue_id "$id")
        if [ -n "$uuid" ]; then
            uuids+=("\"$uuid\"")
        fi
    done

    if [ ${#uuids[@]} -eq 0 ]; then
        echo '{"error": "No valid issues found"}' >&2
        return 1
    fi

    # Build filter with id IN clause
    local id_list
    id_list=$(
        IFS=,
        echo "[${uuids[*]}]"
    )

    local query='
    query BulkGetIssues($filter: IssueFilter!) {
        issues(filter: $filter, first: 50) {
            nodes {
                id
                identifier
                title
                description
                state { name type }
                assignee { name email }
                project { id name }
                projectMilestone { id name }
                cycle { id name number }
                team { name }
                labels { nodes { name } }
                priority
                estimate
                sortOrder
                url
                createdAt
                updatedAt
                archivedAt
                trashed
                parent { id identifier title }
                children { nodes { id identifier title state { name } } }
                relations { nodes { id type relatedIssue { id identifier title state { name } } } }
                inverseRelations { nodes { id type issue { id identifier title state { name } } } }
            }
        }
    }'

    local variables="{\"filter\": {\"id\": {\"in\": $id_list}}}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply output format
    case "$FORMAT" in
    raw)
        echo "$result"
        ;;
    ids)
        format_issues_ids "$result"
        ;;
    safe | *)
        format_issues_list "$result"
        ;;
    esac
}

bulk_update_issues() {
    local identifiers=()
    local from_stdin="false"
    local update_args=()

    # Separate issue IDs from update options
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --stdin)
            from_stdin="true"
            shift
            ;;
        --state | --status | --labels | --label | --title | --description | --project | --parent | --milestone | --priority | --estimate | --assignee | --cycle | --sort-order)
            # These are update options - collect with their values
            update_args+=("$1" "$2")
            shift 2
            ;;
        --state=* | --status=* | --labels=* | --label=* | --title=* | --description=* | --project=* | --parent=* | --milestone=* | --priority=* | --estimate=* | --assignee=* | --cycle=* | --sort-order=*)
            # Support --key=value syntax (AI agents often use this)
            local _key="${1%%=*}" _val="${1#*=}"
            update_args+=("$_key" "$_val")
            shift
            ;;
        --remove-parent | --clear-cycle)
            update_args+=("$1")
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
        *)
            identifiers+=("$1")
            shift
            ;;
        esac
    done

    # Read from stdin if requested
    if [ "$from_stdin" = "true" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && identifiers+=("$line")
        done
    fi

    if [ ${#identifiers[@]} -eq 0 ]; then
        echo '{"error": "No issue identifiers provided"}' >&2
        return 1
    fi

    if [ ${#update_args[@]} -eq 0 ]; then
        echo '{"error": "No update options provided. Example: bulk-update PROJ-1 PROJ-2 --state \"Backlog\""}' >&2
        return 1
    fi

    # Process each issue
    local results=()
    local success_count=0
    local fail_count=0

    for id in "${identifiers[@]}"; do
        local result
        local update_rc=0
        if result=$(update_issue "$id" "${update_args[@]}" 2>&1); then
            update_rc=0
        else
            update_rc=$?
        fi

        local success
        success=$(echo "$result" | jq -r '.success // false' 2>/dev/null || echo "false")

        if [ "$update_rc" -eq 0 ] && [ "$success" = "true" ]; then
            ((++success_count))
            results+=("$(echo "$result" | jq -c '{identifier, success: true}')")
        else
            ((++fail_count))
            if [ -z "$result" ]; then
                result="update_issue exited with status $update_rc without output"
            fi
            results+=("$(jq -cn --arg identifier "$id" --arg error "$result" --argjson exit_code "$update_rc" \
                '{identifier: $identifier, success: false, exit_code: $exit_code, error: $error}')")
        fi
    done

    # Output summary
    local results_json
    results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
    jq -n \
        --argjson success "$([ "$fail_count" -eq 0 ] && echo true || echo false)" \
        --argjson partial "$([ "$success_count" -gt 0 ] && [ "$fail_count" -gt 0 ] && echo true || echo false)" \
        --argjson updated "$success_count" \
        --argjson failed "$fail_count" \
        --argjson results "$results_json" \
        '{success: $success, partial: $partial, updated: $updated, failed: $failed, results: $results}'

    if [ "$fail_count" -gt 0 ]; then
        return 1
    fi
}

get_issue() {
    local issue_id=""
    local with_bundle="false"
    local extra_args=()
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
        --with-bundle)
            with_bundle="true"
            shift
            ;;
        *)
            if [ -z "$issue_id" ]; then
                issue_id="$1"
            else
                extra_args+=("$1")
            fi
            shift
            ;;
        esac
    done

    if [ -z "$issue_id" ]; then
        echo '{"error": "Issue ID required"}' >&2
        return 1
    fi

    # Warn about extra arguments (common mistake: use bulk-get for multiple)
    if [ ${#extra_args[@]} -gt 0 ]; then
        echo "Warning: 'get' accepts only one issue. Ignored: ${extra_args[*]}" >&2
        echo "Hint: Use 'bulk-get' for multiple issues: linear.sh issues bulk-get ${issue_id} ${extra_args[*]}" >&2
    fi

    local query
    if [ "$with_bundle" = "true" ]; then
        # Extended query with 3-level recursive children for bundle analysis
        query='
        query GetIssueWithBundle($id: String!) {
            issue(id: $id) {
                id
                identifier
                title
                description
                state { name type }
                assignee { name email }
                project { id name }
                projectMilestone { id name }
                cycle { id name number }
                team { name }
                labels { nodes { name } }
                priority
                estimate
                sortOrder
                url
                branchName
                createdAt
                updatedAt
                archivedAt
                trashed
                parent { id identifier title }
                relations { nodes { id type relatedIssue { id identifier title state { name } } } }
                inverseRelations { nodes { id type issue { id identifier title state { name } } } }
                children {
                    nodes {
                        id identifier title description
                        state { name type }
                        assignee { name }
                        labels { nodes { name } }
                        priority estimate
                        parent { identifier }
                        relations { nodes { type relatedIssue { identifier } } }
                        inverseRelations { nodes { type issue { identifier } } }
                        children {
                            nodes {
                                id identifier title description
                                state { name type }
                                assignee { name }
                                labels { nodes { name } }
                                priority estimate
                                parent { identifier }
                                relations { nodes { type relatedIssue { identifier } } }
                                inverseRelations { nodes { type issue { identifier } } }
                                children {
                                    nodes {
                                        id identifier title description
                                        state { name type }
                                        assignee { name }
                                        labels { nodes { name } }
                                        priority estimate
                                        parent { identifier }
                                        relations { nodes { type relatedIssue { identifier } } }
                                        inverseRelations { nodes { type issue { identifier } } }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }'
    else
        query='
        query GetIssue($id: String!) {
            issue(id: $id) {
                id
                identifier
                title
                description
                state { name type }
                assignee { name email }
                project { id name }
                projectMilestone { id name }
                cycle { id name number }
                team { name }
                labels { nodes { name } }
                priority
                estimate
                sortOrder
                url
                branchName
                createdAt
                updatedAt
                archivedAt
                trashed
                parent { id identifier title }
                children { nodes { id identifier title state { name } } }
                relations { nodes { id type relatedIssue { id identifier title state { name } } } }
                inverseRelations { nodes { id type issue { id identifier title state { name } } } }
            }
        }'
    fi

    local variables="{\"id\": \"$issue_id\"}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply output format
    case "$FORMAT" in
    raw)
        echo "$result"
        ;;
    compact)
        if [ "$with_bundle" = "true" ]; then
            format_issue_with_bundle_compact "$result"
        else
            format_issue_compact "$result"
        fi
        ;;
    safe | *)
        if [ "$with_bundle" = "true" ]; then
            format_issue_with_bundle "$result"
        else
            format_issue_single "$result"
        fi
        ;;
    esac
}

create_issue() {
    local title=""
    local team=""
    local description=""
    local labels=""
    local project=""
    local state=""
    local priority=""
    local assignee=""
    local parent=""
    local milestone=""
    local cycle=""
    local estimate=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --title)
            title="$2"
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
        --labels | --label)
            labels="${labels:+$labels,}$2"
            shift 2
            ;;
        --project)
            project="$2"
            shift 2
            ;;
        --state | --status)
            state="$2"
            shift 2
            ;;
        --priority)
            priority="$2"
            shift 2
            ;;
        --estimate)
            estimate="$2"
            shift 2
            ;;
        --assignee)
            assignee="$2"
            shift 2
            ;;
        --parent)
            parent="$2"
            shift 2
            ;;
        --milestone)
            milestone="$2"
            shift 2
            ;;
        --cycle)
            cycle="$2"
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

    if [ -z "$title" ]; then
        echo '{"error": "Required: --title"}' >&2
        return 1
    fi

    # Build input object - use jq for proper JSON escaping
    local escaped_title
    escaped_title=$(echo -n "$title" | jq -Rs '.')
    local input_parts=("\"title\": $escaped_title")

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
    input_parts+=("\"teamId\": \"$team_id\"")

    if [ -n "$description" ]; then
        local escaped_desc
        escaped_desc=$(echo -n "$description" | jq -Rs '.')
        input_parts+=("\"description\": $escaped_desc")
    fi
    [ -n "$priority" ] && input_parts+=("\"priority\": $priority")
    [ -n "$estimate" ] && input_parts+=("\"estimate\": $estimate")

    # Handle labels (warn + skip on miss per label)
    if [ -n "$labels" ]; then
        IFS=',' read -ra label_names <<<"$labels"
        local label_ids=()
        for label_name in "${label_names[@]}"; do
            local label_id
            label_id=$(resolve_label_id "$label_name") && label_ids+=("\"$label_id\"")
        done
        if [ ${#label_ids[@]} -gt 0 ]; then
            local label_json
            label_json=$(
                IFS=,
                echo "[${label_ids[*]}]"
            )
            input_parts+=("\"labelIds\": $label_json")
        fi
    fi

    # Handle project (auto-resolves name or UUID)
    if [ -n "$project" ]; then
        local project_id
        project_id=$(resolve_project_id "$project")
        if [ -z "$project_id" ]; then
            return 1
        fi
        input_parts+=("\"projectId\": \"$project_id\"")
    fi

    # Handle state (fail fast with available states on miss)
    if [ -n "$state" ]; then
        local state_id
        state_id=$(resolve_state_id "$state" "$team_id")
        if [ -z "$state_id" ]; then
            return 1
        fi
        input_parts+=("\"stateId\": \"$state_id\"")
    fi

    # Handle assignee
    if [ -n "$assignee" ]; then
        if [ "$assignee" = "me" ]; then
            local me_query='query { viewer { id } }'
            local me_result
            me_result=$(graphql_query "$me_query" "{}")
            local me_id
            me_id=$(echo "$me_result" | jq -r '.viewer.id // empty')
            [ -n "$me_id" ] && input_parts+=("\"assigneeId\": \"$me_id\"")
        else
            local user_query='query GetUser($name: String!) { users(filter: {name: {containsIgnoreCase: $name}}) { nodes { id } } }'
            local user_result
            user_result=$(graphql_query "$user_query" "{\"name\": \"$assignee\"}")
            local user_id
            user_id=$(echo "$user_result" | jq -r '.users.nodes[0].id // empty')
            [ -n "$user_id" ] && input_parts+=("\"assigneeId\": \"$user_id\"")
        fi
    fi

    # Handle parent (for sub-issues) - resolve identifier to UUID
    if [ -n "$parent" ]; then
        local parent_id
        parent_id=$(resolve_issue_id "$parent")
        if [ -z "$parent_id" ]; then
            echo "{\"error\": \"Parent issue not found: $parent\"}" >&2
            return 1
        fi
        input_parts+=("\"parentId\": \"$parent_id\"")
    fi

    # Handle milestone (auto-resolves name or UUID, fail fast on miss)
    if [ -n "$milestone" ]; then
        local milestone_id
        milestone_id=$(resolve_milestone_id "$milestone")
        if [ -z "$milestone_id" ]; then
            return 1
        fi
        input_parts+=("\"projectMilestoneId\": \"$milestone_id\"")
    fi

    # Handle cycle (sprint)
    if [ -n "$cycle" ]; then
        input_parts+=("\"cycleId\": \"$cycle\"")
    fi

    local input_json
    input_json=$(
        IFS=,
        echo "{${input_parts[*]}}"
    )

    local mutation="
    mutation CreateIssue(\$input: IssueCreateInput!) {
        issueCreate(input: \$input) {
            success
            issue {
                $ISSUE_RETURN_FIELDS
            }
        }
    }"

    local result
    result=$(graphql_query "$mutation" "{\"input\": $input_json}")
    # Write-through: upsert new issue into cache
    local created_issue
    created_issue=$(echo "$result" | jq '.issueCreate.issue // empty')
    [[ -n "$created_issue" && "$created_issue" != "null" ]] && cache_upsert_issue "$created_issue" 2>/dev/null || true
    [[ -n "$created_issue" && "$created_issue" != "null" ]] && cache_patch_relation_snapshots "$created_issue" 2>/dev/null || true
    # Download any attachments in the new issue description
    if [[ -n "$created_issue" && "$created_issue" != "null" ]]; then
        local _id _desc
        _id=$(echo "$created_issue" | jq -r '.identifier // empty')
        _desc=$(echo "$created_issue" | jq -r '.description // empty')
        attach_download_from_text "$_desc" "$_id" "description" &
    fi
    local normalized
    normalized=$(normalize_mutation_response "$result" "issueCreate" "issue")
    emit_linear_issue_activity "linear.issue_created" "info" "$normalized"
    echo "$normalized"
}

update_issue() {
    local issue_id="$1"
    shift

    local state=""
    local labels=""
    local title=""
    local description=""
    local project=""
    local priority=""
    local assignee=""
    local parent=""
    local remove_parent="false"
    local milestone=""
    local cycle=""
    local clear_cycle="false"
    local estimate=""
    local sort_order=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --state | --status)
            state="$2"
            shift 2
            ;;
        --state=* | --status=*)
            state="${1#*=}"
            shift
            ;;
        --labels | --label)
            labels="${labels:+$labels,}$2"
            shift 2
            ;;
        --labels=* | --label=*)
            labels="${labels:+$labels,}${1#*=}"
            shift
            ;;
        --title)
            title="$2"
            shift 2
            ;;
        --title=*)
            title="${1#*=}"
            shift
            ;;
        --description)
            description="$2"
            shift 2
            ;;
        --description=*)
            description="${1#*=}"
            shift
            ;;
        --project)
            project="$2"
            shift 2
            ;;
        --project=*)
            project="${1#*=}"
            shift
            ;;
        --parent)
            parent="$2"
            shift 2
            ;;
        --parent=*)
            parent="${1#*=}"
            shift
            ;;
        --remove-parent)
            remove_parent="true"
            shift
            ;;
        --milestone)
            milestone="$2"
            shift 2
            ;;
        --milestone=*)
            milestone="${1#*=}"
            shift
            ;;
        --priority)
            priority="$2"
            shift 2
            ;;
        --priority=*)
            priority="${1#*=}"
            shift
            ;;
        --estimate)
            estimate="$2"
            shift 2
            ;;
        --estimate=*)
            estimate="${1#*=}"
            shift
            ;;
        --assignee)
            assignee="$2"
            shift 2
            ;;
        --assignee=*)
            assignee="${1#*=}"
            shift
            ;;
        --cycle)
            cycle="$2"
            shift 2
            ;;
        --cycle=*)
            cycle="${1#*=}"
            shift
            ;;
        --clear-cycle)
            clear_cycle="true"
            shift
            ;;
        --sort-order)
            sort_order="$2"
            shift 2
            ;;
        --sort-order=*)
            sort_order="${1#*=}"
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

    local input_parts=()

    # Get issue to find team ID (needed for state lookup) - use raw format
    local issue_result
    issue_result=$(get_issue "$issue_id" --format=raw)
    local team_name
    team_name=$(echo "$issue_result" | jq -r '.issue.team.name // empty')

    if [ -n "$title" ]; then
        local escaped_title
        escaped_title=$(echo -n "$title" | jq -Rs '.')
        input_parts+=("\"title\": $escaped_title")
    fi
    if [ -n "$description" ]; then
        local escaped_desc
        escaped_desc=$(echo -n "$description" | jq -Rs '.')
        input_parts+=("\"description\": $escaped_desc")
    fi
    [ -n "$priority" ] && input_parts+=("\"priority\": $priority")
    [ -n "$estimate" ] && input_parts+=("\"estimate\": $estimate")

    # Sort order only meaningful on parent/standalone issues (sub-issues render under parent)
    if [ -n "$sort_order" ]; then
        local parent_id
        parent_id=$(echo "$issue_result" | jq -r '.issue.parent.identifier // empty')
        if [ -n "$parent_id" ]; then
            echo "WARN: $issue_id is a sub-issue of $parent_id — sort order has no effect on sub-issues" >&2
        fi
        input_parts+=("\"sortOrder\": $sort_order")
    fi

    # Handle state (fail fast with available states on miss)
    if [ -n "$state" ]; then
        local state_id
        state_id=$(resolve_state_id "$state" "$team_name")
        if [ -z "$state_id" ]; then
            return 1
        fi
        input_parts+=("\"stateId\": \"$state_id\"")
    fi

    # Handle labels (warn + skip on miss per label)
    if [ -n "$labels" ]; then
        IFS=',' read -ra label_names <<<"$labels"
        local label_ids=()
        for label_name in "${label_names[@]}"; do
            local label_id
            label_id=$(resolve_label_id "$label_name") && label_ids+=("\"$label_id\"")
        done
        local label_json
        label_json=$(
            IFS=,
            echo "[${label_ids[*]}]"
        )
        input_parts+=("\"labelIds\": $label_json")
    fi

    # Handle project (auto-resolves name or UUID)
    if [ -n "$project" ]; then
        local project_id
        project_id=$(resolve_project_id "$project")
        if [ -z "$project_id" ]; then
            return 1
        fi
        input_parts+=("\"projectId\": \"$project_id\"")
    fi

    # Handle assignee
    if [ -n "$assignee" ]; then
        if [ "$assignee" = "me" ]; then
            local me_query='query { viewer { id } }'
            local me_result
            me_result=$(graphql_query "$me_query" "{}")
            local me_id
            me_id=$(echo "$me_result" | jq -r '.viewer.id // empty')
            [ -n "$me_id" ] && input_parts+=("\"assigneeId\": \"$me_id\"")
        else
            local user_query='query GetUser($name: String!) { users(filter: {name: {containsIgnoreCase: $name}}) { nodes { id } } }'
            local user_result
            user_result=$(graphql_query "$user_query" "{\"name\": \"$assignee\"}")
            local user_id
            user_id=$(echo "$user_result" | jq -r '.users.nodes[0].id // empty')
            [ -n "$user_id" ] && input_parts+=("\"assigneeId\": \"$user_id\"")
        fi
    fi

    # Handle parent (set or remove) - resolve identifier to UUID
    if [ "$remove_parent" = "true" ]; then
        input_parts+=("\"parentId\": null")
    elif [ -n "$parent" ]; then
        local parent_id
        parent_id=$(resolve_issue_id "$parent")
        if [ -z "$parent_id" ]; then
            echo "{\"error\": \"Parent issue not found: $parent\"}" >&2
            return 1
        fi
        input_parts+=("\"parentId\": \"$parent_id\"")
    fi

    # Handle milestone (auto-resolves name or UUID, fail fast on miss)
    if [ -n "$milestone" ]; then
        local milestone_id
        milestone_id=$(resolve_milestone_id "$milestone")
        if [ -z "$milestone_id" ]; then
            return 1
        fi
        input_parts+=("\"projectMilestoneId\": \"$milestone_id\"")
    fi

    # Handle cycle (sprint)
    if [ "$clear_cycle" = "true" ] && [ -n "$cycle" ]; then
        echo '{"error": "Use either --cycle or --clear-cycle, not both"}' >&2
        return 1
    elif [ "$clear_cycle" = "true" ]; then
        input_parts+=("\"cycleId\": null")
    elif [ -n "$cycle" ]; then
        input_parts+=("\"cycleId\": \"$cycle\"")
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
    mutation UpdateIssue(\$id: String!, \$input: IssueUpdateInput!) {
        issueUpdate(id: \$id, input: \$input) {
            success
            issue {
                $ISSUE_RETURN_FIELDS
            }
        }
    }"

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$issue_id\", \"input\": $input_json}")
    # Write-through: upsert updated issue into cache
    local updated_issue
    updated_issue=$(echo "$result" | jq '.issueUpdate.issue // empty')
    [[ -n "$updated_issue" && "$updated_issue" != "null" ]] && cache_upsert_issue "$updated_issue" 2>/dev/null || true
    [[ -n "$updated_issue" && "$updated_issue" != "null" ]] && cache_patch_relation_snapshots "$updated_issue" 2>/dev/null || true
    # Download any attachments in the updated description
    if [[ -n "$updated_issue" && "$updated_issue" != "null" ]]; then
        local _id _desc
        _id=$(echo "$updated_issue" | jq -r '.identifier // empty')
        _desc=$(echo "$updated_issue" | jq -r '.description // empty')
        attach_download_from_text "$_desc" "$_id" "description" &
    fi
    local normalized
    normalized=$(normalize_mutation_response "$result" "issueUpdate" "issue")
    if [ -n "$state" ]; then
        local activity_type activity_severity
        read -r activity_type activity_severity < <(linear_update_activity_type "$normalized")
        emit_linear_issue_activity "$activity_type" "$activity_severity" "$normalized"
    fi
    echo "$normalized"
}

archive_issue() {
    local issue_ref="$1"
    shift || true

    # Resolve identifier to UUID (required for archive mutation)
    local issue_id
    issue_id=$(resolve_issue_id "$issue_ref")
    if [ -z "$issue_id" ]; then
        echo "{\"error\": \"Issue not found: $issue_ref\"}" >&2
        return 1
    fi

    local mutation='
    mutation ArchiveIssue($id: String!) {
        issueArchive(id: $id) {
            success
        }
    }'
    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$issue_id\"}")
    # Write-through: remove archived issue from cache
    cache_remove_issue "$issue_id" 2>/dev/null || true
    normalize_mutation_response "$result" "issueArchive" "issue"
}

trash_issue() {
    local issue_ref="$1"
    shift || true

    # Resolve identifier to UUID (required for delete mutation)
    local issue_id
    issue_id=$(resolve_issue_id "$issue_ref")
    if [ -z "$issue_id" ]; then
        echo "{\"error\": \"Issue not found: $issue_ref\"}" >&2
        return 1
    fi

    # Linear's issueDelete moves to trash (recoverable for 30 days)
    local mutation='
    mutation TrashIssue($id: String!) {
        issueDelete(id: $id) {
            success
        }
    }'
    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$issue_id\"}")
    # Write-through: remove trashed issue from cache
    cache_remove_issue "$issue_id" 2>/dev/null || true
    normalize_mutation_response "$result" "issueDelete" "issue"
}

list_children() {
    local issue_id=""
    local recursive="false"
    local pending_only="false"
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
        --recursive | -r)
            recursive="true"
            shift
            ;;
        --pending)
            pending_only="true"
            shift
            ;;
        *)
            issue_id="$1"
            shift
            ;;
        esac
    done

    if [ -z "$issue_id" ]; then
        echo '{"error": "Issue ID required"}' >&2
        return 1
    fi

    local query
    if [ "$recursive" = "true" ]; then
        # Fetch 3 levels deep (covers nearly all real-world nesting)
        # Includes relations for blocking info between sub-issues
        query='
        query GetChildrenRecursive($id: String!) {
            issue(id: $id) {
                identifier
                title
                children {
                    nodes {
                        id
                        identifier
                        title
                        state { name type }
                        assignee { name }
                        labels { nodes { name } }
                        priority
                        estimate
                        parent { identifier }
                        relations { nodes { type relatedIssue { identifier } } }
                        inverseRelations { nodes { type issue { identifier } } }
                        children {
                            nodes {
                                id
                                identifier
                                title
                                state { name type }
                                assignee { name }
                                labels { nodes { name } }
                                priority
                                estimate
                                parent { identifier }
                                relations { nodes { type relatedIssue { identifier } } }
                                inverseRelations { nodes { type issue { identifier } } }
                                children {
                                    nodes {
                                        id
                                        identifier
                                        title
                                        state { name type }
                                        assignee { name }
                                        labels { nodes { name } }
                                        priority
                                        estimate
                                        parent { identifier }
                                        relations { nodes { type relatedIssue { identifier } } }
                                        inverseRelations { nodes { type issue { identifier } } }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }'
    else
        query='
        query GetChildren($id: String!) {
            issue(id: $id) {
                identifier
                title
                children {
                    nodes {
                        id
                        identifier
                        title
                        state { name type }
                        assignee { name }
                        priority
                        estimate
                        createdAt
                    }
                }
            }
        }'
    fi

    local variables="{\"id\": \"$issue_id\"}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply pending filter if requested (filter out completed/canceled)
    if [ "$pending_only" = "true" ]; then
        if [ "$recursive" = "true" ]; then
            # Filter recursively through nested children
            result=$(echo "$result" | jq '
                def filter_pending:
                    if . == null then null
                    elif type == "array" then [.[] | filter_pending]
                    elif type == "object" and has("state") then
                        if .state.type == "completed" or .state.type == "canceled" then empty
                        else . + (if has("children") then {children: {nodes: ([.children.nodes[]? | filter_pending])}} else {} end)
                        end
                    else .
                    end;
                .issue.children.nodes = [.issue.children.nodes[]? | filter_pending]
            ')
        else
            # Simple filter for non-recursive
            result=$(echo "$result" | jq '.issue.children.nodes = [.issue.children.nodes[] | select(.state.type != "completed" and .state.type != "canceled")]')
        fi
    fi

    # Apply output format
    case "$FORMAT" in
    raw)
        echo "$result"
        ;;
    safe | *)
        if [ "$recursive" = "true" ]; then
            format_children_recursive "$result"
        else
            format_children_list "$result"
        fi
        ;;
    esac
}

list_relations() {
    local issue_id=""
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
            issue_id="$1"
            shift
            ;;
        esac
    done

    if [ -z "$issue_id" ]; then
        echo '{"error": "Issue ID required"}' >&2
        return 1
    fi

    local query='
    query GetRelations($id: String!) {
        issue(id: $id) {
            identifier
            title
            relations {
                nodes {
                    id
                    type
                    relatedIssue {
                        id
                        identifier
                        title
                        state { name }
                    }
                }
            }
            inverseRelations {
                nodes {
                    id
                    type
                    issue {
                        id
                        identifier
                        title
                        state { name }
                    }
                }
            }
        }
    }'

    local variables="{\"id\": \"$issue_id\"}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply output format
    case "$FORMAT" in
    raw)
        echo "$result"
        ;;
    safe | *)
        format_relations_list "$result"
        ;;
    esac
}

add_relation() {
    local issue_ref="$1"
    shift

    local blocks=""
    local blocked_by=""
    local related=""
    local duplicate=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --blocks)
            blocks="$2"
            shift 2
            ;;
        --blocked-by)
            blocked_by="$2"
            shift 2
            ;;
        --related)
            related="$2"
            shift 2
            ;;
        --duplicate)
            duplicate="$2"
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

    # Resolve the main issue ID
    local issue_id
    issue_id=$(resolve_issue_id "$issue_ref")
    if [ -z "$issue_id" ]; then
        echo "{\"error\": \"Issue not found: $issue_ref\"}" >&2
        return 1
    fi

    local relation_type=""
    local related_issue_uuid=""
    local other_ref=""

    if [ -n "$blocks" ]; then
        # This issue blocks another: create relation type "blocks" with this as issueId
        relation_type="blocks"
        other_ref="$blocks"
    elif [ -n "$blocked_by" ]; then
        # This issue is blocked by another: create relation type "blocks" with other as issueId
        # Swap: the blocker is the issueId, this issue is relatedIssueId
        relation_type="blocks"
        other_ref="$blocked_by"
        # Will swap after resolving
    elif [ -n "$related" ]; then
        relation_type="related"
        other_ref="$related"
    elif [ -n "$duplicate" ]; then
        relation_type="duplicate"
        other_ref="$duplicate"
    else
        echo '{"error": "Required: --blocks, --blocked-by, --related, or --duplicate"}' >&2
        return 1
    fi

    # Resolve the other issue ID
    related_issue_uuid=$(resolve_issue_id "$other_ref")
    if [ -z "$related_issue_uuid" ]; then
        echo "{\"error\": \"Issue not found: $other_ref\"}" >&2
        return 1
    fi

    # For blocked-by, swap the IDs (blocker becomes issueId)
    if [ -n "$blocked_by" ]; then
        local temp="$issue_id"
        issue_id="$related_issue_uuid"
        related_issue_uuid="$temp"
    fi

    # Validation for blocking relations: same-project + blocking-level (no cross-bundle children)
    if [ "$relation_type" = "blocks" ]; then
        local validation_query='
        query ValidateBlocking($id1: String!, $id2: String!) {
            issue1: issue(id: $id1) { identifier project { id name } parent { identifier } }
            issue2: issue(id: $id2) { identifier project { id name } parent { identifier } }
        }'
        local validation_result
        validation_result=$(graphql_query "$validation_query" "{\"id1\": \"$issue_id\", \"id2\": \"$related_issue_uuid\"}")

        local project1_id project2_id project1_name project2_name issue1_id issue2_id parent1_id parent2_id
        project1_id=$(echo "$validation_result" | jq -r '.issue1.project.id // empty')
        project2_id=$(echo "$validation_result" | jq -r '.issue2.project.id // empty')
        project1_name=$(echo "$validation_result" | jq -r '.issue1.project.name // "none"')
        project2_name=$(echo "$validation_result" | jq -r '.issue2.project.name // "none"')
        issue1_id=$(echo "$validation_result" | jq -r '.issue1.identifier')
        issue2_id=$(echo "$validation_result" | jq -r '.issue2.identifier')
        parent1_id=$(echo "$validation_result" | jq -r '.issue1.parent.identifier // empty')
        parent2_id=$(echo "$validation_result" | jq -r '.issue2.parent.identifier // empty')

        # Check 1: Same-project
        if [ "$project1_id" != "$project2_id" ]; then
            echo "{\"error\": \"Cross-project blocking not allowed. $issue1_id is in '$project1_name', $issue2_id is in '$project2_name'. Use --related for cross-project links, or move issues to same project.\"}" >&2
            return 1
        fi

        # Check 2: Blocking-level rule — children must not block outside their bundle
        # issue1 = blocker (from), issue2 = blocked (to)
        if [ -n "$parent1_id" ] || [ -n "$parent2_id" ]; then
            # Both are children under the same parent → intra-bundle, allowed
            if [ -n "$parent1_id" ] && [ -n "$parent2_id" ] && [ "$parent1_id" = "$parent2_id" ]; then
                : # valid intra-bundle relation
            # Blocker is a child, blocked is outside that bundle
            elif [ -n "$parent1_id" ] && [ "$parent1_id" != "$issue2_id" ]; then
                echo "{\"error\": \"Blocking-level violation: $issue1_id is a child of $parent1_id and cannot block $issue2_id (outside its bundle). Use '$parent1_id --blocks $issue2_id' for the parent-level dependency, and '$issue1_id --related $issue2_id' for traceability.\"}" >&2
                return 1
            # Blocked is a child, blocker is outside that bundle
            elif [ -n "$parent2_id" ] && [ "$parent2_id" != "$issue1_id" ]; then
                echo "{\"error\": \"Blocking-level violation: $issue2_id is a child of $parent2_id and cannot be blocked by $issue1_id (outside its bundle). Use '$issue1_id --blocks $parent2_id' for the parent-level dependency, and '$issue1_id --related $issue2_id' for traceability.\"}" >&2
                return 1
            fi
        fi
    fi

    local mutation='
    mutation CreateRelation($input: IssueRelationCreateInput!) {
        issueRelationCreate(input: $input) {
            success
            issueRelation {
                id
                type
                issue { identifier title }
                relatedIssue { identifier title }
            }
        }
    }'

    local input="{\"issueId\": \"$issue_id\", \"relatedIssueId\": \"$related_issue_uuid\", \"type\": \"$relation_type\"}"
    local result
    result=$(graphql_query "$mutation" "{\"input\": $input}")
    # Write-through: re-fetch both issues to get updated relations
    cache_refresh_issues "$issue_id" "$related_issue_uuid" 2>/dev/null || true
    local normalized
    normalized=$(normalize_mutation_response "$result" "issueRelationCreate" "issueRelation")
    emit_linear_relation_activity "$normalized"
    echo "$normalized"
}

remove_relation() {
    local first_arg="$1"
    shift || true

    # Check if first arg is a UUID (direct relation ID) or issue reference
    if [[ "$first_arg" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        # Direct UUID: delete by relation ID
        local relation_id="$first_arg"
        local mutation='
        mutation DeleteRelation($id: String!) {
            issueRelationDelete(id: $id) {
                success
            }
        }'
        local result
        result=$(graphql_query "$mutation" "{\"id\": \"$relation_id\"}")
        normalize_mutation_response "$result" "issueRelationDelete" "issueRelation"
        return
    fi

    # Issue reference with flags: find and delete the matching relation
    local issue_ref="$first_arg"
    local blocks=""
    local blocked_by=""
    local related=""
    local duplicate=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --blocks)
            blocks="$2"
            shift 2
            ;;
        --blocked-by)
            blocked_by="$2"
            shift 2
            ;;
        --related)
            related="$2"
            shift 2
            ;;
        --duplicate)
            duplicate="$2"
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

    # Resolve the main issue ID
    local issue_id
    issue_id=$(resolve_issue_id "$issue_ref")
    if [ -z "$issue_id" ]; then
        echo "{\"error\": \"Issue not found: $issue_ref\"}" >&2
        return 1
    fi

    local relation_type=""
    local other_ref=""
    local search_inverse="false"

    if [ -n "$blocks" ]; then
        relation_type="blocks"
        other_ref="$blocks"
    elif [ -n "$blocked_by" ]; then
        relation_type="blocks"
        other_ref="$blocked_by"
        search_inverse="true" # Look in inverseRelations
    elif [ -n "$related" ]; then
        relation_type="related"
        other_ref="$related"
    elif [ -n "$duplicate" ]; then
        relation_type="duplicate"
        other_ref="$duplicate"
    else
        echo '{"error": "Required: UUID or --blocks, --blocked-by, --related, or --duplicate"}' >&2
        return 1
    fi

    # Resolve the other issue identifier
    local other_identifier
    other_identifier=$(echo "$other_ref" | tr a-z A-Z)

    # Query relations to find the matching one
    local query='
    query GetRelations($id: String!) {
        issue(id: $id) {
            relations { nodes { id type relatedIssue { identifier } } }
            inverseRelations { nodes { id type issue { identifier } } }
        }
    }'
    local result
    result=$(graphql_query "$query" "{\"id\": \"$issue_id\"}")

    # Find the relation ID
    local relation_id=""
    if [ "$search_inverse" = "true" ]; then
        # Search in inverseRelations (other issue blocks this one)
        relation_id=$(echo "$result" | jq -r --arg type "$relation_type" --arg other "$other_identifier" '
            .issue.inverseRelations.nodes[] | select(.type == $type and .issue.identifier == $other) | .id' | head -n1)
    else
        # Search in relations (this issue blocks/relates to other)
        relation_id=$(echo "$result" | jq -r --arg type "$relation_type" --arg other "$other_identifier" '
            .issue.relations.nodes[] | select(.type == $type and .relatedIssue.identifier == $other) | .id' | head -n1)
    fi

    if [ -z "$relation_id" ] || [ "$relation_id" = "null" ]; then
        echo "{\"error\": \"Relation not found: $issue_ref ${relation_type} $other_ref\"}" >&2
        return 1
    fi

    # Delete the relation
    local mutation='
    mutation DeleteRelation($id: String!) {
        issueRelationDelete(id: $id) {
            success
        }
    }'
    result=$(graphql_query "$mutation" "{\"id\": \"$relation_id\"}")
    # Write-through: re-fetch both issues to update cached relations
    local other_uuid
    other_uuid=$(resolve_issue_id "$other_ref" 2>/dev/null || true)
    cache_refresh_issues "$issue_id" ${other_uuid:+"$other_uuid"} 2>/dev/null || true
    normalize_mutation_response "$result" "issueRelationDelete" "issueRelation"
}

# =============================================================================
# COMPOSITE ACTIONS - Workflow shortcuts combining multiple operations
# =============================================================================

# Activate an issue: set state to "In Progress"
# Usage: activate_issue CC-XXX [--agent <name>]
activate_issue() {
    local issue_id="$1"
    shift

    local agent=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --agent)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                agent="$2"
                shift 2
            else
                echo "{\"error\": \"--agent requires a value (e.g., --agent iced)\"}" >&2
                return 1
            fi
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

    # Update state to In Progress
    local update_result
    update_result=$(update_issue "$issue_id" --state "In Progress")
    local update_success
    update_success=$(echo "$update_result" | jq -r '.success // false')

    if [ "$update_success" != "true" ]; then
        echo "$update_result"
        return 1
    fi

    local identifier
    identifier=$(echo "$update_result" | jq -r '.identifier // empty')
    echo "{\"success\": true, \"identifier\": \"$identifier\", \"action\": \"activated\"}"
}

# Block an issue: add blocked label, create blocked-by relation, post comment
# Usage: block_issue CC-XXX --by CC-YYY [--reason "text"]
block_issue() {
    local issue_id="$1"
    shift

    local blocker=""
    local reason=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --by)
            blocker="$2"
            shift 2
            ;;
        --reason)
            reason="$2"
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

    if [ -z "$blocker" ]; then
        echo '{"error": "Required: --by <blocker-issue>"}' >&2
        return 1
    fi

    # Get current labels and add "blocked"
    local issue_result
    issue_result=$(get_issue "$issue_id" --format=raw)
    local current_labels
    current_labels=$(echo "$issue_result" | jq -r '[.issue.labels.nodes[].name] | join(",")')

    # Add blocked if not present
    if [[ ! "$current_labels" =~ blocked ]]; then
        if [ -n "$current_labels" ]; then
            current_labels="${current_labels},blocked"
        else
            current_labels="blocked"
        fi
    fi

    # Update labels
    local update_result
    update_result=$(update_issue "$issue_id" --labels "$current_labels")
    local update_success
    update_success=$(echo "$update_result" | jq -r '.success // false')

    if [ "$update_success" != "true" ]; then
        echo "$update_result"
        return 1
    fi

    # Add blocked-by relation
    local relation_result
    relation_result=$(add_relation "$issue_id" --blocked-by "$blocker")

    # Post blocking comment
    local comment_body="BLOCKED: Waiting for $blocker."
    [ -n "$reason" ] && comment_body="BLOCKED: Waiting for $blocker. $reason"

    local comment_mutation='
    mutation CreateComment($input: CommentCreateInput!) {
        commentCreate(input: $input) {
            success
            comment { id }
        }
    }'

    local escaped_body
    escaped_body=$(echo "$comment_body" | jq -Rs '.')
    local comment_input="{\"issueId\": \"$issue_id\", \"body\": $escaped_body}"

    # Comment is secondary - don't fail the whole operation if it fails
    set +e
    graphql_query "$comment_mutation" "{\"input\": $comment_input}" >/dev/null 2>&1
    set -e

    # Return combined result
    local identifier
    identifier=$(echo "$update_result" | jq -r '.identifier // empty')
    echo "{\"success\": true, \"identifier\": \"$identifier\", \"action\": \"blocked\", \"blocked_by\": \"$blocker\"}"
}

# Unblock an issue: remove blocked label, post comment
# Usage: unblock_issue CC-XXX
unblock_issue() {
    local issue_id="$1"

    # Get current labels and remove "blocked"
    local issue_result
    issue_result=$(get_issue "$issue_id" --format=raw)
    local current_labels
    current_labels=$(echo "$issue_result" | jq -r '[.issue.labels.nodes[].name | select(. != "blocked")] | join(",")')

    # Update labels (removing blocked)
    local update_result
    if [ -n "$current_labels" ]; then
        update_result=$(update_issue "$issue_id" --labels "$current_labels")
    else
        # No labels left - need to clear all labels
        # Linear requires at least empty array, but we use the original minus blocked
        update_result=$(update_issue "$issue_id" --labels "")
    fi

    local update_success
    update_success=$(echo "$update_result" | jq -r '.success // false')

    if [ "$update_success" != "true" ]; then
        echo "$update_result"
        return 1
    fi

    # Post unblocked comment
    local comment_body="Unblocked. Resuming work."

    local comment_mutation='
    mutation CreateComment($input: CommentCreateInput!) {
        commentCreate(input: $input) {
            success
            comment { id }
        }
    }'

    local escaped_body
    escaped_body=$(echo "$comment_body" | jq -Rs '.')
    local comment_input="{\"issueId\": \"$issue_id\", \"body\": $escaped_body}"

    # Comment is secondary - don't fail the whole operation if it fails
    set +e
    graphql_query "$comment_mutation" "{\"input\": $comment_input}" >/dev/null 2>&1
    set -e

    # Return combined result
    local identifier
    identifier=$(echo "$update_result" | jq -r '.identifier // empty')
    echo "{\"success\": true, \"identifier\": \"$identifier\", \"action\": \"unblocked\"}"
}

# Complete an issue: set state to "Done"
# Usage: complete_issue CC-XXX
complete_issue() {
    local issue_id="$1"

    local update_result
    update_result=$(update_issue "$issue_id" --state "Done")

    local update_success
    update_success=$(echo "$update_result" | jq -r '.success // false')

    if [ "$update_success" != "true" ]; then
        echo "$update_result"
        return 1
    fi

    # Return result
    local identifier
    identifier=$(echo "$update_result" | jq -r '.identifier // empty')
    echo "{\"success\": true, \"identifier\": \"$identifier\", \"action\": \"completed\"}"
}

# Validate issue completion: check state is "In Progress" and has Completion Summary comment
# Usage: validate_completion CC-XXX [CC-YYY ...]
#        validate_completion CC-XXX --include-children-of CC-XXX
# Supports multiple issues for bundle validation
validate_completion() {
    local issue_ids=()
    local include_children_of=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --include-children-of)
            include_children_of="$2"
            shift 2
            ;;
        --include-children-of=*)
            include_children_of="${1#--include-children-of=}"
            shift
            ;;
        *)
            issue_ids+=("$1")
            shift
            ;;
        esac
    done

    if [ ${#issue_ids[@]} -eq 0 ]; then
        echo '{"error": "At least one issue ID required"}' >&2
        return 1
    fi

    # If --include-children-of specified, fetch bundle and extract pending children
    if [ -n "$include_children_of" ]; then
        local bundle
        if ! bundle=$(get_issue "$include_children_of" --with-bundle); then
            echo "{\"error\": \"Failed to fetch bundle for: $include_children_of\"}" >&2
            return 1
        fi
        if [ -z "$bundle" ]; then
            echo "{\"error\": \"Failed to fetch bundle for: $include_children_of\"}" >&2
            return 1
        fi
        local child_ids
        child_ids=$(echo "$bundle" | jq -r '[.children[] | select(.state_type | IN("completed", "canceled") | not) | .id] | .[]' 2>/dev/null)
        for child_id in $child_ids; do
            issue_ids+=("$child_id")
        done
    fi

    local results="[]"
    local all_ok="true"

    for issue_id in "${issue_ids[@]}"; do
        # Get issue state
        local issue
        issue=$(get_issue "$issue_id")
        local state
        state=$(echo "$issue" | jq -r '.state // ""')
        local parent_id
        parent_id=$(echo "$issue" | jq -r '.parent_id // ""')

        # Check for Completion Summary comment
        local comments
        comments=$(json_or_default '[]' array "$SCRIPT_DIR/comments.sh" list "$issue_id")
        local has_summary
        has_summary=$(echo "$comments" | jq 'any(.[]; .body | (contains("Completion Summary") or contains("Bundle Complete")))')

        local result
        result=$(build_completion_validation_result "$issue_id" "$state" "$parent_id" "$has_summary")

        if [ "$(echo "$result" | jq -r '.ok')" != "true" ]; then
            all_ok="false"
        fi

        # Append to results
        results=$(echo "$results" | jq --argjson result "$result" '. + [$result]')
    done

    echo "$results" | jq --argjson all_ok "$all_ok" '{results: ., all_ok: $all_ok}'
}

main() {
    # Main routing
    action="${1:-help}"
    shift || true

    case "$action" in
    list)
        if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        list_issues "$@"
        ;;
    get)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        get_issue "$@"
        ;;
    bulk-get)
        if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        bulk_get_issues "$@"
        ;;
    bulk-update)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        bulk_update_issues "$@"
        ;;
    create)
        if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        create_issue "$@"
        ;;
    update)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        update_issue "$@"
        ;;
    archive)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        archive_issue "$@"
        ;;
    trash | delete)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        trash_issue "$@"
        ;;
    children)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        list_children "$@"
        ;;
    list-relations | relations)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        list_relations "$@"
        ;;
    add-relation)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        add_relation "$@"
        ;;
    remove-relation)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        remove_relation "$@"
        ;;
    # Composite workflow actions
    activate)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        activate_issue "$@"
        ;;
    block)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        block_issue "$@"
        ;;
    unblock)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        unblock_issue "$@"
        ;;
    complete)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        complete_issue "$@"
        ;;
    validate-completion)
        if [ -z "${1:-}" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
            show_help
            exit 0
        fi
        validate_completion "$@"
        ;;
    move)
        echo "Error: 'move' is not an action. To move an issue to a different project:" >&2
        echo "  linear.sh issues update [ISSUE_ID] --project \"Target Project\"" >&2
        exit 1
        ;;
    comment)
        echo "Error: Comments are a separate resource. Use:" >&2
        echo "  linear.sh comments create [ISSUE_ID] --body \"Your comment\"" >&2
        echo "  linear.sh cache comments list [ISSUE_ID]" >&2
        exit 1
        ;;
    help | --help | -h)
        show_help
        ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'issues.sh --help' for usage." >&2
        exit 1
        ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
