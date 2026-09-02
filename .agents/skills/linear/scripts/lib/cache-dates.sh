#!/bin/bash
# Date comparisons against cached Linear records.
# Source this file in command scripts that select by startsAt or updatedAt.
#
# sync stores `startsAt` and `updatedAt` exactly as Linear returns them: UTC,
# millisecond precision, a `Z` suffix. Every date filter over the cache compares
# those strings lexically, so a comparison timestamp must carry the same shape.
# `date -Iseconds` does not — it emits the host's local time with an offset
# suffix, which only agrees on a UTC host. Off UTC it moves the cut by the whole
# offset: at -07:00 every `--cycle current|previous|next` failed to resolve, and
# at +09:00 `current` answered with a cycle that had not started (KEN-1175).

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
# One definition because three commands select it — `cache issues list --cycle`,
# `cache cycles list --type`, and `session-status` — and while it existed as
# three copied expressions a correction landed in one of them and left the other
# two wrong.
cache_working_cycle() {
    jq --arg today "$(cache_now_utc)" \
        '[.[] | select(.startsAt <= $today and .progress < 1)] | sort_by(.startsAt) | last // null'
}

# Cycles before the working one, most recent first. Reads the cycle array on
# stdin; $1 is the working cycle `cache_working_cycle` printed.
#
# With no cycle running the cut falls at now rather than at a position in the
# list: answering "past" with the whole date-sorted set reported a cycle that
# has not started as the previous one.
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
# where no cycle is running — the next cycle to start, not the oldest on record.
cache_cycles_after() {
    local working="${1:-null}"
    jq --argjson w "$working" --arg today "$(cache_now_utc)" \
        '(if $w then $w.startsAt else $today end) as $pivot
         | [.[] | select(.startsAt > $pivot)] | sort_by(.startsAt)'
}
