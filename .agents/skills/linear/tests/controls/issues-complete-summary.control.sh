# Post the caller's summary without the canonical heading. validate-completion
# detects a summary by that marker, so a completion comment goes up that the
# pre-merge check cannot see.
control_expect "an inline summary is prefixed with the canonical heading"
control_replace scripts/commands/issues.sh 1 \
    "            summary=\"## Completion Summary\"\$'\\n\\n'\"\$summary\"" \
    '            :'
