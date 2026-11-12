#!/usr/bin/env bash
# gh-auth.sh's failure record: after a failed credential check,
# KENDEX_GITHUB_AUTH_SOURCE names the source tried and
# KENDEX_GITHUB_AUTH_FAILURE its category, and the check prints nothing.
# pr-view.test.sh holds the router-selected sources and the 401, 403, 5xx and
# timeout answers through github.sh; this suite holds what that route does not
# reach.
#
# A row is `label|env|call|want`:
#   env   NAME=VALUE words set before the call, `-` for none; STUB_USER,
#         STUB_INSTALL and STUB_STATUS pick gh's answer to `api user`,
#         `api installation/repositories` and `auth status`
#   call  check (kendex_github_token_auth_status) or capture
#         (kendex_github_auth_status_capture)
#   want  `rc=<status> source=<s> failure=<f> printed=<text>`, `-` for an
#         unset field or nothing printed
set -euo pipefail

# Every credential, selection, validation and bound a row sees is its own.
unset GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN KENDEX_GITHUB_VALIDATED_TOKEN \
  KENDEX_GITHUB_SELECTED_TOKEN_SOURCE KENDEX_GITHUB_AUTH_SOURCE \
  KENDEX_GITHUB_AUTH_FAILURE KENDEX_GITHUB_AUTH_TIMEOUT

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_AUTH_LIB="$TEST_DIR/../scripts/lib/gh-auth.sh"
TMP_ROOT="$(mktemp -d)" || { echo "gh-auth-failure-record: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "gh-auth-failure-record: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "gh-auth-failure-record: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
PASS=0
FAIL=0

mkdir -p "$TMP_ROOT/bin"
# gh writes a refused call's body to stdout and `gh: <message> (HTTP NNN)` to
# stderr. A stub that outlives its bound is the sleep itself.
cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "api user")
    case "${STUB_USER:-ok}" in
      401) echo '{"message":"Bad credentials"}'; echo "gh: Bad credentials (HTTP 401)" >&2; exit 1 ;;
      integration) echo '{"message":"Resource not accessible by integration"}'; echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1 ;;
      no-status) echo "error connecting to api.github.com" >&2; exit 1 ;;
    esac
    echo test-user
    exit 0
    ;;
  "api installation/repositories")
    case "${STUB_INSTALL:-ok}" in
      401) echo '{"message":"Bad credentials"}'; echo "gh: Bad credentials (HTTP 401)" >&2; exit 1 ;;
      sleep) exec sleep 2 ;;
    esac
    echo 3
    exit 0
    ;;
  "auth status")
    [[ "${STUB_STATUS:-ok}" != fail ]] || { echo "You are not logged into any GitHub hosts." >&2; exit 1; }
    echo "Logged in"
    exit 0
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

run_row() { # ENV CALL
  local env_words="$1" call="$2" rc=0 printed
  (
    PATH="$TMP_ROOT/bin:$PATH"
    if [[ "$env_words" != - ]]; then
      # shellcheck disable=SC2086
      export $env_words
    fi
    # shellcheck source=../scripts/lib/gh-auth.sh
    source "$GH_AUTH_LIB"
    status=0
    case "$call" in
      check) kendex_github_token_auth_status || status=$? ;;
      capture) kendex_github_auth_status_capture 10 "$TMP_ROOT/capture.out" "$TMP_ROOT/capture.err" || status=$? ;;
      *) echo "UNKNOWN-CALL: $call" >&2; exit 2 ;;
    esac
    printf 'rc=%s source=%s failure=%s' "$status" "${KENDEX_GITHUB_AUTH_SOURCE:--}" "${KENDEX_GITHUB_AUTH_FAILURE:--}" >"$TMP_ROOT/record"
  ) >"$TMP_ROOT/printed" 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || { printf 'row harness exited %s\n' "$rc"; return; }
  printed="$(<"$TMP_ROOT/printed")"
  printf '%s printed=%s' "$(<"$TMP_ROOT/record")" "${printed:--}"
}

ROWS="\
an integration refusal the installation endpoint accepts is a pass with no record|GH_TOKEN=tok-app KENDEX_GITHUB_SELECTED_TOKEN_SOURCE=GH_TOKEN STUB_USER=integration|check|rc=0 source=- failure=- printed=-
the installation endpoint's own refusal is the record|GH_TOKEN=tok-app KENDEX_GITHUB_SELECTED_TOKEN_SOURCE=GH_TOKEN STUB_USER=integration STUB_INSTALL=401|check|rc=1 source=GH_TOKEN failure=rejected_credential printed=-
the installation endpoint outliving its bound is a timeout|GH_TOKEN=tok-app KENDEX_GITHUB_SELECTED_TOKEN_SOURCE=GH_TOKEN STUB_USER=integration STUB_INSTALL=sleep KENDEX_GITHUB_AUTH_TIMEOUT=0.2|check|rc=124 source=GH_TOKEN failure=timeout printed=-
a refusal carrying no HTTP status is unknown|GH_TOKEN=tok-user KENDEX_GITHUB_SELECTED_TOKEN_SOURCE=GH_TOKEN STUB_USER=no-status|check|rc=1 source=GH_TOKEN failure=unknown printed=-
with no selection, GH_TOKEN is the source over GITHUB_TOKEN, as gh reads it|GH_TOKEN=tok-user GITHUB_TOKEN=tok-other STUB_USER=401|check|rc=1 source=GH_TOKEN failure=rejected_credential printed=-
with no selection and no GH_TOKEN, GITHUB_TOKEN is the source|GITHUB_TOKEN=tok-user STUB_USER=401|check|rc=1 source=GITHUB_TOKEN failure=rejected_credential printed=-
the keyring's own failure names the keyring|STUB_STATUS=fail|capture|rc=1 source=keyring failure=unknown printed=-
"

echo "=== the failure record ==="
while IFS='|' read -r label env_words call want; do
  [[ -n "$label" ]] || continue
  got="$(run_row "$env_words" "$call")"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
done <<<"$ROWS"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$PASS" -gt 0 && "$FAIL" -eq 0 ]]
