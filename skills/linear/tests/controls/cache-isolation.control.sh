# Four mutations across the issue's three Done-when surfaces. Each was checked
# to redden the suite applied on its own, which is the only way to check the two
# on surface 1: they land on distinct lines, but 1a disables the branch 1b's
# line sits inside, so under the whole control 1b is dead code and 1a is what
# reddens 1b's assertion.

# 1a. The caller's root wins. Take the redirect out of the resolver, leaving
#     whatever the process is standing in to decide, so a suite asking for a
#     cache of its own is overruled by the repository it runs in.
control_expect "LINEAR_CACHE_ROOT outranks the repository the process is standing in"
control_replace scripts/lib/cache.sh 1 \
    '    if [[ -n "${LINEAR_CACHE_ROOT+x}" ]]; then' \
    '    if false; then'

# 1b. The other half of that surface: make the redirect accept a root naming no
#     directory instead of refusing it. The command still fails, on the empty
#     cache it then resolves, so the assertion that catches this is the one
#     reading the refusal itself and not the one reading the exit status.
control_expect "the refusal names the variable and the path it was given"
control_replace scripts/lib/cache.sh 1 \
    '        if ! linear_cache_canonical_existing_dir "$LINEAR_CACHE_ROOT"; then' \
    '        if false; then'

# 2. Every suite is isolated. Disable the assert lib's exit verdict on the
#    redirect, so a suite that ends with it thrown away passes.
control_expect "a suite that ends with the redirect thrown away fails its verdict"
control_replace tests/lib/assert.sh 1 \
    '	if [[ -n "$cache_escape" ]]; then' \
    '	if false; then'

# 3. Lock files do not accumulate. Send every comment-file mutation back to a
#    lock named after the issue, at all three helpers, so the .lock beside each
#    comment file returns.
control_expect "no lock file is left beside an issue's comment file after comments create"
control_replace scripts/lib/cache.sh 2 \
    '    ) 202>"$CACHE_COMMENTS_LOCK"' \
    '    ) 202>"$comment_file.lock"'
control_replace scripts/lib/cache.sh 1 \
    '            ) 202>"$CACHE_COMMENTS_LOCK"' \
    '            ) 202>"$f.lock"'
