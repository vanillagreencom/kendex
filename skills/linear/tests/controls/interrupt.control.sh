# The job's TERM trap, back to the default: the job dies on the runner's TERM
# and its body, and the suite under it, run on to the cap. The body's own trap
# in timed_suite is the next link of the same chain, and the suite's assertion
# reddens on either. The capture under the miss names the job as the step the
# stop never reached.
control_expect "a TERM to the runner stops the suite it is running"
control_expect "a missed TERM stop names its first missing step: job-term"
control_replace tests/must-fail-controls.sh 1 \
	'	trap '"'"'trace_term "job TERM body=[$body]"; [[ -z $body ]] || kill -TERM "$body" 2>/dev/null'"'"' TERM' \
	'	trap - TERM'
