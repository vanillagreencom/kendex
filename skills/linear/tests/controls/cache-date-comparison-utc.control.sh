# Every mutation restores the shape this fix replaced, in the shared helpers.
# The harness applies them together; each assertion below is reddened by the one
# mutation named above it, and none of them masks another.

# 1. The comparison timestamp goes back to local time with an offset suffix,
#    which at the pinned +14 reads as fourteen hours into tomorrow.
control_expect "cache issues list --cycle current resolves the running cycle, not the one starting later today"
control_expect "cache cycles list --type current is the running cycle, not the one starting later today"
control_expect "session-status reports the running cycle as the working one"
control_replace scripts/lib/cache-dates.sh 1 \
    '    date -u +%Y-%m-%dT%H:%M:%S.000Z' \
    '    date -Iseconds # control: local time against a cache of UTC records'

# 2. The same for the `Nd` cutoff, which then lands the offset short of the
#    window the caller asked for.
control_expect "cache issues list --updated-since keeps an issue inside the UTC window"
control_replace scripts/lib/cache-dates.sh 1 \
    '    date -u -d "-$days days" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null ||' \
    '    date -d "-$days days" -Iseconds 2>/dev/null ||'
control_replace scripts/lib/cache-dates.sh 1 \
    '        date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%S.000Z' \
    '        date -v-"${days}"d -Iseconds'

# 3. The past/prev fallback goes back to a position in the date-sorted list —
#    the whole set, so a cycle that has not started leads it.
control_expect "with no cycle running, --type past excludes a cycle that has not started"
control_expect "with no cycle running, session-status prev_cycle is the cycle that already ran"
control_replace scripts/lib/cache-dates.sh 1 \
    '        [.[] | select(if $w then .startsAt < $w.startsAt else .startsAt <= $today end)]' \
    '        [.[]] # control: every cycle counts as past, newest first'

# 4. The upcoming/next fallback likewise, so the oldest cycle on record answers
#    as the next one.
control_expect "with no cycle running, --type upcoming is the next cycle to start"
control_expect "with no cycle running, session-status next_cycle is the cycle that has not started"
control_replace scripts/lib/cache-dates.sh 1 \
    '         | [.[] | select(.startsAt > $pivot)] | sort_by(.startsAt)'"'" \
    '         | [.[]] | sort_by(.startsAt)'"'"' # control: the oldest cycle answers as next'
