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
