# Take the lock out from under every collection rewrite. The merge and the
# write-through then run side by side: the write-through renames its result
# in during the merge's stall, and the merge's rename discards it.
control_expect "the write-through survives a concurrent merge"
control_replace scripts/lib/cache.sh 1 \
    '        if ! flock 201; then' \
    '        if ! true; then'
# Install the delta over a cache that no longer parses, the fail-open the
# merge once had: a delta's worth of issues then reads as the whole set and
# the sync reports completion.
control_expect "a corrupt issue cache fails the sync"
control_replace scripts/lib/cache.sh 1 \
    '        cache_unreadable_error "$existing"' \
    '        cache_install_output "$existing" cat "$delta_file"; return 0'
