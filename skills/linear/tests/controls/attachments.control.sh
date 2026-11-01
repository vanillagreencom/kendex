# A download goes to any host, carrying the Linear credential there.
control_expect 'foreign host: sends no request'
control_replace scripts/commands/attachments.sh 1 \
    '    if [[ "$url" != https://uploads.linear.app/* ]]; then' \
    '    if false; then'
