#!/usr/bin/env bash
# bash-runtime: 4
# Surface: installed journal controls and the HTTP attempts they observe.
# Inputs: linear.sh, lib/common.sh, lib/auth.sh, lib/attachments.sh,
# commands/auth-check.sh, commands/attachments.sh, commands/comments.sh,
# commands/issues.sh and their shared runtime libraries. No network traffic.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
assert_tmpdir TMP_ROOT
PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/bin" "$PROJECT/.agents/skills"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
cp -R -- "$SKILL_DIR" "$PROJECT/.agents/skills/linear"
LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
REAL_MKDIR=$(command -v mkdir)
cat >"$PROJECT/bin/date" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'clock\n' >>"$LOG/clock-calls"
if [[ "${HOLD_CLOCK:-}" == 1 ]]; then
    printf 'locked\n' >"$LOG/ready"
    read -r release <"$LOG/release"
fi
cat "$LOG/now"
SH
cat >"$PROJECT/bin/mkdir" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${REPORT_BUSY:-}" == 1 && "${!#}" == */writer.lock && -d "${!#}" && ! -e "$LOG/reported-busy" ]]; then
    : >"$LOG/reported-busy"
    printf 'busy\n' >"$LOG/busy"
fi
exec "$REAL_MKDIR" "$@"
SH
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
kind=graphql
[[ "$config" != *'/oauth/token'* ]] || kind=mint
[[ "$config" != *'https://uploads.linear.app/private-path'* ]] || kind=download
[[ "$config" != *'upload-file = '* ]] || kind=upload
printf '%s\n' "$kind" >>"$LOG/sends"
n=$(awk -v kind="$kind" '$0 == kind {n++} END {print n+0}' "$LOG/sends")
code=200
case "${MODE:-}:$kind:$n" in
retry:graphql:1|renewal:graphql:1|download:download:1|download-budget:download:1|download-budget:download:3|download-budget:download:4) code=503 ;;
renewal:graphql:2|download:download:2|download-budget:download:2) code=401 ;;
rate:graphql:*) code=400 ;;
write:graphql:*) code=503 ;;
transport:graphql:*) code=000 ;;
upload-transport:upload:*) code=000 ;;
upload-http:upload:*) code=403 ;;
esac
exact=true
if [[ "$kind" == upload && "$config" != *'signed-upload-fixture'* ]]; then exact=false; fi
jq -cn --arg kind "$kind" --arg code "$code" --argjson exact "$exact" \
    '{transport:$kind,status:$code,exact_upload_header:$exact}' >>"$LOG/attempts"
[[ "$code" != 000 || "$kind" == upload ]] || exit 7
format='%{http_code}'
while [[ $# -gt 0 ]]; do
    case "$1" in
    -w) format="$2"; shift 2 ;;
    -o) [[ "$2" == /dev/null ]] || printf 'private-file-body\n' >"$2"; shift 2 ;;
    *) shift ;;
    esac
done
if [[ "$config" == *'dump-header'* ]]; then
    printf 'HTTP/1.1 100 Continue\r\nX-Complexity: 777\r\n\r\n'
    printf 'HTTP/1.1 %s Fixture\r\nAuthorization: private-response-header\r\n' "$code"
    if [[ "${MODE:-}" != missing && "$kind" == graphql ]]; then
        printf 'X-Complexity: 5\r\nX-RateLimit-Complexity-Remaining: 900\r\nX-RateLimit-Requests-Reset: 1791217043000\r\n'
    fi
    printf 'X-RateLimit-Invalid: private-invalid-value\r\n\r\n'
fi
[[ "$code" != 000 ]] || exit 7
if [[ "$kind" == mint ]]; then
    printf '{"access_token":"private-minted-token-%s","token_type":"Bearer","expires_in":3600}' "$n"
elif [[ "$kind" == graphql ]]; then
    if [[ "${MODE:-}" == rate ]]; then
        printf '{"errors":[{"message":"private-error-body","extensions":{"code":"RATELIMITED"}}]}'
    elif [[ "$config" == *'fileUpload('* ]]; then
        printf '{"data":{"fileUpload":{"success":true,"uploadFile":{"uploadUrl":"https://storage.invalid/private-signed-url","assetUrl":"https://uploads.linear.app/private-asset","headers":[{"key":"x-upload","value":"signed-upload-fixture"}]}}}}'
    elif [[ "$config" == *'commentCreate('* ]]; then
        printf '{"data":{"commentCreate":{"success":true,"comment":{"id":"comment","body":"private-response-body","issue":{"identifier":"TEAM-1"}}}}}'
    elif [[ "$config" == *'query GetIssue('* ]]; then
        printf '{"data":{"issue":{"id":"00000000-0000-0000-0000-000000000001","identifier":"TEAM-1"}}}'
    else
        printf '{"data":{"viewer":{"id":"00000000-0000-0000-0000-000000000001","name":"private-viewer-name"}}}'
    fi
fi
printf '%s' "${format/\%\{http_code\}/$code}"
SH
chmod +x "$PROJECT/bin/date" "$PROJECT/bin/mkdir" "$PROJECT/bin/curl"
printf 'private-file-body\n' >"$PROJECT/note.pdf"

run_linear() {
    # Independent journal worlds must not inherit another world's quota hold.
    (cd -- "${CALLER_REPOSITORY:-$PROJECT}" && env -i PATH="$PROJECT/bin:$PATH" HOME="$LOG/home" \
        LOG="$LOG" REAL_MKDIR="$REAL_MKDIR" MODE="$MODE" \
        LINEAR_API_KEY_OVERRIDE="${KEY:-private-personal-key}" \
        LINEAR_CLIENT_ID="${CLIENT_ID:-}" LINEAR_CLIENT_SECRET="${CLIENT_SECRET:-}" \
        LINEAR_RETRY_BASE_DELAY=0 LINEAR_JOURNAL_DIR="$JOURNAL" \
        LINEAR_JOURNAL_CALLER="${CALLER:-}" LINEAR_JOURNAL_ITEM="${ITEM:-}" \
        HOLD_CLOCK="${HOLD_CLOCK:-}" REPORT_BUSY="${REPORT_BUSY:-}" "$BASH" "$LINEAR" "$@")
}

for row in \
    'default|auth|1|0|0|off' \
    'active|auth|1|1|0|active' \
    'retry|auth|2|2|0|active|[["graphql",0,1],["graphql",0,2]]|1' \
    'renewal|auth|5|5|0|active|[["mint",0,1],["graphql",0,1],["graphql",0,2],["mint",0,1],["graphql",1,1]]|3' \
    'download|download|5|5|0|active|[["mint",0,1],["download",0,1],["download",0,2],["mint",0,1],["download",1,1]]|3' \
    'download-budget|download|6|6|1|active|[["mint",0,1],["download",0,1],["download",0,2],["mint",0,1],["download",1,1],["download",1,2]]|3' \
    'upload|upload|4|4|0|active||4' \
    'upload-transport|upload|3|3|1|active||3' \
    'upload-http|upload|3|3|1|active||3' \
    'missing|auth|1|1|0|active' \
    'changed|auth|1|1|0|active' \
    'cap|auth|1|0|0|byte-cap' \
    'stop|auth|1|0|0|stopped' \
    'stop-expired|none|0|0|0|expired' \
    'expiry|auth|1|0|0|expired' \
    'transport|auth|3|3|1|active' \
    'rate|auth|1|1|1|active' \
    'write|write|1|1|1|active'; do
    IFS='|' read -r MODE action sends records expected_rc state sequence logical_requests <<<"$row"
    LOG="$TMP_ROOT/$MODE"
    mkdir -p "$LOG"
    printf '1000\n' >"$LOG/now"
    : >"$LOG/attempts"
    : >"$LOG/sends"
    : >"$LOG/clock-calls"
    JOURNAL="$LOG/journal"
    KEY=private-personal-key CLIENT_ID='' CLIENT_SECRET=''
    CALLER=fixture-caller ITEM=TEAM-1
    if [[ "$MODE" == renewal || "$MODE" == download || "$MODE" == download-budget ]]; then
        CLIENT_ID="fixture-client-$MODE" CLIENT_SECRET=private-client-secret
    fi
    if [[ "$MODE" == default ]]; then
        JOURNAL=''
    else
        max=100000
        [[ "$MODE" != cap ]] || max=1
        out=$(run_linear journal start --max-bytes "$max" --actor-id 00000000-0000-0000-0000-000000000001)
        assert_jq "$MODE: start succeeds" "$out" '.status == "active"'
        assert_eq "$MODE: start sends no HTTP request" "$(wc -l <"$LOG/attempts" | tr -d ' ')" 0
    fi
    [[ "$MODE" != changed ]] || KEY=other-private-key
    [[ "$MODE" != missing ]] || { CALLER=''; ITEM=''; }
    [[ "$MODE" != stop ]] || run_linear journal stop >"$LOG/stop-result"
    case "$MODE" in stop|stop-expired|expiry) printf '4600\n' >"$LOG/now" ;; esac
    [[ "$MODE" != stop-expired ]] || run_linear journal stop >"$LOG/stop-result"
    rc=0
    case "$action" in
    auth) run_linear auth-check >"$LOG/out" 2>"$LOG/err" || rc=$? ;;
    download) run_linear attachments fetch https://uploads.linear.app/private-path --output "$LOG/downloaded" >"$LOG/out" 2>"$LOG/err" || rc=$? ;;
    upload) run_linear comments create TEAM-1 --body private-request-body --attach "$PROJECT/note.pdf" >"$LOG/out" 2>"$LOG/err" || rc=$? ;;
    write) run_linear comments create TEAM-1 --body private-request-body >"$LOG/out" 2>"$LOG/err" || rc=$? ;;
    none) ;;
    esac
    assert_eq "$MODE: request result" "$rc" "$expected_rc"
    assert_eq "$MODE: actual attempts" "$(wc -l <"$LOG/attempts" | tr -d ' ')" "$sends"
    if [[ "$MODE" == default ]]; then
        assert_not 'default: creates no journal directory' test -e "$LOG/journal"
        assert_eq 'default: does no journal clock work' "$(wc -l <"$LOG/clock-calls" | tr -d ' ')" 0
        continue
    fi
    summary=$(run_linear journal read)
    assert_jq "$MODE: collection state" "$summary" ".status == \"$state\""
    assert_jq "$MODE: recorded attempts" "$summary" ".totals.attempts == $records"
    if [[ "$records" != 0 ]]; then
        observed=$(jq -s 'map({transport,status:.http_status})' "$JOURNAL/attempts.jsonl")
        expected=$(jq -s 'map({transport,status})' "$LOG/attempts")
        assert_eq "$MODE: each journal record matches an actual attempt" "$observed" "$expected"
        all=$(jq -s . "$JOURNAL/attempts.jsonl")
        assert_jq "$MODE: no sensitive content is retained" "$all" \
            'tostring | test("private-|signed-upload-fixture|Authorization|variables|uploadUrl|access_token") | not'
        assert_jq "$MODE: final block excludes interim and invalid headers" "$all" \
            'all(.[]; .headers["x-complexity"] != "777" and .headers["x-ratelimit-invalid"] == null)'
        assert_jq "$MODE: attempt fields are explicit" "$all" \
            'all(.[]; .attempt >= 1 and .authorization_phase >= 0 and (.request_id | type == "string" and length > 0))'
        if [[ -n "$sequence" ]]; then
            assert_jq "$MODE: exact authorization phases and send ordinals" "$all" \
                "map([.transport,.authorization_phase,.attempt]) == $sequence"
            assert_jq "$MODE: resends retain one logical request ID" "$all" \
                '[.[] | select(.transport != "mint") | .request_id] | unique | length == 1'
        fi
        if [[ -n "$logical_requests" ]]; then
            assert_jq "$MODE: unrelated logical requests have distinct IDs" "$all" \
                "map(.request_id) | unique | length == $logical_requests"
        fi
        if [[ "$MODE" == changed ]]; then
            assert_jq 'changed: actor identity stays unread' "$all" 'all(.[]; .actor.id == null and .actor.source == "unread")'
        else
            assert_jq "$MODE: supplied actor remains bound" "$all" \
                'all(.[]; .actor.id == "00000000-0000-0000-0000-000000000001" and .actor.source == "supplied")'
        fi
    fi
    case "$MODE" in
    active)
        assert_jq 'active: only returned complexity is summed' "$summary" '.totals.known_complexity == 5 and .totals.complexity_measured == 1 and .top_five_by_attempts[0].attempts == 1'
        assert_jq 'active: caller and item are attributed' "$summary" '.totals.caller_supplied == 1 and .totals.item_known == 1 and .callers[0].caller.script == "fixture-caller"'
        first_bytes=$(wc -c <"$JOURNAL/attempts.jsonl") ;;
    renewal|download|download-budget)
        assert_jq "$MODE: renewal cause is recorded" "$all" 'any(.[]; .transport == "mint" and .cause == "401-renewal") and any(.[]; .authorization_phase == 1)' ;;
    missing)
        assert_jq 'missing: complexity and caller coverage stay explicit' "$summary" '.totals.complexity_measured == 0 and .totals.complexity_missing == 1 and .totals.known_complexity == 0 and .totals.item_known == 0 and .totals.caller_supplied == 0' ;;
    upload|upload-transport|upload-http)
        assert_jq "$MODE: exact signed headers still reach storage" "$(jq -s . "$LOG/attempts")" 'all(.[]; .exact_upload_header)'
        if [[ "$MODE" != upload ]]; then
            expected_code=403 expected_exit=0
            [[ "$MODE" != upload-transport ]] || { expected_code=000; expected_exit=7; }
            assert_jq "$MODE: safe PUT diagnostic" "$(jq -sc 'map(select(has("curl_exit")))' "$LOG/err")" \
                "length == 1 and .[0].http_code == \"$expected_code\" and .[0].curl_exit == $expected_exit"
            assert_eq "$MODE: no success output" "$(cat "$LOG/out")" ''
            assert_not_contains "$MODE: signed URL stays private" "$(cat "$LOG/err")" 'https://storage.invalid/private-signed-url'
            assert_not_contains "$MODE: signed header stays private" "$(cat "$LOG/err")" 'signed-upload-fixture'
        fi ;;
    expiry)
        assert_eq 'expired session records no further attempts' "$(wc -c <"$JOURNAL/attempts.jsonl" | tr -d ' ')" 0
        assert_jq 'expiry: read explains incomplete attempt and process coverage' "$summary" '.complete and (.limitations | length > 0)' ;;
    cap|stop)
        assert_jq "$MODE: partial hour is not complete" "$summary" '.complete == false' ;;
    stop-expired)
        assert_jq 'stop after expiry preserves the complete hour without a later request' "$(cat "$LOG/stop-result")" '.status == "expired" and .complete'
        assert_jq 'stop after expiry remains complete on read' "$summary" '.complete' ;;
    rate)
        assert_jq 'rate: actual HTTP status survives logical rate classification' "$all" 'all(.[]; .http_status == "400")' ;;
    write)
        assert_file_contains 'write: unconfirmed write notice survives observation' "$LOG/err" 'write=unconfirmed' ;;
    esac
done

MODE=active LOG="$TMP_ROOT/callers" JOURNAL="$TMP_ROOT/callers/journal"
KEY=private-personal-key CLIENT_ID='' CLIENT_SECRET='' CALLER=watch ITEM=TEAM-1
mkdir -p "$LOG"
printf '1000\n' >"$LOG/now"
: >"$LOG/attempts"; : >"$LOG/sends"
run_linear journal start --max-bytes 100000 --actor-id 00000000-0000-0000-0000-000000000001 >"$LOG/start"
for pair in watch:TEAM-1 watch:TEAM-2 audit:TEAM-1; do
    CALLER="${pair%%:*}" ITEM="${pair#*:}"
    run_linear auth-check >"$LOG/out"
done
CALLER_REPOSITORY="$TMP_ROOT/other-project"
mkdir -p "$CALLER_REPOSITORY"
git -C "$CALLER_REPOSITORY" init -q -b main
git -C "$CALLER_REPOSITORY" config gc.auto 0
git -C "$CALLER_REPOSITORY" config maintenance.auto false
CALLER=watch ITEM=TEAM-1
run_linear auth-check >"$LOG/other-out"
unset CALLER_REPOSITORY
summary=$(run_linear journal read)
all=$(jq -s . "$JOURNAL/attempts.jsonl")
assert_jq 'caller totals combine carrying items and retain repository boundaries' "$summary" \
    '.callers | length == 3 and ([.[] | select(.caller.script == "watch") | .attempts] | sort == [1,2])'
assert_jq 'top caller includes its combined attempts and returned complexity' "$summary" \
    '.top_five_by_attempts[0] | .caller.script == "watch" and .attempts == 2 and .known_complexity == 10 and .complexity_measured == 2 and .item_known == 2'
assert_jq 'caller totals do not assign one carrying item to the whole caller' "$summary" \
    'all(.callers[]; .caller | has("item") | not)'
assert_jq 'attempt records retain each carrying item' "$all" \
    '[.[] | select(.caller.script == "watch") | .caller.item] | sort == ["TEAM-1","TEAM-1","TEAM-2"]'
assert_jq 'separate entry invocations keep distinct logical request IDs' "$all" \
    'map(.request_id) | unique | length == 4'

# Acknowledgements prove the first writer holds the lock before the second
# reaches it. Both real request processes are reaped before fixture cleanup.
MODE=active LOG="$TMP_ROOT/concurrent" JOURNAL="$TMP_ROOT/concurrent/journal"
KEY=private-personal-key CLIENT_ID='' CLIENT_SECRET='' CALLER=fixture-caller ITEM=TEAM-1
mkdir -p "$LOG"
printf '1000\n' >"$LOG/now"
: >"$LOG/attempts"; : >"$LOG/sends"
mkfifo "$LOG/ready" "$LOG/release" "$LOG/busy"
run_linear journal start --max-bytes "$((first_bytes + 100))" --actor-id 00000000-0000-0000-0000-000000000001 >"$LOG/start"
HOLD_CLOCK=1 run_linear auth-check >"$LOG/first-out" 2>"$LOG/first-err" &
first=$!
read -r ready <"$LOG/ready"
REPORT_BUSY=1 run_linear auth-check >"$LOG/second-out" 2>"$LOG/second-err" &
second=$!
read -r busy <"$LOG/busy"
printf 'release\n' >"$LOG/release"
wait "$first"
wait "$second"
summary=$(run_linear journal read)
assert_jq 'concurrent: byte cap is serialized with append' "$summary" '.status == "byte-cap" and .totals.attempts == 1'
assert_eq 'concurrent: both attempts reached the transport' "$(wc -l <"$LOG/attempts" | tr -d ' ')" 2
assert 'concurrent: encoded bytes stay within the cap' test "$(wc -c <"$JOURNAL/attempts.jsonl")" -le "$((first_bytes + 100))"
