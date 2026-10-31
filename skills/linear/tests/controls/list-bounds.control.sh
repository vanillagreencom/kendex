# A last page trimmed to the bound reads as the end of the collection.
control_expect 'labels list --limit 300: a trimmed last page still notices'
control_replace scripts/lib/pages.sh 1 \
    '            setpath($key + ["pageInfo", "hasNextPage"]; true) |' \
    '            . |'
