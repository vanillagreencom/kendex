# Without the invoked directory's orch, a create through a Claude alias of
# the package, with orch copied into Claude's directory alone, files unread.
control_expect "a create through a Claude alias with orch copied for Claude alone is refused before any API call"
control_replace scripts/lib/issue-validation.sh 1 \
	'	for candidate in "$(cd -L "$here" && pwd)" "$(cd -P "$here" && pwd)"; do' \
	'	for candidate in "$(cd -P "$here" && pwd)"; do'

# Without the physical directory's orch, a create through a Claude alias of
# the package, with orch installed only in the shared tree, files unread.
control_expect "a create through a Claude alias with no orch alias is refused before any API call"
control_replace scripts/lib/issue-validation.sh 1 \
	'	for candidate in "$(cd -L "$here" && pwd)" "$(cd -P "$here" && pwd)"; do' \
	'	for candidate in "$(cd -L "$here" && pwd)"; do'

# A change-scope taken from another directory than the orch it serves runs a
# program of a different install, or none.
control_expect "the copied orch's read is given the change-scope beside it"
control_replace scripts/lib/issue-validation.sh 1 \
	'		CHANGE_SCOPE_PATHS_CLI="$skills/change-scope/scripts/harness-only" \' \
	'		CHANGE_SCOPE_PATHS_CLI="$(cd -P "$here" && pwd)/change-scope/scripts/harness-only" \'
