# Restore the old update decision: a completed-type state ignores open boxes.
control_expect "update refuses"
control_replace scripts/commands/issues.sh 1 \
    '        if [ "$state_type" = completed ]; then' \
    '        if false; then'

# Restore the evidence bypass while retaining the open-box refusal.
control_expect "blank-evidence refuses"
control_replace scripts/commands/issues.sh 1 \
    '            if [ "$missing_evidence_boxes" != '\''[]'\'' ]; then' \
    '            if false; then'

# Check each item only as it is written: the first eligible item changes before
# a later open checklist refuses, which loses the whole-batch guarantee.
control_expect "bulk writes nothing"
control_replace scripts/commands/issues.sh 1 \
    '        [ "$preflight_failed" = 0 ] || return 1' \
    '        :'

# Remove only the canceled-type refusal so the mocked API receives the unsafe
# cancellation, without touching the descendant reader or the existing guards.
control_expect "cancel-child writes nothing"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$state_type" = canceled ]; then' \
    '    if false; then'
