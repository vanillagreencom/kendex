# Let the create path apply an undeclared label: it reaches Linear and is sent.
control_expect "create-undeclared: refused"
control_expect "create-undeclared: no write is sent"
control_expect "create-undeclared: refused before any request"
control_replace scripts/commands/issues.sh 1 \
    '        linear_require_declared_labels "$labels" || return 1' \
    '        linear_require_declared_labels "$labels" || :'
