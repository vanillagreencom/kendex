# Each mutation changes a disposable skill copy and names its assertion.
control_expect 'children: completes'
control_replace scripts/lib/pages.sh 1 \
    '                children=$(jq -cs '\''.[0] + [.[1]]'\'' <<<"$children"$'\''\n'\''"$row") || return 1' \
    '                children=$(jq -cn --argjson rows "$children" --argjson row "$row" '\''$rows + [$row]'\'') || return 1'
control_expect 'children: rows and fields'
control_replace scripts/lib/pages.sh 1 \
    '            data=$(jq -cs '\''.[1] as $children | .[0] | .children.nodes = $children'\'' <<<"$data"$'\''\n'\''"$children") || return 1' \
    '            data=$(jq -c --argjson children "$children" '\''.children.nodes = $children'\'' <<<"$data") || return 1'
control_expect 'children: child-b continuation keeps requested depth'
control_replace scripts/lib/pages.sh 1 \
    '        if (( depth > 1 )); then' \
    '        if (( depth > 0 )); then'
