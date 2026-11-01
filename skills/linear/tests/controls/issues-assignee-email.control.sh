# Match an address as a substring. The tail of another person's address then
# assigns the issue to them.
control_expect "update-email-partial: the action fails"
control_replace scripts/lib/common.sh 1 \
    "    result=\$(graphql_pages 'query GetUserByEmail(\$email: String!, \$after: String) { users(filter: {email: {eqIgnoreCase: \$email}}, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id name email } } }' \"\$vars\" users) || return 1" \
    "    result=\$(graphql_pages 'query GetUserByEmail(\$email: String!, \$after: String) { users(filter: {email: {containsIgnoreCase: \$email}}, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id name email } } }' \"\$vars\" users) || return 1"
