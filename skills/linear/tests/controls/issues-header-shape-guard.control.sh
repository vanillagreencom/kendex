# One mutation per branch the guard makes, each written against the file as it
# ships. Mutations 1 and 2 are the issue's must-fail control: without them the
# validator accepts both refused bodies, as it did before the guard.
#
# 1. The opening check. Without it a body opening with `**Source**:` or
#    `Reached by:` files, on create and update alike.
control_expect "a create opening with a **Source**: line is refused"
control_expect "a create whose first non-empty line is Reached by: is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'		| if $first != null and ($first.text | header) then' \
	'		| if false then'

# 2. The length check. Without it a header of any length files.
control_expect "a create with a 501-character **Symptom**: line is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'		| ([$lines[] | select((.text | header) and .length > $max)] | first) as $long' \
	'		| null as $long'

# 3. The bound. Read as inclusive, a header of exactly 500 characters is
#    refused.
control_expect "a create with a 500-character header line exits zero"
control_replace scripts/lib/issue-validation.sh 1 \
	'		| ([$lines[] | select((.text | header) and .length > $max)] | first) as $long' \
	'		| ([$lines[] | select((.text | header) and .length >= $max)] | first) as $long'

# 4. The unit. Counted in bytes, a short header in a non-Latin script is
#    refused.
control_expect "a create whose header is under 500 characters and over 500 bytes exits zero"
control_replace scripts/lib/issue-validation.sh 1 \
	'			| {line: (.key + 1), length: (.value | length), text: .value}] as $lines' \
	'			| {line: (.key + 1), length: (.value | utf8bytelength), text: .value}] as $lines'

# 5. The update wiring. Without it an update rewrites a body into the shape a
#    create refuses.
control_expect "an update --description-file with a 501-character header is refused"
control_replace scripts/commands/issues.sh 1 \
	'        require_issue_header_shape "$description" || return 1' \
	'        :'

# 6. The complete exemption. Without it an issue filed before the guard can
#    never have its Done-when boxes ticked.
control_expect "a complete ticking a body that opens with a long header exits zero"
control_replace scripts/commands/issues.sh 1 \
	"    update_result=\$(LINEAR_REQUIRE_REACH='' update_issue \"\$issue_id\" \"\${update_args[@]}\")" \
	'    update_result=$(update_issue "$issue_id" "${update_args[@]}")'

# 7. The default. Read as off when unset, every project that never set the key
#    files header-first bodies.
control_expect "with no LINEAR_REQUIRE_REACH key a create opening with a header is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	[[ -n ${LINEAR_REQUIRE_REACH-1} ]] || return 0' \
	'	[[ -n ${LINEAR_REQUIRE_REACH:-} ]] || return 0'

# 8. The off switch. Read as on when empty, a project that turned the reach
#    guard off still has header-first bodies refused.
control_expect "with an empty LINEAR_REQUIRE_REACH a create opening with a header exits zero"
control_replace scripts/lib/issue-validation.sh 1 \
	'	[[ -n ${LINEAR_REQUIRE_REACH-1} ]] || return 0' \
	'	[[ -n ${LINEAR_REQUIRE_REACH:-1} ]] || return 0'
