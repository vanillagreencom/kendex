# The token half of the absent-value normalization. Without it a word whose
# whole meaning is "nothing here" passes as a value, on the symptom read as
# much as on the reach read: both go through this same normalization.
control_expect "a TBD reach is refused"
control_expect "a review-born priority-2 create whose Symptom is a null token is refused"
control_replace scripts/lib/issue-validation.sh 1 \
	'	if [[ "$value" =~ $REACH_ABSENT_PLACEHOLDER ]] || [[ "$lower" =~ $REACH_ABSENT_TOKENS ]]; then' \
	'	if [[ "$value" =~ $REACH_ABSENT_PLACEHOLDER ]]; then'
