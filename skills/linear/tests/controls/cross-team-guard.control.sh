# Unwire update from the cross-team guard: it then writes to another team's
# issue.
control_expect "update of another team issue is refused before any write"
control_replace scripts/commands/issues.sh 1 \
    '    linear_guard_issue_team update "$issue_id" || return 1' \
    '    :'
