# A moved issue's lookup is read as answered, its open comments connection
# left at the first page.
control_expect "a moved issue's comments past one page are read to the end"
control_replace scripts/lib/common.sh 1 \
    '        result=$(graphql_query "query IssueRef(\$id: String!) { issue(id: \$id) { $fields } }" "$variables") || rc=$?' \
    '        result=$(graphql_request "query IssueRef(\$id: String!) { issue(id: \$id) { $fields } }" "$variables") || rc=$?'
