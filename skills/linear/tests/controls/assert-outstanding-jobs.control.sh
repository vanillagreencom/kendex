# Stop failing closed on a background job that is still running. Its assertion
# lands after the totals are computed and after the ledger is removed, so a
# failure there is discarded rather than merely late — the verdict reports the
# assertions it happened to see in time.
control_expect "a suite that ends with a background job still running fails"
control_replace tests/lib/assert.sh 1 \
    '	if [[ -n "${outstanding// /}" ]]; then' \
    '	if false; then'
