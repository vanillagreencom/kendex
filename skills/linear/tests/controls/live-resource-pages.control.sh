# Each transfer mutation restores a response-sized external argument without
# deleting the tested function. Each rule mutation runs on its own skill copy.
control_expect 'single: completes'
control_replace scripts/lib/pages.sh 1 \
    '        all=$(jq -cs '\''.[0] + .[1]'\'' <<<"$all"$'\''\n'\''"$nodes") || return 1' \
    '        all=$(jq -cn --argjson all "$all" --argjson nodes "$nodes" '\''$all + $nodes'\'') || return 1'

control_expect 'cumulative: completes'
control_replace scripts/lib/pages.sh 1 \
    '        .[1] as $nodes | .[0] | setpath($key + ["nodes"]; $nodes)'\'' <<<"$result"$'\''\n'\''"$all") || return 1' \
    '        .[0] | setpath($key + ["nodes"]; $nodes)'\'' --argjson nodes "$all" <<<"$result") || return 1'

control_expect 'entity: completes'
control_replace scripts/lib/pages.sh 1 \
    '            result=$(jq -c --arg type "$type" '\''{($type): .}'\'' <<<"$data") || return 1' \
    '            result=$(jq -cn --arg type "$type" --argjson data "$data" '\''{($type): $data}'\'') || return 1'

control_expect 'nested: completes'
control_replace scripts/lib/pages.sh 1 \
    '            data=$(jq -cs --arg field "$field" '\''.[1] as $connection | .[0] | .[$field] = $connection'\'' <<<"$data"$'\''\n'\''"$connection") || return 1' \
    '            data=$(jq -c --arg field "$field" --argjson connection "$connection" '\''.[$field] = $connection'\'' <<<"$data") || return 1'

control_expect 'children: completes'
control_replace scripts/lib/pages.sh 1 \
    '                children=$(jq -cs '\''.[0] + [.[1]]'\'' <<<"$children"$'\''\n'\''"$row") || return 1' \
    '                children=$(jq -cn --argjson rows "$children" --argjson row "$row" '\''$rows + [$row]'\'') || return 1'

control_expect 'children: rows and fields'
control_replace scripts/lib/pages.sh 1 \
    '            data=$(jq -cs '\''.[1] as $children | .[0] | .children.nodes = $children'\'' <<<"$data"$'\''\n'\''"$children") || return 1' \
    '            data=$(jq -c --argjson children "$children" '\''.children.nodes = $children'\'' <<<"$data") || return 1'

control_expect 'root-rows: completes'
control_replace scripts/lib/pages.sh 1 \
    '                all=$(jq -cs '\''.[0] + [.[1]]'\'' <<<"$all"$'\''\n'\''"$row") || return 1' \
    '                all=$(jq -cn --argjson all "$all" --argjson row "$row" '\''$all + [$row]'\'') || return 1'

control_expect 'root-rows: rows and fields'
control_replace scripts/lib/pages.sh 1 \
    '            data=$(jq -cs --arg root "$root" '\''.[1] as $all | .[0] | .[$root].nodes = $all'\'' <<<"$data"$'\''\n'\''"$all") || return 1' \
    '            data=$(jq -c --arg root "$root" --argjson all "$all" '\''.[$root].nodes = $all'\'' <<<"$data") || return 1'

control_expect 'create: completes'
control_replace scripts/lib/pages.sh 1 \
    '                data=$(jq -cs --arg root "$root" '\''.[1] as $value | .[0] | .[$root] = $value'\'' <<<"$data"$'\''\n'\''"$value") || return 1' \
    '                data=$(jq -c --arg root "$root" --argjson value "$value" '\''.[$root] = $value'\'' <<<"$data") || return 1'

control_expect 'update: completes'
control_replace scripts/lib/pages.sh 1 \
    '            data=$(jq -cs --arg root "$root" '\''.[1] as $value | .[0] | .[$root] = $value'\'' <<<"$data"$'\''\n'\''"$value") || return 1' \
    '            data=$(jq -c --arg root "$root" --argjson value "$value" '\''.[$root] = $value'\'' <<<"$data") || return 1'

control_expect 'shape: rows and fields'
control_replace scripts/lib/pages.sh 1 \
    '        if [[ "$next" == false ]]; then break; fi' \
    '        if [[ "$next" == false || "$count" == 1 ]]; then break; fi'

control_expect 'missing-metadata: cause'
control_replace scripts/lib/pages.sh 1 \
    '            select(.pageInfo.hasNextPage | type == "boolean") | .nodes'\'' <<<"$result"); then' \
    '            .nodes'\'' <<<"$result"); then'

control_expect 'malformed-nodes: cause'
control_replace scripts/lib/pages.sh 1 \
    '            getpath($key) | select(.nodes | type == "array") |' \
    '            getpath($key) |'

control_expect 'nested-metadata: cause'
control_replace scripts/lib/pages.sh 1 \
    '    if ! jq -e '\''type == "object" and all(.. | objects | select(has("nodes") or has("pageInfo"));' \
    '    if ! jq -e '\''type == "object" and all(.. | objects | select(false);'

control_expect 'missing-cursor: cause'
control_replace scripts/lib/pages.sh 1 \
    '        cursor=$(jq -ce --argjson key "$key" '\''getpath($key).pageInfo.endCursor | strings | select(length > 0)'\'' <<<"$result") || {' \
    '        cursor=$(jq -c --argjson key "$key" '\''getpath($key).pageInfo.endCursor'\'' <<<"$result") || {'

control_expect 'repeated-cursor: cause'
control_replace scripts/lib/pages.sh 1 \
    '        next=$(jq -rs '\''.[1] as $cursor | .[0] | index($cursor) != null'\'' <<<"$seen"$'\''\n'\''"$cursor") || return 1' \
    '        next=$(jq -rs '\''false'\'' <<<"$seen"$'\''\n'\''"$cursor") || return 1'

control_expect 'cap: refuses'
control_replace scripts/lib/pages.sh 1 \
    '        if (( count >= 400 )); then' \
    '        if (( count > 400 )); then'

control_expect 'later-page: empty stdout'
control_replace scripts/lib/pages.sh 1 \
    '            result=$(graphql_request "$query" "$variables") || return 1' \
    '            result=$(graphql_request "$query" "$variables") || { printf '\''%s\n'\'' "$all"; return 1; }'

control_expect 'nested-failure: empty stdout'
control_replace scripts/lib/pages.sh 1 \
    '        value=$(linear_complete_entity "$type" "$value") || return 1' \
    '        value=$(linear_complete_entity "$type" "$value") || { printf '\''%s\n'\'' "$data"; return 1; }'

control_expect 'bounded: no continuation'
control_replace scripts/lib/pages.sh 1 \
    '        if (( limit > 0 && collected >= limit )); then break; fi' \
    '        if (( limit > 0 && collected > limit )); then break; fi'
