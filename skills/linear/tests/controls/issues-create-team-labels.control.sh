# Resolve create labels with no team scope: the first same-name label the API
# lists wins, whichever team owns it.
control_expect "key: create sends the kendex team and its label ids"
control_expect "app: create sends the kendex team and its label ids"
control_replace scripts/commands/issues.sh 1 \
    '            if label_id=$(resolve_label_id "$label_name" "$team"); then' \
    '            if label_id=$(resolve_label_id "$label_name"); then'
