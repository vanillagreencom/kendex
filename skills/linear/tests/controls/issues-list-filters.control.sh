# Of several labels only the first filters, so an issue carrying one of them
# passes for one carrying all.
control_expect 'two labels by --labels: filter'
control_replace scripts/lib/common.sh 1 \
    '            if length == 1 then .[0] else {and: .} end'\'')")' \
    '            .[0]'\'')")'

# The owed selection judges launch blockers by the open rule, so a merged
# Verifying blocker holds its dependent off the heartbeat's open-unblocked line.
control_expect 'owed: verification and container facts survive every blocker page'
control_replace scripts/commands/issues.sh 1 \
    '          blocked_by: issue_blocked_by_ids(.inverseRelations.nodes), blocked_by_launch: issue_blocked_by_launch_ids(.inverseRelations.nodes), labels: [(.labels.nodes // [])[] | .name]}]'"'"' <<<"$result"' \
    '          blocked_by: issue_blocked_by_ids(.inverseRelations.nodes), blocked_by_launch: issue_blocked_by_open_ids(.inverseRelations.nodes), labels: [(.labels.nodes // [])[] | .name]}]'"'"' <<<"$result"'
