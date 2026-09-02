# Let every match count as live, so the selection is the first project the name
# query returned rather than the first live one. A canceled project sharing the
# name then wins whenever the API lists it first, and the create lands there
# reporting success.
control_expect "the issueCreate payload carries the live project id, not the canceled one (canceled-first)"
control_replace scripts/lib/common.sh 1 \
    '        | ($all | map(select((.state // "" | ascii_downcase) != "canceled"))) as $live' \
    '        | $all as $live'
