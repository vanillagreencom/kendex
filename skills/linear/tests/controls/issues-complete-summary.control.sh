control_expect "partial complete ids split fails"
control_expect "partial complete ids equals fails"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$update_rc" -ne 0 ] || [ "$update_success" != "true" ]; then' \
    '    if false; then'

# Execute comments.sh directly for the completion summary. Under a Bash its
# shebang names that refuses, as macOS /bin/bash 3.2 does, no summary posts
# and the completion fails.
control_expect "complete --summary-file reports the summary as posted"
control_replace scripts/commands/issues.sh 1 \
    '        comment_result=$("$BASH" "$SCRIPT_DIR/comments.sh" create "$issue_id" --body "$summary")' \
    '        comment_result=$("$SCRIPT_DIR/comments.sh" create "$issue_id" --body "$summary")'
