# Let an unresolved label name be dropped instead of refusing. --labels
# replaces the whole set, so the update then ships a partial set and silently
# strips the labels it could not resolve.
control_expect "unknown label refuses the update"
control_replace scripts/commands/issues.sh 1 \
    '            [ "$label_rc" = 0 ] || return 1' \
    '            [ "$label_rc" = 0 ] || :'

control_expect "update uses live issue-team and workspace label IDs"
control_replace scripts/commands/issues.sh 1 \
    '            label_id=$(resolve_label_id "$label_name" "$team_name") || label_rc=$?' \
    '            label_id=$(resolve_label_id "$label_name") || label_rc=$?'

control_expect "team-missing: no mutation or upload is sent"
control_replace scripts/commands/issues.sh 1 \
    '        if [ -z "$team_name" ]; then' \
    '        if [ -z "$team_name" ] && false; then'

# Refuse an unknown label without saying which team it was looked up in.
control_expect "the refusal names the issue team"
control_replace scripts/commands/issues.sh 1 \
    '            if [ "$label_rc" = 1 ]; then' \
    '            if false; then'
