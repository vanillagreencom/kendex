# Take the caller's redirect back out of the cache resolver, leaving the
# pre-#799 order: whatever the process is standing in decides, and a suite that
# asks for a cache of its own is overruled by the repository it runs in.
control_expect "LINEAR_CACHE_ROOT outranks the repository the process is standing in"
control_replace scripts/lib/cache.sh 1 \
    '    if [[ -n "${LINEAR_CACHE_ROOT:-}" ]]; then' \
    '    if false; then'
