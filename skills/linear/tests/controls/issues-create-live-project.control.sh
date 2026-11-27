# A create refuses while a render carries a `### Project map` block.
control_expect "create-unnamed: accepted"
control_replace scripts/commands/issues.sh 1 \
    '        project_id=$(resolve_project_id "$project" "$team_id") || return 1' \
    '        ! grep -qx "### Project map" "$LINEAR_TAXONOMY_FILE" || return 1; project_id=$(resolve_project_id "$project" "$team_id") || return 1'

# An existing issue's move refuses the same way.
control_expect "update-unnamed: accepted"
control_expect "bulk-unnamed: accepted"
control_replace scripts/commands/issues.sh 1 \
    '    id=$(resolve_project_id "$ref" "$team_id") || return 1' \
    '    ! grep -qx "### Project map" "$LINEAR_TAXONOMY_FILE" || return 1; id=$(resolve_project_id "$ref" "$team_id") || return 1'

# A write drops the project it resolved.
control_expect "create-unnamed-uuid: the write carries the live project"
control_replace scripts/commands/issues.sh 2 \
    '        input_parts+=("\"projectId\": \"$project_id\"")' \
    '        :'
