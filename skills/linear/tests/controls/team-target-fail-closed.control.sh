# Open the fail-closed gate: report a team target as resolved even when none is.
# Writes that need a configured team then have no target, landing wherever the API key
# reaches — including another project's tracker.
control_expect "issues create is refused"
control_replace scripts/lib/common.sh 1 \
    '    if [ -n "${LINEAR_TEAM_TARGET:-}" ]; then' \
    '    if true; then'

control_expect "graphql_query sends an issue-addressed mutation with no team target"
control_replace scripts/lib/common.sh 1 \
    '    check_api_key || return 1' \
    '    linear_require_team_target || return 1; check_api_key || return 1'

control_expect "comments create reaches the API with no configured team"
control_replace scripts/commands/comments.sh 1 \
    'linear_guard_write_action "$action" "update delete" "$@" || exit 1' \
    'linear_guard_write_action "$action" "create update delete" "$@" || exit 1'

control_expect "issues update uses the issue team with no configured team"
control_replace scripts/commands/issues.sh 1 \
    '    action="${1:-help}"' \
    '    action="${1:-help}"; linear_require_team_target || exit 1'
