# Restore the rule: any issue with a parent expects Done. A
# decomposition child run as the managed top-level session then fails on its
# In Review state, which is exactly the pre-merge state it is meant to hold.
control_expect "case2 parented root In Review"
control_replace scripts/lib/issue-validation.sh 1 \
    '		if completion_state_matches "$state" "$role"; then' \
    '		if completion_state_matches "$state" "$([[ -n "$parent_id" ]] && echo bundle-child || echo "$role")"; then'
