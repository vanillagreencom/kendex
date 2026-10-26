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

control_expect "mixed attach-only: returns actual non-image receipts in request order"
control_replace scripts/commands/issues.sh 1 \
    '                '\''. + {attachments_requested: $count, attachments: $attachments}'\'' <<<"$normalized") || return 1' \
    '                '\''. + {attachments_requested: $count, attachments: []}'\'' <<<"$normalized") || return 1'

# Keep the live read but let its null result pass, exposing the upload that
# the destination check must prevent in update and its bulk-update caller.
control_expect "missing update identifier: lookup is the only request, with no upload or mutation"
control_expect "missing update UUID: lookup is the only request, with no upload or mutation"
control_expect "missing bulk identifier: lookup is the only request, with no upload or mutation"
control_expect "missing bulk UUID: lookup is the only request, with no upload or mutation"
control_replace scripts/commands/issues.sh 1 \
    '    if ! jq -e '\''.issue.id | strings | select(length > 0)'\'' <<<"$result" >/dev/null; then' \
    '    if false && ! jq -e '\''.issue.id | strings | select(length > 0)'\'' <<<"$result" >/dev/null; then'

control_expect 'connection: safe PUT diagnostic'
control_replace scripts/lib/attachments.sh 2 \
    '            curl_exit=$?' \
    '            curl_exit=0'

control_expect 'graphql: completed non-image survives the failed batch'
control_replace scripts/commands/issues.sh 1 \
    '            pending_json=$(pending_attachments_json "${attach_pending[@]}") || return "$upload_status"' \
    '            pending_json=$(pending_attachments_json "${attach_pending[@]}") || return "$upload_status"; pending_json="[]"'

control_expect 'resume succeeds after its input is captured'
control_replace scripts/commands/issues.sh 1 \
    '            attach_pending+=("$retained_entry")' \
    '            attach_pending+=("$retained_entry"); attach_pending=()'

control_expect 'private headers: invalid retained input sends no API request'
control_replace scripts/commands/issues.sh 1 \
    '                    type == "object" and keys == ["repo_path", "url"]' \
    '                    type == "object"'
