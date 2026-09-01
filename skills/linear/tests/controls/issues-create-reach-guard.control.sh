# One mutation per check the guard makes, each with the assertion that must
# fire for it. Assertions never abort the suite, so the three break together
# and each still proves its own check load-bearing: a dead check would leave
# its expectation absent from the output.
#
# 1. The presence check — without it an issue naming nothing it reaches gets
#    filed, which is the disposition the reply grammar already makes cheap.
control_expect "a create with no description is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	if [ -z "$reach" ]; then' \
	'	if false; then'

# 2. The refusal list — without it "the Copilot thread" passes as a producer
#    and a review artifact becomes the thing that reaches the defect.
control_expect "a reach naming a review thread is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	if [[ "$lower" =~ $REACH_REFUSED_WORDS ]] || [[ "$lower" =~ $REACH_REFUSED_SHAPES ]]; then' \
	'	if false; then'

# 3. The priority-2 symptom check — without it a hypothetical files at the
#    reported tier.
control_expect "a priority-2 create with no Symptom line is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	if [ "$priority" = "2" ] && [ -z "$(issue_marked_value "$description" '"'"'[Ss]ymptom'"'"')" ]; then' \
	'	if false; then'
