# Resolve a create's project without the map: an off-map UUID is written and
# a map project the team lacks refuses unkeyed.
control_expect "create-off-map-uuid: refused"
control_expect "create-off-map-uuid: no write is sent"
control_expect "create-missing: the refusal is keyed"
control_replace scripts/commands/issues.sh 1 \
    '        project_id=$(linear_map_live "$project_map" "$project" "$team_id") || return 1' \
    '        project_id=$(resolve_project_id "$project" "$team_id") || return 1'
