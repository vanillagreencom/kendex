# Turn --all-projects into an inert flag. Every filter still runs, so the
# command keeps returning rows; it just stops enumerating across projects, and
# the mutual-exclusion refusal with --project goes with it.
control_expect "C: --all-projects with --project exits nonzero"
control_expect "D: per-project rows keep the compact field set"
control_replace scripts/commands/cache-query.sh 1 \
    '            all_projects="true"' \
    '            all_projects="false"'
control_replace scripts/lib/formatters.sh 1 \
    '        blocked_by_open: [(.inverseRelations.nodes // [])[] | select(.type == "blocks" and (.issue.state.type | IN("completed", "canceled") | not)) | .issue.identifier]' \
    '        blocked_by_closed: [(.inverseRelations.nodes // [])[] | select(.type == "blocks" and (.issue.state.type | IN("completed", "canceled") | not)) | .issue.identifier]'
