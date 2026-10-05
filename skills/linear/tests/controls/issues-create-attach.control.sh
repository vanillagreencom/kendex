# Treat an image attachment as a plain file. The image stops being embedded in
# the description and becomes an attachmentCreate record instead, which is the
# opposite of the documented contract.
control_expect "the image embed lands in the created description"
control_replace scripts/commands/issues.sh 1 \
    '        if [[ "$attach_type" == image/* ]]; then' \
    '        if false; then'

control_expect "a repo artifact uses its full repo-relative path as title"
control_replace scripts/commands/issues.sh 1 \
    '            attach_title=$(attach_issue_title "$attach_path") || return 1' \
    '            attach_title="$attach_name"'

control_expect "a successful create returns the uploaded asset URL and attachment title"
control_replace scripts/commands/issues.sh 1 \
    '            created_attachments=$(pending_attachments_json "${attach_pending[@]}") || return 1' \
    "            created_attachments='[]'"

control_expect "a partial failure claims no attachment record"
control_replace scripts/commands/issues.sh 1 \
    '        if [ "$attach_failed" = "0" ]; then' \
    '        if true; then'

control_expect "a create with no attachments keeps the plain normalized response"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$attach_record_count" -gt 0 ]; then' \
    '    if true; then'

control_expect "an attach create keeps the pretty JSON shape every create response has"
control_replace scripts/commands/issues.sh 1 \
    '        normalized=$(echo "$normalized" | jq --argjson count "$attach_record_count" \' \
    '        normalized=$(echo "$normalized" | jq -c --argjson count "$attach_record_count" \'
