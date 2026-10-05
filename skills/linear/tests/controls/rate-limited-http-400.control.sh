# Stop reclassifying a RATELIMITED body served with HTTP 400. The response then
# routes to the generic HTTP-error path, so callers are told the request was
# malformed rather than that they are being throttled.
control_expect "rate-limited 400 reports the rate limit"
control_replace scripts/lib/common.sh 1 \
    '            code=429' \
    '            :'

# Retry every non-200 answer again, so a scope or validation refusal costs
# three requests and three waits before it fails.
control_expect "a generic 400 fails on its first answer"
control_replace scripts/lib/common.sh 1 \
    '    429 | 5?? | 000) ;;' \
    '    *) ;;'

# Drop the header read, so a rate limit names no time the quota refills.
control_expect "a rate limit names the Requests-Reset time"
control_replace scripts/lib/common.sh 1 \
    "        reset=\$(jq -rn --arg ms \"\$value\" '\$ms | tonumber / 1000 | floor | todate') || return 1" \
    '        reset=unavailable'

# A request that reached no server fails on its first try.
control_expect "an unanswered request is retried"
control_replace scripts/lib/common.sh 1 \
    '    429 | 5?? | 000) ;;' \
    '    429 | 5??) ;;'

# Only a non-200 answer is read for the RATELIMITED code.
control_expect "a RATELIMITED body on HTTP 200 reports the rate limit"
control_replace scripts/lib/common.sh 1 \
    "        if jq -e '[.errors[]? | select(.extensions.code == \"RATELIMITED\")] | length > 0' >/dev/null 2>&1 <<<\"\$body\"; then" \
    "        if [[ \"\$code\" != 200 ]] && jq -e '[.errors[]? | select(.extensions.code == \"RATELIMITED\")] | length > 0' >/dev/null 2>&1 <<<\"\$body\"; then"

# Only the first header block is split off, so a reply after an interim block
# reads the response's headers as its body.
control_expect "a reply after an interim header block names the Requests-Reset time"
control_replace scripts/lib/common.sh 1 \
    "        while [[ \"\$body\" == HTTP/* && \"\$body\" == *\$'\\r\\n\\r\\n'* ]]; do" \
    "        for _ in once; do"

# Headers are split off a failed reply only, so a 200's are read as its body.
control_expect "a header-prefixed 200 reads its body"
control_replace scripts/lib/common.sh 1 \
    "        while [[ \"\$body\" == HTTP/* && \"\$body\" == *\$'\\r\\n\\r\\n'* ]]; do" \
    "        while [[ \"\$code\" != 200 && \"\$body\" == HTTP/* && \"\$body\" == *\$'\\r\\n\\r\\n'* ]]; do"

# The GraphQL path hands the retry decision no headers, so a Retry-After is
# never waited out.
control_expect "a rate-limited answer waits out its Retry-After"
control_replace scripts/lib/common.sh 1 \
    '        if linear_retry_wait "$code" "$attempt" "$headers"; then' \
    "        if linear_retry_wait \"\$code\" \"\$attempt\" ''; then"
