# Drop the scope at the create call site, so the resolver is asked for a
# milestone name with no project to resolve it in — which is what both call
# sites did before, having resolved the project id and then not passed it.
control_expect "issues create files the issue under the project own milestone"
control_replace scripts/commands/issues.sh 1 \
    '        milestone_id=$(resolve_milestone_id "$milestone" "$project_id")' \
    '        milestone_id=$(resolve_milestone_id "$milestone")'

# Ask the name query without the project filter, as it shipped. The fixture then
# answers from every project, foreign milestone first, so a name the project
# does not hold is matched anyway.
control_expect "an unmatched name reports a miss, not an API failure"
control_replace scripts/lib/common.sh 1 \
    "    local query='query GetMilestone(\$name: String!, \$projectId: ID!) { projectMilestones(filter: {name: {eq: \$name}, project: {id: {eq: \$projectId}}}) { nodes { id } } }'" \
    "    local query='query GetMilestone(\$name: String!) { projectMilestones(filter: {name: {eq: \$name}}) { nodes { id } } }'"

# Take the first match instead of the whole set, so a second milestone of that
# name is picked from rather than refused.
control_expect "two milestones of that name in the project is a refusal, not a pick"
control_replace scripts/lib/common.sh 1 \
    "    milestone_ids=\$(echo \"\$result\" | jq -r '[(.projectMilestones.nodes // [])[].id] | join(\", \")')" \
    "    milestone_ids=\$(echo \"\$result\" | jq -r '.projectMilestones.nodes[0].id // empty')"

# Let every name resolver take a failed lookup for an empty one. Only the
# milestone lookup fails in this suite, so this is the unchecked exit status
# resolve_milestone_id shipped with: an outage reported as a missing milestone.
control_expect "a failed lookup reports the API failure, not a miss"
control_replace scripts/lib/common.sh 3 \
    '    if ! result=$(graphql_query "$query" "$vars"); then' \
    '    if ! result=$(graphql_query "$query" "$vars" || true); then'

# Resolve a name with no project rather than refusing it.
control_expect "a milestone name with no project to scope it is refused before any lookup"
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
control_replace scripts/commands/issues.sh 2 \
    '        attach_preflight_files "${attach_paths[@]}" || return 1' \
    '        true'

# Read the UUID grammar as lowercase only, so an uppercase UUID is looked up
# as a name.
control_expect "an uppercase UUID is a UUID too"
control_replace scripts/lib/common.sh 1 \
    '    [[ "$1" =~ $LINEAR_UUID_PATTERN ]]' \
    '    [[ "$1" =~ ^[0-9a-f-]+$ ]]'
