# The opening check. Without it a body opening with `**Source**:` or
# `Reached by:` files, on create and update alike.
control_expect "a create opening with a **Source**: line is refused"
control_expect "a create whose first non-empty line is Reached by: is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'		  elif ($lines | map(select($first != null and .line >= $first.line) | .text) | join("\n") | opening | not) then' \
	'		  elif false then'
