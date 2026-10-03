# Drop the key branch from the resolver's filter and keep the name branch: the
# team key matches nothing again on every call site.
control_expect "cycles list: KEN sends the kendex team id"
control_expect "cycles create: KEN sends the kendex team id"
control_expect "issues create: KEN sends the kendex team id"
control_expect "labels create: KEN sends the kendex team id"
control_expect "teams get: KEN sends the kendex team id"
control_replace scripts/lib/common.sh 1 \
    '    local query='"'"'query GetTeam($name: String!) { teams(filter: {or: [{key: {eq: $name}}, {name: {eq: $name}}]}) { nodes { id key name } } }'"'" \
    '    local query='"'"'query GetTeam($name: String!) { teams(filter: {name: {eq: $name}}) { nodes { id key name } } }'"'"

# Take the first of two matching teams instead of refusing the reference.
control_expect "ambiguous: ENG refuses naming both teams"
control_replace scripts/lib/common.sh 1 \
    '        1)' \
    '        [1-9])'

# Keep the ambiguity message and drop the refusal: the resolver warns, returns
# an empty id and the caller sends its request anyway.
control_expect "ambiguous: ENG sends nothing past the team lookup"
control_replace scripts/lib/common.sh 1 \
    '                <<<"$teams" >&2' \
    '                <<<"$teams" >&2; return 0'

# Resolve the update's state through the issue's team name again: ENG is one
# team's key and another's name, so the lookup refuses as ambiguous.
control_expect "issues update --state: sends no team lookup"
control_expect "issues update --state: resolves the state under the issue's own team id"
control_replace scripts/commands/issues.sh 1 \
    '    team_id=$(echo "$issue_result" | jq -r '"'"'.issue.team.id // empty'"'"')' \
    '    team_id=$team_name'
