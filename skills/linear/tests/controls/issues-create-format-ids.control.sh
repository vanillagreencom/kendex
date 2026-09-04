# Make the --format=ids branch print the whole mutation response. Workflows
# capturing the created identifier get a JSON blob instead. The create and update
# branches are the same line, so both move; the create contract is what this
# suite asserts.
control_expect "create --format=ids prints exactly the identifier"
control_replace scripts/commands/issues.sh 2 \
    "        echo \"\$normalized\" | jq -r '.identifier // empty'" \
    '        echo "$normalized"'
