# Strip a valid JSON text character while posting the rest of the body.
control_expect "the posted body preserves every file byte for recovery"
control_replace scripts/commands/comments.sh 1 \
    '        cat -- "$2"' \
    '        cat -- "$2" | tr -d '"'"'\000'"'"''
