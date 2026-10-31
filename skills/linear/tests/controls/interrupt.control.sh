# The job's TERM trap, back to the default: the job dies on the runner's TERM
# and its body, and the suite under it, run on to the cap. The body's own trap
# in timed_suite is the next link of the same chain, and the suite's assertion
# reddens on either. The capture under the miss names the job as the step the
# stop never reached.
control_expect "a TERM to the runner stops the suite it is running"
control_expect "a missed TERM stop names its first missing step: job-term"
control_replace tests/must-fail-controls.sh 1 \
	'	trap '"'"'suite_trace "job TERM body=[$body]"; [[ -z $body ]] || { kill -TERM "$body" 2>/dev/null; suite_trace "job forwarded body=$body rc=$?"; }'"'"' TERM' \
	'	trap - TERM'

# No grace past the next whole second: the KILL can land inside the fixture's
# half-second trap, before it writes the stop mark. suite-process.sh's stop
# bound of SECONDS + STOP_GRACE did the same with the grace at one second.
control_expect "a missed TERM stop names its first missing step: fixture-mark"
control_replace tests/must-fail-controls.sh 1 \
	'SUITE_KILL_GRACE=1' \
	'SUITE_KILL_GRACE=0'
