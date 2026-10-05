#!/usr/bin/env bash
# Selected Linear credential and the OAuth token minted from an app pair,
# kept in a private per-user file until it expires.

set -euo pipefail

# Credential precedence: pre-minted app token, app pair, personal key.
if [[ -n "${LINEAR_APP_TOKEN:-}" ]]; then
    LINEAR_AUTH_KIND="app-token"
elif [[ -n "${LINEAR_CLIENT_ID:-}" && -n "${LINEAR_CLIENT_SECRET:-}" ]]; then
    LINEAR_AUTH_KIND="app"
elif [[ -n "${LINEAR_CLIENT_ID:-}${LINEAR_CLIENT_SECRET:-}" ]]; then
    LINEAR_AUTH_KIND="incomplete-app"
elif [[ -n "${LINEAR_API_KEY:-}" ]]; then
    LINEAR_AUTH_KIND="api-key"
else
    LINEAR_AUTH_KIND="unset"
fi

# One fixed set for every minter: Linear revokes every app token when an app
# requests a different set. The token file's name hashes it, so a token minted
# under another set is never reused.
_LINEAR_APP_SCOPE="read,write,issues:create,comments:create,timeSchedule:write,initiative:read,initiative:write,customer:read,customer:write"

# Resolve only the selected credential: an unused personal key cannot block an app.
linear_resolve_credentials() {
    local name value
    case "$LINEAR_AUTH_KIND" in
    app-token) set -- LINEAR_APP_TOKEN ;;
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
    app-token|app|api-key) return 0 ;;
    incomplete-app)
        echo '{"error": "linear-auth: credential=incomplete-app. Set both LINEAR_CLIENT_ID and LINEAR_CLIENT_SECRET in .env.local."}' >&2 ;;
    unset)
        echo '{"error": "linear-auth: credential=unset. Set LINEAR_APP_TOKEN, LINEAR_CLIENT_ID and LINEAR_CLIENT_SECRET, or LINEAR_API_KEY, in .env.local."}' >&2 ;;
    esac
    return 1
}

# Linear's GraphQL and upload servers use 401 for an expired or revoked token.
linear_auth_unauthorized() {
    jq -cn --arg kind "$LINEAR_AUTH_KIND" \
        '{error: ("linear-auth: http=401 credential=" + $kind +
          (if $kind == "app-token" then "\nApplication token is expired or revoked. Replace LINEAR_APP_TOKEN." else "" end))}' >&2
}

# Prints the Authorization value. Force renewal is used once after an HTTP 401.
linear_authorization() (
    linear_check_credentials || return 1
    linear_resolve_credentials || return 1
    if [[ "$LINEAR_AUTH_KIND" == "app-token" ]]; then
        printf 'Bearer %s' "$LINEAR_APP_TOKEN"
        return 0
    elif [[ "$LINEAR_AUTH_KIND" == "api-key" ]]; then
        printf '%s' "$LINEAR_API_KEY"
        return 0
    fi

    # The pair's token lives per user, outside any checkout, so every
    # invocation and worktree of this user reuses one token until it expires:
    # Linear caps an application's active client-credentials tokens, and a
    # mint per request would spend that cap. The token directory is the first
    # candidate this user owns and can write: the user's cache directory, else
    # one under TMPDIR (else /tmp) named by the user id, for a session such as
    # a sandbox whose writes are held to its workspace and temporary
    # directory, or one with neither HOME nor XDG_CACHE_HOME set. That one directory serves both the read and the store, so a
    # renewal always replaces the token it renews and a revoked token left
    # where this session cannot write is never read. Under a shared /tmp
    # another user could make the name first, so a symlink or another user's
    # directory is never used. The file is named by the fingerprint of the pair
    # and the scope set, so a token minted under another set is never reused.
    local base candidate candidates=() cause dir='' failed='' identity token_file now cached token staged=''
    base=${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}
    [[ -z "$base" ]] || candidates+=("$base/kendex/linear-oauth")
    candidates+=("${TMPDIR:-/tmp}/kendex-linear-oauth-$UID")
    identity=$(linear_key_fingerprint "$LINEAR_CLIENT_ID:$LINEAR_CLIENT_SECRET:$_LINEAR_APP_SCOPE") || return 1
    umask 077
    trap '[[ -z "${staged:-}" ]] || rm -f -- "${staged:?}"' EXIT
    # The staged file is the write probe and, after a mint, the atomic
    # replacement that keeps parallel callers from reading a partial token.
    for candidate in "${candidates[@]}"; do
        if ! mkdir -p -- "$candidate" 2>/dev/null; then
            cause=mkdir-failed
        elif [[ -L "$candidate" ]]; then
            cause=symlink
        elif [[ ! -O "$candidate" ]]; then
            cause=not-owned
        elif ! staged=$(mktemp "$candidate/.token.XXXXXX" 2>/dev/null); then
            cause=not-writable
        else
            dir="$candidate"
            break
        fi
        failed+=" dir=[$candidate] cause=$cause"
    done
    token_file="$dir/$identity.json"
    now=$(date +%s) || return 1
    if [[ -n "$dir" && "${1:-}" != "renew" && -f "$token_file" ]]; then
        cached=$(cat -- "$token_file") || return 1
        # Linear supplies expires_in; the margin avoids expiring in transit.
        if token=$(jq -er --argjson now "$now" '
            select(.expires_at | type == "number" and . == floor) |
            select(.expires_at > ($now + 60)) | .access_token |
            select(type == "string" and length > 0)' <<<"$cached" 2>/dev/null); then
            printf 'Bearer %s' "$token"
            return 0
        fi
    fi

    cached=$(linear_mint_token) || return 1
    token=$(jq -er '.access_token' <<<"$cached") || return 1
    # A store that fails loses only the reuse: this request still runs on the
    # minted token.
    if [[ -n "$dir" ]] && ! { printf '%s\n' "$cached" >"$staged" &&
        mv -f -- "$staged" "$token_file"; } 2>/dev/null; then
        failed+=" dir=[$dir] cause=write-failed"
        dir=''
    fi
    [[ -n "$dir" ]] ||
        printf 'linear-auth: token-store=failed%s\nThe minted token serves this request only; each later request mints again until one of these directories is writable.\n' \
            "$failed" >&2
    printf 'Bearer %s' "$token"
)

# Mint once from the pair and print {access_token, expires_at}; never write files.
linear_mint_token() (
    if [[ -z "${LINEAR_CLIENT_ID:-}" || -z "${LINEAR_CLIENT_SECRET:-}" ]]; then
        local LINEAR_AUTH_KIND="incomplete-app"
        linear_check_credentials
        return 1
    fi
    local LINEAR_AUTH_KIND="app"
    linear_resolve_credentials || return 1
    local now reply http_code response payload payload_quote cached
    now=$(date +%s) || return 1
    # Environment values cannot contain NUL; it separates credentials on stdin.
    payload=$(printf '%s\0%s' "$LINEAR_CLIENT_ID" "$LINEAR_CLIENT_SECRET" | jq -Rsr --arg scope "$_LINEAR_APP_SCOPE" '
        split("\u0000") |
        "grant_type=client_credentials&scope=" + ($scope | @uri) + "&client_id=" + (.[0] | @uri) +
        "&client_secret=" + (.[1] | @uri)') || return 1
    payload_quote=$(curl_config_quote "$payload") || return 1
    # linear_http_post retries as every request does and reports a rate limit
    # in the same RATELIMITED shape.
    reply=$(linear_http_post "$(printf '%s\n' \
        'url = "https://api.linear.app/oauth/token"' \
        'request = "POST"' \
        'header = "Content-Type: application/x-www-form-urlencoded"' \
        "data = $payload_quote")") || return 1
    http_code="${reply%%$'\n'*}"
    response="${reply#*$'\n'}"
    if [[ "$http_code" == 000 ]]; then
        echo '{"error": "linear-auth: token=transport-failed"}' >&2
        return 1
    elif [[ "$http_code" != "200" ]]; then
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
    printf '%s\n' "$cached"
)
