# Read every query as one whose rows select no connection. A --limit over 50
# is then asked for in pages of 250, which Linear refuses as too complex for
# the projects query's rows, instead of being paginated and merged.
control_expect "no request exceeds the 50-item connection maximum"
control_replace scripts/lib/pages.sh 1 \
    '    local rest="${1#*pageInfo}"' \
    '    local rest=""'
