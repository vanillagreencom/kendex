# Drop the scope at the create call site, so the resolver is asked for a
# milestone name with no project to resolve it in — which is what both call
# sites did before, having resolved the project id and then not passed it.
control_expect "issues create files the issue under the project's own milestone"
control_replace scripts/commands/issues.sh 1 \
    '        milestone_id=$(resolve_milestone_id "$milestone" "$project_id")' \
    '        milestone_id=$(resolve_milestone_id "$milestone")'

# Ask the name query without the project filter, as it shipped. The fixture then
# answers from every project, foreign milestone first.
control_expect "issues update sets the project's own milestone"
control_replace scripts/lib/common.sh 1 \
    "    local query='query GetMilestone(\$name: String!, \$projectId: ID!) { projectMilestones(filter: {name: {eq: \$name}, project: {id: {eq: \$projectId}}}) { nodes { id } } }'" \
    "    local query='query GetMilestone(\$name: String!) { projectMilestones(filter: {name: {eq: \$name}}) { nodes { id } } }'"

# Take the first match instead of the whole set, so a second milestone of that
# name is picked from rather than refused.
control_expect "the ambiguity refusal names the second candidate UUID"
control_replace scripts/lib/common.sh 1 \
    "    milestone_ids=\$(echo \"\$result\" | jq -r '[(.projectMilestones.nodes // [])[].id] | join(\", \")')" \
    "    milestone_ids=\$(echo \"\$result\" | jq -r '.projectMilestones.nodes[0].id // empty')"

# Let every name resolver take a failed lookup for an empty one. Only the
# milestone lookup fails in this suite, so this is the unchecked exit status
# resolve_milestone_id shipped with: an outage reported as a missing milestone.
control_expect "a failed lookup reports the API failure"
control_replace scripts/lib/common.sh 3 \
    '    if ! result=$(graphql_query "$query" "$vars"); then' \
    '    if ! result=$(graphql_query "$query" "$vars" || true); then'

# Resolve a name with no project rather than refusing it.
control_expect "the refusal names the missing project"
control_replace scripts/lib/common.sh 1 \
    '    if [ -z "$milestone_ref" ] || [ -n "$project_scope" ]; then' \
    '    if true; then'

# Scope the update's name to --project alone, so an issue already in a project
# is refused unless the caller re-sends the project it is in.
control_expect "issues update scopes the name to the issue's own project"
control_replace scripts/commands/issues.sh 1 \
    '        milestone_id=$(resolve_milestone_id "$milestone" "${project_id:-$issue_project_id}")' \
    '        milestone_id=$(resolve_milestone_id "$milestone" "$project_id")'

# Leave the create's refusal to the resolver, which runs after the upload.
control_expect "no upload is sent before the create refusal"
control_replace scripts/commands/issues.sh 1 \
    '    require_milestone_project "$milestone" "$project" || return 1' \
    '    true'

# Same for the update's.
control_expect "no upload is sent before the update refusal"
control_replace scripts/commands/issues.sh 1 \
    '    require_milestone_project "$milestone" "$milestone_scope" || return 1' \
    '    true'
