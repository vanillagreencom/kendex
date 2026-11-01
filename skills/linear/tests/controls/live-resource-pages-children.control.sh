control_expect 'children: completes'
control_replace scripts/lib/pages.sh 1 \
    '                children=$(jq -cs '\''.[0] + [.[1]]'\'' <<<"$children"$'\''\n'\''"$row") || return 1' \
    '                children=$(jq -cn --argjson rows "$children" --argjson row "$row" '\''$rows + [$row]'\'') || return 1'
