# Each mutation changes a disposable skill copy and names its assertion.
control_expect 'single: completes'
control_replace scripts/lib/pages.sh 1 \
    '        printf '\''%s\n'\'' "$nodes" >>"$spool/nodes" || return 1' \
    '        jq -cn --argjson nodes "$nodes" '\''$nodes'\'' >>"$spool/nodes" || return 1'
control_expect 'cumulative: completes'
control_replace scripts/lib/pages.sh 1 \
    '    jq -cn --argjson key "$key" --argjson limit "$limit" '\''' \
    '    jq -cn --argjson key "$key" --argjson limit "$limit" --argjson all "$(jq -cs add "$spool/nodes")" '\'''
# The merged result goes through linear_complete_result, a variable of its own.
control_expect 'spooled: no variable past one page'
control_replace scripts/lib/pages.sh 1 \
    '    if jq -e '\''all(.. | objects | select(has("nodes") or has("pageInfo"));' \
    '    if false && jq -e '\''all(.. | objects | select(has("nodes") or has("pageInfo"));'
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
