# Treat an image attachment as a plain file. The image stops being embedded in
# the description and becomes an attachmentCreate record instead, which is the
# opposite of the documented contract.
control_expect "the image embed lands in the created description"
control_replace scripts/commands/issues.sh 1 \
    '        if [[ "$attach_type" == image/* ]]; then' \
    '        if false; then'

# Drop the retryable pairs from a failed create binding. The issue exists, so
# the caller loses the only copy of the uploaded URLs.
control_expect "a partial failure claims no attachment record"
control_replace scripts/commands/issues.sh 1 \
    "                '. + {success: false, partial: true, pending_attachments: \$pending}' <<<\"\$normalized\") || return \"\$attach_failed\"" \
    "                '. + {success: false, partial: true}' <<<\"\$normalized\") || return \"\$attach_failed\""

# Print the bare identifier for a failed --format=ids create, hiding the pairs.
control_expect "a --format=ids partial failure returns the retryable JSON, not the bare identifier"
control_replace scripts/commands/issues.sh 1 \
    '    if [[ "$output_format" == "ids" && "$attach_failed" == "0" ]]; then' \
    '    if [[ "$output_format" == "ids" ]]; then'
