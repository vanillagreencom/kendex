# One mutation per Done-when surface.
#
# Surface 1 has two halves — the redirect winning, and a bad root being refused
# rather than ignored — and mutation 1 carries both. The mutation that isolates
# the refusal while leaving valid roots working is
# `    if [[ -d "${LINEAR_CACHE_ROOT:-/nonexistent}" ]]; then` on that same
# line. Each mutation gets its own copy now, so two of them may target one
# line; what refuses this one is that it has no assertion of its own to name.
# It reddens 6 assertions and all 6 are among mutation 1's 9, so whichever one
# it declared would already be mutation 1's and the runner would report SHARED.

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

# 3. Lock files do not accumulate. Send the comment-file mutations back to a
#    lock named after the issue, so the .lock beside each comment file returns.
#    The third helper's line is indented differently and would take a second
#    call, which is not a second mutation: alone it reddens nothing this one
#    does not, so the assertion below is the only name it could take and this
#    mutation has already taken it.
control_expect "no lock file is left beside an issue's comment file after comments create"
control_replace scripts/lib/cache.sh 2 \
    '    ) 202>"$CACHE_COMMENTS_LOCK"' \
    '    ) 202>"$comment_file.lock"'
