# Each mutation changes a disposable skill copy and names its assertion.
control_expect 'single: completes'
control_replace scripts/lib/pages.sh 1 \
    '        printf '\''%s\n'\'' "$nodes" >>"$spool/nodes" || return 1' \
    '        jq -cn --argjson nodes "$nodes" '\''$nodes'\'' >>"$spool/nodes" || return 1'
control_expect 'cumulative: completes'
control_replace scripts/lib/pages.sh 1 \
    '    jq -cn --argjson key "$key" --argjson limit "$limit" '\''' \
    '    jq -cn --argjson key "$key" --argjson limit "$limit" --argjson all "$(jq -cs add "$spool/nodes")" '\'''
# The merged result passes through a variable on its way out.
control_expect 'spooled: no variable past one page'
control_replace scripts/lib/pages.sh 1 \
    '        cat -- "$spool/result"' \
    '        result=$(cat -- "$spool/result") && printf '\''%s\n'\'' "$result"'
# A root collection with an open row completes whole, in one variable.
control_expect 'spooled-open: no variable past one page'
control_replace scripts/lib/pages.sh 1 \
    '    if [[ "$path" == *.* ]] || ! jq -e --arg path "$path" '\''keys == [$path]'\'' "$spool/result" >/dev/null; then' \
    '    if true; then'
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
