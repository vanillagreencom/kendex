# Set Done without the ticked description: the boxes the caller verified stay
# unchecked, and reconcile-work-items reports the close as done-unchecked.
control_expect "the Done update carries the ticked description"
control_replace scripts/commands/issues.sh 1 \
    '            update_args+=(--description "${ticked_description%.}")' \
    '            :'

# Let the section run past the next heading: a box under another heading
# ticks as if the caller had verified it.
control_expect "a box outside the Done-when section stays unchecked"
control_replace scripts/commands/issues.sh 1 \
    '             elif ($line | startswith("## ")) then .section = false' \
    '             elif false then .section = false'

# Tick every open box whatever the caller named: a partly met item closes
# with its unmet boxes checked.
control_expect "an unnamed box stays unchecked"
control_replace scripts/commands/issues.sh 1 \
    '                | if ($line | test("^\\s*[-*] \\[ \\]")) and ($met == "all" or (.boxes as $n | $met | any(.[]; . == $n)))' \
    '                | if ($line | test("^\\s*[-*] \\[ \\]"))'

# Drop the missing-box refusal: a box number the section does not hold
# completes the issue as if it named a met box.
control_expect "a box number past the section refuses before any write"
control_replace scripts/commands/issues.sh 1 \
    '        if [ "$missing_count" -ne 0 ]; then' \
    '        if false; then'

# Accept any value as a box list: box 0 reaches the issue read.
control_expect "--done-when-met '0' refuses before any request"
control_replace scripts/commands/issues.sh 1 \
    '        elif [[ "$done_when_met" =~ ^[1-9][0-9]{0,3}(,[1-9][0-9]{0,3})*$ ]]; then' \
    '        elif true; then'
