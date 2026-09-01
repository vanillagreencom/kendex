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

show_help() {
    cat <<'EOF'
Linear Cache Query - Read from local cache

Usage: cache-query.sh <resource> <action> [options]

Issues:
  issues list [--project X | --all-projects | --no-project] [--state Y] [--label Z]
              [--cycle N|UUID|current|previous|next]
              [--updated-since Nd] [--search REGEX] [--max] [--include-archived]
              [--format=safe|compact|ids|table]
              --all-projects enumerates every project in ONE command (each row
              carries its project name; rows without a project carry ""). Use it
              instead of looping per project — restricted harnesses reject loop
              shapes. Mutually exclusive with --project.
              --no-project returns only issues with no project assigned, read
              from the same per-row project field `issues get` reports. Mutually
              exclusive with --project/--all-projects. Unknown filter flags are
              rejected rather than ignored, so a filter the cache cannot honor
              fails instead of silently returning every issue.
  issues get <ID> [--with-bundle] [--format=safe|compact|raw]
  issues children <ID> [--recursive] [--pending] [--format=safe|ids]
  issues list-relations <ID>
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
  cache-query.sh issues list --all-projects --state "Backlog,Todo" --max --format=compact
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
    local all_projects="false" no_project="false"
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
        --all-projects)
            # Explicit batch enumeration across every project in one command.
            # Harness approval classifiers reject per-project shell loops, so
            # audit workflows load the full comparison set through this flag.
            all_projects="true"
            shift
            ;;
        --no-project)
            # Only issues with no project assigned. The counterpart to --project;
            # audits use it to enumerate genuinely unassigned triage debt.
            no_project="true"
            shift
            ;;
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
        --team | --assignee | --created-since) shift 2 ;; # consume but ignore for cache
        # Boolean on the live path (issues.sh), so it takes no value here
        # either. Consuming one would swallow the following filter flag and
        # return every issue as if that filter had been applied.
        --with-relations) shift ;;
        --help | -h)
            show_help
            return 0
            ;;
        --)
            shift
            break
            ;;
        # Fail closed on an unrecognized flag. Silently ignoring one (the old
        # behavior) turned an unimplemented filter such as --no-project into a
        # full unfiltered listing that looked like assigned issues leaking past
        # the filter, inflating every audit worklist that trusted it.
        -*)
            echo "{\"error\": \"Unknown flag for cache issues list: $1. A filter the cache cannot honor must fail, not silently return every issue. Run 'cache issues list --help'.\"}" >&2
            return 1
            ;;
        *) shift ;;
        esac
    done

    if [[ "$all_projects" == "true" && -n "$project" ]]; then
        echo '{"error": "--all-projects cannot be combined with --project/--project-id: it already enumerates every project"}' >&2
        return 1
    fi

    if [[ "$no_project" == "true" && ( "$all_projects" == "true" || -n "$project" ) ]]; then
        echo '{"error": "--no-project cannot be combined with --project/--project-id/--all-projects: it selects only issues with no project"}' >&2
        return 1
    fi

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

    # Only issues with no project assigned. Reads the same .project.name each row
    # carries and that `cache issues get` reports, so the list cannot disagree
    # with a per-issue record.
    if [[ "$no_project" == "true" ]]; then
        jq_filter="$jq_filter | [.[] | select((.project.name // \"\") == \"\")]"
    fi

    # Filter by label. Repeated --label flags and the --labels "a,b" spelling
    # both accumulate comma-joined, so the joined value is split back into names
    # and every one must be present — comparing the joined string as a single
    # label name matched nothing at all.
    if [[ -n "$label" ]]; then
        local label_jq
        label_jq=$(echo "$label" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')
        jq_filter="$jq_filter | [.[] | select([.labels.nodes[].name] as \$have | $label_jq | all(. as \$want | \$have | any(. == \$want)))]"
    fi

    # Filter by cycle (number, UUID, or keyword: current/previous/next)
    if [[ -n "$cycle" ]]; then
        local cycle_id=""
        case "$cycle" in
        current | previous | next)
            local today_iso cycles_file="$CACHE_DIR/cycles.json"
            today_iso=$(date -Iseconds)
            if [[ -f "$cycles_file" ]]; then
                local working
                working=$(cache_jq_file "$cycles_file" "null" --arg today "$today_iso" \
                    '[.[] | select(.startsAt <= $today and .progress < 1)] | sort_by(.startsAt) | last // null')
                case "$cycle" in
                current)
                    cycle_id=$(echo "$working" | jq -r '.id // empty')
                    ;;
                previous)
                    cycle_id=$(cache_jq_file "$cycles_file" "null" -r --argjson w "$working" \
                        'if $w then ([.[] | select(.startsAt < $w.startsAt)] | sort_by(.startsAt) | last | .id) // empty else empty end')
                    ;;
                next)
                    cycle_id=$(cache_jq_file "$cycles_file" "null" -r --argjson w "$working" \
                        'if $w then ([.[] | select(.startsAt > $w.startsAt)] | sort_by(.startsAt) | first | .id) // empty else empty end')
                    ;;
                esac
            fi
            # A keyword that resolves to no cycle must not fall through to the
            # number branch, where the literal word compiles as a jq function
            # call and the failure reads as "this cycle has no issues".
            if [[ -z "$cycle_id" ]]; then
                jq -cn --arg kw "$cycle" --arg file "$cycles_file" \
                    '{error: ("--cycle " + $kw + " could not be resolved from " + $file + " — sync the cache (linear.sh sync) or pass a cycle number or UUID")}' >&2
                return 1
            fi
            ;;
        *-*-*-*-*) # UUID pattern
            cycle_id="$cycle"
            ;;
        *) # Cycle number
            if ! [[ "$cycle" =~ ^[0-9]+$ ]]; then
                jq -cn --arg v "$cycle" \
                    '{error: ("--cycle expects a cycle number, UUID, or current/previous/next, got: " + $v)}' >&2
                return 1
            fi
            ;;
        esac

        if [[ -n "$cycle_id" ]]; then
            jq_filter="$jq_filter | [.[] | select(.cycle != null and .cycle.id == $(echo "$cycle_id" | jq -R '.'))]"
        else
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
    issues=$(cache_jq_file "$CACHE_DIR/issues.json" "[]" "$jq_filter") || return 1

    # Apply client-side search (regex on title+description)
    if [[ -n "$search" ]]; then
        issues=$(echo "$issues" | jq --arg pattern "$search" \
            '[.[] | select((.title + " " + (.description // "")) | test($pattern; "i"))]')
    fi

    # Limit results unless --max. A truncated read must say so: a bare array
    # of exactly `limit` rows is indistinguishable from a complete one.
    if [[ "$paginate_all" != "true" ]]; then
        if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
            jq -cn --arg v "$limit" '{error: ("--limit must be a non-negative integer, got: " + $v)}' >&2
            return 1
        fi
        local canon="${limit#"${limit%%[!0]*}"}"
        [[ -n "$canon" ]] || canon=0
        if (( ${#canon} > 9 )); then
            jq -cn --arg v "$limit" '{error: ("--limit must be at most 9 digits after leading zeros, got: " + $v)}' >&2
            return 1
        fi
        limit=$canon
        local total
        total=$(echo "$issues" | jq 'length')
        if (( total > limit )); then
            echo "⚠️  Truncated to $limit of $total issues. Pass --max for all results, or --limit N." >&2
        fi
        issues=$(echo "$issues" | jq --argjson n "$limit" '.[0:$n]')
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
    issue=$(cache_jq_file "$CACHE_DIR/issues.json" "" --arg id "$issue_id" \
        '.[] | select(.identifier == $id or .id == $id)') || return 1

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
            "$ISSUE_RELATION_JQ"'{
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
                blocks: issue_blocks_ids($issue.relations.nodes),
                blocked_by: issue_blocked_by_ids($issue.inverseRelations.nodes),
                blocked_by_open: issue_blocked_by_open_ids($issue.inverseRelations.nodes),
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
            children_nodes=$(cache_jq_file "$CACHE_DIR/issues.json" "[]" --arg id "$issue_id" \
                '[.[] | select(.parent.identifier == $id) | {identifier, title, state}]') || return 1
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
        children=$(cache_jq_file "$CACHE_DIR/issues.json" "[]" --arg p "$issue_id" \
            '[.[] | select(.parent.identifier == $p) | {
                id: .identifier,
                uuid: .id,
                title: (.title // ""),
                state: (.state.name // ""),
                state_type: (.state.type // ""),
                assignee: (.assignee.name // ""),
                priority: (.priority // 0),
                estimate: (.estimate // 0)
            }]') || return 1

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
    result=$(cache_jq_file "$CACHE_DIR/issues.json" "" --arg id "$issue_id" "$ISSUE_RELATION_JQ"'
        .[] | select(.identifier == $id or .id == $id) | {
            blocks: issue_blocks_rows(.relations.nodes; false),
            blocked_by: issue_blocked_by_rows(.inverseRelations.nodes; false),
            blocked_by_open: issue_blocked_by_open_rows(.inverseRelations.nodes; false),
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
    ') || return 1

    if [[ -z "$result" ]]; then
        echo "{\"error\": \"Issue not found in cache: $issue_id\"}" >&2
        return 1
    fi
    echo "$result"
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
    result=$(cache_jq_file "$CACHE_DIR/issues.json" '{"issues":{"nodes":[]}}' --argjson ids "$id_json" \
        '{issues: {nodes: [.[] | select(.identifier as $id | $ids | any(. == $id))]}}') || return 1

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
    projects=$(cache_jq_file "$CACHE_DIR/projects.json" "[]" "$jq_filter") || return 1

    if [[ "$first_only" == "true" ]]; then
        # Same fail-closed contract as the live path: no fabricated default,
        # because callers feed this straight back into a --project filter.
        local name
        name=$(echo "$projects" | jq -r '.[0].name // empty')
        if [[ -z "$name" ]]; then
            echo '{"error": "No project matched --first"}' >&2
            return 1
        fi
        echo "$name"
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
    project=$(cache_jq_file "$CACHE_DIR/projects.json" "" --arg ref "$project_ref" \
        '.[] | select(.id == $ref or .name == $ref)') || return 1

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

    # No fallback object here: an unreadable cache must not answer "this
    # project has no dependencies", which is what a well-formed empty
    # relations payload tells every caller asking whether it is blocked.
    cache_jq_file "$CACHE_DIR/projects.json" "" --arg id "$project_id" '.[] | select(.id == $id or .name == $id) | {
        project: {
            id: .id,
            name: .name,
            relations: .relations,
            inverseRelations: .inverseRelations
        }
    }'
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
    labels=$(cache_jq_file "$CACHE_DIR/labels.json" "[]" '.') || return 1

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
    initiatives=$(cache_jq_file "$CACHE_DIR/initiatives.json" "[]" "$jq_filter") || return 1

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
    initiative=$(cache_jq_file "$CACHE_DIR/initiatives.json" "" --arg ref "$ref" \
        '.[] | select(.id == $ref or .name == $ref)') || return 1

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
    cycles=$(cache_jq_file "$CACHE_DIR/cycles.json" "[]" '.') || return 1

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
    # `--help` anywhere selects usage, but the token after a value-taking flag
    # is that flag's VALUE, never a request for help: `--search -h` used to
    # print usage and exit 0, which a caller parsing the output reads as an
    # empty result set.
    local arg skip_value="false"
    for arg in "$@"; do
        if [[ "$skip_value" == "true" ]]; then
            skip_value="false"
            continue
        fi
        case "$arg" in
        --project | --project-id | --state | --status | --label | --labels | --cycle | \
            --updated-since | --created-since | --search | --limit | --format | --team | \
            --assignee | --include-children-of)
            skip_value="true"
            ;;
        --help | -h)
            show_help
            return 0
            ;;
        esac
    done

    case "${1:-}" in
    help)
        show_help
        return 0
        ;;
    esac

    case "${2:-}" in
    help)
        show_help
        return 0
        ;;
    esac

    if [[ ! -f "$CACHE_DIR/meta.json" ]]; then
        cache_missing_error
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
        bulk-get) cache_bulk_get_issues "$@" ;;
        --help | -h) show_help ;;
        view | show)
            echo "{\"error\": \"Unknown issues action: $action. Cache lookups are 'cache issues get [ISSUE_ID]' or 'cache issues bulk-get [ID_1] [ID_2]'; live lookups are 'issues get' / 'issues bulk-get'.\"}" >&2
            return 1
            ;;
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
