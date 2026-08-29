# Delete the ledger comparison. The counters alone cannot notice an assertion
# made in a subshell — they are exactly what the subshell copied — so the
# result is silently discarded and a helper that checks nothing reads as one
# that checked.
control_expect "an assertion made in a command substitution fails the suite"
control_replace tests/lib/assert.sh 1 \
    '	if ((lost > 0)); then' \
    '	if false; then'
