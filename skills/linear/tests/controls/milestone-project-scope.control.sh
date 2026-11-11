# Drop the query's project filter. The fixture returns milestones from both
# projects, so a valid project milestone is refused as ambiguous.
control_expect "issues create files the issue under the project own milestone"
control_replace scripts/lib/common.sh 1 \
    "    local query='query GetMilestone(\$name: String!, \$projectId: ID!, \$after: String) { projectMilestones(filter: {name: {eq: \$name}, project: {id: {eq: \$projectId}}}, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id } } }'" \
    "    local query='query GetMilestone(\$name: String!, \$after: String) { projectMilestones(filter: {name: {eq: \$name}}, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id } } }'"
