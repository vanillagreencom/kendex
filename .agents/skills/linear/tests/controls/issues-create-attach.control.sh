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
    '                attach_record_title "$url" "$source" "$title" || return 1' \
    '                :'

control_expect "a linked worktree cached file retains its repo path on reattachment"
control_replace scripts/lib/attachments.sh 1 \
    '        cached_title=$(jq -r --arg path "$path" \' \
    '        cached_title=$(jq -r --arg path "$canonical_path" \'

control_expect "a failed attachment sync exits nonzero"
control_replace scripts/lib/attachments.sh 1 \
    '    if (( fail_count > 0 )); then' \
    '    if false; then'

control_expect "a failed per-issue attachment fetch exits nonzero"
control_replace scripts/commands/cache-query.sh 1 \
    '                if (( failed > 0 )); then' \
    '                if false; then'

control_expect "a failed project sync exits nonzero"
control_replace scripts/commands/sync.sh 1 \
    '        attach_count=$(attach_sync --quiet) || return 1' \
    '        attach_count=$(attach_sync --quiet) || true'
