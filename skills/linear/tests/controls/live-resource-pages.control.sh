control_expect 'single: completes'
control_replace scripts/lib/pages.sh 1 \
    '        printf '\''%s\n'\'' "$nodes" >>"$spool/nodes" || return 1' \
    '        jq -cn --argjson nodes "$nodes" '\''$nodes'\'' >>"$spool/nodes" || return 1'
