# Each mutation changes a disposable skill copy and names its assertion.
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
control_expect 'root-rows: open row collections completed'
control_replace scripts/lib/pages.sh 1 \
    '            [[ "$open" == true ]] || continue' \
    '            continue'
