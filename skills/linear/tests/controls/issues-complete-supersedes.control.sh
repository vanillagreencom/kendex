control_expect "done cancels the named item after its replacement completes"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$completion_state" = Done ]; then' \
    '    if false; then'

control_expect "unreadable-fail reports Done and a summary-free retry"
control_replace scripts/commands/issues.sh 1 \
    '                '\''{error: "supersession-incomplete", issue: $issue, state: "Done", already_done: true,' \
    '                '\''{error: "supersession-incomplete", issue: $issue, state: "Done", already_done: false,'

control_expect "children-fail leaves related items unchanged"
control_replace scripts/commands/issues.sh 1 \
    '        pending_children=$(pending_issue_descendants "$superseded_result") || return 1' \
    '        pending_children=$(pending_issue_descendants "$superseded_result") || return 1; pending_children=""'

control_expect "deep-children-fail names all open descendants for disposition"
control_replace scripts/commands/issues.sh 1 \
    '        frontier="$next_frontier"' \
    '        frontier=""'
