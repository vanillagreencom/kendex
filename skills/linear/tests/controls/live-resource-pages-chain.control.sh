# Each mutation changes a disposable skill copy and names its assertion.
control_expect 'missing-metadata: cause'
control_replace scripts/lib/pages.sh 1 \
    '            select(.pageInfo.hasNextPage | type == "boolean") | .nodes'\'' <<<"$result"); then' \
    '            .nodes'\'' <<<"$result"); then'
control_expect 'malformed-nodes: cause'
control_replace scripts/lib/pages.sh 1 \
    '            getpath($key) | select(.nodes | type == "array") |' \
    '            getpath($key) |'
control_expect 'missing-cursor: cause'
control_replace scripts/lib/pages.sh 1 \
    '        cursor=$(jq -ce --argjson key "$key" '\''getpath($key).pageInfo.endCursor | strings | select(length > 0)'\'' <<<"$result") || {' \
    '        cursor=$(jq -c --argjson key "$key" '\''getpath($key).pageInfo.endCursor'\'' <<<"$result") || {'
# The repeated reply also proves the fixture bounds a nonterminating pager.
control_expect 'repeated-cursor: page walk budget'
control_expect 'repeated-cursor: cause'
control_replace scripts/lib/pages.sh 1 \
    '        next=$(jq -rs '\''.[1] as $cursor | .[0] | index($cursor) != null'\'' <<<"$seen"$'\''\n'\''"$cursor") || return 1' \
    '        next=$(jq -rs '\''false'\'' <<<"$seen"$'\''\n'\''"$cursor") || return 1'
control_expect 'later-page: empty stdout'
control_replace scripts/lib/pages.sh 1 \
    '            result=$(graphql_request "$query" "$variables") || return 1' \
    '            result=$(graphql_request "$query" "$variables") || { printf '\''%s\n'\'' "$all"; return 1; }'
