# Move the --labels/--clear-labels refusal after the upload. The combination is
# still refused, but the asset has already been pushed to Linear storage and is
# stranded there with nothing referencing it.
control_expect "the refused update uploaded nothing"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$clear_labels" = "true" ] && [ -n "$labels" ]; then' \
    '    if [ "$clear_labels" = "true" ] && [ -n "$labels" ] && [ ${#attach_paths[@]} -eq 0 ]; then'

control_expect 'graphql: completed non-image survives the failed batch'
control_replace scripts/commands/issues.sh 1 \
    '            pending_json=$(pending_attachments_json ${attach_pending[@]+"${attach_pending[@]}"}) || return "$upload_status"' \
    '            pending_json=$(pending_attachments_json ${attach_pending[@]+"${attach_pending[@]}"}) || return "$upload_status"; pending_json="[]"'

control_expect 'resume succeeds after its input is captured'
control_replace scripts/commands/issues.sh 1 \
    '            attach_pending+=("$retained_entry")' \
    '            attach_pending+=("$retained_entry"); attach_pending=()'

control_expect 'private headers: invalid retained input sends no API request'
control_replace scripts/commands/issues.sh 1 \
    '                    type == "object" and keys == ["repo_path", "url"]' \
    '                    type == "object"'

# Forget an image uploaded before the failure. Its embed was never written, and
# the resume set no longer names it, so following the resume steps loses it.
control_expect 'graphql: unwritten image, then exact failed and unattempted upload suffix'
control_replace scripts/commands/issues.sh 1 \
    '            unwritten_images+=("$attach_path")' \
    '            :'

# Let a second --attach-uploaded replace the first, silently unbinding its pairs.
control_expect 'a second retained file refuses'
control_replace scripts/commands/issues.sh 1 \
    '            if [ "$attach_uploaded_set" = true ]; then' \
    '            if false; then'

# Accept a file holding several JSON values, binding only the first.
control_expect 'multiple values: invalid retained input refuses'
control_replace scripts/commands/issues.sh 1 \
    '                if length == 1 and (.[0] | type == "array" and length > 0 and all(.[];' \
    '                if true and (.[0] | type == "array" and length > 0 and all(.[];'
