# Post the caller's summary without the canonical heading. validate-completion
# detects a summary by that marker, so a completion comment goes up that the
# pre-merge check cannot see.
control_expect "an inline summary is prefixed with the canonical heading"
control_replace scripts/commands/issues.sh 1 \
    "            summary=\"## Completion Summary\"\$'\\n\\n'\"\$summary\"" \
    '            :'

control_expect "complete ids split prints only the identifier"
control_expect "complete ids equals prints only the identifier"
control_replace scripts/commands/issues.sh 3 \
    '    if [ "$output_format" = "ids" ]; then' \
    '    if [ "$output_format" = "bogus" ]; then'

control_expect "complete invalid format split sends no request"
control_expect "complete invalid format equals sends no request"
control_replace scripts/commands/issues.sh 4 \
    '            linear_require_format "$output_format" ids || return 1' \
    '            linear_require_format "$output_format" ids || :'

control_expect "partial complete ids split fails"
control_expect "partial complete ids equals fails"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$update_rc" -ne 0 ] || [ "$update_success" != "true" ]; then' \
    '    if false; then'

control_expect "partial complete ids split reports the failure on stderr"
control_expect "partial complete ids equals reports the failure on stderr"
control_replace scripts/commands/issues.sh 1 \
    '        complete_issue "$@"' \
    '        complete_issue "$@" 2>/dev/null'
