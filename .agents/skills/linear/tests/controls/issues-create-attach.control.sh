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

control_expect "a large attachment page series extracts all objects"
control_replace scripts/lib/attachments.sh 1 \
    '        all_nodes=$(printf '\''%s\n%s\n'\'' "$all_nodes" "$nodes" | jq -s '\''add'\'') || return 1' \
    '        all_nodes=$(jq -cn --argjson prior "$all_nodes" --argjson next "$nodes" '\''$prior + $next'\'') || return 1'

control_expect "a large attachment set merges with cached text"
control_replace scripts/lib/attachments.sh 1 \
    '    printf '\''%s\n%s\n'\'' "$results" "$issue_objects" | jq -s '\''add | group_by(.url) | map((map(select(.context == "attachment")) | first) // .[0])'\''' \
    '    jq -cn --argjson text "$results" --argjson objects "$issue_objects" '\''($text + $objects) | group_by(.url) | map((map(select(.context == "attachment")) | first) // .[0])'\'''

control_expect "an angle markdown URL excludes its closing bracket"
control_replace scripts/lib/attachments.sh 1 \
    "    echo \"\$text\" | grep -oE 'https://uploads\.linear\.app/[^[:space:])>\"]+' | sort -u || true" \
    "    echo \"\$text\" | grep -oE 'https://uploads\.linear\.app/[^[:space:])\"]+' | sort -u || true"

control_expect "an angle markdown issue URL excludes its closing bracket"
control_replace scripts/lib/attachments.sh 1 \
    '        .description | capture("(?<url>https://uploads\\.linear\\.app/[^\\s)>\"]+)"; "g") |' \
    '        .description | capture("(?<url>https://uploads\\.linear\\.app/[^\\s)\"]+)"; "g") |'

control_expect "an angle markdown comment URL excludes its closing bracket"
control_replace scripts/lib/attachments.sh 1 \
    '            .body | capture("(?<url>https://uploads\\.linear\\.app/[^\\s)>\"]+)"; "g") |' \
    '            .body | capture("(?<url>https://uploads\\.linear\\.app/[^\\s)\"]+)"; "g") |'

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
