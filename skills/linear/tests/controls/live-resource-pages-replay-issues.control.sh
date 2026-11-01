# A later page that fails reads as an empty last page, so the rows read so far
# pass for the whole collection.
control_expect 'issues-list: partial chain refuses'
control_replace scripts/lib/pages.sh 1 \
    '            result=$(graphql_request "$query" "$variables") || return 1' \
    '            result=$(graphql_request "$query" "$variables") || result=$(jq -cn --argjson key "$key" '\''{} | setpath($key; {nodes: [], pageInfo: {hasNextPage: false, endCursor: null}})'\'')'
