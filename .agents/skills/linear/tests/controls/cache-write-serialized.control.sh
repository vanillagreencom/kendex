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
# Install the full sync's pull without the issue cache's lock. The
# write-through renames its result in during the install's stall, and the
# install's rename discards it.
control_expect "the write-through survives a concurrent full sync"
control_replace scripts/commands/sync.sh 1 \
    '        if ! cache_write "issues.json" jq '"'"'[.[]' \
    '        if ! cache_install_output "$CACHE_DIR/issues.json" jq '"'"'[.[]'
# Mask the write-through command's failure: jq's empty output over a corrupt
# cache is then installed as the cache, and the write-through reports success.
control_expect "a failing write-through leaves the cache byte for byte as it was"
control_replace scripts/lib/cache.sh 1 \
    '    if ! "$@" > "$tmp"; then' \
    '    "$@" > "$tmp" || true; if false; then'
# Write the command's output straight into the target instead of a temp file
# renamed into place. The shell truncates the target as the command starts,
# so the write-through's jq reads an empty cache and the merge's delta is
# gone from what it writes back.
control_expect "the merge delta survives a concurrent write-through"
control_replace scripts/lib/cache.sh 1 \
    '    if ! "$@" > "$tmp"; then' \
    '    rc=0; "$@" > "$target" || rc=$?; rm -f -- "${tmp:?}"; return "$rc"; if false; then'
