# Drop the assignee from the mutation. Activation still reports "set" and
# still moves the issue to In Progress, but nobody is assigned.
control_expect "set: the issueUpdate carries the assignee"
control_replace scripts/commands/issues.sh 1 \
    '            update_args+=(--assignee "$user_id")' \
    '            :'
