# Take the null guard off the labels projection in the safe formatter. A cached
# record with labels:null then aborts the whole jq program, so the read loses
# parent_id and the record along with it.
control_expect "safe cache get keeps parent_id on a labels:null record"
control_replace scripts/lib/formatters.sh 2 \
    '        labels: [(.issue.labels.nodes // [])[] | .name],' \
    '        labels: [.issue.labels.nodes[] | .name],'
