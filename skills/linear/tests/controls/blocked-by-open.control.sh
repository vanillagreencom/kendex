# Drop the state type from the live projection, so the live reads lose the
# field the open/closed decision is made on.
control_expect "live bundle root filters by state type"
control_expect "production inverse projection requests state type"
control_replace scripts/lib/formatters.sh 1 \
    'readonly ISSUE_BLOCKED_BY_NODE_FIELDS='"'"'id type issue { id identifier title state { name type } }'"'"'' \
    'readonly ISSUE_BLOCKED_BY_NODE_FIELDS='"'"'id type issue { id identifier title state { name } }'"'"''

# The bundle root loses its launch field, the one the launch gate reads.
control_expect "live bundle root names launch blockers"
control_replace scripts/lib/formatters.sh 1 \
    '            blocked_by_launch: issue_blocked_by_launch_ids(.issue.inverseRelations.nodes),' \
    '            blocked_by_launch_dropped: null,'

# A bundled node loses its launch field.
control_expect "live bundle child names launch blockers"
control_replace scripts/lib/formatters.sh 1 \
    '                blocked_by_launch: issue_blocked_by_launch_ids($node.inverseRelations.nodes)' \
    '                blocked_by_launch_dropped: null'
