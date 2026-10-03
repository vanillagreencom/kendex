# Resolve a team-id label lookup with no team scope: the first same-name label
# the API lists wins, whichever team owns it, before and after the upload.
control_expect "key: create sends the kendex team and its label ids"
control_expect "app: create sends the kendex team and its label ids"
control_expect "uuid: create sends only workspace labels for a team that owns none"
control_expect "attach: no upload is sent for another team's agent label"
control_replace scripts/lib/common.sh 1 \
    '        query='"'"'query GetLabel($name: String!, $teamId: ID!) { issueLabels(filter: {name: {eq: $name}, or: [{team: {id: {eq: $teamId}}}, {team: {null: true}}]}) { nodes { id } } }'"'" \
    '        query='"'"'query GetLabel($name: String!, $teamId: ID!) { issueLabels(filter: {name: {eq: $name}}) { nodes { id } } }'"'"

# Classify a team reference by a lowercase-only grammar again: an uppercase
# team UUID becomes a name to look up instead of the id the create sends.
control_expect "uuid: no team lookup, and the create and its label lookups send the one team id"
control_replace scripts/lib/common.sh 1 \
    '    if [[ "$team_ref" =~ $LINEAR_UUID_PATTERN ]]; then' \
    '    if [[ "$team_ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then'

# Carry on past an unknown team: the label lookups and the upload run before
# anything names the real fault.
control_expect "unknown-team: no label lookup or upload is sent"
control_replace scripts/commands/issues.sh 1 \
    '    team_id=$(resolve_team_id "$team") || return 1' \
    '    team_id=$(resolve_team_id "$team") || :'

# Read a failed label lookup as a label proved absent: the create skips the
# label and goes ahead without it.
control_expect "lookup-failed: no issueCreate is sent"
control_replace scripts/commands/issues.sh 1 \
    '            1)' \
    '            1 | 2)'
