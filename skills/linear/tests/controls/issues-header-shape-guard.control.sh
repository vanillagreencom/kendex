# The opening check. Without it a body opening with `**Source**:` or
# `Reached by:` files with no advisory, on create and update alike.
control_expect "a create opening with a **Source**: line names its advisory"
control_expect "a create whose first non-empty line is Reached by: names its advisory"
control_replace scripts/lib/issue-validation.sh 1 \
	'			(if ($lines | map(select($first != null and .line >= $first.line) | .text) | join("\n") | opening) then empty' \
	'			(if true then empty'

# Advisory, not refusal. Refusing on any advisory stops a body the filing bar
# only advises on from being written.
control_expect "a create opening with a **Source**: line is written"
control_expect "a create with a 501-character **Symptom**: line is written"
control_replace scripts/lib/issue-validation.sh 1 \
	'	[[ $verdict != "{"* ]]' \
	'	[[ -z $verdict ]]'

# The kept refusal. Without it an invalid post-merge Deadline files.
control_expect "update refuses merge with set at merge"
control_replace scripts/lib/issue-validation.sh 1 \
	'	[[ $verdict != "{"* ]]' \
	'	true'
