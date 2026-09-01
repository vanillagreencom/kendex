control_expect "live get safe filters by state type"
control_expect "production inverse projection requests state type"
control_expect "production GraphQL has one inverse relation projection owner"
control_replace scripts/lib/formatters.sh 1 \
    'readonly ISSUE_BLOCKED_BY_FIELDS='"'"'inverseRelations { nodes { id type issue { id identifier title state { name type } } } }'"'"'' \
    'readonly ISSUE_BLOCKED_BY_FIELDS='"'"'inverseRelations { nodes { id type issue { id identifier title state { name } } } }'"'"''
control_replace scripts/lib/formatters.sh 1 \
    'def issue_is_open: (.state.type | IN("completed", "canceled") | not);' \
    'def issue_is_open: true;'
control_append scripts/commands/issues.sh \
    "BYPASS_RELATION_QUERY='inverseRelations { nodes { id type issue { identifier } } }'"
