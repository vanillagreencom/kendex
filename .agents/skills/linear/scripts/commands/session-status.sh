#!/bin/bash
# Linear GraphQL API - Session Status (aggregated queries for /start workflow)
# Reads live: each section's issues, projects and cycles come from Linear's API
# in this run, every page of each read.
# Usage: session-status.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    cat << 'EOF'
Session Status - Aggregated queries for development session initialization

Usage: session-status.sh [options]

Options:
  --research-days <N>     Days to look back for completed research (default: 7)

Output:
  JSON object with:
  - research: completed research tasks and unprocessed status
  - projects: all started projects with dependencies and active work status:
    - blocked_by: projects that must complete before this project can start
    - blocks: projects that will be unblocked when this project completes
    - priority: project priority (1=urgent, 2=high, 3=normal, 4=low, 0=none)
    - has_active_work: true if project has Todo, In Progress, or Backlog issues
  - backlog_projects: ALL backlog/planned projects ordered by sort_order (manual drag-drop):
    - Each includes: blocked_by, blocked_by_incomplete, blocks, sort_order, ready
    - ready: true if all dependencies satisfied (can be started)
  - next_project: first ready project by sort_order (null if none ready)
  - cycle: current active cycle (or null if none)
  - issues: categorized issue arrays (sub-issues excluded, shown via parent):
    - actionable: Todo, unblocked, excludes research + agent:human + sub-issues
    - in_progress: In Progress state, excludes research + agent:human + sub-issues
    - research_pending: has research label, Todo/Backlog (needs human execution)
    - research_ready: has research label, In Progress/In Review (session_init.sh verifies findings exist)
    - backlog: Backlog state, unblocked, excludes research + sub-issues
    - blocked: has blockers outside completed and canceled state types (excludes sub-issues)
    - Each issue includes state, state_type, blocked_by, blocked_by_open, and children_progress
  - pr_blockers: sub-issues with pending work (Todo/In Progress/Backlog) whose parent is "In Review"

Examples:
  session-status.sh                          # Default: 7 days
  session-status.sh --research-days 14       # Look back 14 days for research
EOF
}
case "${1:-}" in help|--help|-h) show_help; exit 0 ;; esac

source "$SCRIPT_DIR/../lib/common.sh"

# The fields every session read selects, so one issue read by two queries has
# one shape when the reads are merged.
SESSION_ISSUE_FIELDS='
    id
    identifier
    title
    description
    url
    priority
    state { name type }
    labels { pageInfo { hasNextPage endCursor } nodes { name } }
    project { id name }
    cycle { id name number }
    parent { id identifier title }
'"$ISSUE_RELATION_FIELDS"

# Every issue matching FILTER, as one JSON array. Every section's issues pass
# here, and the read leaves out archived and trashed issues by Linear's own
# default (includeArchived false; a trashed issue is archived), so no section
# counts an issue the workspace no longer shows.
# Usage: session_issues '<IssueFilter JSON>'
session_issues() {
    local query="
    query SessionIssues(\$filter: IssueFilter, \$after: String) {
        issues(filter: \$filter, first: 50, after: \$after) {
            pageInfo { hasNextPage endCursor }
            nodes { $SESSION_ISSUE_FIELDS }
        }
    }"
    local variables result
    variables=$(jq -c '{filter: .}' <<<"$1") || return 1
    result=$(graphql_pages "$query" "$variables" issues) || return 1
    jq -c '.issues.nodes' <<<"$result"
}

# The issues with any of the given ids. Usage: session_issues_by_id '<uuid array>'
session_issues_by_id() {
    [[ "$1" != "[]" ]] || { printf '[]\n'; return 0; }
    session_issues "$(jq -c '{id: {in: .}}' <<<"$1")"
}

# Descendants of the given issues, three levels down, the depth the children
# progress below reads. Usage: session_descendants '<uuid array>'
session_descendants() {
    local parents="$1" level=0 rows all='[]' filter
    while [[ "$parents" != "[]" ]] && (( level < 3 )); do
        filter=$(jq -c '{parent: {id: {in: .}}}' <<<"$parents") || return 1
        rows=$(session_issues "$filter") || return 1
        all=$(jq -cs '.[0] + .[1]' <<<"$all"$'\n'"$rows") || return 1
        parents=$(jq -c 'map(.id)' <<<"$rows") || return 1
        level=$((level + 1))
    done
    printf '%s\n' "$all"
}

get_session_status() {
    local research_days=7

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --research-days) research_days="$2"; shift 2 ;;
            --help|-h) show_help; exit 0 ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    if ! [[ "$research_days" =~ ^[0-9]{1,5}$ ]]; then
        jq -cn --arg v "$research_days" '{error: ("--research-days must be a whole number of days, got: " + $v)}' >&2
        return 1
    fi

    # Calculate date threshold for research
    local research_date
    research_date=$(linear_utc_days_ago "$research_days") || return 1

    # =========================================================================
    # Live reads. Every section below reads the issue set merged here, which
    # holds each issue a section selects or looks up: the open issues of
    # started projects, recent completed research and the issues it blocks,
    # pending sub-issues of In Review parents and those parents, and three
    # levels of descendants under both sets. A failed read fails the status.
    # =========================================================================

    # Nested pages of 10 keep a 50-project page under Linear's query
    # complexity limit; lib/pages.sh reads any connection left open.
    local projects_query='
    query SessionProjects($after: String) {
        projects(first: 50, after: $after, includeArchived: true) {
            pageInfo { hasNextPage endCursor }
            nodes {
                id
                name
                description
                state
                progress
                priority
                sortOrder
                labels(first: 10) { pageInfo { hasNextPage endCursor } nodes { name } }
                relations(first: 10) {
                    pageInfo { hasNextPage endCursor }
                    nodes { id type anchorType relatedAnchorType relatedProject { id name state progress } }
                }
                inverseRelations(first: 10) {
                    pageInfo { hasNextPage endCursor }
                    nodes { id type anchorType relatedAnchorType project { id name state progress } }
                }
            }
        }
    }'
    local all_projects
    all_projects=$(graphql_pages "$projects_query" '{}' projects) || return 1
    all_projects=$(jq -c '.projects.nodes' <<<"$all_projects") || return 1

    # Cycles of the configured team, or of every team with none configured.
    local cycle_filter='{}'
    if [[ -n "$LINEAR_TEAM_TARGET" ]]; then
        local team_id
        team_id=$(resolve_team_id "$LINEAR_TEAM_TARGET") || return 1
        cycle_filter=$(jq -cn --arg id "$team_id" '{team: {id: {eq: $id}}}') || return 1
    fi
    local cycles_query='
    query SessionCycles($filter: CycleFilter, $after: String) {
        cycles(filter: $filter, first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
                id number name startsAt endsAt progress
                issueCountHistory completedIssueCountHistory
                scopeHistory completedScopeHistory
                team { name }
            }
        }
    }'
    local all_cycles_page
    all_cycles_page=$(graphql_pages "$cycles_query" "$(jq -c '{filter: .}' <<<"$cycle_filter")" cycles) || return 1

    local started_ids project_issues research_issues blocked_issues review_children review_parents descendants all_issues
    started_ids=$(jq -c '[.[] | select(.state == "started") | .id]' <<<"$all_projects") || return 1
    project_issues='[]'
    if [[ "$started_ids" != "[]" ]]; then
        project_issues=$(session_issues "$(jq -c '{project: {id: {in: .}},
            state: {name: {in: ["Backlog", "Todo", "In Progress", "In Review"]}}}' <<<"$started_ids")") || return 1
    fi
    research_issues=$(session_issues "$(jq -cn --arg date "$research_date" '{labels: {name: {eq: "research"}},
        state: {type: {eq: "completed"}}, updatedAt: {gte: $date}}')") || return 1
    blocked_issues=$(session_issues_by_id "$(jq -c '[.[].relations.nodes[] | select(.type == "blocks") | .relatedIssue.id] | unique' \
        <<<"$research_issues")") || return 1
    review_children=$(session_issues '{"parent": {"state": {"name": {"eq": "In Review"}}}, "state": {"type": {"nin": ["completed", "canceled"]}}}') || return 1
    review_parents=$(session_issues_by_id "$(jq -c '[.[].parent.id] | unique' <<<"$review_children")") || return 1
    descendants=$(session_descendants "$(jq -cs 'add | map(.id) | unique' <<<"$project_issues"$'\n'"$review_children")") || return 1
    all_issues=$(jq -cs 'add | unique_by(.id)' \
        <<<"$project_issues"$'\n'"$research_issues"$'\n'"$blocked_issues"$'\n'"$review_children"$'\n'"$review_parents"$'\n'"$descendants") || return 1

    # --- Research (was Q1 + Q2) ---
    # The research read's own filter (research label, completed, updated
    # within the threshold) selects the set; the merged read looks up what
    # each one blocks.
    local research_json
    research_json=$(jq -s '
        .[0] as $research | .[1] as $all |

        # For each research issue, find blocked issues and check descriptions
        {
            count: ($research | length),
            items: [$research[] | {
                id: .identifier,
                title,
                blocks: [(.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier]
            }],
            unprocessed: [
                $research[] |
                .identifier as $research_id |
                .title as $research_title |
                [(.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue] as $blocked_refs |
                $blocked_refs[] |
                .identifier as $blocked_id |
                # Find the blocked issue among those read
                ($all[] | select(.identifier == $blocked_id)) as $blocked_issue |
                # Only check active issues
                select($blocked_issue.state.type != "completed" and $blocked_issue.state.type != "canceled") |
                # Flag if missing **Research**: reference
                select(($blocked_issue.description // "") | test("\\*\\*Research\\*\\*:"; "i") | not) |
                {research_id: $research_id, research_title: $research_title, blocked_id: $blocked_id, blocked_title: ($blocked_issue.title // "")}
            ] | unique
        }
    ' <<<"$research_issues"$'\n'"$all_issues") || return 1

    # --- Active projects (was Q3) ---
    # All started projects with dependencies, sorted by priority (urgent first, none last)
    local projects_json
    projects_json=$(jq '[.[] | select(.state == "started") | {
        id: .id,
        name: .name,
        state: .state,
        priority: (.priority // 0),
        progress: (.progress // 0),
        perpetual: ([(.labels.nodes // [])[] | .name] | any(. == "perpetual")),
        blocked_by: [
            (.relations.nodes // [])[] |
            select(.type == "dependency") |
            .relatedProject |
            select(.state != "completed" and .state != "canceled") |
            {id, name, state, progress}
        ],
        blocks: [
            (.inverseRelations.nodes // [])[] |
            select(.type == "dependency") |
            .project |
            {id, name, state, progress}
        ]
    }] | sort_by(if .priority == 0 then 5 else .priority end)' <<<"$all_projects") || return 1
    # Collect project IDs for issue filtering
    local project_ids
    project_ids=$(echo "$projects_json" | jq -r '[.[].id] | join(",")')

    # --- Backlog projects (was Q3b) ---
    local backlog_projects_json
    backlog_projects_json=$(jq '
        def is_ready:
            [(.relations.nodes // [])[] | select(.type == "dependency") | .relatedProject] as $blockers |
            ($blockers | length) == 0 or
            ([$blockers[] | select(.state != "completed" and .state != "canceled")] | length) == 0;

        [.[] | select(.state == "backlog" or .state == "planned") | {
            id: .id,
            name: .name,
            description: (.description // ""),
            state: .state,
            priority: (.priority // 0),
            progress: (.progress // 0),
            sort_order: (.sortOrder // 0),
            blocked_by: [
                (.relations.nodes // [])[] |
                select(.type == "dependency") |
                .relatedProject |
                {id, name, state, progress}
            ],
            blocked_by_incomplete: [
                (.relations.nodes // [])[] |
                select(.type == "dependency") |
                .relatedProject |
                select(.state != "completed" and .state != "canceled") |
                {id, name, state, progress}
            ],
            blocks: [
                (.inverseRelations.nodes // [])[] |
                select(.type == "dependency") |
                .project |
                {id, name, state, progress}
            ],
            ready: is_ready
        }] | sort_by(.sort_order)
    ' <<<"$all_projects") || return 1

    # --- Cycles (was Q3c) ---
    # Date-based selection through the shared cycle helpers: working = the
    # started cycle whose end has not passed, prev/next cut at its start, or
    # at now where no cycle is running. Reading a position in the list instead — `last` for
    # previous, `first` for next — inverted both answers between cycles, and
    # this is the read cycle planning consumes.
    local all_cycles
    all_cycles=$(jq -c '.cycles.nodes | sort_by(.startsAt)' <<<"$all_cycles_page") || return 1
    local working_cycle_json
    working_cycle_json=$(linear_working_cycle <<<"$all_cycles") || return 1
    local prev_cycle_json
    prev_cycle_json=$(linear_cycles_before "$working_cycle_json" <<<"$all_cycles" | jq 'first // null') || return 1
    local next_cycle_json
    next_cycle_json=$(linear_cycles_after "$working_cycle_json" <<<"$all_cycles" | jq 'first // null') || return 1

    # --- Project issues categorized (was Q4) ---
    # Aggregate from ALL started projects, tag each issue with project_name
    local issues_json='{"actionable": [], "research_pending": [], "research_ready": [], "backlog": [], "blocked": [], "in_progress": []}'
    if [[ -n "$project_ids" ]]; then
        # The issue set and the project list arrive on stdin, not as arguments:
        # either can outgrow one argument's size limit.
        issues_json=$(jq -s --arg pids "$project_ids" "$ISSUE_RELATION_JQ"'
            .[1] as $projects | .[0] |
            # Build project ID set, name lookup, and priority lookup
            ($pids | split(",")) as $pid_list |
            ([($projects // [])[] | {(.id): .name}] | add // {}) as $project_names |
            # Priority: 1=urgent..4=low, 0=none → remap 0 to 5 so "none" sorts last
            ([($projects // [])[] | {(.id): (if .priority == 0 then 5 else .priority end)}] | add // {}) as $project_priorities |

            # Filter to issues in any started project, active states
            [.[] |
                select(.project.id as $pid | $pid_list | any(. == $pid)) |
                select(.state.name == "Backlog" or .state.name == "Todo" or .state.name == "In Progress" or .state.name == "In Review")
            ] as $project_issues |

            # Load all issues for children lookup
            . as $all |

            # Helper: check if issue is blocked by incomplete issues
            def is_blocked: issue_blocked_by_open_relations(.inverseRelations.nodes) | length > 0;
            # Helper: check if has specific label
            def has_label($name): [(.labels.nodes // [])[] | .name] | any(. == $name);
            # Helper: check if issue is a sub-issue (has parent)
            def is_sub_issue: .parent != null;
            # Helper: recursively flatten children from the merged read
            def flat_children(depth):
                if depth >= 3 then [] else
                    .identifier as $pid |
                    [$all[] | select(.parent.identifier == $pid)] |
                    map(. as $c | [{
                        id: $c.identifier,
                        title: ($c.title // ""),
                        state: ($c.state.name // ""),
                        state_type: ($c.state.type // ""),
                        agent: (([$c.labels.nodes[]? | .name | select(startswith("agent:"))] | first // "none") | gsub("^agent:"; "")),
                        depth: depth
                    }] + ($c | flat_children(depth + 1))) | flatten
                end;
            # Helper: calculate children progress
            def children_progress:
                flat_children(0) |
                if length > 0 then
                    . as $all |
                    {
                        total: ($all | length),
                        done: ([$all[] | select(.state_type == "completed")] | length),
                        children: $all
                    }
                else null end;
            # Helper: format issue for output (includes project_name and project_priority)
            def format_issue: {
                id: .identifier,
                title,
                url: (.url // ""),
                agent: (([(.labels.nodes // [])[] | .name | select(startswith("agent:"))] | first) // "none"),
                priority: (.priority // 0),
                project_priority: ($project_priorities[.project.id] // 5),
                cycle: ((.cycle.number // null)),
                labels: [(.labels.nodes // [])[] | .name],
                project_name: ($project_names[.project.id] // ""),
                state: (.state.name // ""), state_type: (.state.type // ""),
                blocked_by: issue_blocked_by_ids(.inverseRelations.nodes),
                blocked_by_open: issue_blocked_by_open_ids(.inverseRelations.nodes),
                children_progress: children_progress
            };
            # Helper: format research issue
            def format_research: format_issue + {
                blocks: issue_blocks_open_ids(.relations.nodes)
            };
            {
                actionable: [$project_issues[] |
                    select(is_sub_issue | not) |
                    select(is_blocked | not) |
                    select(.state.name == "Todo") |
                    select(has_label("research") | not) |
                    select(has_label("agent:human") | not) |
                    format_issue
                ] | sort_by(.project_priority, .priority),

                in_progress: [$project_issues[] |
                    select(is_sub_issue | not) |
                    select(.state.name == "In Progress") |
                    select(has_label("research") | not) |
                    select(has_label("agent:human") | not) |
                    format_issue
                ] | sort_by(.priority),

                research_pending: [$project_issues[] |
                    select(has_label("research")) |
                    select(.state.name == "Todo" or .state.name == "Backlog") |
                    format_research
                ] | sort_by(.priority),

                research_ready: [$project_issues[] |
                    select(has_label("research")) |
                    select(.state.name == "In Progress" or .state.name == "In Review") |
                    format_research
                ] | sort_by(.priority),

                backlog: [$project_issues[] |
                    select(is_sub_issue | not) |
                    select(is_blocked | not) |
                    select(.state.name == "Backlog") |
                    select(has_label("research") | not) |
                    format_issue
                ] | sort_by(.priority),

                blocked: [$project_issues[] |
                    select(is_sub_issue | not) |
                    select(is_blocked) |
                    select(has_label("research") | not) |
                    format_issue
                ] | sort_by(.priority)
            }
        ' <<<"$all_issues"$'\n'"$projects_json") || return 1
    fi

    # --- PR blockers (was Q5) ---
    local pr_blockers_json
    pr_blockers_json=$(jq '
        . as $all |

        # Recursive children from the merged read
        def children_flat(depth):
            if depth >= 3 then [] else
                .identifier as $pid |
                [$all[] | select(.parent.identifier == $pid)] |
                map(. as $c | [{
                    id: $c.identifier,
                    title: ($c.title // ""),
                    state: ($c.state.name // ""),
                    state_type: ($c.state.type // ""),
                    agent: (([($c.labels.nodes // [])[] | .name | select(startswith("agent:"))] | first) // "none"),
                    priority: ($c.priority // 0),
                    depth: depth
                }] + ($c | children_flat(depth + 1))) | flatten
            end;

        [
            .[] |
            select(.parent != null) |
            select(.state.type != "completed" and .state.type != "canceled") |
            # Find the parent among the issues read to check its state
            .parent.identifier as $parent_id |
            ($all[] | select(.identifier == $parent_id)) as $parent_issue |
            select($parent_issue.state.name == "In Review") |
            select(.state.name != "In Review" and .state.name != "Verifying") |
            {
                id: .identifier,
                title,
                url: (.url // ""),
                agent: (([(.labels.nodes // [])[] | .name | select(startswith("agent:"))] | first) // "none"),
                priority: (.priority // 0),
                parent_id: .parent.identifier,
                parent_title: ($parent_issue.title // ""),
                children: (
                    children_flat(0) |
                    [.[] | select(.state_type != "completed" and .state_type != "canceled" and .state != "Verifying")]
                )
            }
        ]
    ' <<<"$all_issues") || return 1

    # Determine which projects have active work (Todo, Backlog, or In Progress issues)
    local projects_with_work
    projects_with_work=$(jq -s '
        .[0] as $projects | .[1] as $issues |
        ($issues.actionable + $issues.in_progress + $issues.backlog + $issues.research_pending + $issues.research_ready + $issues.blocked) as $active_issues |
        [$projects[] | . as $p |
            ([$active_issues[] | select(.project_name == $p.name)] | length > 0) as $has_work |
            . + {has_active_work: $has_work}
        ]
    ' <<<"$projects_json"$'\n'"$issues_json") || return 1

    # Combine all results, each one a document on stdin
    printf '%s\n' "$research_json" "$projects_with_work" "$backlog_projects_json" "$prev_cycle_json" \
        "$working_cycle_json" "$next_cycle_json" "$issues_json" "$pr_blockers_json" | jq -s '
        . as [$research, $projects, $backlog_projects, $prev_cycle, $cycle, $next_cycle, $issues, $pr_blockers] |
        {
            research: {
                count: $research.count,
                unprocessed: $research.unprocessed,
                all_processed: (($research.unprocessed | length) == 0)
            },
            projects: $projects,
            backlog_projects: $backlog_projects,
            next_project: ([$backlog_projects[] | select(.ready == true)] | first // null),
            prev_cycle: $prev_cycle,
            cycle: $cycle,
            next_cycle: $next_cycle,
            issues: $issues,
            pr_blockers: $pr_blockers
        }'
}

# Main
action="${1:-}"

case "$action" in
    --help|-h|help)
        show_help
        ;;
    *)
        get_session_status "$@"
        ;;
esac
