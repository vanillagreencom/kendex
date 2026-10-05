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
control_expect "the residue a suite writes in its own copy is not read as the edit of its control"
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

# 11. The check for a control file. Without it the run reaches the control's
#     source and dies there, a different verdict.
control_expect "a suite with no control file is reported missing"
control_replace tests/must-fail-controls.sh 1 \
	'	if [[ ! -f "$control" ]]; then' \
	'	if false; then'

# 12. The green check on the unmutated copy. Without it a suite already red
#     satisfies every mutation that names the assertion it is red on.
control_expect "a suite failing from its unmutated copy proves nothing under mutation"
control_replace tests/must-fail-controls.sh 1 \
	'	if [[ "$rc" -ne 0 ]]; then' \
	'	if false; then'

# 13. The verdict on a control that counted no mutation.
control_expect "a control declaring no mutation changed nothing"
control_replace tests/must-fail-controls.sh 1 \
	'	if [[ "$mutations" -eq 0 ]]; then' \
	'	if false; then'

# 14. The verdict on a mutation that did not apply; the copy is then unchanged,
#     which the NOOP check reports instead.
control_expect "a mutation whose line the file lacks did not apply"
control_replace tests/must-fail-controls.sh 1 \
	'		if ! apply_control "$root" "$k"; then' \
	'		if ! apply_control "$root" "$k" 2>/dev/null && false; then'

# 15. What goes under the UNSTAGED verdict, discarded while the verdict stays,
#     so only the row keeping those lines sees it.
control_expect "the unstaged report shows the assertion the suite failed on"
control_replace tests/must-fail-controls.sh 1 \
	"		} | sed 's/^/         | /'" \
	'		} >/dev/null'

# 16. The wait for every mutation of a control, back to the last one alone. Jobs
#     finish in any order, so a first mutation still running reads as passed.
control_expect "a control whose first mutation finishes last is judged on it"
control_replace tests/must-fail-controls.sh 1 \
	'			for ((k = 1; k <= n; k++)); do' \
	'			for ((k = n; k <= n; k++)); do'

# 17. The per-slot wait in launch, back to waiting out the whole batch. A slot
#     one job frees then stays empty until every other running job finishes.
control_expect "a slot one job frees is refilled while another still runs"
control_replace tests/must-fail-controls.sh 1 \
	'	while [[ "$RUNNING" -ge "$CONTROL_JOBS" ]]; do' \
	'	[[ "$RUNNING" -lt "$CONTROL_JOBS" ]] || drain; while false; do'
