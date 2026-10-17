# Compare names as written: a label spelled with other case or punctuation
# than a map project goes unreported.
control_expect "label-like-project: yields its one finding"
control_replace scripts/lib/common.sh 1 \
    "LINEAR_NAME_KEY_JQ='def name_key: ascii_downcase | gsub(\"[^a-z0-9]\"; \"\");'" \
    "LINEAR_NAME_KEY_JQ='def name_key: .;'"

# Report each same-name label of one collision on its own.
control_expect "project-like-label: yields its one finding"
control_replace scripts/commands/projects.sh 1 \
    '          | map(.[0] + {declared: any(.[]; .declared)})) as $collisions' \
    '          | map(.[])) as $collisions'

# Stop at the first page of open issues.
control_expect "outside-map: yields its one finding"
control_replace scripts/commands/projects.sh 1 \
    "    issues=\$(graphql_pages 'query AuditMapIssues(\$teamId: ID!, \$after: String) { issues(filter: {team: {id: {eq: \$teamId}}, state: {type: {nin: [\"completed\", \"canceled\"]}}}, first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { identifier project { id name state } } } }' \\" \
    "    issues=\$(graphql_query 'query AuditMapIssues(\$teamId: ID!, \$after: String) { issues(filter: {team: {id: {eq: \$teamId}}, state: {type: {nin: [\"completed\", \"canceled\"]}}}, first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { identifier project { id name state } } } }' \\"

# Read every state's issues, closed ones included.
control_expect "clean: skips closed issues"
control_replace scripts/commands/projects.sh 1 \
    "    issues=\$(graphql_pages 'query AuditMapIssues(\$teamId: ID!, \$after: String) { issues(filter: {team: {id: {eq: \$teamId}}, state: {type: {nin: [\"completed\", \"canceled\"]}}}, first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { identifier project { id name state } } } }' \\" \
    "    issues=\$(graphql_pages 'query AuditMapIssues(\$teamId: ID!, \$after: String) { issues(filter: {team: {id: {eq: \$teamId}}}, first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { identifier project { id name state } } } }' \\"

# Read every team's open issues.
control_expect "clean: reads only the team's issues"
control_replace scripts/commands/projects.sh 1 \
    "    issues=\$(graphql_pages 'query AuditMapIssues(\$teamId: ID!, \$after: String) { issues(filter: {team: {id: {eq: \$teamId}}, state: {type: {nin: [\"completed\", \"canceled\"]}}}, first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { identifier project { id name state } } } }' \\" \
    "    issues=\$(graphql_pages 'query AuditMapIssues(\$teamId: ID!, \$after: String) { issues(filter: {state: {type: {nin: [\"completed\", \"canceled\"]}}}, first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { identifier project { id name state } } } }' \\"

# Read every team's labels.
control_expect "clean: reads only the team's and workspace labels"
control_replace scripts/commands/projects.sh 1 \
    "    labels=\$(graphql_pages 'query AuditMapLabels(\$teamId: ID!, \$after: String) { issueLabels(filter: {or: [{team: {id: {eq: \$teamId}}}, {team: {null: true}}]}, first: 250, after: \$after) { pageInfo { hasNextPage endCursor } nodes { name } } }' \\" \
    "    labels=\$(graphql_pages 'query AuditMapLabels(\$teamId: ID!, \$after: String) { issueLabels(first: 250, after: \$after) { pageInfo { hasNextPage endCursor } nodes { name } } }' \\"

# Judge an item in a project named for an initiative as any off-map item.
control_expect "initiative-holds-issue: yields its one finding"
control_replace scripts/commands/projects.sh 1 \
    '              | if $initiative != null then' \
    '              | if false then'
