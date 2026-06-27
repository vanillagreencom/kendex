#!/bin/bash
# Linear API Local Cache - Query Command
# Reads from local cache files instead of hitting the API
# Usage: cache-query.sh <resource> <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cache queries are local reads. Source common helpers without resolving
# LINEAR_API_KEY/op:// secrets so cache access works without 1Password auth.
LINEAR_SKIP_API_KEY_RESOLUTION=1
source "$SCRIPT_DIR/../lib/common.sh"
unset LINEAR_SKIP_API_KEY_RESOLUTION
source "$SCRIPT_DIR/../lib/cache.sh"
source "$SCRIPT_DIR/../lib/attachments.sh"
source "$SCRIPT_DIR/../lib/issue-validation.sh"

show_help() {
    cat <<'EOF'
Linear Cache Query - Read from local cache

Usage: cache-query.sh <resource> <action> [options]

Issues:
  issues list [--project X] [--state Y] [--label Z] [--cycle N|UUID|current|previous|next]
              [--updated-since Nd] [--search REGEX] [--max] [--include-archived]
              [--format=safe|compact|ids|table]
  issues get <ID> [--with-bundle] [--format=safe|compact|raw]
  issues children <ID> [--recursive] [--pending] [--format=safe|ids]
  issues list-relations <ID>
  issues validate-completion <ID> [--include-children-of <ID>]
  issues bulk-get <ID1> <ID2> ...

Projects:
  projects list [--state X] [--first]
  projects get <ID-or-name>
  projects list-dependencies <ID>

Comments:
  comments list <issue-ID>

Labels:
  labels list [--team X]

Attachments:
  attachments list [<issue-ID>]          List cached attachments (all or per-issue)
  attachments fetch [<issue-ID>]         Download new attachments (all or per-issue)
  attachments stats                      Show attachment cache stats

Other:
  initiatives list [--status X]
  initiatives get <ID-or-name>
  cycles list [--type current|past|upcoming] [--team X] [--limit N]
  status                Show cache status/freshness

All output uses the same formatters as live API commands.

Examples:
  cache-query.sh issues list --project "Phase 2" --format=compact
  cache-query.sh issues get PROJ-100 --with-bundle
  cache-query.sh projects list --state started
  cache-query.sh status
EOF
}

# =============================================================================
# ISSUES
# =============================================================================

cache_list_issues() {
    local project="" state="" label="" updated_since="" search="" cycle=""
    local include_archived="false" paginate_all="false" limit="75"
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --project)
            project="$2"
            shift 2
            ;;
        --project-id)
            project="$2"
            shift 2
            ;; # treated same — filter by project.id or project.name
        --state | --status)
            state="$2"
            shift 2
            ;;
        --label | --labels)
            label="${label:+$label,}$2"
            shift 2
            ;;
        --cycle)
            cycle="$2"
            shift 2
            ;;
        --cycle=*)
            cycle="${1#--cycle=}"
            shift
            ;;
        --updated-since)
            updated_since="$2"
            shift 2
            ;;
        --search)
            search="$2"
            shift 2
            ;;
        --search=*)
            search="${1#--search=}"
            shift
            ;;
        --max)
            paginate_all="true"
            shift
            ;;
        --limit)
            limit="$2"
            shift 2
            ;;
        --include-archived)
            include_archived="true"
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
        --team | --assignee | --created-since | --with-relations) shift 2 ;; # consume but ignore for cache
        --)
            shift
            break
            ;;
        -*) shift ;; # ignore unknown flags gracefully
        *) shift ;;
        esac
    done

    # Build jq filter chain
    local jq_filter='.'

    # Exclude archived unless requested
    if [[ "$include_archived" != "true" ]]; then
        jq_filter="$jq_filter | [.[] | select(.archivedAt == null and (.trashed | not))]"
    fi

    # Filter by state (comma-separated)
    if [[ -n "$state" ]]; then
        local state_jq
        state_jq=$(echo "$state" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')
        jq_filter="$jq_filter | [.[] | select(.state.name as \$s | $state_jq | any(. == \$s))]"
    fi

    # Filter by project name or ID
    if [[ -n "$project" ]]; then
        jq_filter="$jq_filter | [.[] | select(.project.name == $(echo "$project" | jq -R '.') or .project.id == $(echo "$project" | jq -R '.'))]"
    fi

    # Filter by label
    if [[ -n "$label" ]]; then
        jq_filter="$jq_filter | [.[] | select([.labels.nodes[].name] | any(. == $(echo "$label" | jq -R '.')))]"
    fi

    # Filter by cycle (number, UUID, or keyword: current/previous/next)
    if [[ -n "$cycle" ]]; then
        local cycle_id=""
        case "$cycle" in
        current | previous | next)
            local today_iso
            today_iso=$(date -Iseconds)
            local cycles_file="$CACHE_DIR/cycles.json"
            if [[ -f "$cycles_file" ]]; then
                local working
                working=$(jq --arg today "$today_iso" \
                    '[.[] | select(.startsAt <= $today and .progress < 1)] | sort_by(.startsAt) | last // null' "$cycles_file")
                case "$cycle" in
                current)
                    cycle_id=$(echo "$working" | jq -r '.id // empty')
                    ;;
                previous)
                    cycle_id=$(jq --argjson w "$working" \
                        'if $w then [.[] | select(.startsAt < $w.startsAt)] | sort_by(.startsAt) | last | .id else null end' "$cycles_file" | jq -r '. // empty')
                    ;;
                next)
                    cycle_id=$(jq --argjson w "$working" \
                        'if $w then [.[] | select(.startsAt > $w.startsAt)] | sort_by(.startsAt) | first | .id else null end' "$cycles_file" | jq -r '. // empty')
                    ;;
                esac
            fi
            ;;
        *-*-*-*-*) # UUID pattern
            cycle_id="$cycle"
            ;;
        *) # Assume cycle number
            cycle_id=""
            ;;
        esac

        if [[ -n "$cycle_id" ]]; then
            jq_filter="$jq_filter | [.[] | select(.cycle != null and .cycle.id == $(echo "$cycle_id" | jq -R '.'))]"
        else
            # Filter by number
            jq_filter="$jq_filter | [.[] | select(.cycle != null and .cycle.number == $cycle)]"
        fi
    fi

    # Filter by updated-since
    if [[ -n "$updated_since" ]]; then
        local days="${updated_since%d}"
        local threshold
        threshold=$(date -d "-$days days" -Iseconds 2>/dev/null || date -v-"${days}"d -Iseconds)
        jq_filter="$jq_filter | [.[] | select(.updatedAt >= $(echo "$threshold" | jq -R '.'))]"
    fi

    # Get issues from cache
    local issues
    issues=$(jq "$jq_filter" "$CACHE_DIR/issues.json" 2>/dev/null || echo "[]")

    # Apply client-side search (regex on title+description)
    if [[ -n "$search" ]]; then
        issues=$(echo "$issues" | jq --arg pattern "$search" \
            '[.[] | select((.title + " " + (.description // "")) | test($pattern; "i"))]')
    fi

    # Limit results unless --max
    if [[ "$paginate_all" != "true" ]]; then
        issues=$(echo "$issues" | jq ".[0:$limit]")
    fi

    # Wrap in expected structure for formatters
    local result
    result=$(echo "$issues" | jq '{issues: {nodes: .}}')

    # Apply output format
    case "$FORMAT" in
    compact) format_issues_list_compact "$result" ;;
    ids) format_issues_ids "$result" ;;
    table) format_issues_table "$result" ;;
    raw) echo "$result" ;;
    safe | *) format_issues_list "$result" ;;
    esac
}

cache_get_issue() {
    local issue_id="" with_bundle="false"
    FORMAT="${DEFAULT_FORMAT}"

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
            [[ -z "$issue_id" ]] && issue_id="$1"
            shift
            ;;
        esac
    done

    if [[ -z "$issue_id" ]]; then
        echo '{"error": "Issue ID required"}' >&2
        return 1
    fi

    # Find issue in cache
    local issue
    issue=$(jq --arg id "$issue_id" '.[] | select(.identifier == $id or .id == $id)' \
        "$CACHE_DIR/issues.json" 2>/dev/null)

    if [[ -z "$issue" || "$issue" == "null" ]]; then
        echo "{\"error\": \"Issue not found in cache: $issue_id\"}" >&2
        return 1
    fi

    # Enrich with cached attachments if any exist
    local attachments="[]"
    if [[ -f "$ATTACH_MANIFEST" ]]; then
        attachments=$(attach_get_for_issue "$issue_id")
    fi

    if [[ "$with_bundle" == "true" ]]; then
        # Build bundle: issue + recursive children + pending_count
        local children
        children=$(cache_get_children_recursive "$issue_id" 3)
        local pending_count
        pending_count=$(echo "$children" | jq '[.[] | select(.state_type | IN("completed", "canceled") | not)] | length')

        # Construct the formatted output directly. Both `id` and `identifier`
        # are emitted so consumers that key on either field (raw cache reader
        # vs formatted output reader) work consistently — the cache schema
        # uses `identifier` for the human-readable form, formatted output
        # uses `id` for it. Defensive parity prevents the Round-4 class of
        # 'id: null' / 'identifier missing' bugs across format variants.
        local result
        result=$(jq -n \
            --argjson issue "$issue" \
            --argjson children "$children" \
            --argjson pending "$pending_count" \
            --argjson attachments "$attachments" \
            '{
                id: $issue.identifier,
                identifier: $issue.identifier,
                uuid: $issue.id,
                title: ($issue.title // ""),
                description: ($issue.description // ""),
                state: ($issue.state.name // ""),
                state_type: ($issue.state.type // ""),
                agent: ((([($issue.labels.nodes // [])[] | .name | select(startswith("agent:"))] | first) // "") | sub("^agent:"; "")),
                platform: (([($issue.labels.nodes // [])[] | .name | select(. == "linux" or . == "windows" or . == "macos" or . == "cross-platform")] | first) // ""),
                labels: [($issue.labels.nodes // [])[] | .name],
                priority: ($issue.priority // 0),
                estimate: ($issue.estimate // 0),
                project: ($issue.project.name // ""),
                project_id: ($issue.project.id // ""),
                assignee: ($issue.assignee.name // ""),
                parent_id: ($issue.parent.identifier // ""),
                milestone: ($issue.projectMilestone.name // ""),
                cycle: (if $issue.cycle then ($issue.cycle.name // "Cycle \($issue.cycle.number)") else "" end),
                created_at: ($issue.createdAt // ""),
                updated_at: ($issue.updatedAt // ""),
                blocks: [($issue.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier],
                blocked_by: [($issue.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue.identifier],
                related: [($issue.relations.nodes // [])[] | select(.type == "related") | .relatedIssue.identifier],
                url: ($issue.url // ""),
                children: $children,
                pending_count: $pending,
                attachments: [($attachments // [])[] | {filename, content_type, local_path}]
            }')

        case "$FORMAT" in
        compact)
            # Preserve both `id` and `identifier` for consumer parity (see
            # comment on the result construction above).
            echo "$result" | jq 'del(.description, .url, .created_at, .updated_at, .uuid, .project_id, .platform, .related, .milestone, .cycle)'
            ;;
        raw) echo "$result" ;;
        safe | *) echo "$result" ;;
        esac
    else
        # Wrap in {issue: ...} for formatter compatibility
        local wrapped
        wrapped=$(echo "$issue" | jq '{issue: .}')

        # Helper to append attachments to formatted output
        _append_attachments() {
            local output="$1"
            if [[ "$(echo "$attachments" | jq 'length')" != "0" ]]; then
                echo "$output" | jq --argjson a "$attachments" \
                    '. + {attachments: [($a // [])[] | {filename, content_type, local_path}]}'
            else
                echo "$output"
            fi
        }

        case "$FORMAT" in
        compact)
            # Inject children from cache (sync doesn't store .children.nodes)
            local children_nodes
            children_nodes=$(jq --arg id "$issue_id" \
                '[.[] | select(.parent.identifier == $id) | {identifier, title, state}]' \
                "$CACHE_DIR/issues.json" 2>/dev/null || echo "[]")
            local enriched
            enriched=$(echo "$wrapped" | jq --argjson ch "$children_nodes" '.issue.children = {nodes: $ch}')
            _append_attachments "$(format_issue_compact "$enriched")"
            ;;
        raw) echo "$wrapped" ;;
        safe | *) _append_attachments "$(format_issue_single "$wrapped")" ;;
        esac
    fi
}

cache_list_children() {
    local issue_id="" recursive="false" pending_only="false"
    FORMAT="${DEFAULT_FORMAT}"

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

    if [[ -z "$issue_id" ]]; then
        echo '{"error": "Issue ID required"}' >&2
        return 1
    fi

    if [[ "$recursive" == "true" ]]; then
        local children
        children=$(cache_get_children_recursive "$issue_id" 3)

        if [[ "$pending_only" == "true" ]]; then
            children=$(echo "$children" | jq '[.[] | select(.state_type != "completed" and .state_type != "canceled")]')
        fi
    else
        # Direct children only
        local children
        children=$(jq --arg p "$issue_id" \
            '[.[] | select(.parent.identifier == $p) | {
                id: .identifier,
                uuid: .id,
                title: (.title // ""),
                state: (.state.name // ""),
                state_type: (.state.type // ""),
                assignee: (.assignee.name // ""),
                priority: (.priority // 0),
                estimate: (.estimate // 0)
            }]' "$CACHE_DIR/issues.json" 2>/dev/null || echo "[]")

        if [[ "$pending_only" == "true" ]]; then
            children=$(echo "$children" | jq '[.[] | select(.state_type != "completed" and .state_type != "canceled")]')
        fi
    fi

    # Output in requested format
    case "$FORMAT" in
    ids) echo "$children" | jq -r '.[].id' ;;
    raw) echo "$children" ;;
    safe | *) echo "$children" ;;
    esac
}

cache_list_relations() {
    local issue_id="$1"

    if [[ -z "$issue_id" ]]; then
        echo '{"error": "Issue ID required"}' >&2
        return 1
    fi

    local result
    result=$(jq --arg id "$issue_id" '
        .[] | select(.identifier == $id or .id == $id) | {
            blocks: [(.relations.nodes // [])[] | select(.type == "blocks") | {
                id: .relatedIssue.identifier,
                title: .relatedIssue.title,
                state: .relatedIssue.state.name
            }],
            blocked_by: [(.inverseRelations.nodes // [])[] | select(.type == "blocks") | {
                id: .issue.identifier,
                title: .issue.title,
                state: .issue.state.name
            }],
            related: [(.relations.nodes // [])[] | select(.type == "related") | {
                id: .relatedIssue.identifier,
                title: .relatedIssue.title,
                state: .relatedIssue.state.name
            }],
            duplicates: [(.relations.nodes // [])[] | select(.type == "duplicate") | {
                id: .relatedIssue.identifier,
                title: .relatedIssue.title,
                state: .relatedIssue.state.name
            }]
        }
    ' "$CACHE_DIR/issues.json" 2>/dev/null)

    if [[ -z "$result" ]]; then
        echo "{\"error\": \"Issue not found in cache: $issue_id\"}" >&2
        return 1
    fi
    echo "$result"
}

cache_validate_completion() {
    local issue_ids=()
    local include_children_of=""

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

    if [[ ${#issue_ids[@]} -eq 0 ]]; then
        echo '{"error": "At least one issue ID required"}' >&2
        return 1
    fi

    # If --include-children-of specified, fetch bundle from cache and extract pending children
    if [[ -n "$include_children_of" ]]; then
        local bundle
        if ! bundle=$(cache_get_issue "$include_children_of" --with-bundle); then
            echo "{\"error\": \"Failed to fetch bundle for: $include_children_of\"}" >&2
            return 1
        fi
        if [[ -z "$bundle" ]]; then
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
        local issue
        issue=$(jq --arg id "$issue_id" '.[] | select(.identifier == $id or .id == $id)' \
            "$CACHE_DIR/issues.json" 2>/dev/null)

        local state
        state=$(echo "$issue" | jq -r '.state.name // ""')
        local parent_id
        parent_id=$(echo "$issue" | jq -r '.parent.identifier // ""')

        # Check comments cache for Completion Summary
        local has_summary="false"
        local comment_file="$CACHE_DIR/comments/$issue_id.json"
        if [[ -f "$comment_file" ]]; then
            has_summary=$(jq 'any(.[]; .body | (contains("Completion Summary") or contains("Bundle Complete")))' "$comment_file" 2>/dev/null || echo "false")
        fi

        local result
        result=$(build_completion_validation_result "$issue_id" "$state" "$parent_id" "$has_summary")

        if [ "$(echo "$result" | jq -r '.ok')" != "true" ]; then
            all_ok="false"
        fi

        results=$(echo "$results" | jq --argjson result "$result" '. + [$result]')
    done

    echo "$results" | jq --argjson all_ok "$all_ok" '{results: ., all_ok: $all_ok}'
}

cache_bulk_get_issues() {
    local identifiers=()
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --stdin)
            while IFS= read -r line; do [[ -n "$line" ]] && identifiers+=("$line"); done
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
        *)
            identifiers+=("$1")
            shift
            ;;
        esac
    done

    if [[ ${#identifiers[@]} -eq 0 ]]; then
        echo '{"error": "No issue identifiers provided"}' >&2
        return 1
    fi

    # Build jq id list
    local id_json
    id_json=$(printf '%s\n' "${identifiers[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')

    local result
    result=$(jq --argjson ids "$id_json" \
        '{issues: {nodes: [.[] | select(.identifier as $id | $ids | any(. == $id))]}}' \
        "$CACHE_DIR/issues.json" 2>/dev/null)

    case "$FORMAT" in
    raw) echo "$result" ;;
    ids) format_issues_ids "$result" ;;
    safe | *) format_issues_list "$result" ;;
    esac
}

# =============================================================================
# PROJECTS
# =============================================================================

cache_list_projects() {
    local state="" first_only="false"
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --state)
            state="$2"
            shift 2
            ;;
        --first)
            first_only="true"
            shift
            ;;
        --limit) shift 2 ;; # ignored for cache
        --include-archived) shift ;;
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
        -*) shift ;;
        *) shift ;;
        esac
    done

    local jq_filter='.'
    if [[ -n "$state" ]]; then
        jq_filter="$jq_filter | [.[] | select(.state == $(echo "$state" | jq -R '.'))]"
    fi

    local projects
    projects=$(jq "$jq_filter" "$CACHE_DIR/projects.json" 2>/dev/null || echo "[]")

    if [[ "$first_only" == "true" ]]; then
        echo "$projects" | jq -r '.[0].name // "Backlog"'
        return
    fi

    # Wrap for formatters
    local result
    result=$(echo "$projects" | jq '{projects: {nodes: .}}')

    case "$FORMAT" in
    raw) echo "$result" ;;
    ids) format_projects_ids "$result" ;;
    safe | *) format_projects_list "$result" ;;
    esac
}

cache_get_project() {
    local project_ref=""
    FORMAT="${DEFAULT_FORMAT}"

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

    if [[ -z "$project_ref" ]]; then
        echo '{"error": "Project ID or name required"}' >&2
        return 1
    fi

    local project
    project=$(jq --arg ref "$project_ref" \
        '.[] | select(.id == $ref or .name == $ref)' \
        "$CACHE_DIR/projects.json" 2>/dev/null)

    if [[ -z "$project" || "$project" == "null" ]]; then
        echo "{\"error\": \"Project not found in cache: $project_ref\"}" >&2
        return 1
    fi

    # Wrap for formatter
    local result
    result=$(echo "$project" | jq '{project: .}')

    case "$FORMAT" in
    raw) echo "$result" ;;
    safe | *) format_project_single "$result" ;;
    esac
}

cache_list_dependencies() {
    local project_id="$1"

    if [[ -z "$project_id" ]]; then
        echo '{"error": "Project ID required"}' >&2
        return 1
    fi

    jq --arg id "$project_id" '.[] | select(.id == $id or .name == $id) | {
        project: {
            id: .id,
            name: .name,
            relations: .relations,
            inverseRelations: .inverseRelations
        }
    }' "$CACHE_DIR/projects.json" 2>/dev/null || echo '{"project": {"relations": {"nodes": []}, "inverseRelations": {"nodes": []}}}'
}

# =============================================================================
# COMMENTS
# =============================================================================

cache_list_comments() {
    local issue_id=""
    FORMAT="${DEFAULT_FORMAT}"

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
            [[ -z "$issue_id" ]] && issue_id="$1"
            shift
            ;;
        esac
    done

    if [[ -z "$issue_id" ]]; then
        echo '{"error": "Issue ID required"}' >&2
        return 1
    fi

    local comments
    comments=$(cache_get_comments "$issue_id")

    # Wrap in expected structure for format_comments_list
    local result
    result=$(echo "$comments" | jq '{issue: {comments: {nodes: .}}}')

    case "$FORMAT" in
    raw) echo "$result" ;;
    safe | *) format_comments_list "$result" ;;
    esac
}

# =============================================================================
# LABELS
# =============================================================================

cache_list_labels() {
    local team=""
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --team)
            team="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        *) shift ;;
        esac
    done

    local labels
    labels=$(cat "$CACHE_DIR/labels.json" 2>/dev/null || echo "[]")

    if [[ -n "$team" ]]; then
        labels=$(echo "$labels" | jq --arg t "$team" '[.[] | select(.team.name == $t)]')
    fi

    # Wrap for formatter
    local result
    result=$(echo "$labels" | jq '{labels: {nodes: .}}')

    case "$FORMAT" in
    raw) echo "$result" ;;
    safe | *) format_labels_list "$result" ;;
    esac
}

# =============================================================================
# INITIATIVES
# =============================================================================

cache_list_initiatives() {
    local status=""
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --status)
            status="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        *) shift ;;
        esac
    done

    local jq_filter='.'
    if [[ -n "$status" ]]; then
        jq_filter="$jq_filter | [.[] | select(.status == $(echo "$status" | jq -R '.'))]"
    fi

    local initiatives
    initiatives=$(jq "$jq_filter" "$CACHE_DIR/initiatives.json" 2>/dev/null || echo "[]")

    # Wrap for formatter
    local result
    result=$(echo "$initiatives" | jq '{initiatives: {nodes: .}}')

    case "$FORMAT" in
    raw) echo "$result" ;;
    safe | *) format_initiatives_list "$result" ;;
    esac
}

cache_get_initiative() {
    local ref=""
    FORMAT="${DEFAULT_FORMAT}"

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
            [[ -z "$ref" ]] && ref="$1"
            shift
            ;;
        esac
    done

    if [[ -z "$ref" ]]; then
        echo '{"error": "Initiative ID or name required"}' >&2
        return 1
    fi

    local initiative
    initiative=$(jq --arg ref "$ref" \
        '.[] | select(.id == $ref or .name == $ref)' \
        "$CACHE_DIR/initiatives.json" 2>/dev/null)

    if [[ -z "$initiative" || "$initiative" == "null" ]]; then
        echo "{\"error\": \"Initiative not found in cache: $ref\"}" >&2
        return 1
    fi

    local result
    result=$(echo "$initiative" | jq '{initiative: .}')

    case "$FORMAT" in
    raw) echo "$result" ;;
    safe | *) format_initiative_single "$result" ;;
    esac
}

# =============================================================================
# CYCLES
# =============================================================================

cache_list_cycles() {
    local cycle_type="" team="" limit=50
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --type)
            cycle_type="$2"
            shift 2
            ;;
        --team)
            team="$2"
            shift 2
            ;; # ignored — cache is team-scoped
        --limit)
            limit="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        *) shift ;;
        esac
    done

    local cycles
    cycles=$(cat "$CACHE_DIR/cycles.json" 2>/dev/null || echo "[]")

    # Apply type filter (date-based: "current" = most recent started + incomplete)
    local today_iso
    today_iso=$(date -Iseconds)
    case "$cycle_type" in
    current)
        cycles=$(echo "$cycles" | jq --arg today "$today_iso" \
            '[.[] | select(.startsAt <= $today and .progress < 1)] | sort_by(.startsAt) | [last // empty]')
        ;;
    upcoming | next)
        local working
        working=$(echo "$cycles" | jq --arg today "$today_iso" \
            '[.[] | select(.startsAt <= $today and .progress < 1)] | sort_by(.startsAt) | last // null')
        if [[ "$working" != "null" ]]; then
            cycles=$(echo "$cycles" | jq --argjson w "$working" \
                '[.[] | select(.startsAt > $w.startsAt)] | sort_by(.startsAt) | [first // empty]')
        else
            cycles=$(echo "$cycles" | jq 'sort_by(.startsAt) | [first // empty]')
        fi
        ;;
    past)
        local working_start
        working_start=$(echo "$cycles" | jq -r --arg today "$today_iso" \
            '[.[] | select(.startsAt <= $today and .progress < 1)] | sort_by(.startsAt) | last // null | .startsAt // ""')
        if [[ -n "$working_start" ]]; then
            cycles=$(echo "$cycles" | jq --arg ws "$working_start" \
                '[.[] | select(.startsAt < $ws)] | sort_by(.startsAt) | reverse')
        else
            cycles=$(echo "$cycles" | jq 'sort_by(.startsAt) | reverse')
        fi
        ;;
    esac

    cycles=$(echo "$cycles" | jq ".[:$limit]")

    # Wrap for formatter
    local result
    result=$(echo "$cycles" | jq '{cycles: {nodes: .}}')

    case "$FORMAT" in
    raw) echo "$result" ;;
    safe | *) format_cycles_list "$result" ;;
    esac
}

# =============================================================================
# MAIN ROUTING
# =============================================================================

main() {
    if [[ ! -f "$CACHE_DIR/meta.json" ]]; then
        echo '{"error": "No cache found. Run: linear.sh sync"}' >&2
        return 1
    fi

    local resource="${1:-help}"
    shift || true

    case "$resource" in
    issues)
        local action="${1:-list}"
        shift || true
        case "$action" in
        list) cache_list_issues "$@" ;;
        get) cache_get_issue "$@" ;;
        children) cache_list_children "$@" ;;
        list-relations | relations) cache_list_relations "${1:-}" ;;
        list-comments) cache_list_comments "$@" ;;
        validate-completion) cache_validate_completion "$@" ;;
        bulk-get) cache_bulk_get_issues "$@" ;;
        --help | -h) show_help ;;
        *)
            echo "{\"error\": \"Unknown issues action: $action\"}" >&2
            return 1
            ;;
        esac
        ;;
    projects)
        local action="${1:-list}"
        shift || true
        case "$action" in
        list) cache_list_projects "$@" ;;
        get) cache_get_project "$@" ;;
        list-dependencies | dependencies) cache_list_dependencies "${1:-}" ;;
        --help | -h) show_help ;;
        *)
            echo "{\"error\": \"Unknown projects action: $action\"}" >&2
            return 1
            ;;
        esac
        ;;
    comments)
        local action="${1:-list}"
        shift || true
        case "$action" in
        list) cache_list_comments "$@" ;;
        --help | -h) show_help ;;
        *)
            echo "{\"error\": \"Unknown comments action: $action\"}" >&2
            return 1
            ;;
        esac
        ;;
    labels)
        local action="${1:-list}"
        shift || true
        case "$action" in
        list) cache_list_labels "$@" ;;
        --help | -h) show_help ;;
        *)
            echo "{\"error\": \"Unknown labels action: $action\"}" >&2
            return 1
            ;;
        esac
        ;;
    initiatives)
        local action="${1:-list}"
        shift || true
        case "$action" in
        list) cache_list_initiatives "$@" ;;
        get) cache_get_initiative "$@" ;;
        --help | -h) show_help ;;
        *)
            echo "{\"error\": \"Unknown initiatives action: $action\"}" >&2
            return 1
            ;;
        esac
        ;;
    cycles)
        local action="${1:-list}"
        shift || true
        case "$action" in
        list) cache_list_cycles "$@" ;;
        --help | -h) show_help ;;
        *)
            echo "{\"error\": \"Unknown cycles action: $action\"}" >&2
            return 1
            ;;
        esac
        ;;
    attachments | attachment)
        local action="${1:-list}"
        shift || true
        case "$action" in
        list)
            local issue_id="${1:-}"
            if [[ -n "$issue_id" ]]; then
                attach_get_for_issue "$issue_id"
            else
                attach_list
            fi
            ;;
        fetch)
            local issue_id="${1:-}"
            if [[ -n "$issue_id" ]]; then
                # Fetch attachments for a specific issue
                attach_ensure_dir
                local urls
                urls=$(attach_extract_all_urls | jq --arg id "$issue_id" '[.[] | select(.source == $id)]')
                local count
                count=$(echo "$urls" | jq 'length')
                local downloaded=0
                for (( i=0; i<count; i++ )); do
                    local url source context
                    url=$(echo "$urls" | jq -r ".[$i].url")
                    source=$(echo "$urls" | jq -r ".[$i].source")
                    context=$(echo "$urls" | jq -r ".[$i].context")
                    local rc=0
                    attach_download_url "$url" "$source" "$context" || rc=$?
                    # rc 0 = newly downloaded, rc 2 = already cached, rc 1 = failed
                    if (( rc == 0 )); then
                        (( downloaded++ )) || true
                    fi
                done
                echo "{\"downloaded\": $downloaded, \"total_urls\": $count}"
            else
                local count
                count=$(attach_sync)
                echo "{\"downloaded\": $count}"
            fi
            ;;
        stats) attach_stats ;;
        --help | -h) show_help ;;
        *)
            echo "{\"error\": \"Unknown attachments action: $action\"}" >&2
            return 1
            ;;
        esac
        ;;
    status)
        cache_status
        ;;
    help | --help | -h)
        show_help
        ;;
    *)
        echo "{\"error\": \"Unknown resource: $resource\"}" >&2
        return 1
        ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
