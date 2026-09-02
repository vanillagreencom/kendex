# One mutation per branch the guard makes, each written against the file as it
# ships, since every mutation lands on its own pristine copy. Assertions never
# abort the suite, so a branch that is dead leaves its expectation absent from
# the output.
#
# The placeholder half of the absent-value normalization is not among them, nor
# is the trailing-emphasis trim that feeds it. Both only stop a value from
# normalizing to empty, and the presence check below refuses every value that
# does, so the placeholder assertion is the only one either of them reddens and
# the presence check claims it. A mutation for either would have no assertion
# left to name and the runner would report SHARED.
#
# 1. The token half of the absent-value normalization. Without it a word whose
#    whole meaning is "nothing here" passes as a value, on the symptom read as
#    much as on the reach read: both go through this same normalization.
control_expect "a TBD reach is refused"
control_expect "a review-born priority-2 create whose Symptom is a null token is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	if [[ "$value" =~ $REACH_ABSENT_PLACEHOLDER ]] || [[ "$lower" =~ $REACH_ABSENT_TOKENS ]]; then' \
	'	if [[ "$value" =~ $REACH_ABSENT_PLACEHOLDER ]]; then'

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

# 3. The presence check — without it an issue naming nothing it reaches gets
#    filed, which is the disposition the reply grammar already makes cheap.
control_expect "a create with no description is refused"
control_expect "a whole-line bold [REACH] placeholder body is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	if [ -z "$reach" ]; then' \
	'	if false; then'
