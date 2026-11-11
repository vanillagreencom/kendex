# Revert the issues-list projection, which bulk-get and list print, to
# reading relations alone.
control_expect "bulk-get lists the inverse related issue"
control_expect "list lists the inverse related issue"
control_replace scripts/lib/formatters.sh 1 \
    '        related: issue_related_ids(.relations.nodes; .inverseRelations.nodes),' \
    '        related: [(.relations.nodes // [])[] | select(.type == "related") | .relatedIssue.identifier],'
