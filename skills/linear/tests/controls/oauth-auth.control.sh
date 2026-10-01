control_expect 'normal Git redirects: OAuth suite succeeds'
control_expect 'linked Git redirects: OAuth suite succeeds'
control_replace tests/oauth-auth.test.sh 1 \
    'unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE' \
    ': unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE'
control_expect 'cache: mint count'
control_replace scripts/lib/auth.sh 1 \
    '    if [[ "${1:-}" != "renew" && -f "$token_file" ]]; then' \
    '    if [[ "${1:-}" == "always-mint" && -f "$token_file" ]]; then'

control_expect 'before-expiry: mint count'
control_replace scripts/lib/auth.sh 1 \
    '            select(.expires_at > ($now + 60)) | .access_token |' \
    '            select(.expires_at > ($now - 60)) | .access_token |'

control_expect '401 renewal succeeds'
control_replace scripts/lib/common.sh 1 \
    '            if [[ "$LINEAR_AUTH_KIND" == "app" && "$auth_renewed" == 0 ]]; then' \
    '            if [[ "$LINEAR_AUTH_KIND" == "app" && "$auth_renewed" == 9 ]]; then'

control_expect 'mint: request succeeds'
control_replace scripts/lib/auth.sh 1 \
    '    LINEAR_AUTH_KIND="app"' \
    '    LINEAR_AUTH_KIND="api-key"'

control_expect 'no-credentials: no request reaches GraphQL'
control_replace scripts/lib/auth.sh 1 \
    '    LINEAR_AUTH_KIND="unset"' \
    '    LINEAR_AUTH_KIND="api-key"; LINEAR_API_KEY="missing"'

control_expect 'partial-app: no request reaches GraphQL'
control_replace scripts/lib/auth.sh 1 \
    '    LINEAR_AUTH_KIND="incomplete-app"' \
    '    LINEAR_AUTH_KIND="api-key"; LINEAR_API_KEY="missing"'

control_expect 'app-shadow: credential report'
control_replace scripts/commands/auth-check.sh 1 \
    'if [[ "$LINEAR_AUTH_KIND" == "api-key" ]]; then' \
    'if [[ "$LINEAR_AUTH_KIND" == "api-key" || "$LINEAR_AUTH_KIND" == "app" ]]; then'

control_expect 'attachment download uses selected app'
control_replace scripts/lib/attachments.sh 1 \
    '    authorization_quote=$(curl_config_quote "Authorization: $authorization") || return 1' \
    '    authorization_quote=$(curl_config_quote "Authorization: ${LINEAR_API_KEY:-}") || return 1'

control_expect 'mint keeps client credentials out of jq arguments'
control_replace scripts/lib/auth.sh 1 \
    '    payload=$(printf '\''%s\0%s'\'' "$LINEAR_CLIENT_ID" "$LINEAR_CLIENT_SECRET" | jq -Rsr '\''' \
    '    payload=$(printf '\''%s\0%s'\'' "$LINEAR_CLIENT_ID" "$LINEAR_CLIENT_SECRET" | jq -Rsr --arg secret "$LINEAR_CLIENT_SECRET" '\'''

control_expect 'attachment download keeps token out of curl arguments'
control_expect 'app-renew: renewed token stays out of curl arguments'
control_replace scripts/lib/attachments.sh 1 \
    '            | curl -s -w "%{http_code}" -o "$tmp_file" -D "$tmp_headers" -K -' \
    '            | curl -s -w "%{http_code}" -o "$tmp_file" -D "$tmp_headers" -K - -H "Authorization: $authorization"'

control_expect 'live references: resolved credentials reach token endpoint'
control_replace scripts/lib/auth.sh 1 \
    '    app) set -- LINEAR_CLIENT_ID LINEAR_CLIENT_SECRET ;;' \
    '    app) return 0 ;;'

control_expect 'partial-app-with-key: no request reaches GraphQL'
control_replace scripts/lib/auth.sh 1 \
    '    LINEAR_AUTH_KIND="incomplete-app"' \
    '    LINEAR_AUTH_KIND="incomplete-app"; if [[ -n "${LINEAR_API_KEY:-}" ]]; then LINEAR_AUTH_KIND="api-key"; fi'

control_expect 'inventory references: request succeeds'
control_replace scripts/lib/auth.sh 2 \
    '    linear_resolve_credentials || return 1' \
    '    : linear_resolve_credentials || return 1'

control_expect 'app-renew: download result'
control_replace scripts/lib/attachments.sh 1 \
    '        if [[ "$http_code" == "401" && "$LINEAR_AUTH_KIND" == "app" && "$auth_renewed" == 0 ]]; then' \
    '        if [[ "$http_code" == "401" && "$LINEAR_AUTH_KIND" == "app" && "$auth_renewed" == 9 ]]; then'

control_expect 'app-second-401: download result'
control_replace scripts/lib/attachments.sh 1 \
    '            auth_renewed=1' \
    '            auth_renewed=0'

control_expect 'key-401: download attempts'
control_replace scripts/lib/attachments.sh 1 \
    '        if [[ "$http_code" == "401" && "$LINEAR_AUTH_KIND" == "app" && "$auth_renewed" == 0 ]]; then' \
    '        if [[ "$http_code" == "401" && "$auth_renewed" == 0 ]]; then'

control_expect 'app-renew-failure: download result'
control_replace scripts/lib/attachments.sh 1 \
    '            if ! authorization=$(linear_authorization renew) ||' \
    '            if authorization=$(linear_authorization renew) &&'

control_expect 'app-renew: download keeps selected actor'
control_replace scripts/lib/attachments.sh 1 \
    '            if ! authorization=$(linear_authorization renew) ||' \
    '            if ! authorization=$(linear_authorization) ||'

# Without the new selection branch, the prior auth implementation is reached.
control_expect 'token-only: request succeeds'
control_replace scripts/lib/auth.sh 1 \
    'if [[ -n "${LINEAR_APP_TOKEN:-}" ]]; then' \
    'if [[ -n "${LINEAR_APP_TOKEN:-}" && -z "${LINEAR_APP_TOKEN:-}" ]]; then'

control_expect 'token-beats-pair: request succeeds'
control_replace scripts/lib/auth.sh 1 \
    'if [[ -n "${LINEAR_APP_TOKEN:-}" ]]; then' \
    'if [[ -n "${LINEAR_APP_TOKEN:-}" && -z "${LINEAR_CLIENT_ID:-}${LINEAR_CLIENT_SECRET:-}" ]]; then'

control_expect 'token-only: GraphQL Bearer header'
control_replace scripts/lib/auth.sh 1 \
    '        printf '\''Bearer %s'\'' "$LINEAR_APP_TOKEN"' \
    '        printf '\''%s'\'' "$LINEAR_APP_TOKEN"'

control_expect 'token-only: cache directory absent'
control_replace scripts/lib/auth.sh 1 \
    '        printf '\''Bearer %s'\'' "$LINEAR_APP_TOKEN"' \
    '        printf '\''Bearer %s'\'' "$LINEAR_APP_TOKEN"; mkdir -p -- "$PROJECT_ROOT/.cache/linear/oauth"'

control_expect 'token-reference: only token resolves'
control_replace scripts/lib/auth.sh 1 \
    '    app-token) set -- LINEAR_APP_TOKEN ;;' \
    '    app-token) return 0 ;;'

control_expect 'token-check: application actor'
control_replace scripts/commands/auth-check.sh 1 \
    'actor=$(jq -c --arg kind "$LINEAR_AUTH_KIND" '\''{kind: (if $kind == "app" or $kind == "app-token" then "application" else "user" end), id: .viewer.id, name: .viewer.name}'\'' <<<"$result")' \
    'actor=$(jq -c --arg kind "$LINEAR_AUTH_KIND" '\''{kind: (if $kind == "app" then "application" else "user" end), id: .viewer.id, name: .viewer.name}'\'' <<<"$result")'

control_expect 'token-401: one request uses environment token'
control_replace scripts/lib/common.sh 1 \
    '            if [[ "$LINEAR_AUTH_KIND" == "app" && "$auth_renewed" == 0 ]]; then' \
    '            if [[ "$LINEAR_AUTH_KIND" != "api-key" && "$auth_renewed" == 0 ]]; then'

control_expect 'token-download-401: one download uses Bearer token'
control_replace scripts/lib/attachments.sh 1 \
    '        if [[ "$http_code" == "401" && "$LINEAR_AUTH_KIND" == "app" && "$auth_renewed" == 0 ]]; then' \
    '        if [[ "$http_code" == "401" && "$LINEAR_AUTH_KIND" != "api-key" && "$auth_renewed" == 0 ]]; then'

control_expect 'token-401: credential diagnostic'
control_replace scripts/lib/common.sh 1 \
    '            linear_auth_unauthorized' \
    '            : linear_auth_unauthorized'

control_expect 'token-401: token replacement guidance'
control_replace scripts/lib/auth.sh 1 \
    '          (if $kind == "app-token" then "\nApplication token is expired or revoked. Replace LINEAR_APP_TOKEN." else "" end))}'\'' >&2' \
    '          (if $kind == "app-token" then "" else "" end))}'\'' >&2'

control_expect 'token-download-401: credential diagnostic'
control_replace scripts/lib/attachments.sh 1 \
    '            linear_auth_unauthorized' \
    '            : linear_auth_unauthorized'

# Mint controls pair each defect with the first assertion it reddens.
# Output-only defects stay at the command boundary: the cached-pair caller
# needs the helper's JSON to reach the auth-mint cases without aborting.
while IFS=$'\t' read -r expectation path old replacement; do
    control_expect "$expectation"
    control_replace "$path" 1 "$old" "$replacement"
done <<'MINT_CONTROLS'
mint-host: mint succeeds	scripts/commands/auth-mint.sh	export LINEAR_SKIP_API_KEY_RESOLUTION=1	export LINEAR_SKIP_API_KEY_RESOLUTION=0
mint-host-reference: only pair resolves	scripts/lib/auth.sh	    local LINEAR_AUTH_KIND="app"	    local LINEAR_AUTH_KIND="app"; if [[ "${LINEAR_SKIP_API_KEY_RESOLUTION:-}" == 1 && "${LINEAR_CLIENT_ID:-}" == op://* ]]; then LINEAR_AUTH_KIND="unset"; fi
mint-missing: refuses	scripts/lib/auth.sh	    if [[ -z "${LINEAR_CLIENT_ID:-}" || -z "${LINEAR_CLIENT_SECRET:-}" ]]; then	    if [[ -z "${LINEAR_CLIENT_ID:-}" && -n "${LINEAR_CLIENT_ID:-}" ]]; then
mint-host: token JSON	scripts/commands/auth-mint.sh	linear_mint_token	linear_mint_token | jq '.access_token'
mint-host: cache directory absent	scripts/commands/auth-mint.sh	linear_mint_token	linear_mint_token; mkdir -p -- "$PROJECT_ROOT/.cache/linear/oauth"
mint-response-type: refuses	scripts/lib/auth.sh	        select(.token_type == "Bearer") |	        select(.token_type == "Bearer" or true) |
mint-response-empty: refuses	scripts/lib/auth.sh	        select(.access_token | type == "string" and length > 0) |	        select(.access_token | type == "string") |
mint-response-expiry-low: refuses	scripts/lib/auth.sh	        select(.expires_in | type == "number" and . > 60 and . <= 2592000 and . == floor) |	        select(.expires_in | type == "number" and . >= 60 and . <= 2592000 and . == floor) |
mint-response-expiry-high: refuses	scripts/lib/auth.sh	        select(.expires_in | type == "number" and . > 60 and . <= 2592000 and . == floor) |	        select(.expires_in | type == "number" and . > 60 and . <= 2592001 and . == floor) |
mint-response-expiry-fraction: refuses	scripts/lib/auth.sh	        select(.expires_in | type == "number" and . > 60 and . <= 2592000 and . == floor) |	        select(.expires_in | type == "number" and . > 60 and . <= 2592000) |
mint-token-failure: diagnostic	scripts/lib/auth.sh	    if [[ "$http_code" != "200" ]]; then	    if [[ "$http_code" == "200" && "$http_code" != "200" ]]; then
mint-token-transport: diagnostic	scripts/lib/auth.sh	    ) || { echo '{"error": "linear-auth: token=transport-failed"}' >&2; return 1; }	    ) || { echo '{"error": "linear-auth: token=transport-failed"}' >/dev/null; return 1; }
MINT_CONTROLS

control_expect 'token-beats-partial: request succeeds'
control_replace scripts/lib/auth.sh 1 \
    '    app-token|app|api-key) return 0 ;;' \
    '    app|api-key) return 0 ;;'
