# Take the first of two matching teams instead of refusing the reference.
control_expect "ambiguous: ENG refuses naming both teams"
control_replace scripts/lib/common.sh 1 \
    '        1)' \
    '        [1-9])'
