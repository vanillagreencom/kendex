#!/usr/bin/env bash
# Credential selection and the OAuth lifecycle through requests, auth-check and
# attachment downloads. A pair's token is minted on the first request that
# needs one, kept in one private per-user file under XDG_CACHE_HOME or HOME's
# .cache, else in a directory of this user's under TMPDIR, whichever this user
# owns and can write first, and reused by every later request and invocation
# until it nears expiry or a 401 renews it.
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
# Only fixture setup inherits Git redirects. Request children use env -i,
# so repeating their OAuth cases cannot test the caller's Git environment.
if [[ "${OAUTH_GIT_REDIRECT_CHILD:-0}" == 1 ]]; then
    exit 0
fi
cp -R -- "$SKILL_DIR" "$PROJECT/.agents/skills/linear"
LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
REAL_JQ=$(command -v jq)
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
# A sandbox that refuses writes under the READ_ONLY directories (colon
# separated) refuses mktemp there; MV_FAIL=1 fails the token file's rename.
# Both otherwise run the real command, the next one on PATH.
cat >"$PROJECT/bin/mktemp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
IFS=: read -r -a read_only <<<"${READ_ONLY:-}"
for dir in ${read_only[@]+"${read_only[@]}"}; do
    [[ "${!#}" != "$dir"/* ]] || exit 1
done
export PATH="${PATH#*:}"
exec mktemp "$@"
SH
cat >"$PROJECT/bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${MV_FAIL:-0}" != 1 ]] || exit 1
export PATH="${PATH#*:}"
exec mv "$@"
SH
cat >"$PROJECT/bin/op" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$LOG/op"
case "$*" in
'read op://selected/app/id') printf 'resolved/id' ;;
'read op://selected/app/secret') printf 'resolved&secret' ;;
'read op://selected/app/token') printf 'resolved-token' ;;
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
        if [[ "${MODE:-}" == token-response ]]; then
            printf '%s___HTTP_CODE___200' "${TOKEN_RESPONSE:?}"
            exit
        fi
        if [[ "${MODE:-}" == token-transport ]]; then exit 7; fi
        if [[ "${MODE:-}" == token-ratelimited ]]; then
            printf '{}___HTTP_CODE___429'
            exit
        fi
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
    if [[ "${MODE:-}" == always-401 || ( "${MODE:-}" == once-401 && ! -f "$LOG/denied" ) ||
        "$config" == *'Bearer revoked-token'* ]]; then
        touch "$LOG/denied"
        printf '{}___HTTP_CODE___401'
    else
        printf '{"data":{"viewer":{"id":"actor-id","name":"Actor name"}}}___HTTP_CODE___200'
    fi
else
    echo 'fake-curl: transport=missing-stdin-config' >&2
    exit 1
fi
SH
# ACTION: unset for one GraphQL request, `twice` for two requests in one
# invocation, `none` for no request at all, `download` for one attachment
# download into download.txt.
cat >"$PROJECT/request" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${ACTION:-}" == download ]]; then
    exec bash "$PWD/.agents/skills/linear/scripts/linear.sh" attachments fetch \
        'https://uploads.linear.app/asset/file.txt' --output "$PWD/download.txt"
fi
source "$PWD/.agents/skills/linear/scripts/lib/common.sh"
if [[ "${ACTION:-}" == none ]]; then exit 0; fi
graphql_query 'query Viewer { viewer { id name } }' '{}'
if [[ "${ACTION:-}" == twice ]]; then
    graphql_query 'query Viewer { viewer { id name } }' '{}'
fi
SH
chmod +x "$PROJECT/bin/curl" "$PROJECT/bin/date" "$PROJECT/bin/jq" "$PROJECT/bin/mktemp" "$PROJECT/bin/mv" \
    "$PROJECT/bin/op" "$PROJECT/request"
OUT="" RC=0 NOW=1000
LOG="$TMP_ROOT/log"
mkdir -p "$LOG" "$TMP_ROOT/tmpdir"
# The pair's token files live here, HOME being TMP_ROOT; forget_token starts a
# case with none.
TOKEN_DIR="$TMP_ROOT/.cache/kendex/linear-oauth"
forget_token() { rm -rf -- "${TMP_ROOT:?}/.cache" "${TMP_ROOT:?}/tmpdir/kendex-linear-oauth-$UID"; }
FALLBACK_DIR="$TMP_ROOT/tmpdir/kendex-linear-oauth-$UID"
# One app pair in the private file; an unresolved unused key must not block it.
printf 'LINEAR_CLIENT_ID="app/id"\nLINEAR_CLIENT_SECRET="app&secret"\nLINEAR_API_KEY="op://unused/key"\n' >"$PROJECT/.env.local"
# A run that sends no request mints nothing.
run_oauth_request request ACTION=none
assert_eq 'no-request: run succeeds' "$RC" 0
assert_not 'no-request: never mints' test -s "$LOG/mints"
# The first request mints; later invocations reuse that token until it is
# within a minute of expiry. Each token lasts 3600 s from its mint's clock.
for row in 'mint:1000:1:token-1' 'reuse:1000:1:token-1' 'near-expiry:4541:2:token-2' 'reuse-renewed:4541:2:token-2'; do
    IFS=: read -r label NOW mints token <<<"$row"
    run_oauth_request request
    assert_eq "$label: request succeeds" "$RC" 0
    count=$(wc -l <"$LOG/mints")
    assert_eq "$label: mint count" "${count//[[:space:]]/}" "$mints"
    header=$(tail -n 1 "$LOG/auth")
    assert_eq "$label: Bearer token reaches GraphQL" "$header" "Bearer $token"
done
NOW=1000
token_files=$(find "$TMP_ROOT" "$PROJECT" -type f \( -name '*.json' -o -name '.token.*' \) -path '*oauth*')
assert_eq 'token file: one file, under HOME' "$(wc -l <<<"$token_files" | tr -d ' ')" 1
assert_matches 'token file: named by the pair under kendex/linear-oauth' "$token_files" "^$TOKEN_DIR/[0-9a-f]{12}[.]json\$"
assert_eq 'token file: private' "$(find "$TOKEN_DIR" \( -type d -perm 0700 \) -o \( -type f -perm 0600 \) | wc -l | tr -d ' ')" 2
assert_jq 'token file: token and expiry' "$(cat "$token_files")" '. == {access_token: "token-2", expires_at: 8141}'
assert_not 'token file: no store in the checkout' test -e "$PROJECT/.cache"
TOKEN_NAME="${token_files##*/}"
config=$(cat "$LOG/config")
assert_contains 'mint sends fixed scope and encoded client credentials' "$config" \
    'grant_type=client_credentials&scope=read%2Cwrite%2Cissues%3Acreate%2Ccomments%3Acreate%2CtimeSchedule%3Awrite%2Cinitiative%3Aread%2Cinitiative%3Awrite%2Ccustomer%3Aread%2Ccustomer%3Awrite&client_id=app%2Fid&client_secret=app%26secret'
assert_not 'mint keeps client credentials out of jq arguments' \
    grep -F -e 'app&secret' -e 'app/id' "$LOG/jq-argv"

forget_token
: >"$LOG/mints"
: >"$LOG/auth"
run_oauth_request request ACTION=twice
assert_eq 'two-requests: requests succeed' "$RC" 0
count=$(wc -l <"$LOG/mints")
assert_eq 'two-requests: one mint serves both' "${count//[[:space:]]/}" 1
assert_eq 'two-requests: both carry that token' "$(sort -u "$LOG/auth")" 'Bearer token-1'

# A 401 renews once, and the renewed token is the one every later request of
# that invocation and the next invocation read.
forget_token
: >"$LOG/mints"
: >"$LOG/auth"
rm -f -- "${LOG:?}/denied"
run_oauth_request request MODE=once-401 ACTION=twice
assert_eq '401 renewal succeeds' "$RC" 0
assert_eq '401 renewal uses new token' "$(tail -n 2 "$LOG/auth")" $'Bearer token-2\nBearer token-2'
run_oauth_request request
assert_eq '401 renewal: the next invocation reuses the renewed token' "$(tail -n 1 "$LOG/auth")" 'Bearer token-2'
count=$(wc -l <"$LOG/mints")
assert_eq '401 renewal: one mint and one renewal in all' "${count//[[:space:]]/}" 2
forget_token
: >"$LOG/mints"
run_oauth_request request MODE=always-401
assert_ne 'a second 401 refuses' "$RC" 0
count=$(wc -l <"$LOG/mints")
assert_eq 'a second 401 never renews again' "${count//[[:space:]]/}" 2

forget_token
: >"$LOG/mints"
: >"$LOG/download-auth"
: >"$LOG/curl-argv"
run_oauth_request request ACTION=download
assert_eq 'app attachment download succeeds' "$RC" 0
header=$(cat "$LOG/download-auth")
assert_eq 'attachment download uses selected app' "$header" 'Authorization: Bearer token-1'
argv=$(cat "$LOG/curl-argv")
assert_not_contains 'attachment download keeps token out of curl arguments' "$argv" 'token-1'
forget_token
run_oauth_request request LINEAR_CLIENT_SECRET=bad MODE=token-failure
assert_ne 'token mint failure refuses instead of using personal key' "$RC" 0
forget_token
run_oauth_request auth-check MODE=token-failure
assert_eq 'auth-check: a failed mint refuses' "$RC" 1
assert_jq 'auth-check: a failed mint prints its report' "$OUT" '.ok == false and .credential == "app" and .actor == null'

# Reports retain key provenance without giving advice about an unused key.
for row in \
    'app-shadow|app/id|app&secret|op://unused/key|inherited-key||project-config|app|application|Bearer token-1' \
    'app-inherited|app/id|app&secret||inherited-key||environment|app|application|Bearer token-1' \
    'key-only|||personal-key|||project-config|api-key|user|personal-key' \
    'environment-app|env-app|env-secret|personal-key||override-key|override|app|application|Bearer token-1'; do
    IFS='|' read -r label id secret key inherited override key_source credential kind authorization <<<"$row"
    printf 'LINEAR_API_KEY="%s"\n' "$key" >"$PROJECT/.env.local"
    forget_token
    : >"$LOG/mints"
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
for row in 'live:' 'download:download'; do
    IFS=: read -r label action <<<"$row"
    forget_token
    : >"$LOG/op"
    : >"$LOG/mints"
    : >"$LOG/config"
    : >"$LOG/auth"
    : >"$LOG/download-auth"
    run_oauth_request request MODE=references ACTION="$action"
    assert_eq "$label references: request succeeds" "$RC" 0
    reads=$(sort -u "$LOG/op")
    assert_eq "$label references: only selected app references resolve" "$reads" \
        $'read op://selected/app/id\nread op://selected/app/secret'
    config=$(cat "$LOG/config")
    assert_contains "$label references: resolved credentials reach token endpoint" "$config" \
        'client_id=resolved%2Fid&client_secret=resolved%26secret'
    count=$(wc -l <"$LOG/mints")
    assert_eq "$label references: one mint" "${count//[[:space:]]/}" 1
    if [[ "$action" == download ]]; then
        header=$(cat "$LOG/download-auth")
        assert_eq 'download references: attachment uses minted token' "$header" 'Authorization: Bearer token-1'
    fi
done

# The upload server answers these download responses in turn.
printf 'LINEAR_API_KEY="personal-key"\n' >"$PROJECT/.env.local"
for row in \
    'app-renew|app/id|app&secret|401,200|0|0|2|2|Authorization: Bearer token-2' \
    'app-second-401|app/id|app&secret|401,401,200|0|1|2|2|Authorization: Bearer token-2' \
    'app-renew-failure|app/id|app&secret|401,200|1|1|1|2|Authorization: Bearer token-1' \
    'app-terminal|app/id|app&secret|401,403,200|0|1|2|2|Authorization: Bearer token-2' \
    'app-transport|app/id|app&secret|401,000,200|0|0|3|2|Authorization: Bearer token-2' \
    'key-success|||200|0|0|1|0|Authorization: personal-key' \
    'key-401|||401,200|0|1|1|0|Authorization: personal-key'; do
    IFS='|' read -r label id secret codes fail_renewal expected_rc downloads mints last_auth <<<"$row"
    rm -f -- "$PROJECT/download.txt"
    forget_token
    : >"$LOG/mints"
    : >"$LOG/auth"
    : >"$LOG/download-auth"
    : >"$LOG/curl-argv"
    run_oauth_request request ACTION=download LINEAR_CLIENT_ID="$id" LINEAR_CLIENT_SECRET="$secret" \
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
        assert_jq "$label: download names its file" "$OUT" ".local_path == \"$PROJECT/download.txt\""
        assert_eq "$label: download writes the file" "$(cat "$PROJECT/download.txt")" 'file body'
    else
        assert_not "$label: failed download writes no file" test -e "$PROJECT/download.txt"
        assert_eq "$label: failed download leaves no partial file" \
            "$(find "$PROJECT" -maxdepth 1 -name 'download.txt.*' | wc -l | tr -d ' ')" 0
    fi
done

# A fleet's published token must not use the accompanying proxy-placeholder pair.
for row in \
    'token-only||||published-token|published-token' \
    'token-beats-pair|op://unused/id|op://unused/secret|personal-key|published-token|published-token' \
    'token-beats-partial|partial||personal-key|published-token|published-token' \
    'token-reference|op://unused/id|op://unused/secret|op://unused/key|op://selected/app/token|resolved-token'; do
    IFS='|' read -r label id secret key supplied token <<<"$row"
    forget_token
    printf 'LINEAR_APP_TOKEN="%s"\nLINEAR_API_KEY="%s"\n' "$supplied" "$key" >"$PROJECT/.env.local"
    : >"$LOG/mints"
    : >"$LOG/auth"
    : >"$LOG/op"
    run_oauth_request request LINEAR_CLIENT_ID="$id" LINEAR_CLIENT_SECRET="$secret"
    assert_eq "$label: request succeeds" "$RC" 0
    header=$(cat "$LOG/auth")
    assert_eq "$label: GraphQL Bearer header" "$header" "Bearer $token"
    assert_not "$label: never mints" test -s "$LOG/mints"
    assert_not "$label: cache directory absent" test -e "$TOKEN_DIR"
    reads=$(cat "$LOG/op")
    if [[ "$label" == token-reference ]]; then
        assert_eq 'token-reference: only token resolves' "$reads" 'read op://selected/app/token'
    else
        assert_eq "$label: unused credentials never resolve" "$reads" ''
    fi
done

for row in 'token-check|auth-check||0' 'token-401|request|always-401|1'; do
    IFS='|' read -r label command mode expected_rc <<<"$row"
    forget_token
    : >"$LOG/auth"
    : >"$LOG/mints"
    run_oauth_request "$command" MODE="$mode" LINEAR_APP_TOKEN=environment-token \
        LINEAR_CLIENT_ID=app/id LINEAR_CLIENT_SECRET='app&secret' LINEAR_API_KEY_OVERRIDE=personal-key
    assert_eq "$label: request result" "$RC" "$expected_rc"
    header=$(cat "$LOG/auth")
    assert_eq "$label: one request uses environment token" "$header" 'Bearer environment-token'
    assert_not "$label: never mints" test -s "$LOG/mints"
    assert_not "$label: cache directory absent" test -e "$TOKEN_DIR"
    if [[ "$command" == auth-check ]]; then
        assert_jq 'token-check: application actor' "$OUT" \
            '.ok and .credential == "app-token" and .actor == {kind:"application",id:"actor-id",name:"Actor name"}'
    else
        assert_file_contains 'token-401: credential diagnostic' "$LOG/error" 'linear-auth: http=401 credential=app-token'
        assert 'token-401: token replacement guidance' jq -e \
            '.error | test("expir|revok"; "i") and test("replac[^\n]*LINEAR_APP_TOKEN"; "i")' "$LOG/error"
    fi
done

for row in 'token-download|200|0' 'token-download-401|401,200|1'; do
    IFS='|' read -r label codes expected_rc <<<"$row"
    forget_token
    : >"$LOG/download-auth"
    : >"$LOG/mints"
    run_oauth_request request ACTION=download DOWNLOAD_RESPONSES="$codes" \
        LINEAR_APP_TOKEN=published-token LINEAR_CLIENT_ID=app/id LINEAR_CLIENT_SECRET='app&secret'
    assert_eq "$label: download result" "$RC" "$expected_rc"
    header=$(cat "$LOG/download-auth")
    assert_eq "$label: one download uses Bearer token" "$header" 'Authorization: Bearer published-token'
    assert_not "$label: never mints" test -s "$LOG/mints"
    assert_not "$label: OAuth cache absent" test -e "$TOKEN_DIR"
    if [[ "$expected_rc" == 1 ]]; then
        assert_file_contains 'token-download-401: credential diagnostic' "$LOG/error" 'linear-auth: http=401 credential=app-token'
    fi
done

# The mint host uses only its pair, even when a published token cannot resolve.
for row in 'mint-host|app/id|app&secret' 'mint-host-reference|op://selected/app/id|op://selected/app/secret'; do
    IFS='|' read -r label id secret <<<"$row"
    forget_token
    : >"$LOG/mints"
    : >"$LOG/auth"
    : >"$LOG/op"
    : >"$LOG/config"
    before=$(find "$PROJECT" -type f | sort)
    run_oauth_request auth-mint LINEAR_CLIENT_ID="$id" LINEAR_CLIENT_SECRET="$secret" \
        LINEAR_APP_TOKEN=op://unused/token LINEAR_API_KEY_OVERRIDE=op://unused/key
    assert_eq "$label: mint succeeds" "$RC" 0
    assert_jq "$label: token JSON" "$OUT" '. == {access_token:"token-1",expires_at:4600}'
    count=$(wc -l <"$LOG/mints")
    assert_eq "$label: one mint" "${count//[[:space:]]/}" 1
    assert_not "$label: no GraphQL call" test -s "$LOG/auth"
    assert_not "$label: cache directory absent" test -e "$TOKEN_DIR"
    after=$(find "$PROJECT" -type f | sort)
    assert_eq "$label: no files added" "$after" "$before"
    if [[ "$label" == mint-host-reference ]]; then
        reads=$(cat "$LOG/op")
        assert_eq 'mint-host-reference: only pair resolves' "$reads" \
            $'read op://selected/app/id\nread op://selected/app/secret'
        config=$(cat "$LOG/config")
        assert_contains 'mint-host-reference: resolved pair reaches mint' "$config" \
            'client_id=resolved%2Fid&client_secret=resolved%26secret'
    fi
done

for row in 'mint-missing||' 'mint-missing-secret|app/id|' 'mint-missing-id||app&secret'; do
    IFS='|' read -r label id secret <<<"$row"
    : >"$LOG/mints"
    run_oauth_request auth-mint LINEAR_CLIENT_ID="$id" LINEAR_CLIENT_SECRET="$secret" \
        LINEAR_APP_TOKEN=published-token LINEAR_API_KEY_OVERRIDE=personal-key
    assert_eq "$label: refuses" "$RC" 1
    assert_file_contains "$label: incomplete pair diagnostic" "$LOG/error" 'credential=incomplete-app'
    assert_not "$label: never mints" test -s "$LOG/mints"
    assert_eq "$label: no stdout" "$OUT" ''
done

# Linear's token endpoint supplies token_type, access_token and expires_in.
for row in \
    'type|{"access_token":"token","token_type":"Basic","expires_in":3600}' \
    'empty|{"access_token":"","token_type":"Bearer","expires_in":3600}' \
    'expiry-low|{"access_token":"token","token_type":"Bearer","expires_in":60}' \
    'expiry-high|{"access_token":"token","token_type":"Bearer","expires_in":2592001}' \
    'expiry-fraction|{"access_token":"token","token_type":"Bearer","expires_in":3600.5}'; do
    IFS='|' read -r label response <<<"$row"
    run_oauth_request auth-mint LINEAR_CLIENT_ID=app/id LINEAR_CLIENT_SECRET='app&secret' \
        MODE=token-response TOKEN_RESPONSE="$response"
    assert_eq "mint-response-$label: refuses" "$RC" 1
    assert_file_contains "mint-response-$label: response diagnostic" "$LOG/error" 'token=invalid-response'
    assert_eq "mint-response-$label: no stdout" "$OUT" ''
done
# A mint is a read: an unanswered or rate-limited mint is sent three times, and
# a refused one once.
for row in 'token-failure|token-http=400|1' 'token-transport|token=transport-failed|3' \
    'token-ratelimited|"code":"RATELIMITED"|3'; do
    IFS='|' read -r mode diagnostic mints <<<"$row"
    : >"$LOG/mints"
    run_oauth_request auth-mint LINEAR_CLIENT_ID=app/id LINEAR_CLIENT_SECRET='app&secret' MODE="$mode"
    assert_eq "mint-$mode: refuses" "$RC" 1
    assert_file_contains "mint-$mode: diagnostic" "$LOG/error" "$diagnostic"
    assert_eq "mint-$mode: no stdout" "$OUT" ''
    count=$(wc -l <"$LOG/mints")
    assert_eq "mint-$mode: mint count" "${count//[[:space:]]/}" "$mints"
    assert_file_lacks "mint-$mode: no unconfirmed-write notice" "$LOG/error" 'write=unconfirmed'
done

# A token minted before a scope change, in the per-user file a pair-only key
# names, is never reused: every checkout and catalog version shares that
# directory, so the scope must be part of the name.
if command -v sha256sum >/dev/null 2>&1; then
    old_key=$(printf '%s' 'app/id:app&secret' | sha256sum | cut -c1-12) || { echo 'oauth-auth: digest=failed' >&2; exit 1; }
else
    old_key=$(printf '%s' 'app/id:app&secret' | shasum -a 256 | cut -c1-12) || { echo 'oauth-auth: digest=failed' >&2; exit 1; }
fi
printf 'LINEAR_CLIENT_ID="app/id"\nLINEAR_CLIENT_SECRET="app&secret"\n' >"$PROJECT/.env.local"
forget_token
mkdir -p -- "$TOKEN_DIR"
printf '{"access_token":"old-scope-token","expires_at":99999999}\n' >"$TOKEN_DIR/$old_key.json"
: >"$LOG/mints"
: >"$LOG/auth"
run_oauth_request request
assert_eq 'old-scope token file: request succeeds' "$RC" 0
count=$(wc -l <"$LOG/mints")
assert_eq 'old-scope token file: scope change mints a new token' "${count//[[:space:]]/}" 1
assert_eq 'old-scope token file: the new token reaches GraphQL' "$(cat "$LOG/auth")" 'Bearer token-1'

# A cache directory that cannot be written moves the token to this user's
# directory under TMPDIR, which every later request reads. XDG_CACHE_HOME
# naming a regular file makes the directory unwritable for every user, root
# included.
forget_token
printf 'not a directory\n' >"$TMP_ROOT/cache-file"
: >"$LOG/mints"
: >"$LOG/auth"
run_oauth_request request ACTION=twice XDG_CACHE_HOME="$TMP_ROOT/cache-file"
assert_eq 'unwritable cache dir: requests succeed' "$RC" 0
assert_eq 'unwritable cache dir: one mint serves both requests' "$(cat "$LOG/auth")" $'Bearer token-1\nBearer token-1'
assert_matches 'unwritable cache dir: the token file is in the TMPDIR directory' \
    "$(find "$TMP_ROOT/tmpdir" -type f)" "^$FALLBACK_DIR/[0-9a-f]{12}[.]json\$"
assert_eq 'unwritable cache dir: the TMPDIR directory is private' \
    "$(find "$FALLBACK_DIR" \( -type d -perm 0700 \) -o \( -type f -perm 0600 \) | wc -l | tr -d ' ')" 2
assert_file_lacks 'unwritable cache dir: no store failure' "$LOG/error" 'token-store=failed'

# With neither HOME nor XDG_CACHE_HOME set there is no cache directory, and the
# token lives in this user's directory under TMPDIR.
forget_token
: >"$LOG/mints"
: >"$LOG/auth"
run_oauth_request request ACTION=twice env -u HOME
assert_eq 'no HOME: requests succeed' "$RC" 0
assert_eq 'no HOME: one mint serves both requests' "$(cat "$LOG/auth")" $'Bearer token-1\nBearer token-1'
assert_matches 'no HOME: the token file is in the TMPDIR directory' \
    "$(find "$TMP_ROOT/tmpdir" -type f)" "^$FALLBACK_DIR/[0-9a-f]{12}[.]json\$"

# A cache directory this session can read but not write, holding an unexpired
# token Linear has revoked, is never read: the token lives in the directory
# its renewal can replace, so one mint serves this invocation and the next.
forget_token
mkdir -p -- "$TOKEN_DIR"
printf '{"access_token":"revoked-token","expires_at":99999999}\n' >"$TOKEN_DIR/$TOKEN_NAME"
: >"$LOG/mints"
: >"$LOG/auth"
for invocation in 1 2; do
    run_oauth_request request READ_ONLY="$TOKEN_DIR"
    assert_eq "read-only cache dir: invocation $invocation succeeds" "$RC" 0
done
count=$(wc -l <"$LOG/mints")
assert_eq 'read-only cache dir: one mint across two invocations' "${count//[[:space:]]/}" 1
assert_eq 'read-only cache dir: the revoked token is never sent' "$(cat "$LOG/auth")" $'Bearer token-1\nBearer token-1'

# With no token directory to keep it in, only the reuse is lost: each request
# runs on the token it minted, and stderr names every directory and its cause.
# A TMPDIR entry that is a symlink, which under a shared /tmp could lead to
# another user's directory, is never read or written: the token planted behind
# it is never sent. The not-owned cause needs a second user and has no row.
ELSEWHERE="$TMP_ROOT/elsewhere"
mkdir -p -- "$ELSEWHERE"
for row in \
    "symlink|$TMP_ROOT/cache-file|||dir=[$TMP_ROOT/cache-file/kendex/linear-oauth] cause=mkdir-failed dir=[$FALLBACK_DIR] cause=symlink" \
    "read-only|||$TOKEN_DIR:$FALLBACK_DIR|dir=[$TOKEN_DIR] cause=not-writable dir=[$FALLBACK_DIR] cause=not-writable" \
    "write-failed||1||dir=[$TOKEN_DIR] cause=write-failed"; do
    IFS='|' read -r label xdg mv_fail read_only causes <<<"$row"
    forget_token
    find "$ELSEWHERE" -mindepth 1 -delete
    if [[ "$label" == symlink ]]; then
        printf '{"access_token":"planted-token","expires_at":99999999}\n' >"$ELSEWHERE/$TOKEN_NAME"
        ln -s -- "$ELSEWHERE" "$FALLBACK_DIR"
    fi
    : >"$LOG/mints"
    : >"$LOG/auth"
    run_oauth_request request ACTION=twice ${xdg:+XDG_CACHE_HOME="$xdg"} MV_FAIL="$mv_fail" READ_ONLY="$read_only"
    assert_eq "$label: requests succeed" "$RC" 0
    assert_eq "$label: each request carries its minted token" "$(cat "$LOG/auth")" $'Bearer token-1\nBearer token-2'
    assert_file_contains "$label: stderr names each directory and its cause" "$LOG/error" \
        "linear-auth: token-store=failed $causes"
    files=$(find "$TMP_ROOT" -type f \( -name '*.json' -o -name '.token.*' \) \( -path '*oauth*' -o -path "$ELSEWHERE/*" \)) ||
        { echo 'oauth-auth: find=failed' >&2; exit 1; }
    expected=''
    [[ "$label" != symlink ]] || expected="$ELSEWHERE/$TOKEN_NAME"
    assert_eq "$label: no token file and no staged file is written" "$files" "$expected"
    [[ ! -L "$FALLBACK_DIR" ]] || rm -- "$FALLBACK_DIR"
done

run_oauth_git_redirects "$SCRIPT_DIR/oauth-auth.test.sh" "$TMP_ROOT/git-callers"
