# Take the first project the name query returns instead of the first live one.
# A canceled project sharing the name then wins whenever the API lists it
# first, and the create lands there reporting success.
control_expect "the issueCreate payload carries the live project id, not the canceled one (canceled-first)"
control_replace scripts/lib/common.sh 1 \
    '        '"'"'[(.projects.nodes // [])[] | select((.state // "" | ascii_downcase) != "canceled")][0].id // empty'"'"')' \
    '        '"'"'(.projects.nodes // [])[0].id // empty'"'"')'
