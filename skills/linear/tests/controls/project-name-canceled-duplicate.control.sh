# Linear retains canceled projects after a live project reuses their name.
control_expect 'canceled twins lose to the live project in the configured team'
control_replace scripts/lib/formatters.sh 1 \
    'def project_is_live: (.state // "" | ascii_downcase) != "canceled";' \
    'def project_is_live: true;'

# Keep the request name but remove its team filter. The API fixture then
# returns the foreign project first for the explicit-team create.
control_expect 'same-name projects in two teams resolve under the explicit create team'
control_replace scripts/lib/common.sh 1 \
    '        query='\''query GetProject($name: String!, $teamId: ID!, $after: String) { projects(filter: {name: {eq: $name}, accessibleTeams: {some: {id: {eq: $teamId}}}}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id state teams { pageInfo { hasNextPage endCursor } nodes { name } } } } }'\''' \
    '        query='\''query GetProject($name: String!, $after: String) { projects(filter: {name: {eq: $name}}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id state teams { pageInfo { hasNextPage endCursor } nodes { name } } } } }'\'''

control_expect 'ambiguous live names refuse with every candidate and its team'
control_replace scripts/lib/common.sh 1 \
    '        if [[ "$candidate_count" -gt 1 ]]; then' \
    '        if [[ "$candidate_count" -gt 999 ]]; then'

control_expect 'an existing issue without a team refuses name resolution'
control_replace scripts/commands/issues.sh 1 \
    '        if [[ -z "$team_id" && ! "$project" =~ $LINEAR_UUID_PATTERN ]]; then' \
    '        if [[ -z "$team_id" && ! "$project" =~ $LINEAR_UUID_PATTERN && "$project" == "" ]]; then'
