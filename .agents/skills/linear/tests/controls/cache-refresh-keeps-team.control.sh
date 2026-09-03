# Drop `team { name }` from the RefreshIssues field list, the state this fix
# found. The stub answers from the query's own selection, so the refreshed
# nodes come back team-less, cache_upsert_issue replaces the whole document
# with them, and the team-scoped listing goes short.
control_expect "A: both refreshed rows still carry their team"
control_expect "B: cache issues list --team KEN still returns both refreshed issues"
control_replace scripts/lib/cache.sh 1 \
    '                team { name }' \
    '                identifier # control: the refresh selects no team'
