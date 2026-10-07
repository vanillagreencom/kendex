# One mutation per related builder: each reverts it to reading relations
# alone, which is the defect the suite covers. Removing the inverse arm from
# issue_related_rows reddens the same assertions all four claim, so it has no
# assertion left to name and stands proven by them.
# 1. The issues-list projection, which bulk-get and list print.
control_expect "bulk-get lists the inverse related issue"
control_expect "list lists the inverse related issue"
control_replace scripts/lib/formatters.sh 1 \
    '        related: issue_related_ids(.relations.nodes; .inverseRelations.nodes),' \
    '        related: [(.relations.nodes // [])[] | select(.type == "related") | .relatedIssue.identifier],'

# 2. The single-issue projection.
control_expect "get safe lists the inverse related issue"
control_replace scripts/lib/formatters.sh 1 \
    '        related: issue_related_ids(.issue.relations.nodes; .issue.inverseRelations.nodes),' \
    '        related: [(.issue.relations.nodes // [])[] | select(.type == "related") | .relatedIssue.identifier],'

# 3. The bundle projection.
control_expect "get with bundle lists the inverse related issue"
control_replace scripts/lib/formatters.sh 1 \
    '            related: issue_related_ids(.issue.relations.nodes; .issue.inverseRelations.nodes),' \
    '            related: [(.issue.relations.nodes // [])[] | select(.type == "related") | .relatedIssue.identifier],'

# 4. The list-relations rows.
control_expect "list-relations lists the inverse related row"
control_replace scripts/lib/formatters.sh 1 \
    '        related: issue_related_rows(.issue.relations.nodes; .issue.inverseRelations.nodes),' \
    '        related: [(.issue.relations.nodes // [])[] | select(.type == "related") | issue_related_row(.relatedIssue)],'

# 5. No deduplication by relation id.
control_expect "a relation on both sides is listed once"
control_replace scripts/lib/formatters.sh 1 \
    '    ) as $row ([]; if any(.[]; .relation_id == $row.relation_id) then . else . + [$row] end);' \
    '    ) as $row ([]; . + [$row]);'

# 6. A duplicate is directional: the inverse side is the original, not a
#    duplicate, so reading it there lists the wrong direction.
control_expect "list-relations keeps an inverse duplicate out of duplicates"
control_replace scripts/lib/formatters.sh 1 \
    '        duplicates: [(.issue.relations.nodes // [])[] | select(.type == "duplicate") | {' \
    '        duplicates: [((.issue.relations.nodes // []) + (.issue.inverseRelations.nodes // []))[] | select(.type == "duplicate") | {'
