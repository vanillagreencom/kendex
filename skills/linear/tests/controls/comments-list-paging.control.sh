# An entity's open collection is never continued: the list stops at the
# first page.
control_expect 'two pages: every comment, in order'
control_replace scripts/lib/pages.sh 1 \
    '        next=$(jq -r --arg field "$field" '"'"'.[$field].pageInfo.hasNextPage'"'"' <<<"$data") || return 1' \
    '        next=false'
