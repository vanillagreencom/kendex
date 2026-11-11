# A reference no read answers is dropped.
control_expect 'an unknown reference refuses the read'
control_replace scripts/lib/common.sh 1 \
    '            missing=$(jq -c --arg ref "$ref" '"'"'. + [$ref]'"'"' <<<"$missing") || return 1' \
    '            :'
