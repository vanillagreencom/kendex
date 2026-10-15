# Drop completed children from the bundle expansion. The
# children that validate as Done disappear from the results, so a bundle whose
# work is finished reports on the root alone.
control_expect "A: three results (root + 2 completed children)"
control_replace scripts/commands/issues.sh 1 \
    "        child_ids=\$(echo \"\$bundle\" | jq -r '[.children[] | select(.state_type != \"canceled\") | .id] | .[]' 2>/dev/null)" \
    "        child_ids=\$(echo \"\$bundle\" | jq -r '[.children[] | select(.state_type != \"canceled\" and .state_type != \"completed\") | .id] | .[]' 2>/dev/null)"

control_expect "summary case: CC-950 passes"
control_expect "summary case: CC-951 passes"
control_replace scripts/commands/issues.sh 1 \
    '        has_summary=$(echo "$comments" | jq '\''any(.[]; .body | test("Completion Summary|Bundle Complete"; "i"))'\'')' \
    '        has_summary=$(echo "$comments" | jq '\''any(.[]; .body | (contains("Completion Summary") or contains("Bundle Complete")))'\'')'

control_expect "open container outcome controls completion"
control_replace scripts/commands/issues.sh 1 \
    '        if [ "$role" = "container" ]; then' \
    '        if false; then'

control_expect "absent container outcome controls completion"
control_replace scripts/lib/issue-validation.sh 1 \
    '        | .missing_outcome_box = ($role == "container" and all(.boxes[]; .post_merge))' \
    '        | .missing_outcome_box = false'

# Restore child acceptance without the qualified started phase.
control_expect "qualified child controls bundle acceptance"
control_replace scripts/lib/issue-validation.sh 1 \
    $'\t''if [[ "$role" == "bundle-child" && "$state_type" == started && "$state" != Verifying ]]; then' \
    $'\t''if false; then'

# A state name cannot substitute for branch proof.
control_expect "open-branch child controls bundle acceptance"
control_replace scripts/lib/issue-validation.sh 1 \
    $'\t\t\tstate_ok=$(jq -r --arg state "$state" '\''.completion_state == (if $state == "Done" then "Done" else "Verifying" end)'\'' <<<"$checklist") || return 1' \
    $'\t\t\tstate_ok=true'

control_expect "early-verifying child controls bundle acceptance"
control_replace scripts/lib/issue-validation.sh 1 \
    $'\t''if [[ "$role" == "bundle-child" && "$state_type" == started && "$state" != Verifying ]]; then' \
    $'\t''if [[ "$role" == "bundle-child" && "$state_type" == started ]]; then'

# Restore the inherited display format that omits the required checklist.
control_expect "compact-qualified child controls bundle acceptance"
control_expect "compact-done-open-branch child controls bundle acceptance"
control_expect "compact-done-missing-evidence child controls bundle acceptance"
control_replace scripts/commands/issues.sh 1 \
    '        issue=$(get_issue "$issue_id" --format=safe) || return 1' \
    '        issue=$(get_issue "$issue_id") || return 1'
