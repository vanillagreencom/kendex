# Let a create with no agent:* label through. Under a declared taxonomy the
# create prints a URL and looks like success while the issue sits invisible to
# every agent — the outcome the guard exists to prevent.
control_expect "bare create is refused"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$agent_matched" != "1" ]; then' \
    '    if false; then'
