# Keep the old peer-only predicate: it loses a leaf's cross-bundle wait.
control_expect "cross-bundle leaf (CC-766 --blocks CC-767): issueRelationCreate stores 766>767"
control_replace scripts/lib/issue-validation.sh 1 \
    '		  and (.parent1 == .parent2 or (.has_children | not))' \
    '		  and (.parent1 == .parent2)'
