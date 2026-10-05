#!/usr/bin/env bash
# Linear emits rate-limit rejections with an OUTER
# HTTP 400 whose body carries extensions.code RATELIMITED. These must route
# to the rate-limit path, one JSON line carrying "code":"RATELIMITED" and
# requests_reset, the time X-RateLimit-Requests-Reset names, never surface as
# the generic "HTTP error: 400" — and a failed team lookup must propagate the
# API failure instead of reporting the misleading "Team not found".
# Only a rate-limited, 5xx or unanswered request is retried: a generic 4xx
# fails on its first answer and carries the body's first error message. A
# Retry-After on the answer lengthens the wait before the next one. A 5xx or
# unanswered mutation is sent once, since Linear may already have applied it;
# a rate-limited one is retried, since Linear refused it unrun.
#
# Runs fully offline against a mocked curl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_BASE

# make_env <root> <http_code> <body-json> [headers]: isolated skill copy + a
# curl stub that always answers with the given status/body (linear_http_post
# appends the status code after a delimiter via -w; emulate with
# %{http_code}). Headers, when given, precede the body as `dump-header = "-"`
# writes them: CRLF lines and a blank line, one such block per header block.
# The code `none` is a curl that reaches no server: it writes nothing and
# exits 7. Every invocation appends one line to <root>/calls.
make_env() {
  local root="$1" code="$2" body="$3" headers="${4:-}"
  mkdir -p "$root/.agents/skills" "$root/bin"
  cp -R "$SKILL_DIR" "$root/.agents/skills/linear"
  git -C "$root" init -q >/dev/null
  if [[ -n "$headers" ]]; then
    printf '%s\r\n\r\n%s' "$headers" "$body" > "$root/body.json"
  else
    printf '%s' "$body" > "$root/body.json"
  fi
  cat >"$root/bin/curl" <<SH
#!/usr/bin/env bash
# Consume the -K - config from stdin like the real invocation.
cat >/dev/null
echo sent >>"$root/calls"
[[ "$code" != none ]] || exit 7
args=("\$@")
w_fmt=""
for ((i=0; i<\${#args[@]}; i++)); do
  [[ "\${args[i]}" == "-w" ]] && w_fmt="\${args[i+1]}"
done
cat "$root/body.json"
printf '%s' "\${w_fmt/\%\{http_code\}/$code}"
SH
  chmod +x "$root/bin/curl"
}

RL_BODY='{"errors":[{"message":"Rate limit exceeded. Only 2500 requests are allowed per 1 hour.","extensions":{"type":"ratelimited","code":"RATELIMITED","statusCode":429,"userError":true}}]}'
# Header names as Linear sends them; the reset is epoch milliseconds.
RL_HEADERS=$'HTTP/1.1 400 Bad Request\r\nX-Ratelimit-Requests-Remaining: 0\r\nX-Ratelimit-Requests-Reset: 1791143331872'
RL_RESET="2026-10-04T19:48:51Z"
GENERIC_BODY='{"errors":[{"message":"Argument Validation Error","extensions":{"code":"INVALID_INPUT"}}]}'

# The rate-limit line among OUTPUT's lines, as one JSON object.
quota_line() { jq -c 'select(type == "object" and .code == "RATELIMITED")' 2>/dev/null <<<"$1" || true; }

# Returns the CLI's combined output and its status. The status is asserted by
# the caller rather than here: every call site captures this in a command
# substitution, and a subshell gets its own copy of the counters, so an
# assertion made inside would be recorded where the suite cannot see it.
run_linear() { # root, args...
  local root="$1"; shift
  # No backoff: every response here comes from the curl stub two lines up, so
  # the retry wait would be spent on nothing.
  (cd "$root" && env PATH="$root/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE="lin_api_test" LINEAR_TEAM="Claude" \
    LINEAR_RETRY_BASE_DELAY=0 \
    "$root/.agents/skills/linear/scripts/linear.sh" "$@" 2>&1)
}

echo "=== RATELIMITED body on HTTP 400 routes to the rate-limit path ==="
make_env "$TMP_BASE/rl" 400 "$RL_BODY"
rl_rc=0
out="$(run_linear "$TMP_BASE/rl" statuses list)" || rl_rc=$?

assert_ne "a RATELIMITED body on HTTP 400 fails the call" "$rl_rc" 0
assert_jq "rate-limited 400 reports the rate limit" "$(quota_line "$out")" '.code == "RATELIMITED"'
assert_jq "a rate limit with no reset header says the reset is unavailable" "$(quota_line "$out")" '.requests_reset == "unavailable"'
assert_not_contains "rate-limited 400 is not a generic HTTP error" "$out" "HTTP error: 400"

echo "=== a rate limit names the time the request quota refills ==="
make_env "$TMP_BASE/reset" 400 "$RL_BODY" "$RL_HEADERS"
reset_rc=0
out="$(run_linear "$TMP_BASE/reset" statuses list)" || reset_rc=$?
assert_ne "a rate limit with a reset header fails the call" "$reset_rc" 0
assert_jq "a rate limit names the Requests-Reset time" "$(quota_line "$out")" ".requests_reset == \"$RL_RESET\""
make_env "$TMP_BASE/status429" 429 '{}' "$RL_HEADERS"
status_rc=0
out="$(run_linear "$TMP_BASE/status429" statuses list)" || status_rc=$?
assert_ne "an HTTP 429 fails the call" "$status_rc" 0
assert_jq "an HTTP 429 is the rate-limit path" "$(quota_line "$out")" ".requests_reset == \"$RL_RESET\""
# An interim 100 Continue, or a proxy's CONNECT answer, puts a header block of
# its own ahead of the response's: the reset is read off the last block.
make_env "$TMP_BASE/blocks" 400 "$RL_BODY" $'HTTP/1.1 100 Continue\r\n\r\n'"$RL_HEADERS"
blocks_rc=0
out="$(run_linear "$TMP_BASE/blocks" statuses list)" || blocks_rc=$?
assert_ne "a reply after an interim header block fails the call" "$blocks_rc" 0
assert_jq "a reply after an interim header block names the Requests-Reset time" "$(quota_line "$out")" ".requests_reset == \"$RL_RESET\""
# The RATELIMITED code in the body decides, whatever status carries it.
make_env "$TMP_BASE/ok429" 200 "$RL_BODY"
ok_rc=0
out="$(run_linear "$TMP_BASE/ok429" statuses list)" || ok_rc=$?
assert_ne "a RATELIMITED body on HTTP 200 fails the call" "$ok_rc" 0
assert_jq "a RATELIMITED body on HTTP 200 reports the rate limit" "$(quota_line "$out")" '.code == "RATELIMITED"'

echo "=== a successful reply carries its headers ahead of the body ==="
make_env "$TMP_BASE/ok" 200 '{"data":{"viewer":{"id":"actor-id","name":"Actor name"}}}' \
  $'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Ratelimit-Requests-Remaining: 2499'
ok_out="$(cd "$TMP_BASE/ok" && env PATH="$TMP_BASE/ok/bin:$PATH" \
  LINEAR_API_KEY_OVERRIDE="lin_api_test" LINEAR_TEAM="Claude" LINEAR_RETRY_BASE_DELAY=0 \
  "$TMP_BASE/ok/.agents/skills/linear/scripts/linear.sh" auth-check 2>/dev/null)" || true
assert_jq "a header-prefixed 200 reads its body" "$ok_out" '.ok == true and .actor.id == "actor-id"'
echo "=== failed team lookup propagates the API failure ==="
unit_rc=0
unit="$(cd "$TMP_BASE/rl" && env PATH="$TMP_BASE/rl/bin:$PATH" \
  LINEAR_RETRY_BASE_DELAY=0 bash -c '
  set -u
  LINEAR_API="https://api.linear.app/graphql"
  LINEAR_API_KEY="lin_api_test"
  source "$0/.agents/skills/linear/scripts/lib/common.sh"
  resolve_team_id "Claude"
' "$TMP_BASE/rl" 2>&1)" || unit_rc=$?

assert_ne "a rate-limited team lookup fails" "$unit_rc" 0
assert_jq "team lookup surfaces the rate limit" "$(quota_line "$unit")" '.code == "RATELIMITED"'
assert_contains "team lookup names the failed resolution" "$unit" "Could not resolve team 'Claude'"
assert_not_contains "team lookup does not claim the team is missing" "$unit" "Team not found"
echo "=== generic non-200 carries the body's error message ==="
make_env "$TMP_BASE/gen" 400 "$GENERIC_BODY"
gen_rc=0
out="$(run_linear "$TMP_BASE/gen" statuses list)" || gen_rc=$?

assert_ne "a generic non-200 fails the call" "$gen_rc" 0
assert_contains "generic 400 includes the body message" "$out" "HTTP error: 400: Argument Validation Error"

echo "=== the retry backoff is overridable ==="
# What the retry actually waited is read off a sleep stub, not off the clock:
# a wall-time assertion would pass on a slow host that never honoured the
# override. Every arm below runs against the same stubbed curl, so the only
# variable is the delay the library asks for.
cat >"$TMP_BASE/rl/bin/sleep" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$TMP_BASE/rl/slept"
SH
chmod +x "$TMP_BASE/rl/bin/sleep"

: >"$TMP_BASE/rl/slept"
run_linear "$TMP_BASE/rl" statuses list >/dev/null 2>&1 || true
assert_eq "an overridden base delay is what the retry sleeps" \
  "$(tr '\n' ' ' <"$TMP_BASE/rl/slept")" "0 0 "

: >"$TMP_BASE/rl/slept"
(cd "$TMP_BASE/rl" && env PATH="$TMP_BASE/rl/bin:$PATH" \
  LINEAR_API_KEY_OVERRIDE="lin_api_test" LINEAR_TEAM="Claude" \
  "$TMP_BASE/rl/.agents/skills/linear/scripts/linear.sh" statuses list) >/dev/null 2>&1 || true
assert_eq "the default backoff still doubles from one second" \
  "$(tr '\n' ' ' <"$TMP_BASE/rl/slept")" "1 2 "

junk_rc=0
junk="$(cd "$TMP_BASE/rl" && env PATH="$TMP_BASE/rl/bin:$PATH" \
  LINEAR_API_KEY_OVERRIDE="lin_api_test" LINEAR_TEAM="Claude" \
  LINEAR_RETRY_BASE_DELAY="soon" \
  "$TMP_BASE/rl/.agents/skills/linear/scripts/linear.sh" statuses list 2>&1)" || junk_rc=$?
assert_ne "a non-numeric base delay fails the call" "$junk_rc" 0
assert_contains "a non-numeric base delay names the setting" \
  "$junk" "LINEAR_RETRY_BASE_DELAY must be a whole number of seconds"

# Width is part of the grammar too: 19 digits is outside signed 64-bit
# arithmetic, and the wrap is a negative backoff `sleep` refuses once the
# request has already gone out.
wide_rc=0
wide="$(cd "$TMP_BASE/rl" && env PATH="$TMP_BASE/rl/bin:$PATH" \
  LINEAR_API_KEY_OVERRIDE="lin_api_test" LINEAR_TEAM="Claude" \
  LINEAR_RETRY_BASE_DELAY=9999999999999999999 \
  "$TMP_BASE/rl/.agents/skills/linear/scripts/linear.sh" statuses list 2>&1)" || wide_rc=$?
assert_ne "a base delay too wide for the arithmetic fails the call" "$wide_rc" 0
assert_contains "an over-wide base delay names the setting" \
  "$wide" "LINEAR_RETRY_BASE_DELAY must be a whole number of seconds"

# The process environment is not the only way this value arrives: SKILL.md
# points non-secret defaults at the project's committed settings, and every
# other LINEAR_* key resolves from there. A guard the settings file can walk
# past is no guard — the bad value reaches `sleep` and the run dies mid-flight,
# after the request has already gone out.
printf '[env]\nLINEAR_RETRY_BASE_DELAY = "soon"\n' >"$TMP_BASE/rl/kendex.settings.toml"
settings_rc=0
settings_out="$(cd "$TMP_BASE/rl" && env PATH="$TMP_BASE/rl/bin:$PATH" \
  LINEAR_API_KEY_OVERRIDE="lin_api_test" LINEAR_TEAM="Claude" \
  "$TMP_BASE/rl/.agents/skills/linear/scripts/linear.sh" statuses list 2>&1)" || settings_rc=$?
assert_ne "a non-numeric base delay in kendex.settings.toml fails the call" "$settings_rc" 0
assert_contains "a settings-file base delay reaches the same named refusal" \
  "$settings_out" "LINEAR_RETRY_BASE_DELAY must be a whole number of seconds"
rm -f "$TMP_BASE/rl/kendex.settings.toml"

# A leading zero is a decimal figure. Read in the shell's default base it is
# octal, and 08 is not a number at all: the run would die on an arithmetic
# error where the caller expects the structured rate-limit answer.
: >"$TMP_BASE/rl/slept"
zero_out="$(cd "$TMP_BASE/rl" && env PATH="$TMP_BASE/rl/bin:$PATH" \
  LINEAR_API_KEY_OVERRIDE="lin_api_test" LINEAR_TEAM="Claude" \
  LINEAR_RETRY_BASE_DELAY=08 \
  "$TMP_BASE/rl/.agents/skills/linear/scripts/linear.sh" statuses list 2>&1)" || true
assert_eq "a leading-zero base delay is read in base ten" \
  "$(tr '\n' ' ' <"$TMP_BASE/rl/slept")" "8 16 "
assert_jq "a leading-zero base delay still answers with the rate limit" \
  "$(quota_line "$zero_out")" '.code == "RATELIMITED"'
assert_not_contains "a leading-zero base delay is never an arithmetic error" \
  "$zero_out" "value too great for base"

echo "=== only a rate-limited, 5xx or unanswered query is retried ==="
# Each arm reads the waits the retry asked for off a sleep stub. A request
# retried twice sleeps twice; one that fails on its first answer never sleeps.
for row in "gen|a generic 400 fails on its first answer|" "server|a 5xx is retried|0 0 " "rl|a rate-limited answer is retried|0 0 " \
  "noanswer|an unanswered request is retried|0 0 "; do
  IFS='|' read -r env label want <<<"$row"
  if [[ "$env" == server ]]; then make_env "$TMP_BASE/server" 503 '{}'; fi
  if [[ "$env" == noanswer ]]; then make_env "$TMP_BASE/noanswer" none ''; fi
  cat >"$TMP_BASE/$env/bin/sleep" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$TMP_BASE/$env/slept"
SH
  chmod +x "$TMP_BASE/$env/bin/sleep"
  : >"$TMP_BASE/$env/slept"
  run_linear "$TMP_BASE/$env" statuses list >/dev/null 2>&1 || true
  assert_eq "$label" "$(tr '\n' ' ' <"$TMP_BASE/$env/slept")" "$want"
done

echo "=== a Retry-After the answer carries lengthens the wait ==="
make_env "$TMP_BASE/after" 429 '{}' $'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 5'
cat >"$TMP_BASE/after/bin/sleep" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$TMP_BASE/after/slept"
SH
chmod +x "$TMP_BASE/after/bin/sleep"
: >"$TMP_BASE/after/slept"
run_linear "$TMP_BASE/after" statuses list >/dev/null 2>&1 || true
assert_eq "a rate-limited answer waits out its Retry-After" "$(tr '\n' ' ' <"$TMP_BASE/after/slept")" "5 5 "

echo "=== a 5xx or unanswered query is retried; such a mutation is sent once ==="
# The stub answers every request alike, so the count of requests it saw is the
# count the library sent. Both documents open with a newline and an indent, as
# the commands' heredoc documents do.
MUTATION=$'\n    mutation CreateComment($input: CommentCreateInput!) { commentCreate(input: $input) { success } }'
QUERY=$'\n    query Q { viewer { id } }'
request_once() { # root, document: graphql_request's combined output
  local root="$1"
  (cd "$root" && env PATH="$root/bin:$PATH" LINEAR_RETRY_BASE_DELAY=0 bash -c '
    set -u
    LINEAR_API="https://api.linear.app/graphql"
    LINEAR_API_KEY="lin_api_test"
    source "$0/.agents/skills/linear/scripts/lib/common.sh"
    graphql_request "$1" "{}"
  ' "$root" "$2" 2>&1)
}
for row in "wserver|MUTATION|502|{}|1|a mutation answered 5xx is sent once" \
  "wnoanswer|MUTATION|none||1|an unanswered mutation is sent once" \
  "wrl|MUTATION|400|$RL_BODY|3|a rate-limited mutation is retried" \
  "rserver|QUERY|502|{}|3|an indented query answered 5xx is sent three times" \
  "rnoanswer|QUERY|none||3|an unanswered indented query is sent three times"; do
  IFS='|' read -r env document code body want label <<<"$row"
  make_env "$TMP_BASE/$env" "$code" "$body"
  : >"$TMP_BASE/$env/calls"
  request_rc=0
  out="$(request_once "$TMP_BASE/$env" "${!document}")" || request_rc=$?
  assert_ne "$label: the call fails" "$request_rc" 0
  assert_eq "$label" "$(wc -l <"$TMP_BASE/$env/calls" | tr -d ' ')" "$want"
  if [[ "$want" == 1 ]]; then
    # The key line an agent reads before deciding whether to send the write again.
    assert_contains "$label: names the write unconfirmed" "$out" "linear-http: write=unconfirmed code=${code/none/000}"
  else
    assert_not_contains "$label: names no unconfirmed write" "$out" "linear-http: write=unconfirmed"
  fi
done
