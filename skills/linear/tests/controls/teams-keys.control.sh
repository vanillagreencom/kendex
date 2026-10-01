# The field read and the key-array projection are separate parts of the
# `teams keys` wire contract consumed by Slack.
control_expect 'team keys supplies the workspace and complete key array'
control_replace scripts/commands/teams.sh 1 \
    '    result=$(graphql_query '\''query TeamKeys { organization { urlKey teams { nodes { key } } } }'\'' '\''{}'\'') || return $?' \
    '    result=$(graphql_query '\''query TeamKeys { organization { teams { nodes { key } } } }'\'' '\''{}'\'') || return $?'
