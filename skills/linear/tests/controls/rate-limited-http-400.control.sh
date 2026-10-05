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
    '    *) return 1 ;;' \
    '    *) ;;'

# Drop the header read, so a rate limit names no time the quota refills.
control_expect "a rate limit names the Requests-Reset time"
control_replace scripts/lib/common.sh 1 \
    "        reset=\$(jq -rn --arg ms \"\$value\" '\$ms | tonumber / 1000 | floor | todate') || return 1" \
    '        reset=unavailable'

# A request that reached no server fails on its first try.
control_expect "an unanswered request is retried"
control_replace scripts/lib/common.sh 1 \
    '    5?? | 000)' \
    '    5??)'

# Send every 5xx or unanswered request again, so a mutation Linear applied and
# answered 502, or whose answer was lost, is applied twice.
control_expect "a mutation answered 5xx is sent once"
control_expect "an unanswered mutation is sent once"
control_replace scripts/lib/common.sh 1 \
    '        if [[ "$kind" != read ]]; then' \
    '        if false; then'

# Retry reads alone, so a rate-limited mutation, which Linear refused unrun,
# fails on its first refusal.
control_expect "a rate-limited mutation is retried"
control_replace scripts/lib/common.sh 1 \
    '    429) ;;' \
    '    429) [[ "$kind" == read ]] || return 1 ;;'

# Place every document as a write, so a query answered 5xx fails on its first
# answer.
control_expect "a 5xx is retried"
control_replace scripts/lib/common.sh 1 \
    "    local read_pattern='^[[:space:]]*(query[^_[:alnum:]]|\\{)'" \
    "    local read_pattern='^\$'"

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
    '        if linear_retry_wait "$kind" "$code" "$attempt" "$headers"; then' \
    "        if linear_retry_wait \"\$kind\" \"\$code\" \"\$attempt\" ''; then"

# Say nothing when a write is left unconfirmed, so the caller reads a plain
# HTTP error and sends the write again unchecked.
control_expect "a mutation answered 5xx is sent once: names the write unconfirmed"
control_replace scripts/lib/common.sh 1 \
    "            printf 'linear-http: write=unconfirmed code=%s\\nLinear may have applied this write; read its result before sending it again.\\n' \"\$code\" >&2" \
    '            :'
