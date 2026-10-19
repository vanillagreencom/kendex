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

# Main's rule: a container closes only once every box, the child box among
# them, carries a holder's Evidence, so finished children alone never close it.
control_expect "child-open container outcome controls completion"
control_replace scripts/commands/issues.sh 1 \
    '                | .ok = (.ok and $checklist.errors == [] and $checklist.container_open_boxes == [])'"'"') || return 1' \
    '                | .ok = (.ok and $checklist.completion_state == "Done")'"'"') || return 1'

# Restore child acceptance without the qualified started phase.
control_expect "qualified child controls bundle acceptance"
control_replace scripts/lib/issue-validation.sh 1 \
    $'\t''if [[ "$role" == "bundle-child" && "$state_type" == started && "$state" != Verifying ]]; then' \
    $'\t''if false; then'

# A state name cannot substitute for branch proof.
control_expect "open-branch child controls bundle acceptance"
control_replace scripts/lib/issue-validation.sh 1 \
    $'\t\t\t\telse (.boxes | length) > 0 and .unmet_branch_boxes == []' \
    $'\t\t\t\telse true or (.boxes | length) > 0 and .unmet_branch_boxes == []'

# Main ties pre-merge acceptance to a future completion state. Proved branch
# work must also pass when the child has no post-merge box.
control_expect "branch-only child controls bundle acceptance"
control_replace scripts/lib/issue-validation.sh 1 \
    $'\t\t\t\telse (.boxes | length) > 0 and .unmet_branch_boxes == []' \
    $'\t\t\t\telse .completion_state == "Verifying" and (.boxes | length) > 0 and .unmet_branch_boxes == []'

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
