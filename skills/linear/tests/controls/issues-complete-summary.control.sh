control_expect "partial complete ids split fails"
control_expect "partial complete ids equals fails"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$update_rc" -ne 0 ] || [ "$update_success" != "true" ]; then' \
    '    if false; then'
