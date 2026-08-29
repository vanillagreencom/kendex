# Drop the bulk-get line from the `issues view` hint. The unsupported action
# still fails, but stops naming the command that replaces it.
control_expect "issues view hint names bulk-get"
control_replace scripts/commands/issues.sh 1 \
    '        echo "  linear.sh issues bulk-get [ISSUE_ID_1] [ISSUE_ID_2]   # live state (post-mutation verification)" >&2' \
    '        :'
