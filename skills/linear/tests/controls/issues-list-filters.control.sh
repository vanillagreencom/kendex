# Each mutation changes a disposable skill copy and names its assertion.
# Of several labels only the first filters, so an issue carrying one of them
# passes for one carrying all.
control_expect 'two labels by --labels: filter'
control_replace scripts/lib/common.sh 1 \
    '            if length == 1 then .[0] else {and: .} end'\'')")' \
    '            .[0]'\'')")'
# A second project-scope option is accepted, and the two AND into a filter
# nobody asked for.
control_expect '--project with --all-projects: exit status'
control_replace scripts/lib/common.sh 1 \
    '    [ -n "$1" ] || return 0' \
    '    return 0'

control_expect 'email assignee: filter'
control_replace scripts/lib/common.sh 1 \
    '                filter_parts+=("$(jq -cn --arg v "$2" '\''{assignee: {email: {eqIgnoreCase: $v}}}'\'')")' \
    '                filter_parts+=("$(jq -cn --arg v "$2" '\''{assignee: {name: {eq: $v}}}'\'')")'
