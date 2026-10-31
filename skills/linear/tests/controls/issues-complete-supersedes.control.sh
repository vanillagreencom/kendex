control_expect "done cancels the named item after its replacement completes"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$completion_state" = Done ]; then' \
    '    if false; then'
