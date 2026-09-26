# Drop the assignee from the mutation. Activation still reports "set" and
# still moves the issue to In Progress, but nobody is assigned.
control_expect "set: the issueUpdate carries the assignee"
control_replace scripts/commands/issues.sh 1 \
    '            update_args+=(--assignee "$user_email")' \
    '            :'

# Stop reading the current assignee. An issue someone else already works is
# then handed to the person activating it.
control_expect "kept: the issueUpdate leaves the assignee alone"
control_replace scripts/commands/issues.sh 1 \
    '    elif [ "$current_assignee" != "null" ]; then' \
    '    elif false; then'

# Say nothing when the setting is absent: the one outcome with no lookup
# behind it is the one a person reads to learn why nobody was assigned.
control_expect "unset: stderr carries the keyed line"
control_replace scripts/commands/issues.sh 1 \
    '        assignee_line="assignee-skipped cause=unset"' \
    '        assignee_line=""'

# Treat an address no user has as a hit. The update then refuses the unknown
# assignee and the whole activation fails with it.
control_expect "unknown: activation exits zero"
control_replace scripts/commands/issues.sh 1 \
    '        if [ -z "$user" ]; then' \
    '        if false; then'

# Read a failed users lookup as an unknown address: activation proceeds and
# reports a skip that nothing decided.
control_expect "lookup-failed: activation fails"
control_replace scripts/commands/issues.sh 1 \
    '        user=$(find_user_by_email "$user_email") || return 1' \
    '        user=$(find_user_by_email "$user_email") || user=""'
