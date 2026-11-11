# Drop the refusal: every completed-blocker relation is deleted again.
control_expect "a Done blocker named by --blocked-by is refused: exit status"
control_replace scripts/commands/issues.sh 1 \
    '    [ -n "$blocker" ] || return 0' \
    '    return 0'
