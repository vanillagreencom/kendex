# Drop the assignee from the mutation. Activation still reports "set" and
# still moves the issue to In Progress, but nobody is assigned.
control_expect "set: the issueUpdate carries the assignee"
control_replace scripts/commands/issues.sh 1 \
    '            update_args+=(--assignee "$user_id")' \
    '            :'

# Hand the update the address instead of the resolved id. The update then
# looks the same person up a second time.
control_expect "set: the person is looked up once"
control_replace scripts/commands/issues.sh 1 \
    '            update_args+=(--assignee "$user_id")' \
    '            update_args+=(--assignee "$user_email")'

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

# Treat an address no user has as a hit. Activation then reports the issue
# assigned when nobody is.
control_expect "unknown: the result reports assignee skipped"
control_replace scripts/commands/issues.sh 1 \
    '        if [ -z "$user" ]; then' \
    '        if false; then'

# Read a failed users lookup as an unknown address: activation proceeds and
# reports a skip that nothing decided.
control_expect "lookup-failed: activation fails"
control_replace scripts/commands/issues.sh 1 \
    '        user=$(find_user_by_email "$user_email") || return 1' \
    '        user=$(find_user_by_email "$user_email") || user=""'

# Let a failed issue read through as an empty answer. Activation then reports
# the assignee kept and lands the state change with nothing read.
control_expect "issue-read-failed: activation fails"
control_replace scripts/commands/issues.sh 1 \
    '    result=$(graphql_query "$query" "$variables") || return 1' \
    '    result=$(graphql_query "$query" "$variables") || :'

# Say what happened to the assignee before the update is known to have
# landed. A rejected update then still reports an outcome.
control_expect "update-failed: no assignee line is reported"
control_replace scripts/commands/issues.sh 1 \
    '    # One mutation carries the state, the label set and the assignee.' \
    "    printf '%s\\n' \"\$assignee_line\" >&2"
