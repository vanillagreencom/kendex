# One mutation per verdict the runner reaches, each written against the file as
# it ships and each answering for its own fixture. A verdict taken out does not
# leave its fixture passing: the run falls through to a later verdict and the
# case still fails, so what reddens is the assertions on the verdict string.

# 1. The check that a mutation reddened the assertion it named.
control_expect "the misnamed report names the mutation and the assertion"
control_replace tests/must-fail-controls.sh 1 \
	'			if ! grep -qxF -- "$want" "$WORK/$stem.fails.$k"; then' \
	'			if false; then'

# 2. The check that no two mutations name one assertion.
control_expect "the shared report names the assertion"
control_replace tests/must-fail-controls.sh 1 \
	'	if [[ -n "$shared" ]]; then' \
	'	if false; then'

# 3. The check that every mutation names one.
control_expect "the unnamed report names the mutation"
control_replace tests/must-fail-controls.sh 1 \
	'		if ! grep -q "^$k	" "$CONTROL_EXPECT_FILE"; then' \
	'		if false; then'

# 4. The verdict on a mutation the suite survived.
control_expect "the green report names its suite"
control_replace tests/must-fail-controls.sh 1 \
	'		if [[ "$rc" -eq 0 ]]; then' \
	'		if false; then'

# 5. The verdict on a run the timeout killed.
control_expect "the timeout report names the mutation and the cap"
control_replace tests/must-fail-controls.sh 1 \
	'		if [[ "$rc" -eq 124 ]]; then' \
	'		if false; then'

# 6. The verdict on a control that edits its copy outside a numbered mutation.
control_expect "the ungated report says what it refuses"
control_replace tests/must-fail-controls.sh 1 \
	'	if ! diff -rq "$snapshot" "$root" >/dev/null 2>&1; then' \
	'	if false; then'

# 7. The snapshot that guard measures against. Compared with the source
#    instead, a suite writing inside its own copy is reported as its control
#    editing outside a mutation.
control_expect "a suite's residue is not read as the control's edit"
control_replace tests/must-fail-controls.sh 1 \
	'	if ! diff -rq "$snapshot" "$root" >/dev/null 2>&1; then' \
	'	if ! diff -rq "$SKILL_DIR" "$root" >/dev/null 2>&1; then'

# 8. The condition on the survived-mutation verdict, made unconditional. Every
#    verdict above answers for the case it refuses; this one answers for the
#    case that must not be refused, which nothing else here can redden.
control_expect "a control whose mutations each redden what they named exits 0"
control_replace tests/must-fail-controls.sh 1 \
	'		if [[ "$rc" -eq 0 ]]; then' \
	'		if true; then'

# 9. The other half of 3: an expectation no mutation claims, which nothing
#    drains and the next pass truncates.
control_expect "the trailing report names the expectation nothing claims"
control_replace tests/must-fail-controls.sh 1 \
	'	if [[ -n "$trailing" ]]; then' \
	'	if false; then'

# 10. The match itself, back to the substring form. A control naming a prefix
#     of an assertion that reddened then passes on a claim its own run never
#     made.
control_expect "the prefix report names the assertion the mutation did not redden"
control_replace tests/must-fail-controls.sh 1 \
	'			if ! grep -qxF -- "$want" "$WORK/$stem.fails.$k"; then' \
	'			if ! grep -qF -- "$want" "$WORK/$stem.fails.$k"; then'
