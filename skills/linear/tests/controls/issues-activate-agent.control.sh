# Send the state change without the agent label set. The claim still reports
# success and still moves the issue to In Progress, but nothing records which
# agent took it.
control_expect "issueUpdate carries the state and the replaced agent label set in one mutation"
control_replace scripts/commands/issues.sh 1 \
    '        update_args+=(--labels "$final_labels")' \
    '        :'
