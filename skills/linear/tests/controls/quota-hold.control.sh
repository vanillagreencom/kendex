control_expect 'known hold sends no HTTP'
control_replace scripts/lib/common.sh 1 \
    '    ((now < epoch)) || return 0' \
    '    ((now < epoch)) || return 0; return 0'
