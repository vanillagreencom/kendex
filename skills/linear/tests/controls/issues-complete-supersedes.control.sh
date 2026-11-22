control_expect "done cancels the named item after its replacement completes"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$completion_state" = Done ]; then' \
    '    if false; then'

# Execute comments.sh directly for the supersession disposition comment. Under
# a Bash its shebang names that refuses, as macOS /bin/bash 3.2 does, the
# superseded item is neither commented on nor canceled.
control_expect "done comments naming the replacement before cancellation"
control_replace scripts/commands/issues.sh 1 \
    '        disposition_result=$("$BASH" "$SCRIPT_DIR/comments.sh" create "$superseded_id" --body "Superseded by $replacement.") || return 1' \
    '        disposition_result=$("$SCRIPT_DIR/comments.sh" create "$superseded_id" --body "Superseded by $replacement.") || return 1'
