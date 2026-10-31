# Resolve a team-id label lookup with no team scope: the first same-name label
# the API lists wins, whichever team owns it, before and after the upload.
control_expect "key: create sends the kendex team and its label ids"
control_expect "app: create sends the kendex team and its label ids"
control_expect "uuid: create sends only workspace labels for a team that owns none"
control_expect "attach: no upload is sent for another team's agent label"
control_replace scripts/lib/common.sh 1 \
    '        query='"'"'query GetLabel($name: String!, $teamId: ID!, $after: String) { issueLabels(filter: {name: {eq: $name}, or: [{team: {id: {eq: $teamId}}}, {team: {null: true}}]}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id } } }'"'" \
    '        query='"'"'query GetLabel($name: String!, $teamId: ID!, $after: String) { issueLabels(filter: {name: {eq: $name}}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id } } }'"'"
