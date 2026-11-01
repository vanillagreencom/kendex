# Drop ownerId while leaving the initiative create runnable.
control_expect 'initiatives-create-ownerId-11111111-2222-3333-4444-555555555555: native field'
control_replace scripts/commands/initiatives.sh 2 \
    '        input_json=$(jq -c --arg id "$resolved" '\''. + {ownerId: $id}'\'' <<<"$input_json") || return 1' \
    '        input_json=$(jq -c --arg id "$resolved" '\''. + {ownerId: $id} | del(.ownerId)'\'' <<<"$input_json") || return 1'
