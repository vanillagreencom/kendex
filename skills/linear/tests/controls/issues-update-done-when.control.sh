# Restore the old update decision: a completed-type state ignores open boxes.
control_expect "update refuses"
control_replace scripts/commands/issues.sh 1 \
    '        if [ "$state_type" = completed ]; then' \
    '        if false; then'
