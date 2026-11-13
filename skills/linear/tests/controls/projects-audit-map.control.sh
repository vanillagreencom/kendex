# Stop at the first page of open issues.
control_expect "outside-map: yields its findings"
control_replace scripts/commands/projects.sh 1 \
    "        issues=\$(graphql_pages 'query AuditMapIssues(\$teamId: ID!, \$after: String) { issues(filter: {team: {id: {eq: \$teamId}}, state: {type: {nin: [\"completed\", \"canceled\", \"duplicate\"]}}}, first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { identifier project { id name state } } } }' \\" \
    "        issues=\$(graphql_query 'query AuditMapIssues(\$teamId: ID!, \$after: String) { issues(filter: {team: {id: {eq: \$teamId}}, state: {type: {nin: [\"completed\", \"canceled\", \"duplicate\"]}}}, first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { identifier project { id name state } } } }' \\"

# Each inventory reader lists the team although given an inventory.
control_expect "inventory: labels-audit lists no issues"
control_replace scripts/commands/labels.sh 1 \
    '    if [ -n "$inventory" ]; then' \
    '    if false; then'
control_expect "inventory: projects-audit lists no issues"
control_replace scripts/commands/projects.sh 1 \
    '    if [ -n "$inventory" ]; then' \
    '    if false; then'
control_expect "inventory: open-states lists no issues"
control_replace scripts/commands/issues.sh 2 \
    '    if [[ -n "$inventory" ]]; then' \
    '    if false; then'

# The collection never publishes its file.
control_expect "inventory: the team-mode read publishes the file"
control_replace scripts/lib/pages.sh 1 \
    '    mv -f -- "$staged" "$file" || return 1' \
    '    :'

# A failed collection still writes the file.
control_expect "failed read: publishes nothing"
control_replace scripts/lib/pages.sh 1 \
    '    graphql_pages "$query" "$variables" issues |' \
    '    { graphql_pages "$query" "$variables" issues || :; } |'

# A file the reader cannot use answers as an empty team.
control_expect "other-team: projects-audit refuses inventory-unread"
control_replace scripts/lib/pages.sh 1 \
    '        if [[ "$cause" != ok ]]; then' \
    "        if [[ \"\$cause\" != ok ]]; then printf '[]\\n'; return 0; fi; if false; then"

# The inventory reads no project state.
control_expect "inventory: projects-audit prints what the live read prints"
control_replace scripts/lib/pages.sh 1 \
    "    printf '%s' \"\${fields/    project \\{ id name \\}/\$project}\"" \
    "    printf '%s' \"\$fields\""

# The readers' own coverage: the label audit drops duplicate-state issues,
# the project audit keeps them, the list drops its state filter and keeps the
# project state the live read lacks.
control_expect "inventory: labels audit keeps duplicate-state issues"
control_replace scripts/commands/labels.sh 1 \
    "            jq -c '[.[] | select(.state.type | IN(\"completed\", \"canceled\") | not) | {id, identifier, labels}]') || return 1" \
    "            jq -c '[.[] | select(.state.type | IN(\"completed\", \"canceled\", \"duplicate\") | not) | {id, identifier, labels}]') || return 1"
control_expect "inventory: projects audit leaves out closed and duplicate issues"
control_replace scripts/commands/projects.sh 1 \
    "            jq -c \"\$STATE_TYPE_CLOSED_JQ\"'[.[] | select(.state.type | state_type_closed | not) | {identifier, project}]') || return 1" \
    "            jq -c '[.[] | select(.state.type | IN(\"completed\", \"canceled\") | not) | {identifier, project}]') || return 1"
control_expect "inventory: team-mode keeps its state filter"
control_replace scripts/commands/issues.sh 1 \
    '                    | select($state == null or .state.name == $state.eq or (.state.name | IN(($state.in // [])[])))' \
    '                    | select(true)'
control_expect "inventory: raw prints what the live read prints"
control_replace scripts/commands/issues.sh 1 \
    "                    | if .project != null then .project |= del(.state) else . end]}}') || return 1" \
    "                    ]}}') || return 1"

# The list answers an option it cannot filter on from the inventory.
control_expect "--project: refused before any read"
control_replace scripts/commands/issues.sh 1 \
    '        list_inventory_scope "$with_relations" "$search_given" "$selection" ${args[@]+"${args[@]}"} || return 1' \
    '        :'
