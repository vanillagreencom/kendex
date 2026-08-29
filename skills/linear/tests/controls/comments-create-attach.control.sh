# Stop escaping brackets in the markdown label. A filename containing ']' then
# closes the embed label early and the rendered comment mis-references the
# uploaded asset.
control_expect "the comment body escapes a bracket in the embed label"
control_replace scripts/lib/attachments.sh 1 \
    'attach_markdown_label() {' \
    'attach_markdown_label() { printf "%s" "$1"; return 0; } _unescaped_label_control() {'
