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
# A bare link keeps the punctuation of the sentence it ends.
control_expect 'list: a bare link drops trailing prose punctuation'
control_replace scripts/commands/attachments.sh 1 \
    '             | if .destination then .url else .url | sub("[?!.,:;*_~]+$"; "") end' \
    '             | .url'
# A Markdown link destination is trimmed as a bare link is.
control_expect 'list: a Markdown link destination keeps its url as written'
control_replace scripts/commands/attachments.sh 1 \
    '             | if .destination then .url else .url | sub("[?!.,:;*_~]+$"; "") end' \
    '             | .url | sub("[?!.,:;*_~]+$"; "")'
# A download is sent once, whatever it is answered.
control_expect 'a 503 is retried: attempts'
control_replace scripts/commands/attachments.sh 1 \
    '        if linear_retry_wait read "$code" "$attempt" "$headers"; then' \
    '        if false; then'
# The answer's Retry-After is never read.
control_expect 'a Retry-After within the bound is waited out: waits'
control_replace scripts/lib/common.sh 1 \
    '        ((after <= delay)) || delay="$after"' \
    '        :'
# A Retry-After past the bound is cut to the bound and sent again early.
control_expect 'a Retry-After past the bound fails at once: attempts'
control_replace scripts/lib/common.sh 1 \
    '        ((after <= 60)) || return 1' \
    '        ((after <= 60)) || after=60'
# A Retry-After shorter than the backoff replaces it.
control_expect 'a Retry-After shorter than the backoff waits the backoff: waits'
control_replace scripts/lib/common.sh 1 \
    '        ((after <= delay)) || delay="$after"' \
    '        delay="$after"'
# A final 429 download is reported as any failed download, without the time
# the request quota refills.
control_expect 'a download rate-limited past its retries reports the rate limit: rate limit'
control_replace scripts/commands/attachments.sh 1 \
    '    if [[ "$code" == 429 ]]; then' \
    '    if false; then'
