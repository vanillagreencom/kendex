# Each mutation changes a disposable skill copy and names its assertion.
# A later page that fails reads as an empty last page, so the rows read so far
# pass for the whole collection.
control_expect 'projects-list: partial chain refuses'
control_expect 'initiatives-list: partial chain refuses'
control_expect 'initiatives-get: partial chain refuses'
control_replace scripts/lib/pages.sh 1 \
    '            result=$(graphql_request "$query" "$variables") || return 1' \
    '            result=$(graphql_request "$query" "$variables") || result=$(jq -cn --argjson key "$key" '\''{} | setpath($key; {nodes: [], pageInfo: {hasNextPage: false, endCursor: null}})'\'')'
# The last page alone is returned as the collection.
control_expect 'projects-list: every recorded row is read'
control_replace scripts/lib/pages.sh 1 \
    '        input as $result | [inputs[]] as $nodes | $result |' \
    '        input as $result | [inputs[]] as $nodes | $result | getpath($key + ["nodes"]) as $nodes | $result |'
# A read leaves a local store behind.
control_expect 'projects-list: no local store is written'
control_append scripts/lib/common.sh \
    'mkdir -p -- "$PROJECT_ROOT/.cache/linear"'
# A recorded fixture keeps a workspace id.
control_expect 'projects-get: ids are fixture ids'
control_replace tests/lib/fixtures/recorded/projects-get.json 1 \
    '  "args": ["projects", "get", "00000000-0000-4000-8000-000000000028", "--format=raw"],' \
    '  "args": ["projects", "get", "84dff092-534c-4f71-bcea-3f56b301ab8f", "--format=raw"],'
