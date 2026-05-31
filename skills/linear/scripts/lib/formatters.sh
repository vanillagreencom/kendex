#!/bin/bash
# Linear CLI - Output Formatters
# Converts GraphQL responses to safe, flat structures
# Source this file in command scripts

set -euo pipefail

# Format issues list to safe structure
# Input: Raw GraphQL response with .issues.nodes[]
# Output: Flat array with all nullable fields defaulted
format_issues_list() {
    local raw="$1"
    echo "$raw" | jq '[.issues.nodes[] | {
        id: .identifier,
        uuid: .id,
        title: (.title // ""),
        description: (.description // ""),
        state: (.state.name // ""),
        state_type: (.state.type // ""),
        agent: ((([.labels.nodes[].name | select(startswith("agent:"))] | first) // "") | sub("^agent:"; "")),
        platform: (([.labels.nodes[].name | select(. == "linux" or . == "windows" or . == "macos" or . == "cross-platform")] | first) // ""),
        labels: [(.labels.nodes // [])[] | .name],
        priority: (.priority // 0),
        estimate: (.estimate // 0),
        sort_order: (.sortOrder // 0),
        project: (.project.name // ""),
        project_id: (.project.id // ""),
        assignee: (.assignee.name // ""),
        parent_id: (.parent.identifier // ""),
        milestone: (.projectMilestone.name // ""),
        cycle: (if .cycle then (.cycle.name // "Cycle \(.cycle.number)") else "" end),
        created_at: (.createdAt // ""),
        updated_at: (.updatedAt // ""),
        blocks: [(.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier],
        blocked_by: [(.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue.identifier],
        related: [(.relations.nodes // [])[] | select(.type == "related") | .relatedIssue.identifier],
        url: (.url // "")
    }]'
}

# Format single issue to safe structure
# Input: Raw GraphQL response with .issue
# Output: Flat object (not wrapped in {issue: ...})
format_issue_single() {
    local raw="$1"
    echo "$raw" | jq '{
        id: .issue.identifier,
        identifier: .issue.identifier,
        uuid: .issue.id,
        title: (.issue.title // ""),
        description: (.issue.description // ""),
        state: (.issue.state.name // ""),
        state_type: (.issue.state.type // ""),
        agent: ((([.issue.labels.nodes[].name | select(startswith("agent:"))] | first) // "") | sub("^agent:"; "")),
        platform: (([.issue.labels.nodes[].name | select(. == "linux" or . == "windows" or . == "macos" or . == "cross-platform")] | first) // ""),
        labels: [(.issue.labels.nodes // [])[] | .name],
        priority: (.issue.priority // 0),
        estimate: (.issue.estimate // 0),
        sort_order: (.issue.sortOrder // 0),
        project: (.issue.project.name // ""),
        project_id: (.issue.project.id // ""),
        assignee: (.issue.assignee.name // ""),
        parent_id: (.issue.parent.identifier // ""),
        milestone: (.issue.projectMilestone.name // ""),
        cycle: (if .issue.cycle then (.issue.cycle.name // "Cycle \(.issue.cycle.number)") else "" end),
        created_at: (.issue.createdAt // ""),
        updated_at: (.issue.updatedAt // ""),
        blocks: [(.issue.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier],
        blocked_by: [(.issue.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue.identifier],
        related: [(.issue.relations.nodes // [])[] | select(.type == "related") | .relatedIssue.identifier],
        url: (.issue.url // "")
    }'
}

# Format single issue with bundle info (recursive children + pending count)
# Input: Raw GraphQL response with .issue containing 3-level nested children
# Output: Flat object with children array and pending_count
format_issue_with_bundle() {
    local raw="$1"
    echo "$raw" | jq '
        # Recursive function to flatten children with depth tracking
        # Note: sort_order omitted from children — only meaningful on parent/standalone issues
        def flatten_children(depth):
            . as $node | [{
                id: $node.identifier,
                identifier: $node.identifier,
                uuid: $node.id,
                title: ($node.title // ""),
                description: ($node.description // ""),
                state: ($node.state.name // ""),
                state_type: ($node.state.type // ""),
                assignee: ($node.assignee.name // ""),
                agent: ((([($node.labels.nodes // [])[] | .name | select(startswith("agent:"))] | first) // "") | sub("^agent:"; "")),
                priority: ($node.priority // 0),
                estimate: ($node.estimate // 0),
                labels: [($node.labels.nodes // [])[] | .name],
                depth: depth,
                parent_id: ($node.parent.identifier // ""),
                blocks: [($node.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier],
                blocked_by: [($node.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue.identifier]
            }] + (($node.children.nodes // []) | map(flatten_children(depth + 1)) | flatten);

        # Flatten all children
        ([.issue.children.nodes[] | flatten_children(0)] | flatten) as $children |

        {
            id: .issue.identifier,
            identifier: .issue.identifier,
            uuid: .issue.id,
            title: (.issue.title // ""),
            description: (.issue.description // ""),
            state: (.issue.state.name // ""),
            state_type: (.issue.state.type // ""),
            agent: ((([.issue.labels.nodes[].name | select(startswith("agent:"))] | first) // "") | sub("^agent:"; "")),
            platform: (([.issue.labels.nodes[].name | select(. == "linux" or . == "windows" or . == "macos" or . == "cross-platform")] | first) // ""),
            labels: [(.issue.labels.nodes // [])[] | .name],
            priority: (.issue.priority // 0),
            estimate: (.issue.estimate // 0),
            sort_order: (.issue.sortOrder // 0),
            project: (.issue.project.name // ""),
            project_id: (.issue.project.id // ""),
            assignee: (.issue.assignee.name // ""),
            parent_id: (.issue.parent.identifier // ""),
            milestone: (.issue.projectMilestone.name // ""),
            cycle: (if .issue.cycle then (.issue.cycle.name // "Cycle \(.issue.cycle.number)") else "" end),
            created_at: (.issue.createdAt // ""),
            updated_at: (.issue.updatedAt // ""),
            blocks: [(.issue.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier],
            blocked_by: [(.issue.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue.identifier],
            related: [(.issue.relations.nodes // [])[] | select(.type == "related") | .relatedIssue.identifier],
            url: (.issue.url // ""),
            children: $children,
            pending_count: ([$children[] | select(.state_type | IN("completed", "canceled") | not)] | length)
        }
    '
}

# Format single issue to compact structure (minimal tokens for workflow routing)
# Strips: description, url, timestamps, uuid, project_id
format_issue_compact() {
    local raw="$1"
    echo "$raw" | jq '{
        id: .issue.identifier,
        identifier: .issue.identifier,
        title: (.issue.title // ""),
        state: (.issue.state.name // ""),
        state_type: (.issue.state.type // ""),
        agent: ((([.issue.labels.nodes[].name | select(startswith("agent:"))] | first) // "") | sub("^agent:"; "")),
        labels: [(.issue.labels.nodes // [])[] | .name],
        priority: (.issue.priority // 0),
        estimate: (.issue.estimate // 0),
        sort_order: (.issue.sortOrder // 0),
        project: (.issue.project.name // ""),
        assignee: (.issue.assignee.name // ""),
        parent_id: (.issue.parent.identifier // ""),
        blocks: [(.issue.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier],
        blocked_by: [(.issue.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue.identifier],
        children: [(.issue.children.nodes // [])[] | {id: .identifier, title: .title, state: .state.name}]
    }'
}

# Format issue with bundle to compact structure
format_issue_with_bundle_compact() {
    local raw="$1"
    echo "$raw" | jq '
        def flatten_children(depth):
            . as $node | [{
                id: $node.identifier,
                title: ($node.title // ""),
                state: ($node.state.name // ""),
                state_type: ($node.state.type // ""),
                agent: ((([($node.labels.nodes // [])[] | .name | select(startswith("agent:"))] | first) // "") | sub("^agent:"; "")),
                labels: [($node.labels.nodes // [])[] | .name],
                priority: ($node.priority // 0),
                estimate: ($node.estimate // 0),
                depth: depth,
                parent_id: ($node.parent.identifier // ""),
                blocks: [($node.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier],
                blocked_by: [($node.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue.identifier]
            }] + (($node.children.nodes // []) | map(flatten_children(depth + 1)) | flatten);

        ([.issue.children.nodes[] | flatten_children(0)] | flatten) as $children |
        {
            id: .issue.identifier,
            title: (.issue.title // ""),
            state: (.issue.state.name // ""),
            state_type: (.issue.state.type // ""),
            agent: ((([.issue.labels.nodes[].name | select(startswith("agent:"))] | first) // "") | sub("^agent:"; "")),
            labels: [(.issue.labels.nodes // [])[] | .name],
            priority: (.issue.priority // 0),
            estimate: (.issue.estimate // 0),
            sort_order: (.issue.sortOrder // 0),
            project: (.issue.project.name // ""),
            assignee: (.issue.assignee.name // ""),
            parent_id: (.issue.parent.identifier // ""),
            blocks: [(.issue.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier],
            blocked_by: [(.issue.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue.identifier],
            children: $children,
            pending_count: ([$children[] | select(.state_type | IN("completed", "canceled") | not)] | length)
        }
    '
}

# Format issues list to compact structure
format_issues_list_compact() {
    local raw="$1"
    echo "$raw" | jq '[.issues.nodes[] | {
        id: .identifier,
        title: (.title // ""),
        state: (.state.name // ""),
        state_type: (.state.type // ""),
        agent: ((([.labels.nodes[].name | select(startswith("agent:"))] | first) // "") | sub("^agent:"; "")),
        labels: [(.labels.nodes // [])[] | .name],
        priority: (.priority // 0),
        estimate: (.estimate // 0),
        sort_order: (.sortOrder // 0),
        project: (.project.name // ""),
        parent_id: (.parent.identifier // ""),
        blocks: [(.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier],
        blocked_by: [(.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue.identifier]
    }]'
}

# Format issues list to IDs only
# Input: Raw GraphQL response with .issues.nodes[]
# Output: Newline-separated identifiers
format_issues_ids() {
    local raw="$1"
    echo "$raw" | jq -r '.issues.nodes[].identifier'
}

# Format issues list to table
# Input: Raw GraphQL response with .issues.nodes[]
# Output: Tab-separated table with header
format_issues_table() {
    local raw="$1"
    echo -e "ID\tTITLE\tSTATE\tAGENT\tPRIORITY"
    echo "$raw" | jq -r '.issues.nodes[] | [
        .identifier,
        (.title[:50] // ""),
        (.state.name // ""),
        ((([.labels.nodes[].name | select(startswith("agent:"))] | first) // "-") | sub("^agent:"; "")),
        (.priority // 0)
    ] | @tsv'
}

# Format projects list to safe structure
format_projects_list() {
    local raw="$1"
    echo "$raw" | jq '[.projects.nodes[] | {
        id: .id,
        name: (.name // ""),
        description: (.description // ""),
        content: (.content // ""),
        state: (.state // ""),
        progress: (.progress // 0),
        health: (.health // ""),
        priority: (.priority // null),
        sort_order: (.sortOrder // 0),
        target_date: (.targetDate // ""),
        start_date: (.startDate // ""),
        lead: (.lead.name // ""),
        teams: [(.teams.nodes // [])[] | .name],
        labels: [(.labels.nodes // [])[] | .name],
        url: (.url // "")
    }]'
}

# Format single project to safe structure
format_project_single() {
    local raw="$1"
    echo "$raw" | jq '.projects.nodes[0] // .project | {
        id: .id,
        name: (.name // ""),
        description: (.description // ""),
        content: (.content // ""),
        state: (.state // ""),
        progress: (.progress // 0),
        health: (.health // ""),
        priority: (.priority // null),
        sort_order: (.sortOrder // 0),
        target_date: (.targetDate // ""),
        start_date: (.startDate // ""),
        lead: (.lead.name // ""),
        teams: [(.teams.nodes // [])[] | .name],
        labels: [(.labels.nodes // [])[] | .name],
        url: (.url // ""),
        blocked_by: [(.relations.nodes // [])[] | select(.type == "dependency") | {id: .relatedProject.id, name: .relatedProject.name, state: .relatedProject.state, progress: .relatedProject.progress}],
        blocks: [(.inverseRelations.nodes // [])[] | select(.type == "dependency") | {id: .project.id, name: .project.name, state: .project.state, progress: .project.progress}]
    }'
}

# Format projects list to IDs only
format_projects_ids() {
    local raw="$1"
    echo "$raw" | jq -r '.projects.nodes[].id'
}

# Format initiatives list to safe structure
format_initiatives_list() {
    local raw="$1"
    echo "$raw" | jq '[.initiatives.nodes[] | {
        id: .id,
        name: (.name // ""),
        description: (.description // ""),
        content: (.content // ""),
        status: (.status // ""),
        health: (.health // ""),
        target_date: (.targetDate // ""),
        owner: (.owner.name // ""),
        projects: [(.projects.nodes // [])[] | .name],
        url: (.url // "")
    }]'
}

# Format single initiative to safe structure
format_initiative_single() {
    local raw="$1"
    echo "$raw" | jq '.initiative | {
        id: .id,
        name: (.name // ""),
        description: (.description // ""),
        content: (.content // ""),
        status: (.status // ""),
        health: (.health // ""),
        target_date: (.targetDate // ""),
        owner: (.owner.name // ""),
        projects: [(.projects.nodes // [])[] | .name],
        url: (.url // "")
    }'
}

# Format comments list to safe structure
format_comments_list() {
    local raw="$1"
    echo "$raw" | jq '[.issue.comments.nodes[] | {
        id: .id,
        body: (.body // ""),
        user: (.user.name // ""),
        created_at: (.createdAt // ""),
        updated_at: (.updatedAt // "")
    }]'
}

# Format milestones list to safe structure
format_milestones_list() {
    local raw="$1"
    echo "$raw" | jq '[.projectMilestones.nodes[] | {
        id: .id,
        name: (.name // ""),
        description: (.description // ""),
        target_date: (.targetDate // ""),
        progress: (.progress // 0),
        project: (.project.name // ""),
        sort_order: (.sortOrder // 0)
    }]'
}

# Format single milestone to safe structure
format_milestone_single() {
    local raw="$1"
    echo "$raw" | jq '.projectMilestone | {
        id: .id,
        name: (.name // ""),
        description: (.description // ""),
        target_date: (.targetDate // ""),
        progress: (.progress // 0),
        project: (.project.name // ""),
        sort_order: (.sortOrder // 0),
        issues: [(.issues.nodes // [])[] | {id: .identifier, title: .title, state: .state.name}]
    }'
}

# Format cycles list to safe structure
format_cycles_list() {
    local raw="$1"
    echo "$raw" | jq '[.cycles.nodes[] | {
        id: .id,
        number: (.number // 0),
        name: (.name // ""),
        starts_at: (.startsAt // ""),
        ends_at: (.endsAt // ""),
        progress: (.progress // 0),
        team: (.team.name // ""),
        issue_count: ((.issueCountHistory // [])[-1] // 0),
        completed_count: ((.completedIssueCountHistory // [])[-1] // 0)
    }]'
}

# Format labels list to safe structure
format_labels_list() {
    local raw="$1"
    # Handle both issueLabels and labels keys
    echo "$raw" | jq '(.issueLabels // .labels).nodes | [.[] | {
        id: .id,
        name: (.name // ""),
        color: (.color // ""),
        description: (.description // ""),
        is_group: (.isGroup // false),
        team: (.team.name // ""),
        parent: (.parent.name // "")
    }]'
}

# Format issue relations to safe structure
format_relations_list() {
    local raw="$1"
    echo "$raw" | jq '{
        blocks: [(.issue.relations.nodes // [])[] | select(.type == "blocks") | {
            relation_id: .id,
            id: .relatedIssue.identifier,
            title: .relatedIssue.title,
            state: .relatedIssue.state.name
        }],
        blocked_by: [(.issue.inverseRelations.nodes // [])[] | select(.type == "blocks") | {
            relation_id: .id,
            id: .issue.identifier,
            title: .issue.title,
            state: .issue.state.name
        }],
        related: [(.issue.relations.nodes // [])[] | select(.type == "related") | {
            relation_id: .id,
            id: .relatedIssue.identifier,
            title: .relatedIssue.title,
            state: .relatedIssue.state.name
        }],
        duplicates: [(.issue.relations.nodes // [])[] | select(.type == "duplicate") | {
            relation_id: .id,
            id: .relatedIssue.identifier,
            title: .relatedIssue.title,
            state: .relatedIssue.state.name
        }]
    }'
}

# Format children issues to safe structure
format_children_list() {
    local raw="$1"
    echo "$raw" | jq '[.issue.children.nodes[] | {
        id: .identifier,
        uuid: .id,
        title: (.title // ""),
        state: (.state.name // ""),
        assignee: (.assignee.name // ""),
        priority: (.priority // 0),
        estimate: (.estimate // 0)
    }]'
}

# Format recursive children (3 levels deep) to flat list with depth
# Input: Raw GraphQL response with nested .issue.children structure
# Output: Flat array with depth field indicating nesting level
# Includes blocks/blocked_by from relations for sub-issue ordering
format_children_recursive() {
    local raw="$1"
    echo "$raw" | jq '
        # Recursive function to flatten children with depth tracking
        def flatten_children(depth):
            . as $node | [{
                id: $node.identifier,
                uuid: $node.id,
                title: ($node.title // ""),
                description: ($node.description // ""),
                state: ($node.state.name // ""),
                state_type: ($node.state.type // ""),
                assignee: ($node.assignee.name // ""),
                agent: ((([($node.labels.nodes // [])[] | .name | select(startswith("agent:"))] | first) // "") | sub("^agent:"; "")),
                priority: ($node.priority // 0),
                estimate: ($node.estimate // 0),
                labels: [($node.labels.nodes // [])[] | .name],
                depth: depth,
                parent_id: ($node.parent.identifier // ""),
                blocks: [($node.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier],
                blocked_by: [($node.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue.identifier]
            }] + (($node.children.nodes // []) | map(flatten_children(depth + 1)) | flatten);

        # Start from issue.children.nodes (depth 0 = direct children)
        [.issue.children.nodes[] | flatten_children(0)] | flatten
    '
}

# Format mutation response to consistent structure
# Returns: {success: bool, id: "CC-XXX", url: "...", data: {...}}
format_mutation_response() {
    local result="$1"
    local operation="$2"
    local entity="$3"

    echo "$result" | jq --arg op "$operation" --arg ent "$entity" '{
        success: .[$op].success,
        id: (.[$op][$ent].identifier // .[$op][$ent].id),
        url: (.[$op][$ent].url // ""),
        data: .[$op][$ent]
    }'
}

# Format users list to safe structure
format_users_list() {
    local raw="$1"
    echo "$raw" | jq '[.users.nodes[] | {
        id: .id,
        name: (.name // ""),
        email: (.email // ""),
        display_name: (.displayName // ""),
        active: (.active // false),
        admin: (.admin // false)
    }]'
}

# Format single user to safe structure (handles both .user and .viewer)
format_user_single() {
    local raw="$1"
    echo "$raw" | jq '(.user // .viewer) | {
        id: .id,
        name: (.name // ""),
        email: (.email // ""),
        display_name: (.displayName // ""),
        active: (.active // false),
        admin: (.admin // false),
        teams: [(.teams.nodes // [])[] | .name]
    }'
}

# Format teams list to safe structure
format_teams_list() {
    local raw="$1"
    echo "$raw" | jq '[.teams.nodes[] | {
        id: .id,
        name: (.name // ""),
        key: (.key // ""),
        description: (.description // ""),
        members: [(.members.nodes // [])[] | {name: .name, email: .email}]
    }]'
}

# Format single team to safe structure
format_team_single() {
    local raw="$1"
    echo "$raw" | jq '.team | {
        id: .id,
        name: (.name // ""),
        key: (.key // ""),
        description: (.description // ""),
        members: [(.members.nodes // [])[] | {name: .name, email: .email}],
        labels: [(.labels.nodes // [])[] | {name: .name, color: .color}],
        states: [(.states.nodes // [])[] | {name: .name, type: .type, position: .position}]
    }'
}

# Format workflow states list to safe structure
format_states_list() {
    local raw="$1"
    echo "$raw" | jq '[.workflowStates.nodes[] | {
        id: .id,
        name: (.name // ""),
        type: (.type // ""),
        color: (.color // ""),
        position: (.position // 0)
    }]'
}

# Format documents list to safe structure
# Input: Raw GraphQL response with .documents.nodes[]
# Output: Flat array with all nullable fields defaulted
format_documents_list() {
    local raw="$1"
    echo "$raw" | jq '[.documents.nodes[] | {
        id: .id,
        title: (.title // ""),
        content: (.content // ""),
        project: (.project.name // ""),
        creator: (.creator.name // ""),
        created_at: (.createdAt // ""),
        updated_at: (.updatedAt // "")
    }]'
}

# Format single document to safe structure
# Input: Raw GraphQL response with .document
# Output: Flat object
format_document_single() {
    local raw="$1"
    echo "$raw" | jq '.document | {
        id: .id,
        title: (.title // ""),
        content: (.content // ""),
        project: (.project.name // ""),
        creator: (.creator.name // ""),
        creator_email: (.creator.email // ""),
        created_at: (.createdAt // ""),
        updated_at: (.updatedAt // "")
    }'
}

# Format project labels list to safe structure
# Input: Raw GraphQL response with .projectLabels.nodes[]
# Output: Flat array with all nullable fields defaulted
format_project_labels_list() {
    local raw="$1"
    echo "$raw" | jq '[.projectLabels.nodes[] | {
        id: .id,
        name: (.name // ""),
        color: (.color // ""),
        description: (.description // ""),
        is_group: (.isGroup // false),
        parent: (.parent.name // ""),
        created_at: (.createdAt // "")
    }]'
}
