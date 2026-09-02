# One mutation per branch the guard makes, each with the assertion that must
# fire for it. Assertions never abort the suite, so the branches break together
# and each still proves its own load-bearing: a dead branch would leave its
# expectation absent from the output. No two mutations cancel — the symptom
# branch is inverted rather than deleted, so both of its directions redden.
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

# 3. Placeholder and null-token normalization. The one mutation kills both
#    alternatives, so it declares both expectations: without them the `[REACH]`
#    this repo's own templates ship, and a bare TBD, pass as values, and
#    copying a template verbatim files an issue naming nothing.
control_expect "a whole-line bold [REACH] placeholder body is refused"
control_expect "a TBD reach is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	if [[ "$value" =~ $REACH_ABSENT_PLACEHOLDER ]] || [[ "$lower" =~ $REACH_ABSENT_TOKENS ]]; then' \
	'	if false; then'

# 4. The trailing-emphasis trim that feeds the placeholder check — without it a
#    whole-line bold placeholder arrives as `[REACH]**` and passes as a value.
#    The token list does not go through the trim, so this one expects only the
#    placeholder case.
control_expect "a whole-line bold [REACH] placeholder body is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	value="${value%"${value##*[!*[:space:]]}"}"' \
	'	value="$value"'
