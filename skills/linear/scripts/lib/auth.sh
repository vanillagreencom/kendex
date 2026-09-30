#!/usr/bin/env bash
# Selected Linear credential and its short-lived OAuth token cache.

set -euo pipefail

if [[ -n "${LINEAR_CLIENT_ID:-}" && -n "${LINEAR_CLIENT_SECRET:-}" ]]; then
    LINEAR_AUTH_KIND="app"
elif [[ -n "${LINEAR_CLIENT_ID:-}${LINEAR_CLIENT_SECRET:-}" ]]; then
    LINEAR_AUTH_KIND="incomplete-app"
elif [[ -n "${LINEAR_API_KEY:-}" ]]; then
    LINEAR_AUTH_KIND="api-key"
else
    LINEAR_AUTH_KIND="unset"
fi

# Resolve only the selected credential: an unused personal key cannot block an app.
linear_resolve_credentials() {
    local name value
    case "$LINEAR_AUTH_KIND" in
    app) set -- LINEAR_CLIENT_ID LINEAR_CLIENT_SECRET ;;
    api-key) set -- LINEAR_API_KEY ;;
    incomplete-app|unset) return 0 ;;
    esac
    for name in "$@"; do
        value="${!name}"
        if [[ "$value" == op://* ]]; then
            if ! command -v op >/dev/null; then
                jq -cn --arg name "$name" '{error: ($name + " is a 1Password reference but the op CLI is not installed")}' >&2
                return 1
            fi
            if ! value=$(op read "$value" 2>/dev/null) || [[ -z "$value" ]]; then
                jq -cn --arg name "$name" '{error: ("Failed to resolve " + $name + " from 1Password. Run: op signin")}' >&2
                return 1
            fi
            printf -v "$name" '%s' "$value"
            export "${name?}"
        fi
    done
}

# No personal-key fallback after selecting an app: a failure must keep its actor.
linear_check_credentials() {
    case "$LINEAR_AUTH_KIND" in
    app|api-key) return 0 ;;
    incomplete-app)
        echo '{"error": "linear-auth: credential=incomplete-app. Set both LINEAR_CLIENT_ID and LINEAR_CLIENT_SECRET in .env.local."}' >&2 ;;
    unset)
        echo '{"error": "linear-auth: credential=unset. Set LINEAR_CLIENT_ID and LINEAR_CLIENT_SECRET, or LINEAR_API_KEY, in .env.local."}' >&2 ;;
    esac
    return 1
}

# Prints the Authorization value. Force renewal is used once after an HTTP 401.
linear_authorization() (
    linear_check_credentials || return 1
    linear_resolve_credentials || return 1
    if [[ "$LINEAR_AUTH_KIND" == "api-key" ]]; then
        printf '%s' "$LINEAR_API_KEY"
        return 0
    fi

    # Reuse the cache library's root resolution, including LINEAR_CACHE_ROOT.
    source "$_LIB_DIR/cache.sh" || return 1
    local identity now token_file cached token raw http_code response payload payload_quote staged
    identity=$(linear_key_fingerprint "$LINEAR_CLIENT_ID:$LINEAR_CLIENT_SECRET") || return 1
    token_file="$CACHE_DIR/oauth/$identity.json"
    now=$(date +%s) || return 1
    if [[ "${1:-}" != "renew" && -f "$token_file" ]]; then
        cached=$(cat -- "$token_file") || return 1
        # Linear supplies expires_in; the margin avoids expiring in transit.
        if token=$(jq -er --argjson now "$now" '
            select(.expires_at | type == "number" and . == floor) |
            select(.expires_at > ($now + 60)) | .access_token |
            select(type == "string" and length > 0)' <<<"$cached"); then
            printf 'Bearer %s' "$token"
            return 0
        fi
    fi

    # Scope is fixed: Linear revokes every app token when scopes change.
    # Environment values cannot contain NUL; it separates credentials on stdin.
    payload=$(printf '%s\0%s' "$LINEAR_CLIENT_ID" "$LINEAR_CLIENT_SECRET" | jq -Rsr '
        split("\u0000") |
        "grant_type=client_credentials&scope=read%2Cwrite&client_id=" + (.[0] | @uri) +
        "&client_secret=" + (.[1] | @uri)') || return 1
    payload_quote=$(curl_config_quote "$payload") || return 1
    raw=$(
        printf '%s\n' \
            'url = "https://api.linear.app/oauth/token"' \
            'request = "POST"' \
            'header = "Content-Type: application/x-www-form-urlencoded"' \
            "data = $payload_quote" \
        | curl -s -w '___HTTP_CODE___%{http_code}' -K -
    ) || { echo '{"error": "linear-auth: token=transport-failed"}' >&2; return 1; }
    http_code="${raw##*___HTTP_CODE___}"
    response="${raw%___HTTP_CODE___*}"
    if [[ "$http_code" != "200" ]]; then
        jq -cn --arg code "$http_code" '{error: ("linear-auth: token-http=" + $code)}' >&2
        return 1
    fi
    if ! cached=$(jq -ce --argjson now "$now" '
        select(.token_type == "Bearer") |
        select(.access_token | type == "string" and length > 0) |
        select(.expires_in | type == "number" and . > 60 and . <= 2592000 and . == floor) |
        {access_token, expires_at: ($now + .expires_in)}' <<<"$response"); then
        echo '{"error": "linear-auth: token=invalid-response"}' >&2
        return 1
    fi
    token=$(jq -r '.access_token' <<<"$cached") || return 1
    # Atomic replacement keeps parallel callers from reading a partial token.
    umask 077
    mkdir -p -- "$CACHE_DIR/oauth" || return 1
    staged=$(mktemp "$CACHE_DIR/oauth/.token.XXXXXX") || return 1
    trap 'rm -f -- "${staged:?}"' EXIT
    printf '%s\n' "$cached" >"$staged" || return 1
    mv -f -- "$staged" "$token_file" || return 1
    printf 'Bearer %s' "$token"
)
