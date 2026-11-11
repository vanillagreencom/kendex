# Drop the write refusal: a box under ## Post-merge files on every verb.
control_expect "write check refuses post-merge-heading"
control_expect "create refuses a box under ## Post-merge"
control_expect "update refuses a box under ## Post-merge"
control_expect "bulk-update refuses a box under ## Post-merge"
control_replace scripts/lib/issue-validation.sh 1 \
	'		  elif $outside != null then' \
	'		  elif false then'

# Drop the completion refusal: the item is held only by the parser's state,
# under a refusal that names no outside box.
control_expect "complete names the post-merge-heading box"
control_expect "complete names the bare box"
control_replace scripts/commands/issues.sh 1 \
	"    if jq -e 'any(.outside_boxes[]; .checked | not)' <<<\"\$tick\" >/dev/null; then" \
	'    if false; then'

# Leave outside boxes out of the parser's completion state: its other
# readers, the started bundle child's pre-merge check among them, would
# accept an item complete refuses.
control_expect "parser holds post-merge-heading from completion"
control_expect "started bundle child post-merge-heading state_ok is false"
control_replace scripts/lib/issue-validation.sh 1 \
	'                or any(.outside_boxes[]; .checked | not) then null' \
	'                or false then null'

# Never open a fence: a fenced example box is refused and holds completion.
control_expect "write check files backtick-fence"
control_replace scripts/lib/issue-validation.sh 1 \
	'              elif $run != null then .fence = $run' \
	'              elif false then .fence = $run'

# Never close a fence: a box after the fence goes unread.
control_expect "write check refuses after-fence"
control_replace scripts/lib/issue-validation.sh 1 \
	'                    and ($line | test("^[ \\t]*[`~]+[ \\t]*$")) then .fence = null else . end)' \
	'                    and ($line | test("^[ \\t]*[`~]+[ \\t]*$")) then . else . end)'

# Close a fence on a shorter run: a box inside a longer fence is refused.
control_expect "write check files tilde-fence"
control_replace scripts/lib/issue-validation.sh 1 \
	'                (if $run != null and $run[0:1] == .fence[0:1] and ($run | length) >= (.fence | length)' \
	'                (if $run != null and $run[0:1] == .fence[0:1]'

# Read every outside box as open: a ticked one holds completion.
control_expect "complete accepts checked"
control_replace scripts/lib/issue-validation.sh 1 \
	'                .outside += [{line: ($i + 1), checked: ($line | test("^\\s*[-*] \\[[xX]\\]")),' \
	'                .outside += [{line: ($i + 1), checked: false,'
