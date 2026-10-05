control_expect 'normal Git redirects: OAuth suite succeeds'
control_expect 'linked Git redirects: OAuth suite succeeds'
control_replace tests/oauth-auth.test.sh 1 \
    'unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE' \
    ': unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE'
# The token file is never read back, so every request mints.
control_expect 'reuse: mint count'
control_expect 'two-requests: one mint serves both'
control_replace scripts/lib/auth.sh 1 \
    '    if [[ -n "$dir" && "${1:-}" != "renew" && -f "$token_file" ]]; then' \
    '    if false; then'

# A token is reused up to its expiry, so a request can carry one that expires
# in transit.
control_expect 'near-expiry: Bearer token reaches GraphQL'
control_replace scripts/lib/auth.sh 1 \
    '            select(.expires_at > ($now + 60)) | .access_token |' \
    '            select(.expires_at > 0) | .access_token |'

control_expect 'token file: private'
control_replace scripts/lib/auth.sh 1 \
    '    umask 077' \
    '    umask 022'

control_expect 'token file: one file, under HOME'
control_replace scripts/lib/auth.sh 1 \
    "    if [[ -n \"\$dir\" ]] && ! { printf '%s\n' \"\$cached\" >\"\$staged\" &&" \
    "    if [[ -n \"\$dir\" ]] && ! { mkdir -p -- \"\$PROJECT_ROOT/oauth\" && printf '%s\n' \"\$cached\" >\"\$PROJECT_ROOT/oauth/copy.json\" && printf '%s\n' \"\$cached\" >\"\$staged\" &&"

# A renewal is used once and never written back.
control_expect '401 renewal: the next invocation reuses the renewed token'
control_replace scripts/lib/auth.sh 1 \
    '        mv -f -- "$staged" "$token_file"; } 2>/dev/null; then' \
    '        { [[ "${1:-}" == renew ]] || mv -f -- "$staged" "$token_file"; }; } 2>/dev/null; then'

# The pair mints when common.sh loads, whether or not a request follows.
control_expect 'no-request: never mints'
control_append scripts/lib/common.sh \
    '[[ "$LINEAR_AUTH_KIND" != app || "${LINEAR_SKIP_API_KEY_RESOLUTION:-}" == 1 ]] || linear_authorization >/dev/null'

control_expect 'auth-check: a failed mint prints its report'
control_replace scripts/commands/auth-check.sh 1 \
    '  emit false "API request failed"' \
    '  :'

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
control_replace scripts/commands/attachments.sh 1 \
    '    header=$(curl_config_quote "Authorization: $authorization") || return 1' \
    '    header=$(curl_config_quote "Authorization: ${LINEAR_API_KEY:-}") || return 1'

control_expect 'mint keeps client credentials out of jq arguments'
control_replace scripts/lib/auth.sh 1 \
    '    payload=$(printf '\''%s\0%s'\'' "$LINEAR_CLIENT_ID" "$LINEAR_CLIENT_SECRET" | jq -Rsr --arg scope "$_LINEAR_APP_SCOPE" '\''' \
    '    payload=$(printf '\''%s\0%s'\'' "$LINEAR_CLIENT_ID" "$LINEAR_CLIENT_SECRET" | jq -Rsr --arg scope "$_LINEAR_APP_SCOPE" --arg secret "$LINEAR_CLIENT_SECRET" '\'''

control_expect 'mint sends fixed scope and encoded client credentials'
control_replace scripts/lib/auth.sh 1 \
    '_LINEAR_APP_SCOPE="read,write,issues:create,comments:create,timeSchedule:write,initiative:read,initiative:write,customer:read,customer:write"' \
    '_LINEAR_APP_SCOPE="read,write,initiative:read"'

control_expect 'old-scope token file: scope change mints a new token'
control_replace scripts/lib/auth.sh 1 \
    '    identity=$(linear_key_fingerprint "$LINEAR_CLIENT_ID:$LINEAR_CLIENT_SECRET:$_LINEAR_APP_SCOPE") || return 1' \
    '    identity=$(linear_key_fingerprint "$LINEAR_CLIENT_ID:$LINEAR_CLIENT_SECRET") || return 1'

# A store failure after a successful mint fails the request again.
control_expect 'symlink: requests succeed'
control_replace scripts/lib/auth.sh 1 \
    '    [[ -n "$dir" ]] ||' \
    '    [[ -n "$dir" ]] || return 1 ||'

# The token has one store, the user's cache directory.
control_expect 'unwritable cache dir: one mint serves both requests'
control_replace scripts/lib/auth.sh 1 \
    '    for candidate in "$base/kendex/linear-oauth" "${TMPDIR:-/tmp}/kendex-linear-oauth-$UID"; do' \
    '    for candidate in "$base/kendex/linear-oauth"; do'

# A directory this session cannot write is still taken, so a revoked token
# there is read ahead of the renewal it cannot hold.
control_expect 'read-only cache dir: one mint across two invocations'
control_replace scripts/lib/auth.sh 1 \
    '        elif ! staged=$(mktemp "$candidate/.token.XXXXXX" 2>/dev/null); then' \
    '        elif ! staged=$(mktemp "$candidate/.token.XXXXXX" 2>/dev/null) && false; then'

# Any directory entry under TMPDIR is taken, a symlink included.
control_expect 'symlink: each request carries its minted token'
control_replace scripts/lib/auth.sh 1 \
    '        elif [[ -L "$candidate" ]]; then' \
    '        elif false; then'

# The store-failure line drops each directory and its cause.
control_expect 'symlink: stderr names each directory and its cause'
control_replace scripts/lib/auth.sh 1 \
    '        failed+=" dir=[$candidate] cause=$cause"' \
    '        :'

control_expect 'write-failed: stderr names each directory and its cause'
control_replace scripts/lib/auth.sh 1 \
    '        failed+=" dir=[$dir] cause=write-failed"' \
    '        :'

# The staged file outlives a failed store.
control_expect 'write-failed: no token file and no staged file is written'
control_replace scripts/lib/auth.sh 1 \
    "    trap '[[ -z \"\${staged:-}\" ]] || rm -f -- \"\${staged:?}\"' EXIT" \
    "    trap ':' EXIT"

control_expect 'attachment download keeps token out of curl arguments'
control_expect 'app-renew: renewed token stays out of curl arguments'
control_replace scripts/commands/attachments.sh 1 \
    "            curl -s -o \"\$temp\" -w '%{http_code}' -K -); then" \
    "            curl -s -o \"\$temp\" -w '%{http_code}' -K - -H \"Authorization: \$authorization\"); then"

control_expect 'live references: resolved credentials reach token endpoint'
control_replace scripts/lib/auth.sh 1 \
    '    app) set -- LINEAR_CLIENT_ID LINEAR_CLIENT_SECRET ;;' \
    '    app) return 0 ;;'

control_expect 'partial-app-with-key: no request reaches GraphQL'
control_replace scripts/lib/auth.sh 1 \
    '    LINEAR_AUTH_KIND="incomplete-app"' \
    '    LINEAR_AUTH_KIND="incomplete-app"; if [[ -n "${LINEAR_API_KEY:-}" ]]; then LINEAR_AUTH_KIND="api-key"; fi'

control_expect 'mint-host-reference: resolved pair reaches mint'
control_replace scripts/lib/auth.sh 2 \
    '    linear_resolve_credentials || return 1' \
    '    : linear_resolve_credentials || return 1'

control_expect 'app-renew: download result'
control_replace scripts/commands/attachments.sh 1 \
    '        if [[ "$code" == 401 && "$LINEAR_AUTH_KIND" == app && "$renewed" == 0 ]]; then' \
    '        if [[ "$code" == 401 && "$LINEAR_AUTH_KIND" == app && "$renewed" == 9 ]]; then'

control_expect 'app-second-401: download result'
control_replace scripts/commands/attachments.sh 1 \
    '            renewed=1' \
    '            renewed=0'

control_expect 'key-401: download attempts'
control_replace scripts/commands/attachments.sh 1 \
    '        if [[ "$code" == 401 && "$LINEAR_AUTH_KIND" == app && "$renewed" == 0 ]]; then' \
    '        if [[ "$code" == 401 && "$renewed" == 0 ]]; then'

control_expect 'app-renew-failure: download result'
control_replace scripts/commands/attachments.sh 1 \
    '            authorization=$(linear_authorization renew) || return 1' \
    '            authorization=$(linear_authorization renew) || true'

control_expect 'app-renew: download keeps selected actor'
control_replace scripts/commands/attachments.sh 1 \
    '            authorization=$(linear_authorization renew) || return 1' \
    '            authorization=$(linear_authorization) || return 1'

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
    '        printf '\''Bearer %s'\'' "$LINEAR_APP_TOKEN"; mkdir -p -- "$HOME/.cache/kendex/linear-oauth"'

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
control_replace scripts/commands/attachments.sh 1 \
    '        if [[ "$code" == 401 && "$LINEAR_AUTH_KIND" == app && "$renewed" == 0 ]]; then' \
    '        if [[ "$code" == 401 && "$LINEAR_AUTH_KIND" != api-key && "$renewed" == 0 ]]; then'

control_expect 'token-401: credential diagnostic'
control_replace scripts/lib/common.sh 1 \
    '            linear_auth_unauthorized' \
    '            : linear_auth_unauthorized'

control_expect 'token-401: token replacement guidance'
control_replace scripts/lib/auth.sh 1 \
    '          (if $kind == "app-token" then "\nApplication token is expired or revoked. Replace LINEAR_APP_TOKEN." else "" end))}'\'' >&2' \
    '          (if $kind == "app-token" then "" else "" end))}'\'' >&2'

control_expect 'token-download-401: credential diagnostic'
control_replace scripts/commands/attachments.sh 1 \
    '            linear_auth_unauthorized' \
    '            : linear_auth_unauthorized'

# Mint controls pair each defect with the first assertion it reddens.
# Output-only defects stay at the command boundary: the API path's own mint
# needs the helper's JSON to reach the auth-mint cases without aborting.
while IFS=$'\t' read -r expectation path old replacement; do
    control_expect "$expectation"
    control_replace "$path" 1 "$old" "$replacement"
done <<'MINT_CONTROLS'
mint-host: mint succeeds	scripts/commands/auth-mint.sh	export LINEAR_SKIP_API_KEY_RESOLUTION=1	export LINEAR_SKIP_API_KEY_RESOLUTION=0
mint-host-reference: only pair resolves	scripts/lib/auth.sh	    local LINEAR_AUTH_KIND="app"	    local LINEAR_AUTH_KIND="app"; if [[ "${LINEAR_SKIP_API_KEY_RESOLUTION:-}" == 1 && "${LINEAR_CLIENT_ID:-}" == op://* ]]; then LINEAR_AUTH_KIND="unset"; fi
mint-missing: refuses	scripts/lib/auth.sh	    if [[ -z "${LINEAR_CLIENT_ID:-}" || -z "${LINEAR_CLIENT_SECRET:-}" ]]; then	    if [[ -z "${LINEAR_CLIENT_ID:-}" && -n "${LINEAR_CLIENT_ID:-}" ]]; then
mint-host: token JSON	scripts/commands/auth-mint.sh	linear_mint_token	linear_mint_token | jq '.access_token'
mint-host: cache directory absent	scripts/commands/auth-mint.sh	linear_mint_token	linear_mint_token; mkdir -p -- "$HOME/.cache/kendex/linear-oauth"
mint-response-type: refuses	scripts/lib/auth.sh	        select(.token_type == "Bearer") |	        select(.token_type == "Bearer" or true) |
mint-response-empty: refuses	scripts/lib/auth.sh	        select(.access_token | type == "string" and length > 0) |	        select(.access_token | type == "string") |
mint-response-expiry-low: refuses	scripts/lib/auth.sh	        select(.expires_in | type == "number" and . > 60 and . <= 2592000 and . == floor) |	        select(.expires_in | type == "number" and . >= 60 and . <= 2592000 and . == floor) |
mint-response-expiry-high: refuses	scripts/lib/auth.sh	        select(.expires_in | type == "number" and . > 60 and . <= 2592000 and . == floor) |	        select(.expires_in | type == "number" and . > 60 and . <= 2592001 and . == floor) |
mint-response-expiry-fraction: refuses	scripts/lib/auth.sh	        select(.expires_in | type == "number" and . > 60 and . <= 2592000 and . == floor) |	        select(.expires_in | type == "number" and . > 60 and . <= 2592000) |
mint-token-failure: diagnostic	scripts/lib/auth.sh	    elif [[ "$http_code" != "200" ]]; then	    elif [[ "$http_code" == "200" && "$http_code" != "200" ]]; then
mint-token-transport: diagnostic	scripts/lib/auth.sh	        echo '{"error": "linear-auth: token=transport-failed"}' >&2	        echo '{"error": "linear-auth: token=transport-failed"}' >/dev/null
MINT_CONTROLS

control_expect 'token-beats-partial: request succeeds'
control_replace scripts/lib/auth.sh 1 \
    '    app-token|app|api-key) return 0 ;;' \
    '    app|api-key) return 0 ;;'
