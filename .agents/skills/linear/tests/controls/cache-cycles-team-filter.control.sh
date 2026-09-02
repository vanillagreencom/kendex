# Neutralize the team filter, restoring the discarded `--team`: the flag is
# still accepted at rc 0, and every team's cycles come back — including through
# the type selection, which then picks its one cycle off the whole set.
control_expect "A: --team KEN returns exactly KEN's cycles"
control_expect "B: --team KEN --type current picks KEN's current cycle"
control_replace scripts/commands/cache-query.sh 1 \
    '        cycles=$(echo "$cycles" | jq --arg t "$team" '"'"'[.[] | select(.team.name == $t)]'"'"')' \
    '        : # control: the flag is consumed and the cache goes through unfiltered'
