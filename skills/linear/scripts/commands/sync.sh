#!/bin/bash
# Linear API Local Cache - Sync Command
# Usage: sync.sh [--full] [--if-stale N] [--reconcile] [--stats]
# Syncs Linear data to local JSON cache files

set -euo pipefail
shopt -s inherit_errexit  # Propagate set -e into command substitutions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/cache.sh"
source "$SCRIPT_DIR/../lib/attachments.sh"

show_help() {
    cat << 'EOF'
Linear Cache Sync

Usage: sync.sh [options]

Options:
  --full              Force full sync (ignore existing cache)
  --if-stale <N>      Only sync if cache is older than N minutes (skip if fresh)
  --reconcile         Force reconciliation (check for externally deleted issues)
  --no-attachments    Skip downloading file attachments/images
  --stats             Show cache statistics after sync
  --help              Show this help

Notes:
  Reconciliation detects issues deleted/archived outside our tools (e.g., Linear web).
  Runs automatically once per hour, or on --full/--reconcile.
  Our own archive/trash/delete commands update cache immediately (no sync needed).

Examples:
  sync.sh                       # Incremental sync (or full if no cache)
  sync.sh --full                # Full sync from scratch
  sync.sh --if-stale 15         # Sync only if cache > 15 minutes old
  sync.sh --reconcile           # Incremental sync + forced reconciliation
  sync.sh --stats               # Sync and show statistics
EOF
}

# =============================================================================
# SYNC FUNCTIONS
# =============================================================================

sync_issues() {
    local since="$1"  # Empty for full sync, ISO date for incremental

    local filter_json="{}"
    if [[ -n "$since" ]]; then
        filter_json="{\"updatedAt\": {\"gte\": \"$since\"}}"
    fi

    local query='
    query SyncIssues($filter: IssueFilter, $first: Int, $includeArchived: Boolean, $after: String) {
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
                comments { nodes { id body createdAt updatedAt user { name } } }
                relations { nodes { id type relatedIssue { id identifier title state { name type } } } }
                inverseRelations { nodes { id type issue { id identifier title state { name type } } } }
            }
        }
    }'

    local all_nodes="[]"
    local cursor="null"
    local page_count=0
    local max_pages=200

    while true; do
        local variables="{\"filter\": $filter_json, \"first\": 75, \"includeArchived\": true, \"after\": $cursor}"
        local result
        result=$(graphql_query "$query" "$variables")

        local nodes
        nodes=$(echo "$result" | jq '.issues.nodes')
        all_nodes=$(echo "$all_nodes" "$nodes" | jq -s 'add')

        local has_next
        has_next=$(echo "$result" | jq -r '.issues.pageInfo.hasNextPage')

        page_count=$((page_count + 1))

        if [[ "$has_next" != "true" ]] || (( page_count >= max_pages )); then
            break
        fi

        cursor=$(echo "$result" | jq '.issues.pageInfo.endCursor')
    done

    echo "$all_nodes"
}

# Extract comments from synced issue nodes into per-issue files, then strip from issues
extract_comments() {
    local issues_file="$1"
    cache_ensure_dir

    # Write comment files for issues that have comments
    jq -c '.[] | select(.comments.nodes | length > 0) | {id: .identifier, comments: .comments.nodes}' \
        "$issues_file" 2>/dev/null | while IFS= read -r line; do
        local issue_id
        issue_id=$(echo "$line" | jq -r '.id')
        echo "$line" | jq '.comments' > "$CACHE_DIR/comments/$issue_id.json"
    done

    # Remove stale comment files for issues with 0 comments
    jq -r '.[] | select((.comments.nodes | length) == 0) | .identifier' \
        "$issues_file" 2>/dev/null | while IFS= read -r issue_id; do
        rm -f "$CACHE_DIR/comments/$issue_id.json" "$CACHE_DIR/comments/$issue_id.json.lock"
    done

    # Strip comments from issues to keep issues.json lean
    jq '[.[] | del(.comments)]' "$issues_file" > "$issues_file.tmp"
    mv "$issues_file.tmp" "$issues_file"
}

sync_projects() {
    local since="$1"

    local filter_json="{}"
    if [[ -n "$since" ]]; then
        filter_json="{\"updatedAt\": {\"gte\": \"$since\"}}"
    fi

    # Fetch projects with basic fields (paginated)
    local query='
    query SyncProjects($filter: ProjectFilter, $first: Int, $after: String) {
        projects(filter: $filter, first: $first, includeArchived: true, after: $after) {
            pageInfo { hasNextPage endCursor }
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

    local projects="[]"
    local cursor="null"
    local page=0

    while true; do
        local variables="{\"filter\": $filter_json, \"first\": 75, \"after\": $cursor}"
        local result
        result=$(graphql_query "$query" "$variables")
        local nodes
        nodes=$(echo "$result" | jq '.projects.nodes')
        projects=$(echo "$projects" "$nodes" | jq -s 'add')

        local has_next
        has_next=$(echo "$result" | jq -r '.projects.pageInfo.hasNextPage')
        page=$((page + 1))

        if [[ "$has_next" != "true" ]] || (( page >= 50 )); then
            break
        fi
        cursor=$(echo "$result" | jq '.projects.pageInfo.endCursor')
    done

    local project_count
    project_count=$(echo "$projects" | jq 'length')

    # Skip enrichment if no projects to process
    if (( project_count == 0 )); then
        echo "[]"
        return
    fi

    # Fetch dependencies for each project
    local deps_query='
    query GetProjectDeps($id: String!) {
        project(id: $id) {
            relations {
                nodes {
                    id type anchorType relatedAnchorType
                    relatedProject { id name state progress }
                }
            }
            inverseRelations {
                nodes {
                    id type anchorType relatedAnchorType
                    project { id name state progress }
                }
            }
        }
    }'

    local enriched="[]"

    for (( i=0; i<project_count; i++ )); do
        local proj
        proj=$(echo "$projects" | jq ".[$i]")
        local pid
        pid=$(echo "$proj" | jq -r '.id')

        local deps_result
        deps_result=$(graphql_query "$deps_query" "{\"id\": \"$pid\"}")

        local proj_with_deps
        proj_with_deps=$(jq -n \
            --argjson base "$proj" \
            --argjson deps "$deps_result" \
            '$base + {
                relations: ($deps.project.relations // {nodes: []}),
                inverseRelations: ($deps.project.inverseRelations // {nodes: []})
            }')
        enriched=$(echo "$enriched" | jq --argjson p "$proj_with_deps" '. + [$p]')
    done

    echo "$enriched"
}

sync_cycles() {
    local team_name
    team_name=$(apply_team_default "")
    local query='
    query SyncCycles($after: String, $teamName: String!) {
        cycles(filter: {team: {name: {eq: $teamName}}}, first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
                id number name startsAt endsAt progress
                issueCountHistory completedIssueCountHistory
                scopeHistory completedScopeHistory
                team { name }
            }
        }
    }'

    local all_nodes="[]"
    local cursor="null"
    local page=0

    while true; do
        local result
        result=$(graphql_query "$query" "{\"after\": $cursor, \"teamName\": \"$team_name\"}")
        local nodes
        nodes=$(echo "$result" | jq '.cycles.nodes')
        all_nodes=$(echo "$all_nodes" "$nodes" | jq -s 'add')

        local has_next
        has_next=$(echo "$result" | jq -r '.cycles.pageInfo.hasNextPage')
        page=$((page + 1))

        if [[ "$has_next" != "true" ]] || (( page >= 50 )); then
            break
        fi
        cursor=$(echo "$result" | jq '.cycles.pageInfo.endCursor')
    done

    echo "$all_nodes"
}

sync_initiatives() {
    local query='
    query SyncInitiatives($after: String) {
        initiatives(first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
                id name description content status health targetDate url
                owner { name }
                projects { nodes { id name state } }
                createdAt updatedAt
            }
        }
    }'

    local all_nodes="[]"
    local cursor="null"
    local page=0

    while true; do
        local result
        result=$(graphql_query "$query" "{\"after\": $cursor}")
        local nodes
        nodes=$(echo "$result" | jq '.initiatives.nodes')
        all_nodes=$(echo "$all_nodes" "$nodes" | jq -s 'add')

        local has_next
        has_next=$(echo "$result" | jq -r '.initiatives.pageInfo.hasNextPage')
        page=$((page + 1))

        if [[ "$has_next" != "true" ]] || (( page >= 50 )); then
            break
        fi
        cursor=$(echo "$result" | jq '.initiatives.pageInfo.endCursor')
    done

    echo "$all_nodes"
}

sync_labels() {
    local query='
    query SyncLabels($after: String) {
        issueLabels(first: 250, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
                id name color description isGroup
                team { name }
                parent { name }
            }
        }
    }'

    local all_nodes="[]"
    local cursor="null"
    local page=0

    while true; do
        local result
        result=$(graphql_query "$query" "{\"after\": $cursor}")
        local nodes
        nodes=$(echo "$result" | jq '.issueLabels.nodes')
        all_nodes=$(echo "$all_nodes" "$nodes" | jq -s 'add')

        local has_next
        has_next=$(echo "$result" | jq -r '.issueLabels.pageInfo.hasNextPage')
        page=$((page + 1))

        if [[ "$has_next" != "true" ]] || (( page >= 20 )); then
            break
        fi
        cursor=$(echo "$result" | jq '.issueLabels.pageInfo.endCursor')
    done

    echo "$all_nodes"
}

# =============================================================================
# RECONCILIATION - detect issues deleted/trashed/archived outside our tools
# Linear doesn't update updatedAt on archive/trash, so incremental sync misses them.
# This batch-checks all cached UUIDs against the API and removes stale entries.
# =============================================================================

# Check if reconciliation was done recently (< max_age_minutes)
reconcile_is_fresh() {
    local max_age_minutes="${1:-60}"
    local meta="$CACHE_DIR/meta.json"
    [[ -f "$meta" ]] || return 1
    local last
    last=$(jq -r '.reconciled_at // empty' "$meta")
    [[ -n "$last" ]] || return 1
    local last_epoch
    last_epoch=$(date -d "$last" +%s 2>/dev/null || echo 0)
    local now_epoch
    now_epoch=$(date +%s)
    local age_minutes=$(( (now_epoch - last_epoch) / 60 ))
    (( age_minutes < max_age_minutes ))
}

# Returns count of removed issues on stdout
reconcile_issues() {
    local cache_file="$CACHE_DIR/issues.json"
    if [[ ! -f "$cache_file" ]]; then
        echo 0
        return
    fi

    # Get all UUIDs from cache
    local cached_uuids
    cached_uuids=$(jq -r '[.[].id] | .[]' "$cache_file" 2>/dev/null)
    if [[ -z "$cached_uuids" ]]; then
        echo 0
        return
    fi

    # Build JSON array of UUIDs
    local uuid_array
    uuid_array=$(echo "$cached_uuids" | jq -R . | jq -s .)

    # Batch query API (lightweight fields, large page size)
    local query='
    query ReconcileIssues($filter: IssueFilter!, $first: Int, $includeArchived: Boolean, $after: String) {
        issues(filter: $filter, first: $first, includeArchived: $includeArchived, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { id identifier trashed archivedAt }
        }
    }'

    local all_nodes="[]"
    local cursor="null"
    local page=0

    while true; do
        local variables="{\"filter\": {\"id\": {\"in\": $uuid_array}}, \"first\": 250, \"includeArchived\": true, \"after\": $cursor}"
        local result
        result=$(graphql_query "$query" "$variables")

        local nodes
        nodes=$(echo "$result" | jq '.issues.nodes')
        all_nodes=$(echo "$all_nodes" "$nodes" | jq -s 'add')

        local has_next
        has_next=$(echo "$result" | jq -r '.issues.pageInfo.hasNextPage')
        page=$((page + 1))

        if [[ "$has_next" != "true" ]] || (( page >= 10 )); then
            break
        fi
        cursor=$(echo "$result" | jq '.issues.pageInfo.endCursor')
    done

    # Build set of API-returned UUIDs
    local api_uuids
    api_uuids=$(echo "$all_nodes" | jq -r '[.[].id] | .[]')

    # Safety check: if API returned < 50% of cached UUIDs, something went wrong
    # (API error, rate limit, filter size limit). Abort to avoid mass-deletion.
    local cached_count api_count
    cached_count=$(echo "$cached_uuids" | wc -l)
    api_count=$(echo "$all_nodes" | jq 'length')
    if (( cached_count > 10 && api_count * 2 < cached_count )); then
        echo "Reconciliation safety: API returned $api_count of $cached_count cached issues, aborting" >&2
        echo 0
        return
    fi

    # Find issues to remove using sorted set comparison (comm)
    # Avoids unreliable grep -qF in a loop which intermittently misses matches
    local tmp_cached tmp_api tmp_deleted
    tmp_cached=$(mktemp)
    tmp_api=$(mktemp)
    tmp_deleted=$(mktemp)

    echo "$cached_uuids" | sort > "$tmp_cached"
    echo "$api_uuids" | sort > "$tmp_api"

    # comm -23: lines only in cached (not in API) = permanently deleted
    comm -23 "$tmp_cached" "$tmp_api" > "$tmp_deleted"

    # Append trashed/archived UUIDs
    echo "$all_nodes" | jq -r '[.[] | select(.trashed == true or .archivedAt != null)] | .[].id' >> "$tmp_deleted"

    # Deduplicate and remove
    local remove_count=0
    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] || continue
        cache_remove_issue "$uuid"
        (( remove_count++ )) || true
    done < <(sort -u "$tmp_deleted")

    rm -f "$tmp_cached" "$tmp_api" "$tmp_deleted"
    echo "$remove_count"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local full=false
    local if_stale=""
    local force_reconcile=false
    local show_stats=false
    local skip_attachments=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full) full=true; shift ;;
            --if-stale) if_stale="$2"; shift 2 ;;
            --reconcile) force_reconcile=true; shift ;;
            --no-attachments) skip_attachments=true; shift ;;
            --stats) show_stats=true; shift ;;
            --help|-h) show_help; exit 0 ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    # Check if sync needed when --if-stale specified
    if [[ -n "$if_stale" ]] && cache_is_fresh "$if_stale"; then
        echo "Cache fresh (< ${if_stale}m), skipped" >&2
        if [[ "$show_stats" == true ]]; then
            cache_status
        fi
        return 0
    fi

    local lock_rc=0
    cache_lock || lock_rc=$?
    if (( lock_rc == 2 )); then
        # Another process just synced — cache is fresh, nothing to do
        if [[ "$show_stats" == true ]]; then
            cache_status
        fi
        return 0
    elif (( lock_rc != 0 )); then
        exit 1
    fi
    cache_ensure_dir

    local start_time
    start_time=$(date +%s)
    local summary_parts=()

    if [[ "$full" == true ]] || [[ ! -f "$CACHE_DIR/meta.json" ]]; then
        echo "Full sync..." >&2

        sync_issues "" > "$CACHE_DIR/issues.json"
        # Strip problematic control chars from text fields (Linear descriptions can contain them)
        # Preserves \n (0a), \r (0d), \t (09) which are valid in markdown
        jq '[.[] | .description = ((.description // "") | gsub("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]"; "")) | .title = ((.title // "") | gsub("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]"; ""))]' \
            "$CACHE_DIR/issues.json" > "$CACHE_DIR/issues.json.tmp" && mv "$CACHE_DIR/issues.json.tmp" "$CACHE_DIR/issues.json"
        local issue_total
        issue_total=$(jq 'length' "$CACHE_DIR/issues.json")

        # Remove trashed/archived from full sync result
        local trashed_count
        trashed_count=$(jq '[.[] | select(.trashed == true or .archivedAt != null)] | length' "$CACHE_DIR/issues.json")
        if (( trashed_count > 0 )); then
            jq '[.[] | select(.trashed != true and .archivedAt == null)]' \
                "$CACHE_DIR/issues.json" > "$CACHE_DIR/issues.json.tmp"
            mv "$CACHE_DIR/issues.json.tmp" "$CACHE_DIR/issues.json"
            issue_total=$(( issue_total - trashed_count ))
            summary_parts+=("filtered $trashed_count archived")
        fi

        extract_comments "$CACHE_DIR/issues.json"
        summary_parts+=("$issue_total issues")

        sync_projects "" > "$CACHE_DIR/projects.json"
        local proj_total
        proj_total=$(jq 'length' "$CACHE_DIR/projects.json")
        summary_parts+=("$proj_total projects")

        sync_cycles > "$CACHE_DIR/cycles.json.tmp" && mv "$CACHE_DIR/cycles.json.tmp" "$CACHE_DIR/cycles.json"
        sync_initiatives > "$CACHE_DIR/initiatives.json.tmp" && mv "$CACHE_DIR/initiatives.json.tmp" "$CACHE_DIR/initiatives.json"
        sync_labels > "$CACHE_DIR/labels.json.tmp" && mv "$CACHE_DIR/labels.json.tmp" "$CACHE_DIR/labels.json"
    else
        local last_sync
        last_sync=$(jq -r '.synced_at' "$CACHE_DIR/meta.json")
        echo "Syncing..." >&2

        # Issues delta
        local delta_issues
        delta_issues=$(sync_issues "$last_sync")
        local delta_count
        delta_count=$(echo "$delta_issues" | jq 'length')
        if (( delta_count > 0 )); then
            # Clean control chars, then filter out trashed/archived before merging
            echo "$delta_issues" | jq '[.[] | .description = ((.description // "") | gsub("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]"; "")) | .title = ((.title // "") | gsub("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]"; ""))]' \
                > "$CACHE_DIR/.delta_issues_raw.json"
            # Split: archived/trashed go to removal, active go to merge
            local archived_delta_count
            archived_delta_count=$(jq '[.[] | select(.trashed == true or .archivedAt != null)] | length' "$CACHE_DIR/.delta_issues_raw.json")
            if (( archived_delta_count > 0 )); then
                # Remove newly archived/trashed from cache (use identifier for comment cleanup)
                jq -r '[.[] | select(.trashed == true or .archivedAt != null)] | .[] | "\(.id)\t\(.identifier)"' \
                    "$CACHE_DIR/.delta_issues_raw.json" | while IFS=$'\t' read -r uuid identifier; do
                    cache_remove_issue "$uuid"
                    # Clean comment file even if issue wasn't in cache (already removed)
                    [[ -n "$identifier" ]] && rm -f "$CACHE_DIR/comments/$identifier.json" "$CACHE_DIR/comments/$identifier.json.lock"
                done
                summary_parts+=("$archived_delta_count archived removed")
            fi
            # Strip problematic control chars from text fields (Linear
            # descriptions can contain them) — same normalization the full
            # sync path applies on line 538. Without this on the delta
            # path, incremental syncs merged unescaped control chars into
            # issues.json and downstream `jq` consumers (cache-query,
            # flightdeck/parallel-check) failed to parse.
            jq '[.[]
                  | select(.trashed != true and .archivedAt == null)
                  | .description = ((.description // "") | gsub("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]"; ""))
                  | .title = ((.title // "") | gsub("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]"; ""))]' \
                "$CACHE_DIR/.delta_issues_raw.json" > "$CACHE_DIR/.delta_issues.json"
            delta_count=$(jq 'length' "$CACHE_DIR/.delta_issues.json")
            extract_comments "$CACHE_DIR/.delta_issues.json"
            cache_merge "issues.json" "$CACHE_DIR/.delta_issues.json"
            # Patch stale embedded relation snapshots for delta issues
            jq -c '.[]' "$CACHE_DIR/.delta_issues.json" 2>/dev/null | while IFS= read -r issue; do
                cache_patch_relation_snapshots "$issue"
            done
            rm -f "$CACHE_DIR/.delta_issues.json" "$CACHE_DIR/.delta_issues_raw.json"
            summary_parts+=("$delta_count issues updated")
        fi

        # Projects delta
        local delta_projects
        delta_projects=$(sync_projects "$last_sync")
        local delta_proj_count
        delta_proj_count=$(echo "$delta_projects" | jq 'length')
        if (( delta_proj_count > 0 )); then
            echo "$delta_projects" > "$CACHE_DIR/.delta_projects.json"
            cache_merge "projects.json" "$CACHE_DIR/.delta_projects.json"
            rm -f "$CACHE_DIR/.delta_projects.json"
            summary_parts+=("$delta_proj_count projects updated")
        fi

        # Reconcile: time-gated to once per hour, or forced with --reconcile
        local did_reconcile=false
        if [[ "$force_reconcile" == true ]] || ! reconcile_is_fresh 60; then
            local reconciled_count
            reconciled_count=$(reconcile_issues)
            did_reconcile=true
            if (( reconciled_count > 0 )); then
                summary_parts+=("$reconciled_count stale removed")
            fi
        fi

        # Cycles, initiatives, labels — cheap, always refresh
        # Use temp file + mv to prevent truncation on failure
        sync_cycles > "$CACHE_DIR/cycles.json.tmp" && mv "$CACHE_DIR/cycles.json.tmp" "$CACHE_DIR/cycles.json"
        sync_initiatives > "$CACHE_DIR/initiatives.json.tmp" && mv "$CACHE_DIR/initiatives.json.tmp" "$CACHE_DIR/initiatives.json"
        sync_labels > "$CACHE_DIR/labels.json.tmp" && mv "$CACHE_DIR/labels.json.tmp" "$CACHE_DIR/labels.json"
    fi

    # Download file attachments/images from issue descriptions and comments
    if [[ "$skip_attachments" != "true" ]]; then
        local attach_count
        attach_count=$(attach_sync --quiet)
        if (( attach_count > 0 )); then
            summary_parts+=("$attach_count attachments downloaded")
        fi
    fi

    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    # Update metadata
    local issue_count project_count cycle_count initiative_count
    issue_count=$(jq 'length' "$CACHE_DIR/issues.json" 2>/dev/null || echo 0)
    project_count=$(jq 'length' "$CACHE_DIR/projects.json" 2>/dev/null || echo 0)
    cycle_count=$(jq 'length' "$CACHE_DIR/cycles.json" 2>/dev/null || echo 0)
    initiative_count=$(jq 'length' "$CACHE_DIR/initiatives.json" 2>/dev/null || echo 0)

    # Track reconciliation timestamp
    local reconciled_at
    if [[ "$full" == true ]] || [[ "${did_reconcile:-}" == true ]]; then
        reconciled_at="$(date -Iseconds)"
    else
        reconciled_at=$(jq -r '.reconciled_at // empty' "$CACHE_DIR/meta.json" 2>/dev/null || echo "")
    fi

    jq -n \
        --arg ts "$(date -Iseconds)" \
        --arg reconciled "${reconciled_at:-}" \
        --argjson issues "$issue_count" \
        --argjson projects "$project_count" \
        --argjson cycles "$cycle_count" \
        --argjson initiatives "$initiative_count" \
        --argjson elapsed "$elapsed" \
        '{
            synced_at: $ts,
            reconciled_at: (if $reconciled != "" then $reconciled else null end),
            elapsed_seconds: $elapsed,
            stats: {issues: $issues, projects: $projects, cycles: $cycles, initiatives: $initiatives}
        }' \
        > "$CACHE_DIR/meta.json"

    cache_unlock

    # Summary line
    if (( ${#summary_parts[@]} > 0 )); then
        local IFS=", "
        echo "Done (${elapsed}s): ${summary_parts[*]}" >&2
    else
        echo "Done (${elapsed}s): no changes" >&2
    fi

    if [[ "$show_stats" == true ]]; then
        cache_status
    fi
}

# Allow sourcing for individual sync functions, or run as command
if [[ "${BASH_SOURCE[0]}" == "$0" ]] || [[ "${1:-}" != "" ]]; then
    action="${1:-}"
    case "$action" in
        --help|-h|help) show_help ;;
        *) main "$@" ;;
    esac
fi
