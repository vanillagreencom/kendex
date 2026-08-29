# Fold update_issue's stderr into its stdout. The advisory warning a succeeding
# update writes then breaks the .success parse, and a committed update is
# reported as a failure — the exact merge this suite pins.
control_expect "a success-path warning is not reported as a failed update"
control_replace scripts/commands/issues.sh 1 \
    '        if result=$(update_issue "$id" "${update_args[@]}" 2>"$stderr_file"); then' \
    '        if result=$(update_issue "$id" "${update_args[@]}" 2>&1 | tee "$stderr_file"); then'
