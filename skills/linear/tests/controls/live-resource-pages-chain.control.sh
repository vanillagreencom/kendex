control_expect 'missing-metadata: cause'
control_replace scripts/lib/pages.sh 1 \
    '            select(.pageInfo.hasNextPage | type == "boolean") | .nodes'\'' <<<"$result"); then' \
    '            .nodes'\'' <<<"$result"); then'
