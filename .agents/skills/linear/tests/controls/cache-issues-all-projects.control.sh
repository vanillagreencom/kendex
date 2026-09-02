# Turn --all-projects into an inert flag. Every filter still runs, so the
# command keeps returning rows; it just stops enumerating across projects, and
# the mutual-exclusion refusal with --project goes with it.
control_expect "C: --all-projects with --project exits nonzero"
control_replace scripts/commands/cache-query.sh 1 \
    '            all_projects="true"' \
    '            all_projects="false"'
control_expect "D: per-project rows keep the compact field set"
control_replace scripts/lib/formatters.sh 1 \
    '        blocked_by_open: issue_blocked_by_open_ids(.inverseRelations.nodes)' \
    '        blocked_by_closed: issue_blocked_by_open_ids(.inverseRelations.nodes)'
