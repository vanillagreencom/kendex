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
control_replace scripts/lib/auth.sh 1 \
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
