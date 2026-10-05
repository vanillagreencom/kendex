# Let a create with no agent:* label through. Under a declared taxonomy the
# create prints a URL and looks like success while the issue sits invisible to
# every agent — the outcome the guard exists to prevent.
control_expect "bare create is refused"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$agent_matched" != "1" ]; then' \
    '    if false; then'

# Read no agent set from the taxonomy. A consumer that declares a taxonomy and
# leaves LINEAR_AGENT_LABELS unset then files unrouted issues.
control_expect "a declared taxonomy with no key refuses a bare create"
control_expect "a declared taxonomy with no key refuses a typoed agent label"
control_replace scripts/commands/issues.sh 1 \
    '        declared=$(linear_taxonomy_agent_labels) || return 1' \
    '        declared=""'

# Read an empty key as unset. A project that turned the refusal off has it
# back from its taxonomy.
control_expect "a declared taxonomy with an empty key leaves a bare create alone"
control_replace scripts/commands/issues.sh 1 \
    '    if [ -n "${LINEAR_AGENT_LABELS+x}" ]; then' \
    '    if [ -n "${LINEAR_AGENT_LABELS:+x}" ]; then'

# Pass a taxonomy the CLI cannot read as one listing no agent labels.
control_expect "an unreadable taxonomy with no key refuses a bare create"
control_replace scripts/commands/issues.sh 1 \
    '        declared=$(linear_taxonomy_agent_labels) || return 1' \
    '        declared=$(linear_taxonomy_agent_labels) || declared=""'

# Take every category's labels as the agent set, not the agent category's.
control_expect "a taxonomy with no agent category leaves a bare create alone"
control_replace scripts/lib/common.sh 1 \
    "    jq -r '.categories.agent.labels // [] | join(\", \")' <<<\"\$contract\"" \
    "    jq -r '[.categories[].labels // [] | .[]] | join(\", \")' <<<\"\$contract\""

# Drop the opt-out, so a deliberate bare create meets the taxonomy read.
control_expect "--no-agent-label never reads the taxonomy"
control_replace scripts/commands/issues.sh 1 \
    '    [ "$opt_out" = "1" ] && return 0' \
    '    :'
