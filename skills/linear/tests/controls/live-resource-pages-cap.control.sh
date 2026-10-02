# Each mutation changes a disposable skill copy and names its assertion.
control_expect 'cap: refuses'
control_replace scripts/lib/pages.sh 1 \
    '        if (( count >= 400 )); then' \
    '        if (( count > 400 )); then'
