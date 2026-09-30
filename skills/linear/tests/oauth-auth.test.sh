#!/usr/bin/env bash
# Credential selection and OAuth lifecycle through requests, auth-check and cache fetch.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
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
fixture_root=$(git -C "$PROJECT" rev-parse --show-toplevel)
assert_eq 'fixture Git root stays in scratch' "$fixture_root" "$PROJECT"
cp -R -- "$SKILL_DIR" "$PROJECT/.agents/skills/linear"
LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
REAL_JQ=$(command -v jq)
export LINEAR_CACHE_ROOT="$PROJECT"
cat >"$PROJECT/bin/date" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${NOW:?}"
SH
cat >"$PROJECT/bin/jq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"$LOG/jq-argv"
exec "${REAL_JQ:?}" "$@"
SH
cat >"$PROJECT/bin/op" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$LOG/op"
case "$*" in
'read op://selected/app/id') printf 'resolved/id' ;;
'read op://selected/app/secret') printf 'resolved&secret' ;;
*) exit 1 ;;
esac
SH
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"$LOG/curl-argv"
if [[ "$*" == *'-K -'* ]]; then
    config=$(cat)
    printf '%s\n' "$config" >>"$LOG/config"
    if [[ "$config" == *'https://api.linear.app/oauth/token'* ]]; then
        printf 'mint\n' >>"$LOG/mints"
        n=$(wc -l <"$LOG/mints")
        if [[ "${MODE:-}" == token-failure || ( "${FAIL_RENEWAL:-0}" == 1 && "$n" -gt 1 ) || ( "${MODE:-}" == references &&
            "$config" != *'client_id=resolved%2Fid&client_secret=resolved%26secret'* ) ]]; then
            printf '{"error":"invalid_client"}___HTTP_CODE___400'
        else
            printf '{"access_token":"token-%s","token_type":"Bearer","expires_in":3600}___HTTP_CODE___200' "$n"
        fi
        exit
    fi
    if [[ "$config" == *'https://uploads.linear.app/'* ]]; then
        sed -n 's/^header = "\(Authorization: .*\)"$/\1/p' <<<"$config" >>"$LOG/download-auth"
        n=$(wc -l <"$LOG/download-auth")
        IFS=, read -r -a codes <<<"${DOWNLOAD_RESPONSES:-200}"
        code="${codes[n-1]:-200}"
        while [[ $# -gt 0 ]]; do
            case "$1" in
            -o) printf 'file body\n' >"$2"; shift 2 ;;
            -D) printf 'Content-Type: text/plain\n' >"$2"; shift 2 ;;
            *) shift ;;
            esac
        done
        if [[ "$code" == 000 ]]; then exit 7; fi
        printf '%s' "$code"
        exit
    fi
    sed -n 's/^header = "Authorization: \(.*\)"$/\1/p' <<<"$config" >>"$LOG/auth"
    if [[ "${MODE:-}" == always-401 || ( "${MODE:-}" == once-401 && ! -f "$LOG/denied" ) ]]; then
        touch "$LOG/denied"
        printf '{}___HTTP_CODE___401'
    elif [[ "$config" == *SyncIssueAttachments* ]]; then
        printf '{"data":{"attachments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"url":"https://uploads.linear.app/asset/findings.txt","title":"docs/findings.txt","issue":{"identifier":"TEAM-1"}}]}}}___HTTP_CODE___200'
    else
        printf '{"data":{"viewer":{"id":"actor-id","name":"Actor name"}}}___HTTP_CODE___200'
    fi
else
    echo 'fake-curl: transport=missing-stdin-config' >&2
    exit 1
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
chmod +x "$PROJECT/bin/curl" "$PROJECT/bin/date" "$PROJECT/bin/jq" "$PROJECT/bin/op" "$PROJECT/request"
OUT="" RC=0 NOW=1000
LOG="$TMP_ROOT/log"
mkdir -p "$LOG"
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
assert_not 'mint keeps client credentials out of jq arguments' \
    grep -F -e 'app&secret' -e 'app/id' "$LOG/jq-argv"
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

run_oauth_request request MODE=download
assert_eq 'app attachment download succeeds' "$RC" 0
header=$(cat "$LOG/download-auth")
assert_eq 'attachment download uses selected app' "$header" 'Authorization: Bearer token-5'
argv=$(cat "$LOG/curl-argv")
assert_not_contains 'attachment download keeps token out of curl arguments' "$argv" 'token-5'

# A new secret cannot reuse the token minted by an old one.
run_oauth_request request LINEAR_CLIENT_SECRET=rotated
assert_eq 'secret rotation succeeds' "$RC" 0
header=$(tail -n 1 "$LOG/auth")
assert_eq 'secret rotation mints a new token' "$header" 'Bearer token-6'
run_oauth_request request LINEAR_CLIENT_SECRET=bad MODE=token-failure
assert_ne 'token mint failure refuses instead of using personal key' "$RC" 0

# Reports retain key provenance without giving advice about an unused key.
for row in \
    'app-shadow|app/id|app&secret|op://unused/key|inherited-key||project-config|app|application|Bearer token-5' \
    'app-inherited|app/id|app&secret||inherited-key||environment|app|application|Bearer token-5' \
    'key-only|||personal-key|||project-config|api-key|user|personal-key' \
    'environment-app|env-app|env-secret|personal-key||override-key|override|app|application|Bearer token-8'; do
    IFS='|' read -r label id secret key inherited override key_source credential kind authorization <<<"$row"
    printf 'LINEAR_API_KEY="%s"\n' "$key" >"$PROJECT/.env.local"
    run_oauth_request auth-check LINEAR_CLIENT_ID="$id" LINEAR_CLIENT_SECRET="$secret" \
        LINEAR_API_KEY="$inherited" LINEAR_API_KEY_OVERRIDE="$override"
    assert_eq "$label: auth-check succeeds" "$RC" 0
    assert "$label: credential report" jq -e --arg source "$key_source" --arg credential "$credential" --arg kind "$kind" \
        '.ok and .credential == $credential and .actor == {kind:$kind,id:"actor-id",name:"Actor name"} and
         .api_key_source == $source and .team == null and .writes_enabled == false and
         (.warnings | length == 1 and all(.[]; contains("LINEAR_TEAM") and (contains("LINEAR_API_KEY") | not)))' <<<"$OUT"
    header=$(tail -n 1 "$LOG/auth")
    assert_eq "$label: selected authorization reaches GraphQL" "$header" "$authorization"
done

for row in 'no-credentials||||credential=unset' \
    'partial-app|partial|||credential=incomplete-app' \
    'partial-app-with-key|partial||personal-key|credential=incomplete-app' \
    'partial-secret-with-key||partial|personal-key|credential=incomplete-app'; do
    IFS='|' read -r label id secret key error <<<"$row"
    printf 'LINEAR_API_KEY="%s"\n' "$key" >"$PROJECT/.env.local"
    : >"$LOG/auth"
    run_oauth_request request LINEAR_CLIENT_ID="$id" LINEAR_CLIENT_SECRET="$secret" LINEAR_API_KEY_OVERRIDE="$key"
    assert_ne "$label: request refuses" "$RC" 0
    assert_file_contains "$label: selected credential refusal" "$LOG/error" "$error"
    assert_not "$label: no request reaches GraphQL" test -s "$LOG/auth"
done

# Private app references select the app even when the unused key cannot resolve.
printf 'LINEAR_CLIENT_ID="op://selected/app/id"\nLINEAR_CLIENT_SECRET="op://selected/app/secret"\nLINEAR_API_KEY="op://unused/key"\n' >"$PROJECT/.env.local"
printf '[{"identifier":"TEAM-1","description":""}]' >"$PROJECT/.cache/linear/issues.json"
printf '{"synced_at":"2026-09-30T00:00:00Z"}' >"$PROJECT/.cache/linear/meta.json"
: >"$LOG/op"
run_oauth_request cache-read
assert_eq 'app references: cache-only read succeeds' "$RC" 0
assert_not 'app references: cache-only read never resolves secrets' test -s "$LOG/op"
for row in 'live:request' 'inventory:cache-fetch'; do
    IFS=: read -r label command <<<"$row"
    rm -rf -- "$PROJECT/.cache/linear/oauth"
    : >"$LOG/op"
    : >"$LOG/mints"
    : >"$LOG/config"
    : >"$LOG/auth"
    : >"$LOG/download-auth"
    run_oauth_request "$command" MODE=references
    assert_eq "$label references: request succeeds" "$RC" 0
    reads=$(sort -u "$LOG/op")
    assert_eq "$label references: only selected app references resolve" "$reads" \
        $'read op://selected/app/id\nread op://selected/app/secret'
    config=$(cat "$LOG/config")
    assert_contains "$label references: resolved credentials reach token endpoint" "$config" \
        'client_id=resolved%2Fid&client_secret=resolved%26secret'
    if [[ "$command" == cache-fetch ]]; then
        assert_jq 'inventory references: attachment fetch downloads the live record' "$OUT" \
            '.downloaded == 1 and .total_urls == 1'
        assert_contains 'inventory references: inventory reaches GraphQL' "$config" SyncIssueAttachments
        header=$(cat "$LOG/download-auth")
        assert_eq 'inventory references: attachment uses minted token' "$header" 'Authorization: Bearer token-1'
    fi
    run_oauth_request request MODE=references
    assert_eq "$label references: resolved credentials reuse the cache" "$RC" 0
    count=$(wc -l <"$LOG/mints")
    assert_eq "$label references: cache identity uses resolved values" "${count//[[:space:]]/}" 1
done

# Inventory succeeds before the upload server returns these download responses.
printf 'LINEAR_API_KEY="personal-key"\n' >"$PROJECT/.env.local"
for row in \
    'app-renew|app/id|app&secret|401,200|0|0|2|2|Authorization: Bearer token-2' \
    'app-second-401|app/id|app&secret|401,401,200|0|1|2|2|Authorization: Bearer token-2' \
    'app-renew-failure|app/id|app&secret|401,200|1|1|1|2|Authorization: Bearer token-1' \
    'app-terminal|app/id|app&secret|401,403,200|0|1|2|2|Authorization: Bearer token-2' \
    'app-transport|app/id|app&secret|401,000,200|0|1|2|2|Authorization: Bearer token-2' \
    'key-success|||200|0|0|1|0|Authorization: personal-key' \
    'key-401|||401,200|0|1|1|0|Authorization: personal-key'; do
    IFS='|' read -r label id secret codes fail_renewal expected_rc downloads mints last_auth <<<"$row"
    rm -rf -- "$PROJECT/.cache/linear/oauth" "$PROJECT/.cache/linear/attachments"
    : >"$LOG/mints"
    : >"$LOG/auth"
    : >"$LOG/download-auth"
    : >"$LOG/curl-argv"
    run_oauth_request cache-fetch LINEAR_CLIENT_ID="$id" LINEAR_CLIENT_SECRET="$secret" \
        DOWNLOAD_RESPONSES="$codes" FAIL_RENEWAL="$fail_renewal"
    assert_eq "$label: download result" "$RC" "$expected_rc"
    count=$(wc -l <"$LOG/download-auth")
    assert_eq "$label: download attempts" "${count//[[:space:]]/}" "$downloads"
    count=$(wc -l <"$LOG/mints")
    assert_eq "$label: mint count" "${count//[[:space:]]/}" "$mints"
    header=$(tail -n 1 "$LOG/download-auth")
    assert_eq "$label: download keeps selected actor" "$header" "$last_auth"
    argv=$(cat "$LOG/curl-argv")
    assert_not_contains "$label: renewed token stays out of curl arguments" "$argv" 'token-2'
    if [[ "$expected_rc" == 0 ]]; then
        assert_jq "$label: download is recorded" "$OUT" '.downloaded == 1 and .total_urls == 1'
    else
        manifest=$(cat "$PROJECT/.cache/linear/attachments/manifest.json")
        assert_jq "$label: failed download is not recorded" "$manifest" 'length == 0'
    fi
done
if [[ "${OAUTH_GIT_REDIRECT_CHILD:-0}" != 1 ]]; then
    run_oauth_git_redirects "$SCRIPT_DIR/oauth-auth.test.sh" "$TMP_ROOT/git-callers"
fi
