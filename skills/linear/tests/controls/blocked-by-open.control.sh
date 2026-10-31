# Drop the state type from the live projection, so the live reads lose the
# field the open/closed decision is made on.
control_expect "live get safe filters by state type"
control_expect "production inverse projection requests state type"
control_replace scripts/lib/formatters.sh 1 \
    'readonly ISSUE_BLOCKED_BY_NODE_FIELDS='"'"'id type issue { id identifier title state { name type } }'"'"'' \
    'readonly ISSUE_BLOCKED_BY_NODE_FIELDS='"'"'id type issue { id identifier title state { name } }'"'"''
