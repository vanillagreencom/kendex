control_expect 'entity: completes'
control_replace scripts/lib/pages.sh 1 \
    '            result=$(jq -c --arg type "$type" '\''{($type): .}'\'' <<<"$data") || return 1' \
    '            result=$(jq -cn --arg type "$type" --argjson data "$data" '\''{($type): $data}'\'') || return 1'
