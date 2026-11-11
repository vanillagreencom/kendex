# Of several labels only the first filters, so an issue carrying one of them
# passes for one carrying all.
control_expect 'two labels by --labels: filter'
control_replace scripts/lib/common.sh 1 \
    '            if length == 1 then .[0] else {and: .} end'\'')")' \
    '            .[0]'\'')")'
