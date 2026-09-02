#!/bin/bash
# Date comparisons against cached Linear records.
# Source this file in command scripts that select by startsAt or updatedAt.
#
# sync stores `startsAt` and `updatedAt` exactly as Linear returns them: UTC,
# millisecond precision, a `Z` suffix. Every date filter over the cache compares
# those strings lexically, so a comparison timestamp must carry the same shape.
# `date -Iseconds` does not — it emits the host's local time with an offset
# suffix, which only agrees on a UTC host. Off UTC it moves the cut by the whole
# offset, so within that window either side of a cycle boundary the answer is
# wrong: east of UTC `current` names a cycle that has not started, and west of
# it `current` names the previous cycle, or nothing at all when no earlier cycle
# is incomplete (KEN-1175).

# Now, in the shape the cache stores.
cache_now_utc() {
    date -u +%Y-%m-%dT%H:%M:%S.000Z
}

# The same shape N days back, for the `--updated-since 7d` and `--research-days`
# cutoffs. GNU and BSD date disagree on the flag, so both are tried.
cache_utc_days_ago() {
    local days="$1"
    date -u -d "-$days days" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null ||
        date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%S.000Z
}

# The cycle a team is working in: the most recently started cycle that is not
# finished. Reads the cycle array on stdin, prints that cycle or `null`.
#
# One definition, called from `cache issues list --cycle`, `cache cycles list
# --type` and `session-status`. As copied expressions their no-working-cycle
# fallbacks had already drifted apart.
cache_working_cycle() {
    # sync writes this array in the order Linear paged it, so the sort carries
    # weight. One term per line keeps it separately provable from the end taken.
    jq --arg today "$(cache_now_utc)" \
        '[.[] | select(.startsAt <= $today and .progress < 1)]
           | sort_by(.startsAt)
           | last // null'
}

# Cycles before the working one, most recent first. Reads the cycle array on
# stdin; $1 is the working cycle `cache_working_cycle` printed.
#
# With no cycle running the cut falls at now rather than at a position in the
# list.
cache_cycles_before() {
    local working="${1:-null}"
    jq --argjson w "$working" --arg today "$(cache_now_utc)" '
        # The working cycle is excluded from its own past, so its arm cuts
        # strictly below its start. The now arm excludes nothing, so a cycle
        # starting this second has started and counts as past.
        [.[] | select(if $w then .startsAt < $w.startsAt else .startsAt <= $today end)]
        | sort_by(.startsAt) | reverse'
}

# Cycles after the working one, earliest first. Same inputs, same cut at now
# where no cycle is running.
cache_cycles_after() {
    local working="${1:-null}"
    jq --argjson w "$working" --arg today "$(cache_now_utc)" \
        '(if $w then $w.startsAt else $today end) as $pivot
         | [.[] | select(.startsAt > $pivot)] | sort_by(.startsAt)'
}
