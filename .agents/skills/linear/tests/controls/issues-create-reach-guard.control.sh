# One mutation per branch the guard makes, each with the assertion that must
# fire for it. Assertions never abort the suite, so the branches break together
# and a branch that is dead leaves its expectation absent from the output. No
# two mutations cancel — the symptom branch is inverted rather than deleted, so
# both of its directions redden, and the two halves of the absent-value
# normalization are chained rather than collapsed into one `if false`, so each
# half answers for its own assertions.
#
# One mutation cannot answer for itself here, and says so where it stands: this
# runner applies every mutation to ONE copy and runs the suite once, so a
# mutation whose only effect is already produced by another cannot be told
# apart. Where a mutation is in that position the comment says so rather than
# the header claiming otherwise.
#
# 1. The presence check — without it an issue naming nothing it reaches gets
#    filed, which is the disposition the reply grammar already makes cheap.
control_expect "a create with no description is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	if [ -z "$reach" ]; then' \
	'	if false; then'

# 2. The symptom branch and its binding to --review-born, inverted so both
#    directions redden at once: without the check a review-born hypothetical
#    files at the reported tier, and without the binding a structural priority
#    2 — a planner, a roadmap layer, the merge-pr rebundle — is refused, which
#    aborts a merge on an orphan child.
control_expect "a review-born priority-2 create with no Symptom line is refused"
control_expect "a structural priority-2 create with no Symptom line exits zero"
control_replace scripts/lib/issue-validation.sh 1 \
	'	if [ "$review_born" = "1" ] && [ "$priority" = "2" ] &&' \
	'	if [ "$review_born" != "1" ] && [ "$priority" = "2" ] &&'

# 3. The placeholder half of the absent-value normalization, on its own, so
#    what discriminates it is not shared with the token half below. Without it
#    the `[REACH]` this repo's own templates ship passes as a value, and
#    copying a template verbatim files an issue naming nothing.
control_expect "a whole-line bold [REACH] placeholder body is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	if [[ "$value" =~ $REACH_ABSENT_PLACEHOLDER ]] || [[ "$lower" =~ $REACH_ABSENT_TOKENS ]]; then' \
	'	if [[ "$lower" =~ $REACH_ABSENT_TOKENS ]]; then'

# 4. The token half, on its own — chained onto what 3 left, since mutations
#    land in one copy. Without it a word whose whole meaning is "nothing here"
#    passes as a value, on the symptom read as much as on the reach read: both
#    go through this same normalization.
control_expect "a TBD reach is refused"
control_expect "a review-born priority-2 create whose Symptom is a null token is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	if [[ "$lower" =~ $REACH_ABSENT_TOKENS ]]; then' \
	'	if false; then'

# 5. The trailing-emphasis trim that feeds the placeholder check — without it a
#    whole-line bold placeholder arrives as `[REACH]**` and passes as a value.
#
#    NOT DISCRIMINATED HERE, and it cannot be: its only effect is that the
#    placeholder check stops matching, which mutation 3 has already produced by
#    killing that check outright, so the expectation below is 3's. Deleting
#    this mutation leaves the run green and deleting 3 instead leaves this one
#    reddening on its own — the trim IS covered, by a mutation this runner
#    cannot separate from another. It stays because it records what the trim
#    holds up; it is not evidence on top of 3.
control_expect "a whole-line bold [REACH] placeholder body is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	value="${value%"${value##*[!*[:space:]]}"}"' \
	'	value="$value"'
