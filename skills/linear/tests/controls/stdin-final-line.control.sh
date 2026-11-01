# Stop the comments reader at the last line break, dropping an identifier
# written after it.
control_expect "comments bulk-list --stdin keeps the last identifier"
control_replace scripts/commands/comments.sh 1 \
    '            while IFS= read -r line || [[ -n "$line" ]]; do [[ -n "$line" ]] && identifiers+=("$line"); done' \
    '            while IFS= read -r line; do [[ -n "$line" ]] && identifiers+=("$line"); done'
