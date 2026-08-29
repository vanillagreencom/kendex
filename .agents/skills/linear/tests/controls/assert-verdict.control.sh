# Delete the zero-assertion branch. Every other suite in this skill executes
# assertions and stays green, which is the point: without this control the one
# mechanism the change exists to add would be the one thing it never checked.
control_expect "a suite that executes no assertion fails"
control_replace tests/lib/assert.sh 1 \
    '	if ((ledger_ran == 0)); then' \
    '	if false; then'
