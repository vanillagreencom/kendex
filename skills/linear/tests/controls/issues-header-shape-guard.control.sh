# Without the opening check an unexplained authored body files.
control_expect "a create opening with a **Source**: line exits nonzero"
control_expect "a create whose first non-empty line is Reached by: exits nonzero"
control_replace scripts/lib/issue-validation.sh 1 \
	'		  elif ($lines | map(select($first != null and .line >= $first.line) | .text) | join("\n") | opening | not) then' \
	'		  elif false then'

# Advisory, not refusal. Refusing on any advisory stops a body the filing bar
# only advises on from being written.
control_expect "a create with a 501-character **Symptom**: line is written"
control_replace scripts/lib/issue-validation.sh 1 \
	'	[[ $verdict != "{"* ]]' \
	'	[[ -z $verdict ]]'

# The kept refusal. Without it an invalid post-merge Deadline files.
control_expect "update refuses merge with set at merge"
control_replace scripts/lib/issue-validation.sh 1 \
	'	[[ $verdict != "{"* ]]' \
	'	true'

# Without the opening-detail advisory a machine-detail opening files unadvised.
control_expect "opening detail relative-path names its kinds"
control_expect "create advises once per written issue"
control_replace scripts/lib/issue-validation.sh 1 \
	'			($lines | map(select(.line >= $first.line) | .text) | join("\n") | opening_parts | opening_detail_advice($first.line)),' \
	'			empty,'
