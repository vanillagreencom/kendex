# Each mutation changes a disposable skill copy and names its assertion.
# A download goes to any host, carrying the Linear credential there.
control_expect 'foreign host: sends no request'
control_replace scripts/commands/attachments.sh 1 \
    '    if [[ "$url" != https://uploads.linear.app/* ]]; then' \
    '    if false; then'
# A link a record already names is listed a second time.
control_expect 'list: a record and a link with one url list once'
control_replace scripts/commands/attachments.sh 1 \
    '            | add // [] | unique_by(.url) | map(select(.url as $u | $recorded | index($u) | not)))'\'' <<<"$result"' \
    '            | add // [] | unique_by(.url))'\'' <<<"$result"'
# A record on any host is listed, so a fetch of it would send the credential.
control_expect 'list: a record off the upload host is left out'
control_replace scripts/commands/attachments.sh 1 \
    '        [$issue.attachments.nodes[] | select(.url | startswith("https://uploads.linear.app/"))' \
    '        [$issue.attachments.nodes[]'
# A read that found no issue goes on to list one.
control_expect 'list of a missing issue: names the issue'
control_replace scripts/commands/attachments.sh 1 \
    "    if ! jq -e '.issue.id | strings | select(length > 0)' <<<\"\$result\" >/dev/null; then" \
    '    if false; then'
