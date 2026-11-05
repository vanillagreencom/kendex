# One mutation per projection the suite covers. The open filter inside
# `issue_blocks_open_ids` is not among them: alone it reddens only the session
# research assertion, which mutation 2 reddens and claims, so a mutation for
# the filter would have no assertion left to name and the runner would report
# SHARED. Mutation 2 covers the filter.
# 1. Drop the state type from the live projection, so the live reads lose the
#    field the open/closed decision is made on.
control_expect "live get safe filters by state type"
control_expect "production inverse projection requests state type"
control_replace scripts/lib/formatters.sh 1 \
    'readonly ISSUE_BLOCKED_BY_NODE_FIELDS='"'"'id type issue { id identifier title state { name type } }'"'"'' \
    'readonly ISSUE_BLOCKED_BY_NODE_FIELDS='"'"'id type issue { id identifier title state { name } }'"'"''

# 2. Call every state open, which takes the session status routing and the
#    blocks projection.
control_expect "session status routes terminal-only history to backlog"
control_expect "session research blocks include only open targets"
control_replace scripts/lib/formatters.sh 1 \
    'def issue_is_open: (.state.type | IN("completed", "canceled") | not);' \
    'def issue_is_open: true;'

# 3. A second projection of the same relation, so the one-owner assertion has
#    something to find.
control_expect "production GraphQL has one inverse relation projection owner"
control_append scripts/commands/issues.sh \
    "BYPASS_RELATION_QUERY='inverseRelations { nodes { id type issue { identifier } } }'"

# 4. The bundle root loses its launch field, the one the launch gate reads;
#    the single read keeps its own line, so only the bundle's assertion falls.
control_expect "live bundle root names launch blockers"
control_replace scripts/lib/formatters.sh 1 \
    '            blocked_by_launch: issue_blocked_by_launch_ids(.issue.inverseRelations.nodes),' \
    '            blocked_by_launch_dropped: null,'

# 5. A bundled node loses its launch field.
control_expect "live bundle child names launch blockers"
control_replace scripts/lib/formatters.sh 1 \
    '                blocked_by_launch: issue_blocked_by_launch_ids($node.inverseRelations.nodes)' \
    '                blocked_by_launch_dropped: null'
