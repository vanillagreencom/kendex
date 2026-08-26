#!/bin/bash
# Linear GraphQL API - Session Status (aggregated queries for /start workflow)
# Reads entirely from local cache — zero API calls
# Usage: session-status.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/cache.sh"

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
    - blocked: has incomplete blockers (excludes sub-issues)
    - Each issue includes children_progress: {total, done, children[]} if it has sub-issues
  - pr_blockers: sub-issues with pending work (Todo/In Progress/Backlog) whose parent is "In Review"

Examples:
  session-status.sh                          # Default: 7 days
  session-status.sh --research-days 14       # Look back 14 days for research
EOF
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

    # Auto-sync guard: ensure cache is reasonably fresh
    if ! cache_is_fresh 15; then
        echo "Cache stale or missing, syncing..." >&2
        "$BASH" "$SCRIPT_DIR/sync.sh" 2>&1 | while read -r line; do echo "  $line" >&2; done
    fi

    # Calculate date threshold for research
    local research_date
    research_date=$(date -d "-$research_days days" -Iseconds 2>/dev/null || date -v-"${research_days}"d -Iseconds)

    # =========================================================================
    # All data read from cache — zero API calls
    # =========================================================================

    local issues_file="$CACHE_DIR/issues.json"
    local projects_file="$CACHE_DIR/projects.json"
    local cycles_file="$CACHE_DIR/cycles.json"

    # --- Research (was Q1 + Q2) ---
    # Research: completed issues with research label, updated within threshold
    local research_json
    research_json=$(jq --arg date "$research_date" '
        # All issues in cache
        . as $all |

        # Completed research issues updated recently
        [.[] | select(
            [.labels.nodes[].name] | any(. == "research")
        ) | select(
            .state.type == "completed"
        ) | select(
            .updatedAt >= $date
        )] as $research |

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
                # Find the actual blocked issue in our cache
                ($all[] | select(.identifier == $blocked_id)) as $blocked_issue |
                # Only check active issues
                select($blocked_issue.state.type != "completed" and $blocked_issue.state.type != "canceled") |
                # Flag if missing **Research**: reference
                select(($blocked_issue.description // "") | test("\\*\\*Research\\*\\*:"; "i") | not) |
                {research_id: $research_id, research_title: $research_title, blocked_id: $blocked_id, blocked_title: ($blocked_issue.title // "")}
            ] | unique
        }
    ' "$issues_file")

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
    }] | sort_by(if .priority == 0 then 5 else .priority end)' "$projects_file")
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
    ' "$projects_file")

    # --- Cycles (was Q3c) ---
    # Use date-based selection: working = most recent started + incomplete
    local today_iso
    today_iso=$(date -Iseconds)
    local all_cycles
    all_cycles=$(jq 'sort_by(.startsAt)' "$cycles_file")
    local working_cycle_json
    working_cycle_json=$(echo "$all_cycles" | jq --arg today "$today_iso" \
        '[.[] | select(.startsAt <= $today and .progress < 1)] | last // null')
    local prev_cycle_json
    prev_cycle_json=$(echo "$all_cycles" | jq --argjson working "$working_cycle_json" '
        if $working then
            [.[] | select(.startsAt < $working.startsAt)] | last // null
        else
            last // null
        end
    ')
    local next_cycle_json
    next_cycle_json=$(echo "$all_cycles" | jq --argjson working "$working_cycle_json" '
        if $working then
            [.[] | select(.startsAt > $working.startsAt)] | first // null
        else
            first // null
        end
    ')

    # --- Project issues categorized (was Q4) ---
    # Aggregate from ALL started projects, tag each issue with project_name
    local issues_json='{"actionable": [], "research_pending": [], "research_ready": [], "backlog": [], "blocked": [], "in_progress": []}'
    if [[ -n "$project_ids" ]]; then
        issues_json=$(jq --arg pids "$project_ids" --argjson projects "$projects_json" '
            # Build project ID set, name lookup, and priority lookup
            ($pids | split(",")) as $pid_list |
            ([($projects // [])[] | {(.id): .name}] | add // {}) as $project_names |
            # Priority: 1=urgent..4=low, 0=none → remap 0 to 5 so "none" sorts last
            ([($projects // [])[] | {(.id): (if .priority == 0 then 5 else .priority end)}] | add // {}) as $project_priorities |

            # Filter to issues in any started project, active states, not archived
            [.[] |
                select(.project.id as $pid | $pid_list | any(. == $pid)) |
                select(.archivedAt == null and (.trashed | not)) |
                select(.state.name == "Backlog" or .state.name == "Todo" or .state.name == "In Progress" or .state.name == "In Review")
            ] as $project_issues |

            # Load all issues for children lookup
            . as $all |

            # Helper: check if issue is blocked by incomplete issues
            def is_blocked: [(.inverseRelations.nodes // [])[] | select(.type == "blocks" and .issue.state.type != "completed")] | length > 0;
            # Helper: check if has specific label
            def has_label($name): [(.labels.nodes // [])[] | .name] | any(. == $name);
            # Helper: check if issue is a sub-issue (has parent)
            def is_sub_issue: .parent != null;
            # Helper: recursively flatten children from cache (not nested GraphQL)
            def cache_children(depth):
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
                    }] + ($c | cache_children(depth + 1))) | flatten
                end;
            # Helper: calculate children progress
            def children_progress:
                cache_children(0) |
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
                children_progress: children_progress
            };
            # Helper: format blocked issue
            def format_blocked: format_issue + {
                blocked_by: [(.inverseRelations.nodes // [])[] | select(.type == "blocks" and .issue.state.type != "completed") | .issue.identifier]
            };
            # Helper: format research issue
            def format_research: format_issue + {
                blocks: [(.relations.nodes // [])[] | select(.type == "blocks" and .relatedIssue.state.type != "completed") | .relatedIssue.identifier]
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
                    format_blocked
                ] | sort_by(.priority)
            }
        ' "$issues_file")
    fi

    # --- PR blockers (was Q5) ---
    local pr_blockers_json
    pr_blockers_json=$(jq '
        . as $all |

        # Recursive children from cache
        def cache_children_flat(depth):
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
                }] + ($c | cache_children_flat(depth + 1))) | flatten
            end;

        [
            .[] |
            select(.parent != null) |
            select(.state.type != "completed" and .state.type != "canceled") |
            # Find parent in cache to check its state
            .parent.identifier as $parent_id |
            ($all[] | select(.identifier == $parent_id)) as $parent_issue |
            select($parent_issue.state.name == "In Review") |
            select(.state.name != "In Review") |
            {
                id: .identifier,
                title,
                url: (.url // ""),
                agent: (([(.labels.nodes // [])[] | .name | select(startswith("agent:"))] | first) // "none"),
                priority: (.priority // 0),
                parent_id: .parent.identifier,
                parent_title: ($parent_issue.title // ""),
                children: (
                    cache_children_flat(0) |
                    [.[] | select(.state_type != "completed" and .state_type != "canceled")]
                )
            }
        ]
    ' "$issues_file")

    # Determine which projects have active work (Todo, Backlog, or In Progress issues)
    local projects_with_work
    projects_with_work=$(jq --argjson projects "$projects_json" --argjson issues "$issues_json" '
        ($issues.actionable + $issues.in_progress + $issues.backlog + $issues.research_pending + $issues.research_ready + $issues.blocked) as $active_issues |
        [$projects[] | . as $p |
            ([$active_issues[] | select(.project_name == $p.name)] | length > 0) as $has_work |
            . + {has_active_work: $has_work}
        ]
    ' <<< 'null')

    # Combine all results
    jq -n \
        --argjson research "$research_json" \
        --argjson projects "$projects_with_work" \
        --argjson backlog_projects "$backlog_projects_json" \
        --argjson prev_cycle "$prev_cycle_json" \
        --argjson cycle "$working_cycle_json" \
        --argjson next_cycle "$next_cycle_json" \
        --argjson issues "$issues_json" \
        --argjson pr_blockers "$pr_blockers_json" \
        '{
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
