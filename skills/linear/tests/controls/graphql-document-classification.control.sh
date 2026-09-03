# Add a document that buries its mutation behind a leading fragment. The
# classifier reads the leading token, so such a document posts as a read and
# skips the team guard entirely — the shape this lint exists to forbid.
control_expect "every document classifies as its operation"
control_append scripts/commands/labels.sh \
    "_control_buried_mutation='fragment L on IssueLabel { id } mutation BuriedCreate(\$input: IssueLabelCreateInput!) { issueLabelCreate(input: \$input) { success } }'"
