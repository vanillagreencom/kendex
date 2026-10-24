# Mutations exercise independent diagnostic and compatibility guarantees in
# the real create/update/bulk routes. Header-first refusal is also covered by
# the structural opening check; its diagnostic remains protected by the suite.
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
	'			| {line: (.key + 1), length: (.value | header_text | length), text: .value}] as $lines' \
	'			| {line: (.key + 1), length: (.value | header_text | utf8bytelength), text: .value}] as $lines'

# 5. The update wiring. Without it an update rewrites a body into the shape a
#    create refuses.
control_expect "an update --description-file with a 501-character header is refused"
control_replace scripts/commands/issues.sh 1 \
	'        require_issue_header_shape "$description" "${stored_description%.}" || return 1' \
	'        :'

# 6. The complete exemption. Without it an issue filed before the guard can
#    never have its Done-when boxes ticked.
control_expect "a complete ticking a body that opens with a long header exits zero"
control_replace scripts/commands/issues.sh 1 \
	"        update_result=\$(LINEAR_REQUIRE_REACH='' update_issue \"\$issue_id\" \"\${update_args[@]}\")" \
	'        update_result=$(update_issue "$issue_id" "${update_args[@]}")'

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

# 9. Bulk preflight. Keeping the per-issue check still sends a team lookup
#    and nests the structured refusal inside the bulk results.
control_expect "a bulk-update split opening description refuses before any API call"
control_expect "a bulk-update equals long description names the rule, the line and its length"
control_replace scripts/commands/issues.sh 1 \
	'    [[ "$description_set" != "true" ]] || require_issue_header_shape "$description" || return 1' \
	'    [[ "$description_set" != "true" ]] || :'

control_expect 'create refuses release v* with +72h'
control_replace scripts/lib/issue-validation.sh 1 \
	'			| if (.trigger | test("^release(?: |$)")) and .trigger_kind != "release" then' \
	'			| if false then'

control_expect 'update refuses merge with set at merge'
control_replace scripts/lib/issue-validation.sh 1 \
	'			  elif .deadline_rule != null then' \
	'			  elif false then'

control_expect "an owner action before the outcome exits zero"
control_replace scripts/lib/issue-validation.sh 1 \
	'		| ($content | if length > 0 and (.[0].text | owner_action) then .[1:] else . end | first) as $first' \
	'		| ($content | first) as $first'

control_expect "an owner-shaped opening **Brad, what you do:** Run the check. Comment the result. followed by a header names the rule, the line and its length"
control_replace scripts/lib/issue-validation.sh 1 \
	'		| ($content | if length > 0 and (.[0].text | owner_action) then .[1:] else . end | first) as $first' \
	'		| ($content | if length > 0 and (.[0].text | owner_action) then [] else . end | first) as $first'

# The stored-body exemption. Without it an owner ask over a body filed
# header-first, and the rollback or close writing that body back, are refused.
control_expect "an owner ask over a stored body opening with **Source**: exits zero"
control_expect "the rollback or close writing the stored body back without the action line exits zero"
control_replace scripts/lib/issue-validation.sh 1 \
	'		| if $moves_action then' \
	'		| if false then'

# The exemption's one check. Without it an owner action of any length is
# written over an unchanged stored body.
control_expect "a 501-character owner action over the unchanged stored body is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'			([$lines[:1][] | select((.text | owner_action) and .length > $max) | long_header($max)] | first // empty)' \
	'			empty'

# Missing quoted blocks must reach the structural refusal through the real
# create entry point, independently of the older header-first refusal.
control_expect "create refuses missing-why opening"
control_replace scripts/lib/issue-validation.sh 1 \
	'		  elif $opening_ok | not then' \
	'		  elif false then'
