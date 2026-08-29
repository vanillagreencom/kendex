# Treat an image attachment as a plain file. The image stops being embedded in
# the description and becomes an attachmentCreate record instead, which is the
# opposite of the documented contract.
control_expect "the image embed lands in the created description"
control_replace scripts/commands/issues.sh 1 \
    '        if [[ "$attach_type" == image/* ]]; then' \
    '        if false; then'
