#!/usr/bin/env bash
# Credential selection and OAuth lifecycle through the request and auth-check.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
assert_tmpdir TMP_ROOT
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/bin" "$PROJECT/.agents/skills"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
cp -R -- "$SKILL_DIR" "$PROJECT/.agents/skills/linear"
LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
export LINEAR_CACHE_ROOT="$PROJECT"

cat >"$PROJECT/bin/date" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${NOW:?}"
SH
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'-K -'* ]]; then
    config=$(cat)
    printf '%s\n' "$config" >>"$LOG/config"
    if [[ "$config" == *'https://api.linear.app/oauth/token'* ]]; then
        printf 'mint\n' >>"$LOG/mints"
        n=$(wc -l <"$LOG/mints")
        if [[ "${MODE:-}" == token-failure ]]; then
            printf '{"error":"invalid_client"}___HTTP_CODE___400'
        else
            printf '{"access_token":"token-%s","token_type":"Bearer","expires_in":3600}___HTTP_CODE___200' "$n"
        fi
        exit
    fi
    sed -n 's/^header = "Authorization: \(.*\)"$/\1/p' <<<"$config" >>"$LOG/auth"
    if [[ "${MODE:-}" == always-401 || ( "${MODE:-}" == once-401 && ! -f "$LOG/denied" ) ]]; then
        touch "$LOG/denied"
        printf '{}___HTTP_CODE___401'
    else
        printf '{"data":{"viewer":{"id":"actor-id","name":"Actor name"}}}___HTTP_CODE___200'
    fi
else
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -H) printf '%s\n' "$2" >"$LOG/download-auth"; shift 2 ;;
        -o) printf 'file body\n' >"$2"; shift 2 ;;
        -D) printf 'Content-Type: text/plain\n' >"$2"; shift 2 ;;
        *) shift ;;
        esac
    done
    printf 200
fi
SH
cat >"$PROJECT/request" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$PWD/.agents/skills/linear/scripts/lib/common.sh"
if [[ "${MODE:-}" == download ]]; then
    source "$_LIB_DIR/cache.sh"
    source "$_LIB_DIR/attachments.sh"
    attach_download_url 'https://uploads.linear.app/asset/file.txt' TEAM-1 description
else
    graphql_query '{ viewer { id name } }' '{}'
fi
SH
chmod +x "$PROJECT/bin/curl" "$PROJECT/bin/date" "$PROJECT/request"
OUT="" RC=0 NOW=1000
LOG="$TMP_ROOT/log"
mkdir -p "$LOG"
: >"$LOG/mints"
: >"$LOG/auth"

# One app pair in the private file; an unresolved unused key must not block it.
printf 'LINEAR_CLIENT_ID="app/id"\nLINEAR_CLIENT_SECRET="app&secret"\nLINEAR_API_KEY="op://unused/key"\n' >"$PROJECT/.env.local"
for row in 'mint:1000:1:token-1' 'cache:1000:1:token-1' 'before-expiry:4540:2:token-2' 'expired:9000:3:token-3'; do
    IFS=: read -r label NOW mints token <<<"$row"
    run_oauth_request request
    assert_eq "$label: request succeeds" "$RC" 0
    count=$(wc -l <"$LOG/mints")
    assert_eq "$label: mint count" "${count//[[:space:]]/}" "$mints"
    header=$(tail -n 1 "$LOG/auth")
    assert_eq "$label: Bearer token reaches GraphQL" "$header" "Bearer $token"
done
config=$(cat "$LOG/config")
assert_contains 'mint sends fixed scope and encoded client credentials' "$config" \
    'grant_type=client_credentials&scope=read%2Cwrite&client_id=app%2Fid&client_secret=app%26secret'
cache_files=("$PROJECT/.cache/linear/oauth/"*.json)
assert_eq 'one app cache record exists' "${#cache_files[@]}" 1
cached=$(cat -- "${cache_files[0]}")
assert_jq 'cache stores token and expiry' "$cached" '.access_token == "token-3" and .expires_at == 12600'
mode=$(stat -c %a "${cache_files[0]}" 2>/dev/null || stat -f %Lp "${cache_files[0]}")
assert_eq 'token file is private' "$mode" 600

run_oauth_request request MODE=once-401
assert_eq '401 renewal succeeds' "$RC" 0
header=$(tail -n 1 "$LOG/auth")
assert_eq '401 renewal uses new token' "$header" 'Bearer token-4'
run_oauth_request request MODE=always-401
assert_ne 'a second 401 refuses' "$RC" 0
count=$(wc -l <"$LOG/mints")
assert_eq 'a second 401 never renews again' "${count//[[:space:]]/}" 5

run_oauth_request auth-check
assert_eq 'app auth-check succeeds' "$RC" 0
assert_jq 'auth-check reports selected application and actor' "$OUT" \
    '.credential == "app" and .actor == {kind:"application",id:"actor-id",name:"Actor name"}'
run_oauth_request request MODE=download
assert_eq 'app attachment download succeeds' "$RC" 0
header=$(cat "$LOG/download-auth")
assert_eq 'attachment download uses selected app' "$header" 'Authorization: Bearer token-5'

# A new secret cannot reuse the token minted by an old one.
run_oauth_request request LINEAR_CLIENT_SECRET=rotated
assert_eq 'secret rotation succeeds' "$RC" 0
header=$(tail -n 1 "$LOG/auth")
assert_eq 'secret rotation mints a new token' "$header" 'Bearer token-6'
run_oauth_request request LINEAR_CLIENT_SECRET=bad MODE=token-failure
assert_ne 'token mint failure refuses instead of using personal key' "$RC" 0

# Key-only installs preserve the bare header and user actor.
printf 'LINEAR_API_KEY="personal-key"\n' >"$PROJECT/.env.local"
run_oauth_request request
assert_eq 'key-only request succeeds' "$RC" 0
header=$(tail -n 1 "$LOG/auth")
assert_eq 'personal key reaches GraphQL without Bearer' "$header" personal-key
run_oauth_request auth-check
assert_jq 'auth-check reports personal key and user actor' "$OUT" \
    '.credential == "api-key" and .actor.kind == "user" and .actor.id == "actor-id"'

# Both app values in process env win over the key from project files.
run_oauth_request request LINEAR_CLIENT_ID=env-app LINEAR_CLIENT_SECRET=env-secret
assert_eq 'environment app beats project key' "$RC" 0
header=$(tail -n 1 "$LOG/auth")
assert_eq 'app precedence uses Bearer' "$header" 'Bearer token-8'

for row in 'no-credentials:' 'partial-app:LINEAR_CLIENT_ID=partial'; do
    IFS=: read -r label credential <<<"$row"
    : >"$PROJECT/.env.local"
    : >"$LOG/auth"
    if [[ -n "$credential" ]]; then run_oauth_request request "$credential"; else run_oauth_request request; fi
    assert_ne "$label: request refuses" "$RC" 0
    assert_not "$label: no request reaches GraphQL" test -s "$LOG/auth"
done
