# Resolve create labels with no team scope: the first same-name label the API
# lists wins, whichever team owns it.
control_expect "key: create sends the kendex team and its label ids"
control_expect "app: create sends the kendex team and its label ids"
control_replace scripts/commands/issues.sh 1 \
    '            label_id=$(resolve_label_id "$label_name" "$team") || label_rc=$?' \
    '            label_id=$(resolve_label_id "$label_name") || label_rc=$?'

# Classify a team reference by a lowercase-only grammar again: an uppercase
# team UUID becomes a name to resolve_team_id and an id to the label lookups.
control_expect "uuid: the create and its label lookups send the one team id"
control_replace scripts/lib/common.sh 1 \
    '    if [[ "$team_ref" =~ $LINEAR_UUID_PATTERN ]]; then' \
    '    if [[ "$team_ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then'

# Resolve the pre-upload agent labels with no team scope: another team's
# same-name label passes, and the asset uploads before the create refuses.
control_expect "attach: no upload is sent for another team's agent label"
control_replace scripts/commands/issues.sh 1 \
    '                    if ! resolve_label_id "$pre_label_name" "$team" >/dev/null; then' \
    '                    if ! resolve_label_id "$pre_label_name" >/dev/null; then'
