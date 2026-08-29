# Take the ancestor case out of the violation message. An ancestor pair is then
# explained as a bundle-peer mismatch, losing the one statement that says the
# hierarchy already encodes the dependency.
control_expect "missing ancestor explanation"
control_replace scripts/lib/issue-validation.sh 1 \
    '	if [[ -n "$ancestor" ]]; then' \
    '	if false; then'
