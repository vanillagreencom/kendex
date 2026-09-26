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
    "    result=\$(graphql_query 'query GetUserByEmail(\$email: String!) { users(filter: {email: {eqIgnoreCase: \$email}}) { nodes { id name email } } }' \"\$vars\") || return 1" \
    "    result=\$(graphql_query 'query GetUserByEmail(\$email: String!) { users(filter: {email: {eq: \$email}}) { nodes { id name email } } }' \"\$vars\") || return 1"

# Match an address as a substring. The tail of another person's address then
# assigns the issue to them.
control_expect "update-email-partial: the action fails"
control_replace scripts/commands/issues.sh 1 \
    "    result=\$(graphql_query 'query GetUserByEmail(\$email: String!) { users(filter: {email: {eqIgnoreCase: \$email}}) { nodes { id name email } } }' \"\$vars\") || return 1" \
    "    result=\$(graphql_query 'query GetUserByEmail(\$email: String!) { users(filter: {email: {containsIgnoreCase: \$email}}) { nodes { id name email } } }' \"\$vars\") || return 1"

# Send a user id down the name path. No name matches it, so the form
# activation hands the update refuses.
control_expect "update-id: the action exits zero"
control_replace scripts/commands/issues.sh 1 \
    '    if [[ "$ref" =~ $LINEAR_UUID_PATTERN ]]; then' \
    '    if false; then'

# Let a miss through. The mutation goes out with an empty assignee id instead
# of refusing.
control_expect "create-email-miss: the action fails"
control_replace scripts/commands/issues.sh 1 \
    '    if [ -z "$assignee_id" ]; then' \
    '    if false; then'

# Leave the assignee to be resolved after the upload whenever files are
# attached. A miss then uploads the asset first and refuses only after it.
control_expect "create-attach-miss: no file is uploaded"
control_expect "update-attach-miss: no file is uploaded"
control_replace scripts/commands/issues.sh 2 \
    '    if [ -n "$assignee" ]; then' \
    '    if [ -n "$assignee" ] && [ ${#attach_paths[@]} -eq 0 ]; then'
