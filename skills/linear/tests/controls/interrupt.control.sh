# The job's TERM trap, back to the default: the job dies on the runner's TERM
# and its body, and the suite under it, run on to the cap. The body's own trap
# in timed_suite is the next link of the same chain, and the suite's assertion
# reddens on either.
control_expect "a TERM to the runner stops the suite it is running"
control_replace tests/must-fail-controls.sh 1 \
	'	trap '"'"'[[ -z $body ]] || kill -TERM "$body" 2>/dev/null'"'"' TERM' \
	'	trap - TERM'
