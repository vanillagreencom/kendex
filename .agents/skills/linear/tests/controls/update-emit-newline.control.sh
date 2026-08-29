# Drop the terminating newline from the completed-state activity line: `read`
# then returns 1 at EOF, the failure this suite exists to catch.
control_expect "output ends with a newline so read returns 0"
control_replace scripts/commands/issues.sh 1 \
    "        completed:*|*:done|*:complete|*:completed) printf 'linear.issue_finished success\\n' ;;" \
    "        completed:*|*:done|*:complete|*:completed) printf 'linear.issue_finished success' ;;"
