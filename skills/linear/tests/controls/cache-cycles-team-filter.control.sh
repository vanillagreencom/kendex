# One mutation per assertion the suite makes.
#
# The harness applies both at once, and mutation 1 subsumes mutation 2 there:
# with nothing filtering, the inline spelling binds a team that changes no
# answer, so mutation 1 alone reddens both assertions. Applied on its own,
# mutation 2 reddens only the inline assertion. That harness limitation — one
# control per suite, every mutation applied together — is KEN-1177.

# 1. Neutralize the filter, restoring the discarded `--team`: the flag is still
#    accepted at rc 0 and every team's cycles come back.
control_expect "--team KEN returns exactly KEN's cycles"
control_replace scripts/commands/cache-query.sh 1 \
    '        cycles=$(echo "$cycles" | jq --arg t "$team" '"'"'[.[] | select(.team.name == $t)]'"'"')' \
    '        : # control: the flag is consumed and the cache goes through unfiltered'

# 2. Drop the inline binding, so `--team=X` filters nothing while the space
#    form does.
control_expect "--team=KEN, the inline spelling, filters the same"
control_replace scripts/commands/cache-query.sh 1 \
    '            team="${1#--team=}"' \
    '            : # control: the inline spelling binds nothing'
