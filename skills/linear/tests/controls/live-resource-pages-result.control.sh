control_expect 'root-rows: completes'
control_replace scripts/lib/pages.sh 1 \
    '                all=$(jq -cs '\''.[0] + [.[1]]'\'' <<<"$all"$'\''\n'\''"$row") || return 1' \
    '                all=$(jq -cn --argjson all "$all" --argjson row "$row" '\''$all + [$row]'\'') || return 1'
