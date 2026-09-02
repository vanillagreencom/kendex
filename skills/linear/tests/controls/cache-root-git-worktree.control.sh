# Take the cache root from the caller's logical working directory instead of
# the git worktree root. Reached through a symlinked checkout the two disagree,
# and the cache path — including the one the missing-cache diagnostic reports —
# follows the link.
control_expect "logical installed invocation: the missing-cache diagnostic names the physical cache path"
control_replace scripts/lib/cache.sh 1 \
    'CACHE_PROJECT_ROOT="$(linear_cache_project_root)"' \
    'CACHE_PROJECT_ROOT="$PWD"'
