# Open the fail-closed gate: report a team target as resolved even when none is.
# Writes that need a configured team then have no target, landing wherever the API key
# reaches — including another project's tracker.
control_expect "issues create is refused"
control_replace scripts/lib/common.sh 1 \
    '    if [ -n "${LINEAR_TEAM_TARGET:-}" ]; then' \
    '    if true; then'
