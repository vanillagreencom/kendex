# Let a merge that shrinks the cache through. A transient empty or partial
# query result then overwrites a healthy cache and the sync reports completion.
control_expect "an aborted cache merge fails the sync"
control_replace scripts/lib/cache.sh 1 \
    '    if (( result_count < existing_count )); then' \
    '    if false; then'
