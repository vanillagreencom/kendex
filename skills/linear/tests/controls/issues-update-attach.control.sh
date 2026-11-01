# Move the --labels/--clear-labels refusal after the upload. The combination is
# still refused, but the asset has already been pushed to Linear storage and is
# stranded there with nothing referencing it.
control_expect "the refused update uploaded nothing"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$clear_labels" = "true" ] && [ -n "$labels" ]; then' \
    '    if [ "$clear_labels" = "true" ] && [ -n "$labels" ] && [ ${#attach_paths[@]} -eq 0 ]; then'
