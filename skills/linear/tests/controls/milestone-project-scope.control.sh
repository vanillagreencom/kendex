# Drop the query's project filter. The fixture returns milestones from both
# projects, so a valid project milestone is refused as ambiguous.
control_expect "issues create files the issue under the project own milestone"
control_replace scripts/lib/common.sh 1 \
    "    local query='query GetMilestone(\$name: String!, \$projectId: ID!, \$after: String) { projectMilestones(filter: {name: {eq: \$name}, project: {id: {eq: \$projectId}}}, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id } } }'" \
    "    local query='query GetMilestone(\$name: String!, \$after: String) { projectMilestones(filter: {name: {eq: \$name}}, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id } } }'"

# Take the first match instead of the whole set, so a second milestone of that
# name is picked from rather than refused.
control_expect "two milestones of that name in the project is a refusal, not a pick"
control_replace scripts/lib/common.sh 1 \
    "    milestone_ids=\$(echo \"\$result\" | jq -r '[(.projectMilestones.nodes // [])[].id] | join(\", \")')" \
    "    milestone_ids=\$(echo \"\$result\" | jq -r '.projectMilestones.nodes[0].id // empty')"

# Resolve a name with no project rather than refusing it.
control_expect "a milestone name with no project to scope it is refused before any milestone lookup"
control_replace scripts/lib/common.sh 1 \
    '    if [ -z "$milestone_ref" ] || [ -n "$project_scope" ]; then' \
    '    if true; then'

# Scope the update's name to --project alone, so an issue already in a project
# is refused unless the caller re-sends the project it is in.
control_expect "issues update scopes the name to the issue own project"
control_replace scripts/commands/issues.sh 1 \
    '        milestone_id=$(resolve_milestone_id "$milestone" "${project_id:-$issue_project_id}")' \
    '        milestone_id=$(resolve_milestone_id "$milestone" "$project_id")'

# Leave the create's milestone unresolved where it is hoisted, so the refusal
# falls back to whatever runs after the upload.
control_expect "a project-less name refuses the create before its upload"
control_expect "an ambiguous name refuses the create before its upload"
control_replace scripts/commands/issues.sh 1 \
    '        milestone_id=$(resolve_milestone_id "$milestone" "$project_id")' \
    '        milestone_id=deferred-uuid'

# Same for the update's.
control_expect "a name refuses the update of an issue in no project before its upload"
control_expect "an ambiguous name refuses the update before its upload"
control_replace scripts/commands/issues.sh 1 \
    '        milestone_id=$(resolve_milestone_id "$milestone" "${project_id:-$issue_project_id}")' \
    '        milestone_id=deferred-uuid'

# Scope the update to the issue's own project even when --project names another,
# so setting a milestone while moving an issue resolves in the project it is
# leaving.
control_expect "--project wins over the project the issue is already in"
control_replace scripts/commands/issues.sh 1 \
    '        milestone_id=$(resolve_milestone_id "$milestone" "${project_id:-$issue_project_id}")' \
    '        milestone_id=$(resolve_milestone_id "$milestone" "$issue_project_id")'


# Stop treating a UUID as already resolved, so the project requirement reaches
# a reference that names one milestone on its own.
control_expect "a milestone UUID needs no project and no lookup"
control_replace scripts/lib/common.sh 2 \
    '    if milestone_ref_is_uuid "$milestone_ref"; then' \
    '    if false; then'

# Skip the --attach preflight, so an unreadable path reaches the resolvers this
# change hoisted and costs API calls before the refusal --help promises.
control_expect "an unreadable --attach path refuses before any lookup"
control_replace scripts/commands/issues.sh 3 \
    '        attach_preflight_files "${attach_paths[@]}" || return 1' \
    '        true'

# Read the UUID grammar as lowercase only, so an uppercase UUID is looked up
# as a name.
control_expect "an uppercase UUID is a UUID too"
control_replace scripts/lib/common.sh 1 \
    '    [[ "$1" =~ $LINEAR_UUID_PATTERN ]]' \
    '    [[ "$1" =~ ^[0-9a-f-]+$ ]]'
