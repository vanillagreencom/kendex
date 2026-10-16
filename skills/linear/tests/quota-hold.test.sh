#!/usr/bin/env bash
# Surface: the shared quota receipt and persistent transport hold. Real command
# processes use one private home and an injected date command. curl is the only
# network fixture. The received-response arm also models an in-flight reply
# that arrives after another process has saved a later hold.
set -euo pipefail
export MSYS=winsymlinks:nativestrict
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" || exit 1
assert_tmpdir TMP_ROOT
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1
PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"
REAL_DATE="$(command -v date)"
cat >"$PROJECT/bin/date" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in '+%s'|'-u +%s') cat "$LOG/now" ;; *) exec "$REAL_DATE" "$@" ;; esac
SH
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
case "$config" in
  *'/oauth/token'*)
    printf 'mint\n' >>"$LOG/sends"
    printf '%s' '{"access_token":"fixture-token","token_type":"Bearer","expires_in":3600}___HTTP_CODE___200' ;;
  *'https://uploads.linear.app/'*)
    printf 'download\n' >>"$LOG/sends"
    output=''
    while (($#)); do
      if [[ "$1" == -o ]]; then output="$2"; shift; fi
      shift
    done
    printf 'fixture-content' >"$output"
    code=$(cat "$LOG/download-code")
    printf '200\n' >"$LOG/download-code"
    printf '___HTTP_CODE___%s' "$code" ;;
  *)
    printf 'graphql\n' >>"$LOG/sends"
    if [[ "$(cat "$LOG/reply")" == rate ]]; then
      printf 'HTTP/1.1 400 Bad Request\r\n'
      cat "$LOG/headers"
      printf '\r\n'
      cat "$LOG/body"
      printf '___HTTP_CODE___400'
    else
      printf '%s' '{"data":{"viewer":{"id":"fixture-actor","name":"Fixture actor","email":"actor@example.invalid"}}}___HTTP_CODE___200'
    fi ;;
esac
SH
cat >"$PROJECT/bin/invoke" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == response ]]; then
    source .agents/skills/linear/scripts/lib/common.sh
    headers=$(cat "$LOG/headers")
    body=$(cat "$LOG/body")
    linear_rate_limited "$headers" "$body"
else
    shift
    exec "$BASH" .agents/skills/linear/scripts/linear.sh "$@"
fi
SH
chmod +x "$PROJECT/bin/date" "$PROJECT/bin/curl" "$PROJECT/bin/invoke"

world() {
    LOG="$TMP_ROOT/$1"
    mkdir -p "$LOG/home" "$LOG/temp"
    printf '10000\n' >"$LOG/now"
    printf 'rate\n' >"$LOG/reply"
    : >"$LOG/sends"
    AUTH_ENV=(LINEAR_API_KEY_OVERRIDE=fixture-key-a)
}
reply() { # MESSAGE REQUEST_MS COMPLEXITY_MS ENDPOINT_MS ENDPOINT_NAME
    jq -cn --arg message "$1" '{errors:[{message:$message,extensions:{code:"RATELIMITED"}}]}' >"$LOG/body"
    : >"$LOG/headers"
    [[ -z "$2" ]] || printf 'X-RateLimit-Requests-Reset: %s\r\n' "$2" >>"$LOG/headers"
    [[ -z "$3" ]] || printf 'X-RateLimit-Complexity-Reset: %s\r\n' "$3" >>"$LOG/headers"
    [[ -z "$4" ]] || printf 'X-RateLimit-Endpoint-Requests-Reset: %s\r\n' "$4" >>"$LOG/headers"
    [[ -z "$5" ]] || printf 'X-RateLimit-Endpoint-Name: %s\r\n' "$5" >>"$LOG/headers"
    return 0
}
run() {
    RC=0
    OUT=$(cd -- "$PROJECT" && env -i PATH="$PROJECT/bin:$PATH" HOME="$LOG/home" TMPDIR="$LOG/temp" \
        LOG="$LOG" REAL_DATE="$REAL_DATE" LINEAR_RETRY_BASE_DELAY=0 LINEAR_JOURNAL_DIR="$LOG/journal" \
        "${AUTH_ENV[@]}" "$BASH" "$PROJECT/bin/invoke" "$@" 2>"$LOG/err") || RC=$?
}
quota() { jq -Rsc '[split("\n")[] | fromjson? | select(.code == "RATELIMITED")] | last' "$LOG/err"; }

# Linear's measured request-refusal text is retained from rate-limited-http-400.
# Endpoint naming and the reset headers follow Linear's documented response.
# The complexity row exercises a refusal that names the documented limit.
while IFS='|' read -r name message requests complexity endpoint endpoint_name status limit epoch; do
    world "$name"
    reply "$message" "$requests" "$complexity" "$endpoint" "$endpoint_name"
    run cli auth-check
    assert_ne "$name refuses its initial request" "$RC" 0
    got=$(quota)
    assert_jq "$name selected receipt" "$got" ".quota.status == \"$status\" and .quota.limit == \"$limit\" and .quota.reset_epoch == $epoch"
done <<'ROWS'
request|Rate limit exceeded. Only 2500 requests are allowed per 1 hour.|20000123|30000456|||future|requests|20001
complexity|Complexity rate limit exceeded.|30000456|20000123|||future|complexity|20001
endpoint|Rate limit exceeded.|30000456|40000789|20000123|issueCreate|future|endpoint|20001
unknown|Rate limit exceeded.|20000123|30000456|25000789||future|unknown|30001
elapsed|Rate limit exceeded.|9999000||||elapsed|unknown|9999
missing|Rate limit exceeded.|||||missing|unknown|null
invalid|Rate limit exceeded.|later|NaN|||invalid|unknown|null
named-missing|Rate limit exceeded. Only 2500 requests are allowed per 1 hour.||30000456|||missing|requests|null
ROWS

world shared
reply 'Rate limit exceeded.' 20000123 30000456 '' ''
run cli journal start --max-bytes 100000 --actor-id 11111111-1111-4111-8111-111111111111
assert_eq 'journal starts without HTTP' "$RC:$(wc -l <"$LOG/sends" | tr -d ' ')" '0:0'
run cli auth-check
assert_ne 'initial refusal fails' "$RC" 0
assert_jq 'raw requests_reset keeps the request header time' "$(quota)" '.requests_reset == "1970-01-01T05:33:20Z" and .quota.reset == "1970-01-01T08:20:01Z"'
before=$(wc -l <"$LOG/sends" | tr -d ' ')
assert_eq 'a future refusal stops before retry HTTP' "$before" 1
journal_before=$(wc -l <"$LOG/journal/attempts.jsonl" | tr -d ' ')
printf 'success\n' >"$LOG/reply"
run cli auth-check
assert_ne 'known hold refuses a separate process' "$RC" 0
assert_eq 'known hold sends no HTTP' "$(wc -l <"$LOG/sends" | tr -d ' ')" "$before"
assert_jq 'known hold reports its local source' "$(quota)" '.source == "local" and .quota.reset_epoch == 30001'
assert_eq 'local refusal writes no HTTP journal row' "$(wc -l <"$LOG/journal/attempts.jsonl" | tr -d ' ')" "$journal_before"
AUTH_ENV=(LINEAR_API_KEY_OVERRIDE=fixture-key-b)
run cli auth-check
assert_eq 'another binding remains independent' "$RC" 0
AUTH_ENV=(LINEAR_API_KEY_OVERRIDE=fixture-key-a)
printf '30001\n' >"$LOG/now"
run cli auth-check
assert_eq 'a passed reset permits an ordinary request' "$RC" 0

# An already in-flight earlier refusal cannot shorten a learned future hold.
printf '10000\n' >"$LOG/now"
reply 'Rate limit exceeded.' 15000000 '' '' ''
run response
assert_jq 'an earlier reply preserves the later hold' "$(quota)" '.quota.reset_epoch == 30001 and .requests_reset == "1970-01-01T04:10:00Z"'

world app
AUTH_ENV=(LINEAR_CLIENT_ID=fixture-client LINEAR_CLIENT_SECRET=fixture-secret)
reply 'Rate limit exceeded.' 20000000 '' '' ''
run cli auth-check
assert_ne 'app refusal fails' "$RC" 0
assert_eq 'app initial request mints once' "$(grep -c '^mint$' "$LOG/sends" || true)" 1
token_file=$(find "$LOG/home" -name '*.json' -type f ! -name 'quota-*')
printf 'success\n' >"$LOG/reply"
# The shipped download authorizes initially and renews once after a 401.
# Both use the same mint transport as GraphQL's authorization path.
while IFS='|' read -r name transport expires download_code expected_rc expected_sends; do
    jq --argjson expires "$expires" '.expires_at=$expires' "$token_file" >"$LOG/expired-token"
    mv -- "$LOG/expired-token" "$token_file"
    printf '%s\n' "$download_code" >"$LOG/download-code"
    : >"$LOG/sends"
    if [[ "$transport" == graphql ]]; then run cli auth-check
    else run cli attachments fetch https://uploads.linear.app/fixture --output "$LOG/$name.out"
    fi
    assert_eq "$name status" "$RC" "$expected_rc"
    assert_eq "$name HTTP sequence" "$(paste -sd, "$LOG/sends")" "$expected_sends"
    if [[ "$transport" == graphql ]]; then
        assert_jq "$name local refusal" "$(quota)" '.source == "local" and .quota.reset_epoch == 20000'
    else
        assert_file_contains "$name downloaded file" "$LOG/$name.out" fixture-content
    fi
done <<'ROWS'
graphql-held|graphql|0|200|1|
download-initial|download|0|200|0|mint,download
download-renewal|download|20000|401|0|download,mint,download
ROWS
before=$(wc -l <"$LOG/sends" | tr -d ' ')

# Private files are required evidence. Malformed and unreadable records never
# become a successful empty inventory. A failed save retains the refusal.
record=$(find "$LOG/home" -name 'quota-*.json' -type f)
assert 'one private hold record exists' test -f "$record"
cp -- "$record" "$LOG/valid-record"
printf 'broken\n' >"$record"
run cli auth-check
assert_ne 'malformed hold refuses' "$RC" 0
assert_file_contains 'malformed hold reports unavailable' "$LOG/err" '"code":"LINEAR_HOLD_UNAVAILABLE"'
assert_eq 'malformed hold sends no HTTP' "$(wc -l <"$LOG/sends" | tr -d ' ')" "$before"
cp -- "$LOG/valid-record" "$record"
REAL_JQ="$(command -v jq)"
cat >"$PROJECT/bin/jq" <<SH
#!/usr/bin/env bash
case "\${!#}" in */quota-*.json) exit 1 ;; esac
exec "$REAL_JQ" "\$@"
SH
chmod +x "$PROJECT/bin/jq"
run cli auth-check
assert_ne 'unreadable required hold refuses' "$RC" 0
assert_file_contains 'unreadable required hold reports unavailable' "$LOG/err" '"code":"LINEAR_HOLD_UNAVAILABLE"'
assert_eq 'unreadable required hold sends no HTTP' "$(wc -l <"$LOG/sends" | tr -d ' ')" "$before"
rm -- "$PROJECT/bin/jq"

# Auth never selects a symlink candidate. Its contents cannot become required
# quota state merely because a prior hold exists behind that link.
world ineligible_candidate
reply 'Rate limit exceeded.' 20000000 '' '' ''
run cli auth-check
record=$(find "$LOG/home" -name 'quota-*.json' -type f)
private_dir=${record%/*}
mv -- "$private_dir" "$LOG/excluded"
ln -s "$LOG/excluded" "$private_dir"
[[ -L "$private_dir" ]] || { printf 'quota-hold: fixture=symlink-failed\n' >&2; exit 1; }
printf 'success\n' >"$LOG/reply"
before=$(wc -l <"$LOG/sends" | tr -d ' ')
run cli auth-check
assert_eq 'unselected symlink candidate permits GraphQL' "$RC" 0
assert_eq 'unselected candidate sends one HTTP' "$(wc -l <"$LOG/sends" | tr -d ' ')" "$((before + 1))"

world failed_store
reply 'Rate limit exceeded.' 20000000 '' '' ''
cat >"$PROJECT/bin/mv" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$PROJECT/bin/mv"
run cli auth-check
assert_ne 'failed persistence keeps the request refused' "$RC" 0
assert_jq 'failed persistence preserves the selected reset' "$(quota)" '.quota.reset_epoch == 20000 and .hold_storage == "unavailable"'
rm -- "$PROJECT/bin/mv"
