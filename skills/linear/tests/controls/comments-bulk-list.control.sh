# Each mutation changes a disposable skill copy and names its assertion.
# An identifier Linear returned no issue for reads as an issue with no comments.
control_expect 'missing: refuses'
control_replace scripts/lib/common.sh 1 \
    '    if [[ "$missing" != "[]" ]]; then' \
    '    if false; then'
# An argument that is no identifier is sent as one.
control_expect 'not an identifier: refuses before any request'
control_replace scripts/lib/common.sh 1 \
    '    if [[ "$bad" != "[]" ]]; then' \
    '    if false; then'
# A multi-line argument passes the identifier shape line by line and is sent.
control_expect 'a line break: refuses before any request'
control_replace scripts/lib/common.sh 1 \
    '    local defs='\''def identifier: test("\\A[A-Za-z0-9]+-[0-9]+\\z");' \
    '    local defs='\''def identifier: test("^[A-Za-z0-9]+-[0-9]+$");'
# A UUID is taken where only an identifier keys the output.
control_expect 'a UUID: refuses before any request'
control_replace scripts/lib/common.sh 1 \
    '        def accepted: identifier or ($kind == "refs" and uuid);'"'"'' \
    '        def accepted: identifier or uuid;'"'"''
# The output keys each named identifier to the read row under its own name, so
# a moved issue's earlier identifier, which names no row, reads as null.
control_expect "a moved issue's earlier identifier keys the comments of the issue it names"
control_replace scripts/commands/comments.sh 1 \
    '        | reduce $ids[] as $i ({}; .[$i] = $read[$refs[$i]])' \
    '        | reduce $ids[] as $i ({}; .[$i] = $read[$i])'
# A moved issue's lookup is read as answered, its open comments connection
# left at the first page.
control_expect "a moved issue's comments past one page are read to the end"
control_replace scripts/lib/common.sh 1 \
    '        result=$(graphql_query "query IssueRef(\$id: String!) { issue(id: \$id) { $fields } }" "$variables") || rc=$?' \
    '        result=$(graphql_request "query IssueRef(\$id: String!) { issue(id: \$id) { $fields } }" "$variables") || rc=$?'
# Linear's "Entity not found" answer fails the request like any other error,
# so the identifier it names is never listed as missing.
control_expect 'missing: names the identifier'
control_replace scripts/lib/common.sh 1 \
    '                "Entity not found: "*)' \
    '                "Entity not found (control): "*)'

control_expect 'safe comments: author email'
control_replace scripts/lib/formatters.sh 1 \
    '    user_email: (.user.email // ""),' \
    '    user_email: "",'
control_expect 'comment query: requests email'
control_replace scripts/commands/comments.sh 1 \
    '                        user { name email }' \
    '                        user { name }'
control_expect 'continued comment query: requests email'
control_replace scripts/lib/pages.sh 1 \
    "    issue:comments) printf '%s' 'id body createdAt updatedAt user { name email }' ;;" \
    "    issue:comments) printf '%s' 'id body createdAt updatedAt user { name }' ;;"
