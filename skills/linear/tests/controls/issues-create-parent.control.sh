# Accept the follow-up repair without checking that the parent actually
# attached. `issues create --parent` then reports a child under a parent it may
# not be under.
control_expect "scenario repair-unverified fails"
control_replace scripts/commands/issues.sh 1 \
    '            if [ "$updated_parent_id" != "$requested_parent_id" ]; then' \
    '            if false; then'
