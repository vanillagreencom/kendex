# Keep the request name but remove its team filter. The API fixture then
# returns the foreign project first for the explicit-team create.
control_expect 'same-name projects in two teams resolve under the explicit create team'
control_replace scripts/lib/common.sh 1 \
    '        query='\''query GetProject($name: String!, $teamId: ID!, $after: String) { projects(filter: {name: {eq: $name}, accessibleTeams: {some: {id: {eq: $teamId}}}}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id state teams { pageInfo { hasNextPage endCursor } nodes { name } } } } }'\''' \
    '        query='\''query GetProject($name: String!, $after: String) { projects(filter: {name: {eq: $name}}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id state teams { pageInfo { hasNextPage endCursor } nodes { name } } } } }'\'''
