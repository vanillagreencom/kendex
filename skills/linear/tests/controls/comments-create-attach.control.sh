# Stop escaping brackets in the markdown label. A filename containing ']' then
# closes the embed label early and the rendered comment mis-references the
# uploaded asset.
control_expect "the comment body escapes a bracket in the embed label"
control_replace scripts/lib/attachments.sh 1 \
    'attach_markdown_label() {' \
    'attach_markdown_label() { printf "%s" "$1"; return 0; } _unescaped_label_control() {'

# Let the shared live reader accept a null destination while retaining its
# check. Missing issues then reach the upload and comment requests.
control_expect "missing UUID: lookup is the only request, with no upload or comment"
control_replace scripts/commands/issues.sh 1 \
    '    if ! jq -e '\''.issue.id | strings | select(length > 0)'\'' <<<"$result" >/dev/null; then' \
    '    if false && ! jq -e '\''.issue.id | strings | select(length > 0)'\'' <<<"$result" >/dev/null; then'
