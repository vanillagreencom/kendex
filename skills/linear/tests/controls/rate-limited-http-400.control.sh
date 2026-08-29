# Stop reclassifying a RATELIMITED body served with HTTP 400. The response then
# routes to the generic HTTP-error path, so callers are told the request was
# malformed rather than that they are being throttled.
control_expect "rate-limited 400 reports the rate limit"
control_replace scripts/lib/common.sh 1 \
    '            http_code=429' \
    '            :'
