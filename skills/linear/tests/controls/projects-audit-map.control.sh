# Stop at the first page of open issues.
control_expect "outside-map: yields its findings"
control_replace scripts/commands/projects.sh 1 \
    "    issues=\$(graphql_pages 'query AuditMapIssues(\$teamId: ID!, \$after: String) { issues(filter: {team: {id: {eq: \$teamId}}, state: {type: {nin: [\"completed\", \"canceled\", \"duplicate\"]}}}, first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { identifier project { id name state } } } }' \\" \
    "    issues=\$(graphql_query 'query AuditMapIssues(\$teamId: ID!, \$after: String) { issues(filter: {team: {id: {eq: \$teamId}}, state: {type: {nin: [\"completed\", \"canceled\", \"duplicate\"]}}}, first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { identifier project { id name state } } } }' \\"
