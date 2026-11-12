# Restore the old update decision: a completed-type state ignores open boxes.
control_expect "update refuses"
control_replace scripts/commands/issues.sh 1 \
    '        if [ "$state_type" = completed ]; then' \
    '        if false; then'

# A second instrument: the closing-type refusal, which the completed-type
# mutation above cannot redden. Remove only it so the mocked API receives the
# unsafe cancellation, without touching the descendant reader.
control_expect "cancel-child writes nothing"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$closing" = true ]; then' \
    '    if false; then'
