#!/bin/bash
# Date comparisons against Linear's cycle and issue timestamps. common.sh
# sources this file, so every command has it.
#
# Linear returns `startsAt`, `endsAt` and `updatedAt` in UTC, millisecond
# precision, with a `Z` suffix, and every date filter here compares those
# strings lexically, so a comparison timestamp must carry the same shape.
# `date -Iseconds` does not — it emits the host's local time with an offset
# suffix, which only agrees on a UTC host. Off UTC it moves the cut by the
# whole offset, so within that window either side of a cycle boundary the
# answer is wrong: east of UTC `current` names a cycle that has not started,
# and west of it `current` names the previous cycle, or nothing at all when
# a gap came before the running one.

# Now, in the shape Linear returns.
linear_now_utc() {
    date -u +%Y-%m-%dT%H:%M:%S.000Z
}

# The same shape N days back, for the `--updated-since 7d`, `--created-since 7d`
# and `--research-days` cutoffs. GNU and BSD date disagree on the flag, so both
# are tried.
linear_utc_days_ago() {
    local days="$1"
    date -u -d "-$days days" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null ||
        date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%S.000Z
}

# The cycle a team is working in: the most recently started cycle whose end
# has not passed. Reads the cycle array on stdin, prints that cycle or `null`.
# Progress does not decide it: a cycle that ended with issues unfinished keeps
# a progress below 1 for good, and between two cycles it is not running.
#
# One definition for every caller: as copied expressions their
# no-working-cycle fallbacks drifted apart.
linear_working_cycle() {
    # The array arrives in the order Linear paged it, so the sort carries
    # weight. One term per line keeps it separately provable from the end taken.
    jq --arg today "$(linear_now_utc)" \
        '[.[] | select(.startsAt <= $today and .endsAt > $today)]
           | sort_by(.startsAt)
           | last // null'
}

# Cycles before the working one, most recent first. Reads the cycle array on
# stdin; $1 is the working cycle `linear_working_cycle` printed.
#
# With no cycle running the cut falls at now rather than at a position in the
# list.
linear_cycles_before() {
    local working="${1:-null}"
    jq --argjson w "$working" --arg today "$(linear_now_utc)" '
        # The working cycle is excluded from its own past, so its arm cuts
        # strictly below its start. The now arm excludes nothing, so a cycle
        # starting this second has started and counts as past.
        [.[] | select(if $w then .startsAt < $w.startsAt else .startsAt <= $today end)]
        | sort_by(.startsAt) | reverse'
}

# Cycles after the working one, earliest first. Same inputs, same cut at now
# where no cycle is running.
linear_cycles_after() {
    local working="${1:-null}"
    jq --argjson w "$working" --arg today "$(linear_now_utc)" \
        '(if $w then $w.startsAt else $today end) as $pivot
         | [.[] | select(.startsAt > $pivot)] | sort_by(.startsAt)'
}
