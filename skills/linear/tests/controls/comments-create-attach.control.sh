# Stop escaping brackets in the markdown label. A filename containing ']' then
# closes the embed label early and the rendered comment mis-references the
# uploaded asset.
control_expect "the comment body escapes a bracket in the embed label"
control_replace scripts/lib/attachments.sh 1 \
    'attach_markdown_label() {' \
    'attach_markdown_label() { printf "%s" "$1"; return 0; } _unescaped_label_control() {'

# Skip the live destination check while retaining its code. Missing issues
# then reach the upload and comment requests.
control_expect "missing UUID: lookup is the only request, with no upload or comment"
control_replace scripts/commands/comments.sh 1 \
    '        if ! issue_result=$(bash "$SCRIPT_DIR/issues.sh" get "$issue_id" --format=raw) ||' \
    '        if false && ! issue_result=$(bash "$SCRIPT_DIR/issues.sh" get "$issue_id" --format=raw) &&'
