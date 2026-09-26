# Send an address down the name path. Linear matches no name against it, so
# every email form refuses.
control_expect "create-email: the action exits zero"
control_replace scripts/commands/issues.sh 1 \
    '    elif [[ "$ref" == *@* ]]; then' \
    '    elif false; then'

# Compare addresses as written. The same person typed in another case is then
# nobody.
control_expect "update-email: the issueUpdate carries the user's id"
control_replace scripts/commands/issues.sh 1 \
    "        'first(.[] | select((.email | ascii_downcase) == (\$email | ascii_downcase))) // empty' <<<\"\$users\"" \
    "        'first(.[] | select(.email == \$email)) // empty' <<<\"\$users\""

# Match an address as a substring. The tail of another person's address then
# assigns the issue to them.
control_expect "update-email-partial: the action fails"
control_replace scripts/commands/issues.sh 1 \
    "        'first(.[] | select((.email | ascii_downcase) == (\$email | ascii_downcase))) // empty' <<<\"\$users\"" \
    "        'first(.[] | select(.email | ascii_downcase | contains(\$email | ascii_downcase))) // empty' <<<\"\$users\""

# Let a miss through. The mutation goes out with an empty assignee id instead
# of refusing.
control_expect "create-email-miss: the action fails"
control_replace scripts/commands/issues.sh 1 \
    '    if [ -z "$assignee_id" ]; then' \
    '    if false; then'
