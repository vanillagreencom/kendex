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

read_description_file() {
    local description_file="$1"
    if [[ -z "$description_file" ]]; then
        echo '{"error": "--description-file requires a non-empty path argument"}' >&2
        return 1
    fi
    if [[ ! -r "$description_file" ]]; then
        echo "{\"error\": \"--description-file path not readable: $description_file\"}" >&2
        return 1
    fi
    description=$(<"$description_file")
}

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
  activate       Claim issue: set "In Progress" (--agent applies agent:<name> label)
  block          Block issue: add label + relation + comment
  unblock        Unblock issue: remove label + comment
  complete       Complete issue: post optional summary comment, then set "Done"
  validate-completion  Pre-merge check: state + summary comment
                 (--include-children-of <ID> for bundles)

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
  --description-file <path>  Read description from file (preferred for markdown)
  --label(s) <a,b,c>    Comma-separated label names
  --project <name|uuid> Project (name or UUID, auto-resolved)
  --state <name>        Initial state (case-sensitive, fails with available list)
  --priority <0-4>      Priority: 0=None, 1=Urgent, 2=High, 3=Normal, 4=Low
  --estimate <1-5>      Effort estimate (points)
  --assignee <name|me>  Assignee
  --parent <id>         Parent issue ID (creates sub-issue)
  --milestone <name|uuid> Project milestone (name or UUID)
  --cycle <id>          Cycle (sprint) ID
  --format=ids          Print ONLY the created issue identifier (for capture;
                        default output is the full JSON create response)

Update Options:
  --state <name>        New state
  --label(s) <a,b,c>    Replace labels (comma-separated)
  --title <text>        New title
  --description <text>  New description
  --description-file <path>  Read new description from file (preferred for markdown)
  --project <name|uuid> Move to project (name or UUID, auto-resolved)
  --priority <0-4>      Priority: 0=None, 1=Urgent, 2=High, 3=Normal, 4=Low
  --estimate <0-5>      Effort estimate (points); 0 clears the estimate (unset)
  --clear-estimate      Clear the estimate (unset; e.g. coordination parents = no estimate)
  --assignee <name|me>  Change assignee
  --parent <id>         Set parent issue (convert to sub-issue)
  --remove-parent       Remove parent (convert to top-level issue)
  --milestone <name|uuid> Set project milestone (name or UUID)
  --cycle <id>          Set cycle (sprint) ID
  --clear-cycle         Remove cycle assignment
  --sort-order <float>  Manual sort position (lower = higher; parent/standalone only)
  --format <fmt>        Output format for the updated issue: safe | compact | ids |
                        raw. When omitted, emits the mutation summary
                        ({success, identifier, url, data}) as before.

Relation Options (add-relation):
  --blocks <id>         This issue blocks another
  --blocked-by <id>     This issue is blocked by another
  --related <id>        Mark as related
  --duplicate <id>      Mark as duplicate

Activate Options:
  --agent <name>        Apply the exclusive agent:<name> issue label together
                        with the "In Progress" transition (replaces any existing
                        agent:* label, preserves other labels). Fails without
                        changing state when the label does not exist.

Complete Options:
  --summary <text>       Post a completion summary comment, then set "Done"
  --summary-file <path>  Read the summary from a file (preferred for markdown)
  The comment is posted BEFORE the state transition; if posting fails the issue
  state is unchanged. Text lacking a "Completion Summary"/"Bundle Complete"
  marker is prefixed with a "## Completion Summary" heading so
  validate-completion detects it.

Validate-Completion:
  Pre-merge validation. Session-root issues (positional targets) are expected
  in "In Progress" or "In Review" — "Done" fails state_ok because managed
  session roots stay pre-merge until PR merge. This pre-merge state rule applies
  ONLY to the session root, not to expanded bundle children.
  Bundle children expanded via --include-children-of are expected in "Done":
  every completed child IS included and validates as Done/pass (a still-pending
  child fails state_ok). Canceled children are excluded from the expansion —
  abandoned work can never be "Done" and is not a pending gap. Each validated
  issue must also have a comment containing "Completion Summary" or
  "Bundle Complete".

Examples:
  # Basic operations
  issues.sh list --label "backend" --state "Todo"
  issues.sh get PROJ-42
  issues.sh create --title "New task" --labels "backend,priority:high"
  issues.sh create --title "Bundle" --project "Phase 2" --format=ids  # Print only the new identifier
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

  # Estimate (1-5 real points; clear for coordination-only parents)
  issues.sh update PROJ-42 --estimate 3
  issues.sh update PROJ-42 --clear-estimate      # Unset estimate (coordination parent)
  issues.sh update PROJ-42 --estimate 0          # Alias for --clear-estimate

  # Bulk operations (reduces API calls)
  issues.sh list --project-id <uuid> --with-relations   # Single query with all relations
  issues.sh bulk-get PROJ-184 PROJ-185 PROJ-186 PROJ-187    # Multiple issues with full details

  # Workflow actions (dev shortcuts)
  issues.sh activate PROJ-42 --agent rust        # In Progress + agent:rust label
  issues.sh block PROJ-42 --by PROJ-41 --reason "Need market data types first"
  issues.sh unblock PROJ-42                      # Resume after blocker resolved
  issues.sh complete PROJ-42                     # Mark done
  issues.sh complete PROJ-42 --summary-file tmp/completion-summary-PROJ-42.md  # Summary comment, then done
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
        --remove-parent | --clear-cycle | --clear-estimate)
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
    local description_file=""
    local labels=""
    local project=""
    local state=""
    local priority=""
    local assignee=""
    local parent=""
    local milestone=""
    local cycle=""
    local estimate=""
    local requested_parent_id=""
    local output_format=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --title)
            title="$2"
            shift 2
            ;;
        --format)
            output_format="$2"
            shift 2
            ;;
        --format=*)
            output_format="${1#--format=}"
            shift
            ;;
        --team)
            team="$2"
            shift 2
            ;;
        --description)
            description="$2"
            shift 2
            ;;
        --description-file)
            description_file="$2"
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
        --parent=*)
            parent="${1#*=}"
            shift
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

    if [[ -n "$description" && -n "$description_file" ]]; then
        echo '{"error": "--description and --description-file are mutually exclusive"}' >&2
        return 1
    fi
    if [[ -n "$description_file" ]]; then
        read_description_file "$description_file"
    fi

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
        if ! parent_id=$(resolve_issue_id "$parent") || [ -z "$parent_id" ]; then
            echo "{\"error\": \"Parent issue not found: $parent\"}" >&2
            return 1
        fi
        requested_parent_id="$parent_id"
        input_parts+=("\"parentId\": \"$requested_parent_id\"")
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
    if [[ -n "$requested_parent_id" ]]; then
        if [[ -z "$created_issue" || "$created_issue" = "null" ]]; then
            jq -nc --arg parent "$parent" \
                '{error: "Issue created but response omitted issue object; cannot verify requested parent " + $parent}' >&2
            return 1
        fi

        local created_parent_id
        created_parent_id=$(echo "$created_issue" | jq -r '.parent.id // empty')
        if [ "$created_parent_id" != "$requested_parent_id" ]; then
            local child_issue_id
            child_issue_id=$(echo "$created_issue" | jq -r '.id // empty')
            if [ -z "$child_issue_id" ]; then
                jq -nc --arg parent "$parent" \
                    '{error: "Issue created but response omitted child id; cannot verify requested parent " + $parent}' >&2
                return 1
            fi

            local parent_fix_mutation="
            mutation EnsureIssueParent(\$id: String!, \$input: IssueUpdateInput!) {
                issueUpdate(id: \$id, input: \$input) {
                    success
                    issue {
                        $ISSUE_RETURN_FIELDS
                    }
                }
            }"
            local parent_fix_variables
            parent_fix_variables=$(jq -cn --arg id "$child_issue_id" --arg parentId "$requested_parent_id" \
                '{id: $id, input: {parentId: $parentId}}')
            local parent_fix_result
            if ! parent_fix_result=$(graphql_query "$parent_fix_mutation" "$parent_fix_variables"); then
                jq -nc --arg child "$child_issue_id" --arg parent "$parent" \
                    '{error: "Issue " + $child + " was created, but Linear did not attach parent " + $parent + " during create and the follow-up repair failed"}' >&2
                return 1
            fi

            local updated_issue
            updated_issue=$(echo "$parent_fix_result" | jq '.issueUpdate.issue // empty')
            local updated_parent_id
            updated_parent_id=$(echo "$updated_issue" | jq -r '.parent.id // empty')
            if [ "$updated_parent_id" != "$requested_parent_id" ]; then
                jq -nc --arg child "$child_issue_id" --arg parent "$parent" \
                    '{error: "Issue " + $child + " was created, but parent " + $parent + " could not be verified after follow-up repair"}' >&2
                return 1
            fi

            result=$(echo "$parent_fix_result" | jq -c '{issueCreate: {success: (.issueUpdate.success // false), issue: .issueUpdate.issue}}')
            created_issue="$updated_issue"
        fi
    fi
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
    # --format=ids mirrors the query-command contract: print ONLY the created
    # identifier (one per line, nothing else) so workflows can capture it
    # deterministically. Any other/absent format keeps the default JSON output.
    if [ "$output_format" = "ids" ]; then
        echo "$normalized" | jq -r '.identifier // empty'
    else
        echo "$normalized"
    fi
}

update_issue() {
    local issue_id="$1"
    shift

    local state=""
    local labels=""
    local title=""
    local description=""
    local description_file=""
    local project=""
    local priority=""
    local assignee=""
    local parent=""
    local remove_parent="false"
    local milestone=""
    local cycle=""
    local clear_cycle="false"
    local estimate=""
    local clear_estimate="false"
    local sort_order=""
    local output_format=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --format)
            output_format="$2"
            shift 2
            ;;
        --format=*)
            output_format="${1#--format=}"
            shift
            ;;
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
        --description-file)
            description_file="$2"
            shift 2
            ;;
        --description-file=*)
            description_file="${1#*=}"
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
        --clear-estimate)
            clear_estimate="true"
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

    if [[ -n "$description" && -n "$description_file" ]]; then
        echo '{"error": "--description and --description-file are mutually exclusive"}' >&2
        return 1
    fi
    if [[ -n "$description_file" ]]; then
        read_description_file "$description_file"
    fi

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

    # Handle estimate. Real estimates are 1-5; Linear represents "no estimate" as
    # null. Clear the estimate via --clear-estimate or the --estimate 0 alias
    # (used to bring coordination-only parents into the estimate-0 format).
    if [ "$clear_estimate" = "true" ] && [ -n "$estimate" ] && [ "$estimate" != "0" ]; then
        echo '{"error": "Use either --estimate <1-5> or --clear-estimate, not both"}' >&2
        return 1
    elif [ "$clear_estimate" = "true" ] || [ "$estimate" = "0" ]; then
        input_parts+=("\"estimate\": null")
    elif [ -n "$estimate" ]; then
        if [[ "$estimate" =~ ^[1-5]$ ]]; then
            input_parts+=("\"estimate\": $estimate")
        else
            echo '{"error": "Invalid --estimate: must be an integer 1-5 (use 0 or --clear-estimate to unset)"}' >&2
            return 1
        fi
    fi

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

    # Output format. Default (no --format) preserves the historical mutation
    # summary so existing callers that parse .success/.identifier/.data keep
    # working. When --format is passed explicitly, emit the updated issue in the
    # documented read format (safe is the README default), consistent with the
    # query actions. `safe`/`compact` reuse the shared formatters by wrapping the
    # mutation's issue in {issue: ...}; a response that omitted the issue object
    # falls back to the mutation summary.
    local wrapped_issue=""
    if [[ -n "$updated_issue" && "$updated_issue" != "null" ]]; then
        wrapped_issue=$(jq -n --argjson i "$updated_issue" '{issue: $i}')
    fi
    case "$output_format" in
    safe)
        if [[ -n "$wrapped_issue" ]]; then
            format_issue_single "$wrapped_issue"
        else
            echo "$normalized"
        fi
        ;;
    compact)
        if [[ -n "$wrapped_issue" ]]; then
            format_issue_compact "$wrapped_issue"
        else
            echo "$normalized"
        fi
        ;;
    ids)
        echo "$normalized" | jq -r '.identifier // empty'
        ;;
    raw)
        echo "$result"
        ;;
    "" | *)
        echo "$normalized"
        ;;
    esac
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

# Parent levels selected per ancestor query. A chain that comes back with
# exactly this many parents may be cut off by the query depth rather than
# rooted; extend_ancestor_chain keeps fetching until a short chunk proves a
# true root (null parent).
ANCESTOR_FETCH_DEPTH=5
ANCESTOR_FETCH_MAX_CHUNKS=20

# build_parent_selection DEPTH — nested GraphQL parent selection, DEPTH levels
build_parent_selection() {
    local depth="$1" selection="" i
    for ((i = 0; i < depth; i++)); do
        selection="parent { id identifier $selection }"
    done
    printf '%s' "$selection"
}

# extend_ancestor_chain IDENTIFIER_CHAIN ID_CHAIN
# Complete a possibly-truncated ancestor chain (newline-separated identifiers,
# self first). A chain shorter than ANCESTOR_FETCH_DEPTH+1 entries already
# ends at a true root; a full-length chain may instead be cut off by the
# query depth, so follow up with chunked ancestor queries for the deepest
# entry until a chunk comes back short. Prints the completed chain. Fails
# (error on stderr) when the hierarchy exceeds the chunk bound or a lookup
# misbehaves — callers must treat failure as "do not derive remediation",
# never as "chain is complete".
extend_ancestor_chain() {
    local chain="$1"
    local id_chain="$2"
    local full=$((ANCESTOR_FETCH_DEPTH + 1))
    local chunks=0
    local segment="$chain"
    local deepest deepest_id chunk_result rest segment_ids rest_ids

    while [ "$(printf '%s\n' "$segment" | grep -c '')" -ge "$full" ]; do
        chunks=$((chunks + 1))
        if [ "$chunks" -gt "$ANCESTOR_FETCH_MAX_CHUNKS" ]; then
            echo "{\"error\": \"Hierarchy too deep to validate: no root issue within $((ANCESTOR_FETCH_DEPTH + ANCESTOR_FETCH_MAX_CHUNKS * ANCESTOR_FETCH_DEPTH)) ancestor levels. Refusing to validate the blocking relation against a truncated ancestor chain.\"}" >&2
            return 1
        fi
        deepest=$(printf '%s\n' "$chain" | tail -n 1)
        deepest_id=$(printf '%s\n' "$id_chain" | tail -n 1)
        local chunk_query="
        query AncestorChunk(\$id: String!) {
            issue(id: \$id) { id identifier $(build_parent_selection "$ANCESTOR_FETCH_DEPTH") }
        }"
        chunk_result=$(graphql_query "$chunk_query" "{\"id\": \"$deepest\"}") || return 1
        local chunk_issue
        chunk_issue=$(echo "$chunk_result" | jq -c '.issue')
        validate_parent_chain_shape "$chunk_issue" "$ANCESTOR_FETCH_DEPTH" "$deepest" || return 1
        segment=$(echo "$chunk_result" | jq -r '.issue | recurse(.parent; . != null) | .identifier')
        segment_ids=$(echo "$chunk_result" | jq -r '.issue | recurse(.parent; . != null) | .id')
        if [ "$(printf '%s\n' "$segment" | sed -n '1p')" != "$deepest" ] \
            || [ "$(printf '%s\n' "$segment_ids" | sed -n '1p')" != "$deepest_id" ]; then
            echo "{\"error\": \"Ancestor lookup for $deepest returned an unexpected issue; refusing to validate the blocking relation against an incomplete ancestor chain.\"}" >&2
            return 1
        fi
        rest=$(printf '%s\n' "$segment" | tail -n +2)
        rest_ids=$(printf '%s\n' "$segment_ids" | tail -n +2)
        if hierarchy_chains_overlap "$rest" "$chain" \
            || hierarchy_chains_overlap "$rest_ids" "$id_chain"; then
            echo "{\"error\": \"Hierarchy validation failed closed: parent cycle detected while extending '$deepest'.\"}" >&2
            return 1
        fi
        if [ -n "$rest" ]; then
            chain="$chain
$rest"
            id_chain="$id_chain
$rest_ids"
        fi
    done

    printf '%s\n' "$chain"
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

    # Validation for blocking relations: same-project + blocking-level rule
    # (blocking relations connect peers of one bundle — see issue-validation.sh)
    if [ "$relation_type" = "blocks" ]; then
        # The parent chain is fetched ANCESTOR_FETCH_DEPTH levels per query and
        # extended chunk-by-chunk to a proven root when remediation needs it.
        local ancestor_selection
        ancestor_selection=$(build_parent_selection "$ANCESTOR_FETCH_DEPTH")
        local validation_query="
        query ValidateBlocking(\$id1: String!, \$id2: String!) {
            issue1: issue(id: \$id1) { id identifier project { id name } $ancestor_selection }
            issue2: issue(id: \$id2) { id identifier project { id name } $ancestor_selection }
        }"
        local validation_result
        validation_result=$(graphql_query "$validation_query" "{\"id1\": \"$issue_id\", \"id2\": \"$related_issue_uuid\"}")

        local issue1_json issue2_json
        issue1_json=$(echo "$validation_result" | jq -c '.issue1')
        issue2_json=$(echo "$validation_result" | jq -c '.issue2')
        validate_parent_chain_shape "$issue1_json" "$ANCESTOR_FETCH_DEPTH" "$issue_id" || return 1
        validate_parent_chain_shape "$issue2_json" "$ANCESTOR_FETCH_DEPTH" "$related_issue_uuid" || return 1
        validate_issue_project_shape "$issue1_json" "$issue_id" || return 1
        validate_issue_project_shape "$issue2_json" "$related_issue_uuid" || return 1

        local project1_id project2_id project1_name project2_name issue1_id issue2_id
        project1_id=$(echo "$validation_result" | jq -r 'if .issue1.project == null then "__NO_PROJECT__" else .issue1.project.id end')
        project2_id=$(echo "$validation_result" | jq -r 'if .issue2.project == null then "__NO_PROJECT__" else .issue2.project.id end')
        project1_name=$(echo "$validation_result" | jq -r 'if .issue1.project == null then "none" else .issue1.project.name end')
        project2_name=$(echo "$validation_result" | jq -r 'if .issue2.project == null then "none" else .issue2.project.name end')
        issue1_id=$(echo "$validation_result" | jq -r '.issue1.identifier')
        issue2_id=$(echo "$validation_result" | jq -r '.issue2.identifier')

        # Check 1: Same-project
        if [ "$project1_id" != "$project2_id" ]; then
            echo "{\"error\": \"Cross-project blocking not allowed. $issue1_id is in '$project1_name', $issue2_id is in '$project2_name'. Use --related for cross-project links, or move issues to same project.\"}" >&2
            return 1
        fi

        # Check 2: Blocking-level rule — a blocking relation connects peers of
        # one bundle: same direct parent, or both top-level. The rejection
        # message derives its remediation from the same predicate
        # (blocking_level_ok), so a prescribed command is never itself rejected.
        # issue1 = blocker (from), issue2 = blocked (to)
        local chain1 chain2 id_chain1 id_chain2 parent1_id parent2_id
        chain1=$(echo "$validation_result" | jq -r '.issue1 | recurse(.parent; . != null) | .identifier')
        chain2=$(echo "$validation_result" | jq -r '.issue2 | recurse(.parent; . != null) | .identifier')
        id_chain1=$(echo "$validation_result" | jq -r '.issue1 | recurse(.parent; . != null) | .id')
        id_chain2=$(echo "$validation_result" | jq -r '.issue2 | recurse(.parent; . != null) | .id')

        # A full eager selection may hide one more parent edge. Prove both
        # chains terminate at explicit validated roots before any same-parent
        # shortcut can accept the relation. Shallow chains return unchanged.
        chain1=$(extend_ancestor_chain "$chain1" "$id_chain1") || return 1
        chain2=$(extend_ancestor_chain "$chain2" "$id_chain2") || return 1
        parent1_id=$(sed -n '2p' <<<"$chain1")
        parent2_id=$(sed -n '2p' <<<"$chain2")

        if ! blocking_level_ok "$parent1_id" "$parent2_id"; then
            local violation_message
            violation_message=$(blocking_level_violation_message "$issue1_id" "$issue2_id" "$chain1" "$chain2")
            echo "{\"error\": \"$violation_message\"}" >&2
            return 1
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
# --agent applies the exclusive agent:<name> issue label in the same
# issueUpdate mutation as the state change. The label is validated before any
# mutation, so an unknown agent fails without touching issue state.
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

    local final_labels=""
    if [ -n "$agent" ]; then
        local agent_label="agent:$agent"
        # Fail before the state change when the agent label doesn't resolve —
        # update_issue's own label handling is warn+skip, which would silently
        # activate without the label.
        local agent_label_id
        if ! agent_label_id=$(resolve_label_id "$agent_label") || [ -z "$agent_label_id" ]; then
            echo "{\"error\": \"Agent label not found: '$agent_label'. Issue state unchanged. Verify agent labels with 'linear.sh cache labels list --format=safe'.\"}" >&2
            return 1
        fi

        # Agent labels are exclusive: replace any existing agent:* label and
        # preserve all other labels (--labels replaces the full set).
        local issue_result
        issue_result=$(get_issue "$issue_id" --format=raw)
        final_labels=$(echo "$issue_result" | jq -r --arg agent_label "$agent_label" \
            '[.issue.labels.nodes[].name | select(startswith("agent:") | not)] + [$agent_label] | join(",")')
    fi

    # Update state to In Progress (single mutation carries the label set too)
    local update_result
    if [ -n "$agent" ]; then
        update_result=$(update_issue "$issue_id" --state "In Progress" --labels "$final_labels")
    else
        update_result=$(update_issue "$issue_id" --state "In Progress")
    fi
    local update_success
    update_success=$(echo "$update_result" | jq -r '.success // false')

    if [ "$update_success" != "true" ]; then
        echo "$update_result"
        return 1
    fi

    local identifier
    identifier=$(echo "$update_result" | jq -r '.identifier // empty')
    if [ -n "$agent" ]; then
        echo "{\"success\": true, \"identifier\": \"$identifier\", \"action\": \"activated\", \"agent\": \"$agent\"}"
    else
        echo "{\"success\": true, \"identifier\": \"$identifier\", \"action\": \"activated\"}"
    fi
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
# Usage: complete_issue CC-XXX [--summary <text> | --summary-file <path>]
# The summary comment is posted BEFORE the state transition so a failed post
# never yields a Done issue without a completion summary. Unknown or trailing
# arguments are rejected before any mutation.
complete_issue() {
    local issue_id="$1"
    shift

    local summary=""
    local summary_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --summary)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                summary="$2"
                shift 2
            else
                echo '{"error": "--summary requires a text value"}' >&2
                return 1
            fi
            ;;
        --summary=*)
            summary="${1#*=}"
            if [ -z "$summary" ]; then
                echo '{"error": "--summary requires a text value"}' >&2
                return 1
            fi
            shift
            ;;
        --summary-file)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                summary_file="$2"
                shift 2
            else
                echo '{"error": "--summary-file requires a path argument"}' >&2
                return 1
            fi
            ;;
        --summary-file=*)
            summary_file="${1#*=}"
            if [ -z "$summary_file" ]; then
                echo '{"error": "--summary-file requires a path argument"}' >&2
                return 1
            fi
            shift
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Usage: issues.sh complete <issue-id> [--summary <text> | --summary-file <path>]\"}" >&2
            return 1
            ;;
        *)
            echo "{\"error\": \"Unexpected argument: $1. Usage: issues.sh complete <issue-id> [--summary <text> | --summary-file <path>]\"}" >&2
            return 1
            ;;
        esac
    done

    if [[ -n "$summary" && -n "$summary_file" ]]; then
        echo '{"error": "--summary and --summary-file are mutually exclusive"}' >&2
        return 1
    fi
    if [[ -n "$summary_file" ]]; then
        if [[ ! -r "$summary_file" ]]; then
            echo "{\"error\": \"--summary-file path not readable: $summary_file\"}" >&2
            return 1
        fi
        summary=$(<"$summary_file")
        if [ -z "$summary" ]; then
            echo "{\"error\": \"--summary-file is empty: $summary_file\"}" >&2
            return 1
        fi
    fi

    if [ -n "$summary" ]; then
        # validate-completion detects the summary by these markers; prefix the
        # canonical heading when the caller's text carries neither.
        if [[ "$summary" != *"Completion Summary"* && "$summary" != *"Bundle Complete"* ]]; then
            summary="## Completion Summary"$'\n\n'"$summary"
        fi

        # Post the comment first: a posting failure must leave state unchanged
        local comment_result=""
        local comment_rc=0
        set +e
        comment_result=$("$SCRIPT_DIR/comments.sh" create "$issue_id" --body "$summary")
        comment_rc=$?
        set -e
        if [ "$comment_rc" -ne 0 ] || [ "$(echo "$comment_result" | jq -r '.success // false')" != "true" ]; then
            echo "{\"error\": \"Completion summary comment failed for $issue_id. Issue state unchanged.\"}" >&2
            return 1
        fi
    fi

    local update_result
    local update_rc=0
    set +e
    update_result=$(update_issue "$issue_id" --state "Done")
    update_rc=$?
    set -e

    local update_success
    update_success=$(echo "$update_result" | jq -r '.success // false')

    if [ "$update_rc" -ne 0 ] || [ "$update_success" != "true" ]; then
        if [ -n "$summary" ]; then
            echo "{\"error\": \"State transition to Done failed after the summary comment was posted. Rerun 'issues.sh complete $issue_id' without summary flags to avoid a duplicate comment.\"}" >&2
        fi
        if [ -n "$update_result" ]; then
            echo "$update_result"
        fi
        return 1
    fi

    # Return result
    local identifier
    identifier=$(echo "$update_result" | jq -r '.identifier // empty')
    if [ -n "$summary" ]; then
        echo "{\"success\": true, \"identifier\": \"$identifier\", \"action\": \"completed\", \"summary_posted\": true}"
    else
        echo "{\"success\": true, \"identifier\": \"$identifier\", \"action\": \"completed\"}"
    fi
}

# Validate issue completion: check state is "In Progress" and has Completion Summary comment
# Usage: validate_completion CC-XXX [CC-YYY ...]
#        validate_completion CC-XXX --include-children-of CC-XXX
# Supports multiple issues for bundle validation
validate_completion() {
    local issue_ids=()
    # Roles parallel issue_ids: positional targets are managed session roots;
    # bundle-expanded children (below) are bundle sub-issues.
    local roles=()
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
            roles+=("session-root")
            shift
            ;;
        esac
    done

    if [ ${#issue_ids[@]} -eq 0 ]; then
        echo '{"error": "At least one issue ID required"}' >&2
        return 1
    fi

    # If --include-children-of specified, fetch the bundle and expand its
    # children as bundle-child validation targets. Per the documented bundle
    # contract each child is expected to be "Done", so COMPLETED children must
    # be INCLUDED (they are exactly what validates as Done) — not dropped.
    # Only CANCELED children are excluded: abandoned work can never be "Done",
    # is not a pending gap, and including it would permanently fail any bundle
    # that legitimately canceled a sub-issue. This mirrors the `children
    # --pending` filter, which likewise treats completed vs canceled distinctly
    # from still-pending work.
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
        child_ids=$(echo "$bundle" | jq -r '[.children[] | select(.state_type != "canceled") | .id] | .[]' 2>/dev/null)
        for child_id in $child_ids; do
            issue_ids+=("$child_id")
            roles+=("bundle-child")
        done
    fi

    local results="[]"
    local all_ok="true"

    local i
    for i in "${!issue_ids[@]}"; do
        local issue_id="${issue_ids[$i]}"
        local role="${roles[$i]}"
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
        result=$(build_completion_validation_result "$issue_id" "$state" "$parent_id" "$has_summary" "$role")

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
    view | show)
        echo "Error: Unknown action '$action' — supported issue lookups:" >&2
        echo "  linear.sh issues get [ISSUE_ID]" >&2
        echo "  linear.sh issues bulk-get [ISSUE_ID_1] [ISSUE_ID_2]   # live state (post-mutation verification)" >&2
        echo "  linear.sh cache issues get [ISSUE_ID]                 # cache read" >&2
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
