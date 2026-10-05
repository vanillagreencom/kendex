# Each mutation changes a disposable skill copy and names its assertion.
# A later page that fails reads as an empty last page, so the rows read so far
# pass for the whole collection.
control_expect 'comments-list: partial chain refuses'
control_replace scripts/lib/pages.sh 1 \
    '            result=$(graphql_request "$query" "$variables") || return 1' \
    '            result=$(graphql_request "$query" "$variables") || result=$(jq -cn --argjson key "$key" '\''{} | setpath($key; {nodes: [], pageInfo: {hasNextPage: false, endCursor: null}})'\'')'
# The last page alone is returned as the collection.
control_expect 'comments-list: every recorded row is read'
control_replace scripts/lib/pages.sh 1 \
    '        .[1] as $nodes | .[0] | setpath($key + ["nodes"]; $nodes)'\'' <<<"$result"$'\''\n'\''"$all") || return 1' \
    '        .[0]'\'' <<<"$result"$'\''\n'\''"$all") || return 1'
# A read leaves a local store behind.
control_expect 'comments-list: no local store is written'
control_append scripts/lib/common.sh \
    'mkdir -p -- "$PROJECT_ROOT/.cache/linear"'
# The read keeps its first page's rows only, so the project the second page
# holds, one the status keeps, is lost.
control_expect 'session-status: every recorded row is read'
control_replace scripts/lib/pages.sh 1 \
    '        all=$(jq -cs '\''.[0] + .[1]'\'' <<<"$all"$'\''\n'\''"$nodes") || return 1' \
    '        all=$(jq -cs '\''if .[0] == [] then .[1] else .[0] end'\'' <<<"$all"$'\''\n'\''"$nodes") || return 1'
