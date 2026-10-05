# Send the state change without the agent label set. The claim still reports
# success and still moves the issue to In Progress, but nothing records which
# agent took it.
control_expect "issueUpdate carries the state and the replaced agent label set in one mutation"
control_replace scripts/commands/issues.sh 1 \
    '        update_args+=(--labels "$final_labels")' \
    '        :'

control_expect "activation uses live issue-team and workspace label IDs"
control_replace scripts/lib/common.sh 1 \
    '        query='"'"'query GetLabel($name: String!, $teamName: String!, $after: String) { issueLabels(filter: {name: {eq: $name}, or: [{team: {name: {eq: $teamName}}}, {team: {null: true}}]}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id } } }'"'" \
    '        query='"'"'query GetLabel($name: String!, $teamName: String!, $after: String) { issueLabels(filter: {name: {eq: $name}}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id } } }'"'"

control_expect "recorded activation refuses an unresolved agent"
control_replace scripts/commands/issues.sh 1 \
    '            [ "$label_rc" = 0 ] || return 1' \
    '            [ "$label_rc" = 0 ] || :'
