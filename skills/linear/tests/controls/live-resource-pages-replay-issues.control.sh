# Each mutation changes a disposable skill copy and names its assertion.
# A later page that fails reads as an empty last page, so the rows read so far
# pass for the whole collection.
control_expect 'issues-list: partial chain refuses'
control_replace scripts/lib/pages.sh 1 \
    '            result=$(graphql_request "$query" "$variables") || return 1' \
    '            result=$(graphql_request "$query" "$variables") || result=$(jq -cn --argjson key "$key" '\''{} | setpath($key; {nodes: [], pageInfo: {hasNextPage: false, endCursor: null}})'\'')'
# The last page alone is returned as the collection.
control_expect 'issues-list: every recorded row is read'
control_replace scripts/lib/pages.sh 1 \
    '        .[1] as $nodes | .[0] | setpath($key + ["nodes"]; $nodes)'\'' <<<"$result"$'\''\n'\''"$all") || return 1' \
    '        .[0]'\'' <<<"$result"$'\''\n'\''"$all") || return 1'
# A read leaves a local store behind.
control_expect 'issues-list: no local store is written'
control_append scripts/lib/common.sh \
    'mkdir -p -- "$PROJECT_ROOT/.cache/linear"'
# A recorded fixture names another team's issue.
control_expect 'issues-get: identifiers are fixture identifiers'
control_replace tests/lib/fixtures/recorded/issues-get.json 1 \
    '  "args": ["issues", "get", "KEN-9002", "--format=raw"],' \
    '  "args": ["issues", "get", "HT-812", "--format=raw"],'
# --pending drops an open grandchild along with the Done child above it.
control_expect 'issues-children-pending: every recorded row is read'
control_replace scripts/commands/issues.sh 1 \
    '                rows=$(jq -c "$open"'\''map(select(open))'\'' <<<"$rows") || return 1' \
    '                rows=$(jq -c "$open"'\''map(select(open and .depth == 0))'\'' <<<"$rows") || return 1'
# The raw --pending read keeps every closed row.
control_expect 'issues-children-pending-raw: every recorded row is read'
control_replace scripts/commands/issues.sh 1 \
    '                        | select(open or ((.children.nodes // []) | length > 0)));' \
    '                        | select(true));'
