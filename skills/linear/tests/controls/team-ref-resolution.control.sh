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

# Each team-filtered read filters on the raw reference as a team name again,
# so the team key reads empty on that surface alone.
control_expect "statuses list: KEN sends the kendex team id"
control_replace scripts/commands/statuses.sh 1 \
    '        filter_json=$(jq -cn --arg id "$team_id" '"'"'{team: {id: {eq: $id}}}'"'"')' \
    '        filter_json=$(jq -cn --arg id "$team" '"'"'{team: {name: {eq: $id}}}'"'"')'

control_expect "statuses get: KEN sends the kendex team id"
control_replace scripts/commands/statuses.sh 1 \
    '        filter_json=$(jq -cn --arg id "$team_id" --argjson base "$filter_json" '"'"'$base + {team: {id: {eq: $id}}}'"'"')' \
    '        filter_json=$(jq -cn --arg id "$team" --argjson base "$filter_json" '"'"'$base + {team: {name: {eq: $id}}}'"'"')'

control_expect "issues list: KEN sends the kendex team id"
control_replace scripts/lib/common.sh 1 \
    '        filter_parts+=("$(jq -cn --arg v "$team_id" '"'"'{team: {id: {eq: $v}}}'"'"')")' \
    '        filter_parts+=("$(jq -cn --arg v "$team" '"'"'{team: {name: {eq: $v}}}'"'"')")'

control_expect "projects list: KEN sends the kendex team id"
control_replace scripts/commands/projects.sh 1 \
    '        filter_parts+=("$(jq -cn --arg v "$team_id" '"'"'{accessibleTeams: {some: {id: {eq: $v}}}}'"'"')")' \
    '        filter_parts+=("$(jq -cn --arg v "$team" '"'"'{accessibleTeams: {some: {name: {eq: $v}}}}'"'"')")'

control_expect "labels list: KEN sends the kendex team id"
control_replace scripts/commands/labels.sh 1 \
    '        filter_json=$(jq -cn --arg id "$team_id" '"'"'{team: {id: {eq: $id}}}'"'"')' \
    '        filter_json=$(jq -cn --arg id "$team" '"'"'{team: {name: {eq: $id}}}'"'"')'

# Drop the state-name filter when the team id merges in: statuses get answers
# the team's first state instead of the one named.
control_expect "statuses get: KEN keeps the state name beside the team"
control_replace scripts/commands/statuses.sh 1 \
    '        filter_json=$(jq -cn --arg id "$team_id" --argjson base "$filter_json" '"'"'$base + {team: {id: {eq: $id}}}'"'"')' \
    '        filter_json=$(jq -cn --arg id "$team_id" --argjson base "$filter_json" '"'"'{team: {id: {eq: $id}}}'"'"')'

# Accept an empty --team value: each read sends no team filter and reads every
# team.
control_expect "issues list: empty --team sends no request"
control_expect "projects list: empty --team sends no request"
control_expect "labels list: empty --team sends no request"
control_expect "statuses list: empty --team sends no request"
control_expect "statuses get: empty --team sends no request"
control_replace scripts/lib/common.sh 1 \
    '    "")' \
    '    " ")'

# Accept a dash-led --team value: the next flag binds as the team.
control_expect "issues list: dash-led --team sends no request"
control_expect "projects list: dash-led --team sends no request"
control_expect "labels list: dash-led --team sends no request"
control_expect "statuses list: dash-led --team sends no request"
control_expect "statuses get: dash-led --team sends no request"
control_replace scripts/lib/common.sh 1 \
    '    -*)' \
    '    -\*)'
