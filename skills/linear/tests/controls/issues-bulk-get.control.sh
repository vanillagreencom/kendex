# Each mutation changes a disposable skill copy and names its assertion.
# A UUID refuses as no issue identifier.
control_expect 'a UUID reads its issue'
control_replace scripts/lib/common.sh 1 \
    '        def accepted: identifier or ($kind == "refs" and uuid);'"'"'' \
    '        def accepted: identifier;'"'"''
# The batch answers a reference by identifier alone, so a UUID costs a lookup.
control_expect 'mixed refs are read in one request'
control_replace scripts/lib/common.sh 1 \
    '        | {key: $r, value: ([$rows[] | select(.identifier == $r or .id == $r) | .identifier] | first)}]' \
    '        | {key: $r, value: ([$rows[] | select(.identifier == $r) | .identifier] | first)}]'
# The rows print in the order Linear returned them.
control_expect 'the issues print in the order named'
control_replace scripts/lib/common.sh 1 \
    '        | {nodes: ([$refs[] | $answered[.] as $id | $rows[] | select(.identifier == $id)] | reduce .[] as $row ([];' \
    '        | {nodes: ([$rows[]] | reduce .[] as $row ([];'
# The batch leaves archived issues out, so each costs a lookup.
control_expect 'an archived issue is read in one request'
control_replace scripts/lib/common.sh 1 \
    '        issues(filter: \$filter, first: 50, after: \$after, includeArchived: true) {' \
    '        issues(filter: \$filter, first: 50, after: \$after) {'
# Two refs naming one issue print it twice.
control_expect 'two refs naming one issue print it once'
control_replace scripts/lib/common.sh 1 \
    '            if any(.[]; .id == $row.id) then . else . + [$row] end)),' \
    '            . + [$row])),'
# A reference the batch leaves unanswered is never looked up.
control_expect "a moved issue's earlier identifier resolves"
control_replace scripts/lib/common.sh 1 \
    '        result=$(graphql_query "query IssueRef(\$id: String!) { issue(id: \$id) { $fields } }" "$variables") || rc=$?' \
    '        rc=2'
# Every failed lookup reads as an issue Linear does not have, and the loop
# goes on to the refs after it.
control_expect 'a rate-limited lookup fails the read without missing'
control_expect 'a 503 lookup fails the read without missing'
control_replace scripts/lib/common.sh 1 \
    '        if ((rc == 2)); then' \
    '        if ((rc != 0)); then'
# A reference no read answers is dropped.
control_expect 'an unknown reference refuses the read'
control_replace scripts/lib/common.sh 1 \
    '            missing=$(jq -c --arg ref "$ref" '"'"'. + [$ref]'"'"' <<<"$missing") || return 1' \
    '            :'
