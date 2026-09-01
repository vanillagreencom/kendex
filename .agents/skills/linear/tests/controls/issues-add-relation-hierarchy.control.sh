# Blind the guard to the blocker's own parent. The one-query read is what
# separates a bundle peer from a child of a child: without it siblings no
# longer share a parent, and a grandchild reads as a second top-level issue.
control_expect "siblings (CC-763 --blocks CC-764): the accepted relation sent issueRelationCreate"
control_expect "different parents (CC-766 --blocks CC-761): the relation is rejected"
control_replace scripts/commands/issues.sh 1 \
    '        parent1_id=$(jq -r '"'"'.issue1.parent.identifier? // ""'"'"' <<<"$validation_result" 2>/dev/null)' \
    '        parent1_id=""'
