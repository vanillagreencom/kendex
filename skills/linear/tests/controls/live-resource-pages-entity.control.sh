# Each mutation changes a disposable skill copy and names its assertion.
control_expect 'entity: completes'
control_replace scripts/lib/pages.sh 1 \
    '            result=$(jq -c --arg type "$type" '\''{($type): .}'\'' <<<"$data") || return 1' \
    '            result=$(jq -cn --arg type "$type" --argjson data "$data" '\''{($type): $data}'\'') || return 1'
control_expect 'nested: completes'
control_replace scripts/lib/pages.sh 1 \
    '            data=$(jq -cs --arg field "$field" '\''.[1] as $connection | .[0] | .[$field] = $connection'\'' <<<"$data"$'\''\n'\''"$connection") || return 1' \
    '            data=$(jq -c --arg field "$field" --argjson connection "$connection" '\''.[$field] = $connection'\'' <<<"$data") || return 1'
# Skip nested continuation at its owner, so the first page reaches the existing
# row assertion instead of recursively passing open metadata to the pager.
control_expect 'nested: rows and fields'
control_replace scripts/lib/pages.sh 1 \
    '        next=$(jq -r --arg field "$field" '\''.[$field].pageInfo.hasNextPage'\'' <<<"$data") || return 1' \
    '        next=$(jq -r --arg field "$field" '\''.[$field].pageInfo.hasNextPage and false'\'' <<<"$data") || return 1'
control_expect 'nested-metadata: cause'
control_replace scripts/lib/pages.sh 1 \
    '    if ! jq -e '\''type == "object" and all(.. | objects | select(has("nodes") or has("pageInfo"));' \
    '    if ! jq -e '\''type == "object" and all(.. | objects | select(false);'
control_expect 'nested-failure: empty stdout'
control_replace scripts/lib/pages.sh 1 \
    '        value=$(linear_complete_entity "$type" "$value") || return 1' \
    '        value=$(linear_complete_entity "$type" "$value") || { printf '\''%s\n'\'' "$data"; return 1; }'
