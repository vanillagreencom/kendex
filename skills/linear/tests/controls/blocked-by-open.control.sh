control_expect "issues get keeps every blocker but marks only nonterminal blockers open"
control_replace scripts/lib/formatters.sh 2 \
    '        blocked_by_open: [(.issue.inverseRelations.nodes // [])[] | select(.type == "blocks" and (.issue.state.type | IN("completed", "canceled") | not)) | .issue.identifier],' \
    '        blocked_by_open: [(.issue.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue.identifier],'
