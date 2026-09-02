# Disable the reverse-roster loop's body. The runner then walks the controls
# directory, finds the orphan, and says nothing: every roster case in the
# fixture reports a clean run.
control_expect "a control no suite owns fails the full run"
control_replace tests/must-fail-controls.sh 1 \
	'		if [[ " ${stems[*]} " != *" $stem "* ]]; then' \
	'		if false; then'
