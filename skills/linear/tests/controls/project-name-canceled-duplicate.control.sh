# Let every match count as live, so PROJECT_PICK_JQ (scripts/lib/formatters.sh)
# selects the first project the name query returned rather than the first live
# one. A canceled project sharing the name then wins whenever the API lists it
# first, and the create lands there reporting success.
control_expect "the issueCreate payload carries the live project id, not the canceled one (canceled-first)"
control_replace scripts/lib/formatters.sh 1 \
    'def project_is_live: (.state // "" | ascii_downcase) != "canceled";' \
    'def project_is_live: true;'
