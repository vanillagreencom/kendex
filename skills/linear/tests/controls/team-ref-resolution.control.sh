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
