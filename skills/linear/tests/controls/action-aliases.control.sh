# Drop the `relations` alias from the issues dispatcher. The documented legacy
# name then falls through to the unknown-action path instead of the canonical
# relation list.
control_expect "issues relations alias routes to the canonical relation list"
control_replace scripts/commands/issues.sh 1 \
    '    list-relations | relations)' \
    '    list-relations)'
