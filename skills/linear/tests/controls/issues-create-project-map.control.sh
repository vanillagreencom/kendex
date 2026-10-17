# Let a create with no project through the preflight: it reaches Linear.
control_expect "create-no-project: the refusal is keyed"
control_expect "create-no-project: refused before any request"
control_replace scripts/commands/issues.sh 1 \
    '        [[ "$action" == create ]] || return 0' \
    '        return 0'

# Leave an off-map name to the live check: the refusal costs a read.
control_expect "create-off-map: refused before any request"
control_expect "create-off-map: map reads"
control_replace scripts/commands/issues.sh 1 \
    '    [[ ! "$ref" =~ $LINEAR_UUID_PATTERN ]] || return 0' \
    '    return 0'

# Drop the update and bulk-update preflight.
control_expect "update-off-map: map reads"
control_expect "bulk-off-map: map reads"
control_replace scripts/commands/issues.sh 2 \
    '        linear_map_preflight "$project_map" "$project" update || return 1' \
    '        :'

# Resolve a create's project without the map: an off-map UUID is written and
# a map project the team lacks refuses unkeyed.
control_expect "create-off-map-uuid: refused"
control_expect "create-off-map-uuid: no write is sent"
control_expect "create-missing: the refusal is keyed"
control_replace scripts/commands/issues.sh 1 \
    '        project_id=$(linear_map_live "$project_map" "$project" "$team_id") || return 1' \
    '        project_id=$(resolve_project_id "$project" "$team_id") || return 1'

# Resolve an existing issue's project without the map.
control_expect "update-off-map-uuid: refused"
control_expect "update-off-map-uuid: no write is sent"
control_expect "update-on-map: map reads"
control_replace scripts/commands/issues.sh 1 \
    '        id=$(linear_map_live "$map" "$ref" "$team_id") || return 1' \
    '        id=$(resolve_project_id "$ref" "$team_id") || return 1'

# Skip bulk-update's live check: each update_issue reads the map itself, and
# the issues before a refused one are written.
control_expect "bulk-off-map-uuid: map reads"
control_replace scripts/commands/issues.sh 1 \
    '                issue_project_id "$project_map" "$project" "$team_id" "$id" || return 1' \
    '                :'

# Forget the project each team resolved: every issue reads the map again.
control_expect "bulk-on-map: map reads"
control_replace scripts/commands/issues.sh 1 \
    '    LINEAR_ISSUE_PROJECT_IDS[$key]="$id"' \
    '    :'

# Key the resolved project by its ref alone: the first issue's team passes it
# for every issue, in the name form and the UUID form.
control_expect "bulk-mixed-team-missing: refused"
control_expect "bulk-mixed-team-missing: the refusal is keyed"
control_expect "bulk-mixed-team-missing: map reads"
control_expect "bulk-mixed-team-uuid: refused"
control_expect "bulk-mixed-team-uuid: no write is sent"
control_replace scripts/commands/issues.sh 1 \
    '    local map="$1" ref="$2" team_id="$3" issue="$4" key="$3:$2" id' \
    '    local map="$1" ref="$2" team_id="$3" issue="$4" key="$2" id'

# With no team set, judge the project across the workspace: another team's
# project of the map name passes and is written.
control_expect "bulk-no-team-missing: refused"
control_expect "bulk-no-team-missing: the refusal is keyed"
control_expect "bulk-no-team-missing: no write is sent"
control_replace scripts/commands/issues.sh 1 \
    '        id=$(linear_map_live "$map" "$ref" "$team_id") || return 1' \
    '        id=$(linear_map_live "$map" "$ref" "${DEFAULT_TEAM:+$team_id}") || return 1'

# Read the space form's option name as the project.
control_expect "bulk-on-map-space: accepted"
control_expect "bulk-on-map-space: the write carries the map project"
control_replace scripts/commands/issues.sh 1 \
    '            [[ "$1" != --project ]] || project="$2"' \
    '            [[ "$1" != --project ]] || project="$1"'

# Read every team's projects: another team's project passes for the map's.
control_expect "create-missing: refused"
control_expect "create-missing: no write is sent"
control_replace scripts/lib/common.sh 1 \
    "        query='query ProjectMap(\$names: [String!], \$teamId: ID!, \$after: String) { projects(filter: {name: {in: \$names}, accessibleTeams: {some: {id: {eq: \$teamId}}}}, first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id name state targetDate } } }'" \
    "        query='query ProjectMap(\$names: [String!], \$teamId: ID!, \$after: String) { projects(filter: {name: {in: \$names}}, first: 100, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id name state targetDate } } }'"

# Accept a standing project carrying a deliverable's fields.
control_expect "invalid: refused"
control_expect "invalid: the refusal is keyed"
control_replace scripts/lib/common.sh 1 \
    '                        and (has("ends_when") | not) and (has("initiative") | not)))))' \
    '                        and true))))'

# Take the first of two live projects of one name.
control_expect "create-twin: refused"
control_expect "create-twin: no write is sent"
control_replace scripts/commands/issues.sh 1 \
    "    1) jq -r '.id' <<<\"\$entry\" ;;" \
    "    [1-9]*) jq -r '.id' <<<\"\$entry\" ;;"
