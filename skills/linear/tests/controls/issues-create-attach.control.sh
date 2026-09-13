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

control_expect "an issue attachment object downloads without a description link"
control_replace scripts/lib/attachments.sh 1 \
    '    issue_objects=$(attach_issue_object_urls) || return 1' \
    '    issue_objects="[]"'

control_expect "re-uploading a cached file retains its source repo path"
control_replace scripts/lib/attachments.sh 1 \
    '    if [[ -n "$cached_title" ]]; then' \
    '    if false; then'

control_expect "an existing download gains the attachment repo path"
control_replace scripts/lib/attachments.sh 1 \
    '                attach_record_title "$url" "$source" "$title"' \
    '                :'
