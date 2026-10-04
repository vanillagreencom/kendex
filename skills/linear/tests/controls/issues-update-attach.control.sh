# Move the --labels/--clear-labels refusal after the upload. The combination is
# still refused, but the asset has already been pushed to Linear storage and is
# stranded there with nothing referencing it.
control_expect "the refused update uploaded nothing"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$clear_labels" = "true" ] && [ -n "$labels" ]; then' \
    '    if [ "$clear_labels" = "true" ] && [ -n "$labels" ] && [ ${#attach_paths[@]} -eq 0 ]; then'

control_expect "an attach-only update returns the new asset URL and repo path"
control_replace scripts/commands/issues.sh 1 \
    '            --argjson attachments "$attachments_json" \' \
    "            --argjson attachments '[]' \\"

# Keep the live read but let its null result pass, exposing the upload that
# the destination check must prevent in update and its bulk-update caller.
control_expect "missing update identifier: lookup is the only request, with no upload or mutation"
control_expect "missing update UUID: lookup is the only request, with no upload or mutation"
control_expect "missing bulk identifier: lookup is the only request, with no upload or mutation"
control_expect "missing bulk UUID: lookup is the only request, with no upload or mutation"
control_replace scripts/commands/issues.sh 1 \
    '    if ! jq -e '\''.issue.id | strings | select(length > 0)'\'' <<<"$result" >/dev/null; then' \
    '    if false && ! jq -e '\''.issue.id | strings | select(length > 0)'\'' <<<"$result" >/dev/null; then'
