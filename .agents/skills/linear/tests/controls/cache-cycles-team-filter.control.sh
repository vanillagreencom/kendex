# Four mutations over the suite's five claims, each checked to redden the suite
# applied on its own: 2 reddens the D upcoming assertion, 3 the D past
# assertion, and 4 the two E assertions. Claim C, that no --team is unfiltered,
# carries none, because neutralizing the filter leaves it passing.
#
# Under the combined run the harness applies all four at once and mutation 1
# subsumes the rest: with the filter neutralized `--team SETTLED` gets the whole
# cache, which always holds a started-and-incomplete cycle, so the working ==
# null arms 2 and 3 target never execute, and 4's effect is already produced by
# the unfiltered pass-through. The all-four and mutation-1-alone FAIL sets are
# identical. So the combined run demonstrates mutation 1; what proves 2, 3 and 4
# is the one-at-a-time check above.
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
