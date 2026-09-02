# One mutation per Done-when surface, each checked to redden the suite applied
# on its own.
#
# Surface 1 has two halves — the redirect winning, and a bad root being refused
# rather than ignored — and one control cannot pin them separately. The only
# mutation that isolates the refusal while leaving valid roots working is
# `    if [[ -d "${LINEAR_CACHE_ROOT:-/nonexistent}" ]]; then`, which reddens
# exactly section C and leaves A, B, D and E green; it lands on the same line as
# mutation 1, and the harness runs one control per suite. So mutation 1 carries
# both of surface 1's assertions.

# 1. The caller's root wins. Take the redirect out of the resolver, leaving
#    whatever the process is standing in to decide, so a suite asking for a
#    cache of its own is overruled by the repository it runs in.
control_expect "LINEAR_CACHE_ROOT outranks the repository the process is standing in"
control_expect "the refusal names the variable and the path it was given"
control_replace scripts/lib/cache.sh 1 \
    '    if [[ -n "${LINEAR_CACHE_ROOT+x}" ]]; then' \
    '    if false; then'

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
