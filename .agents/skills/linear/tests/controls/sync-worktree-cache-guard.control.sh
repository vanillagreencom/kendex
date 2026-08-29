# Treat a repo with no WORKTREE_SYMLINKS configuration as an opt-out. A
# clobbered worktree cache is then synced in place, re-pulling the full Linear
# history into the worktree instead of the shared cache.
control_expect "an unconfigured repo with a main .cache still refuses"
control_replace scripts/lib/cache.sh 1 \
    '    if [[ -n "${WORKTREE_SYMLINKS:-}" ]]; then' \
    '    if [[ -z "${WORKTREE_SYMLINKS:-}" ]]; then return 1; elif [[ -n "${WORKTREE_SYMLINKS:-}" ]]; then'
