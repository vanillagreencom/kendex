#!/usr/bin/env bash
# Regression test (#1018): Linear emits rate-limit rejections with an OUTER
# HTTP 400 whose body carries extensions.code RATELIMITED. These must route
# to the rate-limit path ("Rate limited. Try again later."), never surface as
# the generic "HTTP error: 400" — and a failed team lookup must propagate the
# API failure instead of reporting the misleading "Team not found".
# A generic non-200 must carry the body's first error message.
#
# Runs fully offline against a mocked curl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_BASE

# make_env <root> <http_code> <body-json>: isolated skill copy + a curl stub
# that always answers with the given status/body (graphql_query appends the
# status code after a NUL-ish delimiter via -w; emulate with %{http_code}).
make_env() {
  local root="$1" code="$2" body="$3"
  mkdir -p "$root/.agents/skills" "$root/bin"
  cp -R "$SKILL_DIR" "$root/.agents/skills/linear"
  git -C "$root" init -q >/dev/null
  printf '%s' "$body" > "$root/body.json"
  cat >"$root/bin/curl" <<SH
#!/usr/bin/env bash
# Consume the -K - config from stdin like the real invocation.
cat >/dev/null
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
GENERIC_BODY='{"errors":[{"message":"Argument Validation Error","extensions":{"code":"INVALID_INPUT"}}]}'

run_linear() { # root, args...
  local root="$1"; shift
  (cd "$root" && env PATH="$root/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE="lin_api_test" LINEAR_TEAM="Claude" \
    "$root/.agents/skills/linear/scripts/linear.sh" "$@" 2>&1) || true
}

echo "=== RATELIMITED body on HTTP 400 routes to the rate-limit path ==="
make_env "$TMP_BASE/rl" 400 "$RL_BODY"
out="$(run_linear "$TMP_BASE/rl" statuses list)"
assert_contains "rate-limited 400 reports the rate limit" "$out" "Rate limited. Try again later."
assert_not_contains "rate-limited 400 is not a generic HTTP error" "$out" "HTTP error: 400"
echo "=== failed team lookup propagates the API failure ==="
unit="$(cd "$TMP_BASE/rl" && env PATH="$TMP_BASE/rl/bin:$PATH" bash -c '
  set -u
  LINEAR_API="https://api.linear.app/graphql"
  LINEAR_API_KEY="lin_api_test"
  source "$0/.agents/skills/linear/scripts/lib/common.sh"
  resolve_team_id "Claude"
' "$TMP_BASE/rl" 2>&1)" || true
assert_contains "team lookup surfaces the rate limit" "$unit" "Rate limited. Try again later."
assert_contains "team lookup names the failed resolution" "$unit" "Could not resolve team 'Claude'"
assert_not_contains "team lookup does not claim the team is missing" "$unit" "Team not found"
echo "=== generic non-200 carries the body's error message ==="
make_env "$TMP_BASE/gen" 400 "$GENERIC_BODY"
out="$(run_linear "$TMP_BASE/gen" statuses list)"
assert_contains "generic 400 includes the body message" "$out" "HTTP error: 400: Argument Validation Error"
