# The harness applies every mutation below together; each assertion is reddened
# by the mutation named above it, and none of them masks another.

# 1. The comparison timestamp goes back to local time with an offset suffix.
control_expect "cache issues list --cycle current resolves the running cycle, not the one starting later today"
control_expect "cache cycles list --type current is the running cycle, not the one starting later today"
control_expect "session-status reports the running cycle as the working one"
control_replace scripts/lib/cache-dates.sh 1 \
    '    date -u +%Y-%m-%dT%H:%M:%S.000Z' \
    '    date -Iseconds # control: local time against a cache of UTC records'

# 2. The working cycle becomes the EARLIEST started incomplete cycle instead of
#    the most recent.
control_expect "cache issues list --cycle current resolves the running cycle, not the one starting later today"
control_expect "cache issues list --cycle previous is the cycle before the running one"
control_expect "cache issues list --cycle next is the cycle after the running one"
control_expect "cache cycles list --type current is the running cycle, not the one starting later today"
control_expect "session-status reports the running cycle as the working one"
control_replace scripts/lib/cache-dates.sh 1 \
    '           | last // null'"'" \
    '           | first // null'"'"' # control: the earliest started cycle is the working one'

# 3. The working cycle stops sorting, so it takes the end of the array in the
#    order sync wrote it — which is the order Linear paged it, not by date.
#    session-status is absent below because it pre-sorts before calling in.
control_expect "cache issues list --cycle current resolves the running cycle, not the one starting later today"
control_expect "cache issues list --cycle previous is the cycle before the running one"
control_expect "cache issues list --cycle next is the cycle after the running one"
control_expect "cache cycles list --type current is the running cycle, not the one starting later today"
control_replace scripts/lib/cache-dates.sh 1 \
    '           | sort_by(.startsAt)' \
    '           | . # control: the working cycle is picked off the unsorted array'

# 4. The `Nd` cutoff stops reading its argument, so no day count narrows the
#    window.
control_expect "cache issues list --updated-since keeps the UTC window and no more"
control_expect "session-status research reads the same day-count cutoff"
control_replace scripts/lib/cache-dates.sh 1 \
    '    local days="$1"' \
    '    local days=36500 # control: the window ignores the caller day count'

# 5. The past/prev fallback loses its order, so the head of the list is the
#    OLDEST cycle that has started rather than the most recent.
control_expect "with no cycle running, --type past is every started cycle newest-first, and no future one"
control_expect "with no cycle running, session-status prev_cycle is the most recent cycle that ran"
control_replace scripts/lib/cache-dates.sh 1 \
    '        | sort_by(.startsAt) | reverse'"'" \
    '        | sort_by(.startsAt)'"'"' # control: past runs oldest-first'

# 6. The upcoming/next fallback likewise, so the head is the cycle farthest out.
control_expect "with no cycle running, --type upcoming is the NEXT cycle to start, not the farthest out"
control_expect "with no cycle running, session-status next_cycle is the earliest cycle still to start"
control_replace scripts/lib/cache-dates.sh 1 \
    '         | [.[] | select(.startsAt > $pivot)] | sort_by(.startsAt)'"'" \
    '         | [.[] | select(.startsAt > $pivot)] | sort_by(.startsAt) | reverse'"'"' # control: next runs farthest-first'

# 7. The two `--cycle` keywords swap the helper they read.
control_expect "cache issues list --cycle previous is the cycle before the running one"
control_expect "cache issues list --cycle next is the cycle after the running one"
control_expect "with no cycle running, --cycle previous answers with the most recent cycle that started"
control_expect "with no cycle running, --cycle next answers with the earliest cycle still to start"
control_replace scripts/commands/cache-query.sh 1 \
    '                    cycle_id=$(cache_cycles_before "$working" <<<"$all_cycles" | jq -r '"'"'first | .id // empty'"'"')' \
    '                    cycle_id=$(cache_cycles_after "$working" <<<"$all_cycles" | jq -r '"'"'first | .id // empty'"'"') # control: previous reads forward'
control_replace scripts/commands/cache-query.sh 1 \
    '                    cycle_id=$(cache_cycles_after "$working" <<<"$all_cycles" | jq -r '"'"'first | .id // empty'"'"')' \
    '                    cycle_id=$(cache_cycles_before "$working" <<<"$all_cycles" | jq -r '"'"'first | .id // empty'"'"') # control: next reads backward'
