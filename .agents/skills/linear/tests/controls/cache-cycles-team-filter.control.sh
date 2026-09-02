# Four mutations, one per claim the suite makes.
#
# 1. Neutralize the team filter, restoring the discarded `--team`: the flag is
#    still accepted at rc 0, and every team's cycles come back — including
#    through the type selection, which then works off the whole set.
# 2. Restore the positional upcoming fallback, which answers a team with no
#    started-and-incomplete cycle with the OLDEST cycle on record rather than
#    the earliest one still ahead of today.
# 3. Restore the positional past fallback, which returns the team's whole set
#    and so reports its future cycle as past.
# 4. Drop the inline `--team=X` binding, so that spelling filters nothing while
#    the space form does.
control_expect "A: --team KEN returns exactly KEN's cycles"
control_expect "B: --team KEN --type current picks KEN's current cycle"
control_expect "D: --team SETTLED --type upcoming skips the completed cycle"
control_expect "D: --team SETTLED --type past excludes the future cycle"
control_expect "E: --team=KEN --type current picks KEN's current cycle"

control_replace scripts/commands/cache-query.sh 1 \
    '        cycles=$(echo "$cycles" | jq --arg t "$team" '"'"'[.[] | select(.team.name == $t)]'"'"')' \
    '        : # control: the flag is consumed and the cache goes through unfiltered'

control_replace scripts/commands/cache-query.sh 1 \
    "                '[.[] | select(.startsAt > \$today)] | sort_by(.startsAt) | [first // empty]')" \
    "                'sort_by(.startsAt) | [first // empty]')"

control_replace scripts/commands/cache-query.sh 1 \
    "                '[.[] | select(.startsAt <= \$today)] | sort_by(.startsAt) | reverse')" \
    "                'sort_by(.startsAt) | reverse')"

control_replace scripts/commands/cache-query.sh 1 \
    '            team="${1#--team=}"' \
    '            : # control: the inline spelling binds nothing'
