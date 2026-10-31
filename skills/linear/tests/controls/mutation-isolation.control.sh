# The runner's verdict: a mutation is judged on the assertion it named, matched
# whole against one line of the suite's output.
control_expect "the misnamed report names the mutation and the assertion"
control_replace tests/must-fail-controls.sh 1 \
	'				if [[ "$line" == "FAIL: ${wanted[i]}" ]]; then' \
	'				if false; then'

# The suite cap, an instrument no verdict mutation reddens: a hung suite that
# ignores TERM runs past the cap, and with every suite like it the job runs to
# its limit and is cancelled with no verdict.
control_expect "the mutation cap kills a suite that ignores TERM: KILL completes at cap plus grace"
control_replace tests/must-fail-controls.sh 1 \
	'			stop_tree "$tree"' \
	'			:'
