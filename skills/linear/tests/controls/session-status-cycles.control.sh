# Now in local time with a UTC suffix: east of UTC a cycle six hours out has
# already started.
control_expect 'running cycle: cycle is the started one'
control_replace scripts/lib/cycle-dates.sh 1 \
    '    date -u +%Y-%m-%dT%H:%M:%S.000Z' \
    '    date +%Y-%m-%dT%H:%M:%S.000Z'
