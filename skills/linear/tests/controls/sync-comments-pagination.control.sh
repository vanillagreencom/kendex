# Restore the fail-open on a failed comments query: take the status check off
# graphql_query. The caller invokes sync_comments as an `if !` condition, which
# suspends errexit for the whole body, so the failure falls through and the
# sync stamps a complete pull over a cache that never received one.
control_expect "a apierror response is diagnosed as: the comments query failed"
control_replace scripts/commands/sync.sh 1 \
    '        if ! result=$(graphql_query "$query" "{\"filter\": $filter_json, \"first\": 250, \"after\": $cursor}"); then' \
    '        result=$(graphql_query "$query" "{\"filter\": $filter_json, \"first\": 250, \"after\": $cursor}") || true; if false; then'
