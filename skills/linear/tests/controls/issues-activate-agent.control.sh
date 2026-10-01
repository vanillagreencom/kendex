# Send the state change without the agent label set. The claim still reports
# success and still moves the issue to In Progress, but nothing records which
# agent took it.
control_expect "issueUpdate carries the state and the replaced agent label set in one mutation"
control_replace scripts/commands/issues.sh 1 \
    '        update_args+=(--labels "$final_labels")' \
    '        :'

control_expect "activation uses live issue-team and workspace label IDs"
control_replace scripts/commands/issues.sh 1 \
    '            label_id=$(resolve_label_id "$label_name" "$team_name") || return 1' \
    '            label_id=$(resolve_label_id "$label_name") || return 1'

control_expect "recorded activation refuses an unresolved agent"
control_replace scripts/commands/issues.sh 1 \
    '            label_id=$(resolve_label_id "$label_name" "$team_name") || return 1' \
    '            label_id=$(resolve_label_id "$label_name" "$team_name") || :'
