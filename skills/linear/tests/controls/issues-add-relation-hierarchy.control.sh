# Keep the old peer-only predicate: it loses a leaf's cross-bundle wait.
control_expect "cross-bundle leaf (CC-766 --blocks CC-767): the accepted relation sent issueRelationCreate"
control_replace scripts/lib/issue-validation.sh 1 \
    '		  and (.parent1 == .parent2 or (.has_children | not))' \
    '		  and (.parent1 == .parent2)'

# Treat every blocked issue as a leaf, including a cross-bundle container.
control_expect "cross-bundle container (CC-766 --blocks CC-769): the relation is rejected"
control_replace scripts/lib/issue-validation.sh 1 \
    '		  and (.parent1 == .parent2 or (.has_children | not))' \
    '		  and true'

# Skip ancestry: the leaf exception must not admit a grandparent relation.
control_expect "grandparent pair (CC-761 --blocks CC-766): the relation is rejected"
control_replace scripts/lib/issue-validation.sh 1 \
    '		| (($f.ancestors1 | index($f.blocked)) == null and ($f.ancestors2 | index($f.blocker)) == null)' \
    '		| true'

# Blind the guard to the blocker's own parent: container siblings stop matching.
control_expect "siblings (CC-763 --blocks CC-764): the accepted relation sent issueRelationCreate"
control_replace scripts/lib/issue-validation.sh 1 \
    '		   parent1: ($ancestors_a[0] // ""), parent2: ($ancestors_b[0] // ""),' \
    '		   parent1: "", parent2: ($ancestors_b[0] // ""),'

# An unselected frontier is not the end of a parent chain.
control_expect "incomplete chain (CC-766 --blocks CC-790): the relation is rejected"
control_replace scripts/lib/issue-validation.sh 1 \
    '			if type != "object" or (.identifier | type) != "string" or .identifier == "" or (has("parent") | not)' \
    '			if type != "object" or (.identifier | type) != "string" or .identifier == ""'

# Missing child status cannot prove that the blocked issue is a leaf.
control_expect "missing child status: the relation is rejected"
control_replace scripts/lib/issue-validation.sh 1 \
    '		| if ($b.children.nodes | type) != "array" or ($b.children.pageInfo.hasNextPage | type) != "boolean"' \
    '		| if false'

# Linear excludes archived children by default. They still make a container.
control_expect "archived-child container: the relation is rejected"
control_replace scripts/lib/issue-validation.sh 1 \
    'BLOCKING_CHILD_FIELDS='"'"'children(first: 1, includeArchived: true) { nodes { id } pageInfo { hasNextPage } }'"'"'' \
    'BLOCKING_CHILD_FIELDS='"'"'children(first: 1) { nodes { id } pageInfo { hasNextPage } }'"'"''
