# Drop ownerId while leaving the initiative create runnable.
control_expect 'initiatives-create-ownerId-11111111-2222-3333-4444-555555555555: native field'
control_replace scripts/commands/initiatives.sh 2 \
    '        input_json=$(jq -c --arg id "$resolved" '\''. + {ownerId: $id}'\'' <<<"$input_json") || return 1' \
    '        input_json=$(jq -c --arg id "$resolved" '\''. + {ownerId: $id} | del(.ownerId)'\'' <<<"$input_json") || return 1'

# An unknown initiative label must stop the write.
control_expect 'initiatives-create-labelIds-refused: refuses'
control_replace scripts/lib/common.sh 1 \
    '        if [[ -z "$id" ]]; then' \
    '        if false; then'

# A malformed --link must stop before the entity write.
control_expect 'initiatives-create-link: malformed link makes no write'
control_replace scripts/lib/common.sh 1 \
    '    if [[ "$value" != *=* || -z "${value%%=*}" || -z "${value#*=}" ]]; then' \
    '    if false; then'

# Repeating the URL must skip the link mutation.
control_expect 'initiatives-create-link: repeat skips URL'
control_replace scripts/lib/common.sh 1 \
    '        if jq -e --arg url "$url" '\''any(.[]; .url == $url)'\'' <<<"$existing" >/dev/null; then' \
    '        if false; then'

# A successful entity write followed by a refused link is a partial write.
control_expect 'initiatives-create-link-fail-link: partial write'
control_replace scripts/lib/common.sh 1 \
    '            jq -c --argjson link "$link" '\''. + {partial: true, failed_link: $link}'\'' <<<"$normalized"' \
    '            jq -c --argjson link "$link" '\''. + {partial: true, failed_link: $link} | del(.partial)'\'' <<<"$normalized"'

# Native leadId is required independently of initiative ownerId.
control_expect 'projects-create-leadId-11111111-2222-3333-4444-555555555555: native field'
control_replace scripts/commands/projects.sh 2 \
    '        input_parts+=("\"leadId\": $resolved")' \
    '        input_parts+=("\"description\": $resolved")'

control_expect 'initiatives-create-leadTeamId-team-id: native field'
control_replace scripts/commands/initiatives.sh 2 \
    '        input_json=$(jq -c --arg id "$resolved" '\''. + {leadTeamId: $id}'\'' <<<"$input_json") || return 1' \
    '        input_json=$(jq -c --arg id "$resolved" '\''. + {leadTeamId: $id} | del(.leadTeamId)'\'' <<<"$input_json") || return 1'

control_expect 'initiatives-create-link: failed entity makes no link'
control_replace scripts/lib/common.sh 1 \
    '    if ! jq -e '\''.success == true'\'' <<<"$normalized" >/dev/null; then' \
    '    if false; then'

control_expect 'initiatives-create-link-false-link: partial write'
control_replace scripts/lib/common.sh 1 \
    '            || ! jq -e '\''.entityExternalLinkCreate.success == true'\'' <<<"$reply" >/dev/null; then' \
    '            || ! true; then'

control_expect 'initiatives: later-page duplicate skips'
control_replace scripts/lib/pages.sh 1 \
    '    project:externalLinks|initiative:links) printf '\''%s'\'' '\''id label url'\'' ;;' \
    '    project:externalLinks|initiative:links) printf '\''%s'\'' '\''id label'\'' ;;'

# Native owner and lead IDs must be verified before writes.
control_expect 'initiatives-create-ownerId-refused: refuses'
control_replace scripts/lib/common.sh 1 \
    '        if [[ "$role" == Assignee ]]; then' \
    '        if true; then'

# Each requested link keeps its own label and URL.
control_expect 'initiatives-create-link: parent and URL'
control_replace scripts/lib/common.sh 1 \
    '        vars=$(jq -cn --arg key "${entity}Id" --arg id "$id" --argjson link "$link" '\''{input: ($link + {($key): $id})}'\'') || return 1' \
    '        vars=$(jq -cn --arg key "${entity}Id" --arg id "$id" --argjson link "$link" --argjson links "$links" '\''{input: ($links[0] + {($key): $id})}'\'') || return 1'

# Project reads use Linear's externalLinks field.
control_expect 'projects-list: succeeds'
control_replace scripts/commands/projects.sh 1 \
    '                externalLinks(first: 10) { pageInfo { hasNextPage endCursor } nodes { id label url } }' \
    '                links(first: 10) { pageInfo { hasNextPage endCursor } nodes { id label url } }'
