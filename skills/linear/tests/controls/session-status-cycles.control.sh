# Each mutation changes a disposable skill copy and names its assertion.
# Now in local time with a UTC suffix: east of UTC a cycle six hours out has
# already started.
control_expect 'running cycle: cycle is the started one'
control_replace scripts/lib/cycle-dates.sh 1 \
    '    date -u +%Y-%m-%dT%H:%M:%S.000Z' \
    '    date +%Y-%m-%dT%H:%M:%S.000Z'
# The earlier cycles in date order, so the oldest stands for the previous one.
control_expect 'running cycle: prev is the latest earlier cycle'
control_replace scripts/lib/cycle-dates.sh 1 \
    '        | sort_by(.startsAt) | reverse'\''' \
    '        | sort_by(.startsAt)'\'''
# Progress for the end: a cycle that ended with issues unfinished stays the
# working cycle through the gap after it.
control_expect 'ended unfinished cycle: cycle is null'
control_replace scripts/lib/cycle-dates.sh 1 \
    "        '[.[] | select(.startsAt <= \$today and .endsAt > \$today)]" \
    "        '[.[] | select(.startsAt <= \$today and .progress < 1)]"
# Progress for the start too: a running cycle whose issues are all done stops
# being the working cycle before its end.
control_expect 'finished running cycle: cycle is the started one'
control_replace scripts/lib/cycle-dates.sh 1 \
    "        '[.[] | select(.startsAt <= \$today and .endsAt > \$today)]" \
    "        '[.[] | select(.startsAt <= \$today and .endsAt > \$today and .progress < 1)]"
