# Silence the truncation warning. A default listing of exactly 75 rows is then
# indistinguishable from a complete result, which is the whole point of the
# announcement.
control_expect "the slice announces itself with both counts"
control_replace scripts/commands/cache-query.sh 1 \
    '            echo "⚠️  Truncated to $limit of $total issues. Pass --max for all results, or --limit N." >&2' \
    '            :'
