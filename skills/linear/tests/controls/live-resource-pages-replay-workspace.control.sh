# Each mutation changes a disposable skill copy and names its assertion.
# A later page that fails reads as an empty last page, so the rows read so far
# pass for the whole collection.
control_expect 'labels-list: partial chain refuses'
control_replace scripts/lib/pages.sh 1 \
    '            result=$(graphql_request "$query" "$variables") || return 1' \
    '            result=$(graphql_request "$query" "$variables") || result=$(jq -cn --argjson key "$key" '\''{} | setpath($key; {nodes: [], pageInfo: {hasNextPage: false, endCursor: null}})'\'')'
# The last page alone is returned as the collection.
control_expect 'labels-list: every recorded row is read'
control_replace scripts/lib/pages.sh 1 \
    '        .[1] as $nodes | .[0] | setpath($key + ["nodes"]; $nodes)'\'' <<<"$result"$'\''\n'\''"$all") || return 1' \
    '        .[0]'\'' <<<"$result"$'\''\n'\''"$all") || return 1'
# A read leaves a local store behind.
control_expect 'labels-list: no local store is written'
control_append scripts/lib/common.sh \
    'mkdir -p -- "$PROJECT_ROOT/.cache/linear"'
# A recorded fixture keeps another team's key.
control_expect 'teams-keys: names are fixture names'
control_replace tests/lib/fixtures/recorded/teams-keys.json 1 \
    '    {"operation":"TeamKeys","response":{"data":{"organization":{"urlKey":"fixture","teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"key":"FXA"},{"key":"FXB"},{"key":"FXC"},{"key":"FXD"},{"key":"FXE"},{"key":"FXF"},{"key":"FXG"},{"key":"KEN"},{"key":"FXH"},{"key":"FXI"},{"key":"FXJ"}]}}}}}' \
    '    {"operation":"TeamKeys","response":{"data":{"organization":{"urlKey":"fixture","teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"key":"HT"},{"key":"FXB"},{"key":"FXC"},{"key":"FXD"},{"key":"FXE"},{"key":"FXF"},{"key":"FXG"},{"key":"KEN"},{"key":"FXH"},{"key":"FXI"},{"key":"FXJ"}]}}}}}'
