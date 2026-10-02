# Each mutation changes a disposable skill copy and names its assertion.
control_expect 'single: completes'
control_replace scripts/lib/pages.sh 1 \
    '        all=$(jq -cs '\''.[0] + .[1]'\'' <<<"$all"$'\''\n'\''"$nodes") || return 1' \
    '        all=$(jq -cn --argjson all "$all" --argjson nodes "$nodes" '\''$all + $nodes'\'') || return 1'
control_expect 'cumulative: completes'
control_replace scripts/lib/pages.sh 1 \
    '        .[1] as $nodes | .[0] | setpath($key + ["nodes"]; $nodes)'\'' <<<"$result"$'\''\n'\''"$all") || return 1' \
    '        .[0] | setpath($key + ["nodes"]; $nodes)'\'' --argjson nodes "$all" <<<"$result") || return 1'
# Root truncation leaves nested completion intact. An open nested page passed
# to linear_complete_result would otherwise re-enter that same broken pager.
control_expect 'shape: rows and fields'
control_replace scripts/lib/pages.sh 1 \
    '        if [[ "$next" == false ]]; then break; fi' \
    '        if [[ "$next" == false || ( "$path" == issues && "$count" == 1 ) ]]; then break; fi'
control_expect 'bounded: no continuation'
control_replace scripts/lib/pages.sh 1 \
    '        if (( limit > 0 && collected >= limit )); then break; fi' \
    '        if (( limit > 0 && collected > limit )); then break; fi'
