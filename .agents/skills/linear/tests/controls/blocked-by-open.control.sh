control_expect "live get safe filters by state type"
control_expect "live relation queries request blocker type only on inverse relations"
control_replace scripts/lib/formatters.sh 1 \
    'readonly ISSUE_RELATION_FIELDS='"'"'relations { nodes { id type relatedIssue { id identifier title state { name } } } } inverseRelations { nodes { id type issue { id identifier title state { name type } } } }'"'"'' \
    'readonly ISSUE_RELATION_FIELDS='"'"'relations { nodes { id type relatedIssue { id identifier title state { name type } } } } inverseRelations { nodes { id type issue { id identifier title state { name } } } }'"'"''
control_replace scripts/lib/formatters.sh 1 \
    'def issue_is_open: (.state.type | IN("completed", "canceled") | not);' \
    'def issue_is_open: true;'
