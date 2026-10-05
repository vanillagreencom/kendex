# Each mutation opens or closes one part of the cross-team guard: a refused
# verb that writes to another team's issue, or an allowed verb that is
# refused, or a guard that spends a request it does not need.

# The refused verbs, each unwired from the guard.
control_expect "update of another team issue is refused before any write"
control_replace scripts/commands/issues.sh 1 \
    '    linear_guard_issue_team update "$issue_id" || return 1' \
    '    :'

control_expect "bulk-update with one foreign issue writes nothing"
control_replace scripts/commands/issues.sh 1 \
    '    linear_guard_issue_team bulk-update "${identifiers[@]}" || return 1' \
    '    :'

control_expect "activate of another team issue is refused"
control_replace scripts/commands/issues.sh 1 \
    '    linear_guard_issue_team activate "$issue_id" || return 1' \
    '    :'

control_expect "block of another team issue is refused"
control_replace scripts/commands/issues.sh 1 \
    '    linear_guard_issue_team block "$issue_id" || return 1' \
    '    :'

control_expect "unblock of another team issue is refused"
control_replace scripts/commands/issues.sh 1 \
    '    linear_guard_issue_team unblock "$issue_id" || return 1' \
    '    :'

control_expect "complete of another team issue is refused"
control_replace scripts/commands/issues.sh 1 \
    '    linear_guard_issue_team complete "$issue_id" || return 1' \
    '    :'

control_expect "archive of another team issue is refused"
control_replace scripts/commands/issues.sh 1 \
    '    linear_guard_issue_team archive "$issue_ref" || return 1' \
    '    :'

control_expect "trash of another team issue is refused"
control_replace scripts/commands/issues.sh 1 \
    '    linear_guard_issue_team trash "$issue_ref" || return 1' \
    '    :'

control_expect "create in another team is refused"
control_replace scripts/commands/issues.sh 1 \
    '    linear_guard_create_team "$explicit_team" || return 1' \
    '    :'

# The guard runs after the checks that need no request.
control_expect "an unreadable attach path refuses before the guard reads the team"
control_replace scripts/commands/issues.sh 1 \
    '    local clear_labels="false"' \
    '    local clear_labels="false"; linear_guard_issue_team update "$issue_id" || return 1'

control_expect "bulk-update refuses an unreadable attach path before the guard reads the team"
control_replace scripts/commands/issues.sh 1 \
    '            [[ "$1" != --attach ]] || attach_paths+=("$2")' \
    '            :'

# How the guard judges an issue's team and its own.
control_expect "a team configured by name resolves to its key and refuses"
control_replace scripts/lib/common.sh 1 \
    '        if [[ "$team" != "$DEFAULT_TEAM" ]]; then' \
    '        if false; then'

control_expect "update of an own team issue writes with no guard request"
control_replace scripts/lib/common.sh 1 \
    '        if [[ "$team" != "$DEFAULT_TEAM" ]]; then' \
    '        if true; then'

control_expect "an own team issue passes with the team configured by name"
control_replace scripts/lib/common.sh 1 \
    '            if [[ "$team" != "$(jq -r '"'"'.key'"'"' <<<"$LINEAR_OWN_TEAM")" ]]; then' \
    '            if true; then'

control_expect "a configured team that matches no team refuses the write"
control_replace scripts/lib/common.sh 1 \
    '            linear_own_team || return 1' \
    '            linear_own_team || continue'

control_expect "bulk-update reads a team configured by name once"
control_replace scripts/lib/common.sh 1 \
    '    [[ -n "$LINEAR_OWN_TEAM" ]] && return 0' \
    '    :'

control_expect "an own team issue passes with the team configured by UUID"
control_replace scripts/lib/common.sh 1 \
    "        || query='query GetTeamById(\$name: ID!, \$after: String) { teams(filter: {id: {eq: \$name}}, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id key name } } }'" \
    '        || :'

control_expect "a lowercase identifier is judged by its team key"
control_replace scripts/lib/common.sh 1 \
    '            team=$(tr '"'"'[:lower:]'"'"' '"'"'[:upper:]'"'"' <<<"${ref%-*}")' \
    '            team="${ref%-*}"'

control_expect "an issue named by UUID is read for its team and refused"
control_replace scripts/lib/common.sh 1 \
    '        if [[ "$ref" =~ ^[A-Za-z0-9]+-[0-9]+$ ]]; then' \
    '        if true; then'

control_expect "an own team issue named by UUID passes"
control_replace scripts/lib/common.sh 1 \
    '                || ! team=$(jq -er '"'"'.issue.team.key | strings | select(length > 0)'"'"' <<<"$result"); then' \
    '                || ! team=$(jq -er '"'"'.issue.team.name | strings | select(length > 0)'"'"' <<<"$result"); then'

control_expect "an issue whose team cannot be read is refused"
control_replace scripts/lib/common.sh 1 \
    '                echo "linear: refused=cross-team-unread action=$action issue=$ref" >&2' \
    '                continue'

control_expect "create under the own team by another spelling passes"
control_replace scripts/lib/common.sh 1 \
    '    [[ "$(jq -r '"'"'.id'"'"' <<<"$target")" == "$(jq -r '"'"'.id'"'"' <<<"$LINEAR_OWN_TEAM")" ]] && return 0' \
    '    :'

control_expect "with no team configured the guard is inactive and the update passes"
control_replace scripts/lib/common.sh 1 \
    '        linear_cross_team_inactive "$action"' \
    '        :'

# The allowed verbs, each put behind the guard.
control_expect "block of an own team issue by another team issue passes"
control_replace scripts/commands/issues.sh 1 \
    '    linear_guard_issue_team block "$issue_id" || return 1' \
    '    linear_guard_issue_team block "$issue_id" "$blocker" || return 1'

control_expect "comments create on another team issue passes"
control_replace scripts/commands/comments.sh 1 \
    '        create_comment "$@"' \
    '        linear_guard_issue_team create "$1" || exit 1; create_comment "$@"'

control_expect "add-relation from another team issue passes"
control_replace scripts/commands/issues.sh 1 \
    '        add_relation "$@"' \
    '        linear_guard_issue_team add-relation "$1" || exit 1; add_relation "$@"'

control_expect "remove-relation from another team issue passes"
control_replace scripts/commands/issues.sh 1 \
    '        remove_relation "$@"' \
    '        linear_guard_issue_team remove-relation "$1" || exit 1; remove_relation "$@"'

control_expect "get of another team issue passes"
control_replace scripts/commands/issues.sh 1 \
    '        get_issue "$@"' \
    '        linear_guard_issue_team get "$1" || exit 1; get_issue "$@"'
