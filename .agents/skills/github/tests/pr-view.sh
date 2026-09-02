#!/usr/bin/env bash
# Regression tests for github.sh pr-view bounded auth and no-PR behavior.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
GITHUB_SH="$REPO_ROOT/skills/github/scripts/github.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    if [[ -n "$stderr_file" && -f "$stderr_file" ]]; then
      sed 's/^/        stderr: /' "$stderr_file"
    fi
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${STUB_GH_CALLS:-/dev/null}"

_auth_ok() {
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ "$tok" == op://* ]]; then
    return 1
  fi
  if [[ "${STUB_TOKEN_ONLY:-0}" == "1" ]]; then
    [[ "$tok" == "ghs_VALIDBOT123" ]]
    return
  fi
  [[ "${STUB_AUTH_OK:-1}" == "1" ]]
}

case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      if [[ "${STUB_AUTH_SLEEP:-0}" == "1" ]]; then
        sleep 2
      fi
      if [[ "${STUB_AUTH_STATUS_FAIL:-0}" == "1" ]]; then
        echo "keyring default failed" >&2
        exit 1
      fi
      if _auth_ok; then
        echo "Logged in"
        exit 0
      fi
      echo "gh auth failed" >&2
      exit 1
    fi
    ;;
  api)
    if [[ "${2:-}" == "user" ]]; then
      if [[ "${STUB_API_USER_SLEEP:-0}" == "1" ]]; then
        sleep 2
      fi
      _auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "test-user"
      exit 0
    fi
    ;;
  pr)
    if [[ "${2:-}" == "view" ]]; then
      _auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      case "${STUB_PR_MODE:-ok}" in
        no_pr)
          echo 'no pull requests found for branch "feature/no-pr"' >&2
          exit 1
          ;;
        auth)
          echo "HTTP 401: Bad credentials" >&2
          exit 1
          ;;
        hang)
          sleep 2
          ;;
        *)
          echo '{"number":42,"state":"OPEN"}'
          exit 0
          ;;
      esac
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

cat > "$TMP_ROOT/bin/op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'op called: %s\n' "$*" >>"${STUB_OP_CALLS:?}"
case "${STUB_OP_MODE:-fail}" in
  slow)
    sleep 2
    ;;
  ok)
    echo "ghs_VALIDBOT123"
    exit 0
    ;;
  *)
    echo "1Password item not available" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/op"

run_pr_view() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       STUB_OP_CALLS="$TMP_ROOT/op.calls" \
       env -u GH_TOKEN -u GITHUB_TOKEN "$@" "$GITHUB_SH" -C "$TMP_ROOT/repo" pr-view --json number,state)
}

# Invoke pr-view with an unsupported --format=<mode>, logging every gh call to
# calls_file so tests can prove the flag is not forwarded to gh pr view.
run_pr_view_format() {
  local fmt="$1" calls_file="$2"
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       STUB_GH_CALLS="$calls_file" \
       env -u GH_TOKEN -u GITHUB_TOKEN "$GITHUB_SH" -C "$TMP_ROOT/repo" pr-view 42 "--format=$fmt")
}

run_pr_view_passthrough() {
  local calls_file="$1"
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       STUB_GH_CALLS="$calls_file" \
       env -u GH_TOKEN -u GITHUB_TOKEN "$GITHUB_SH" -C "$TMP_ROOT/repo" \
       pr-view 42 --web extra-position)
}

run_pr_view_no_pr_passthrough() {
  local calls_file="$1"
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       STUB_GH_CALLS="$calls_file" \
       env -u GH_TOKEN -u GITHUB_TOKEN "$GITHUB_SH" -C "$TMP_ROOT/repo" \
       pr-view --repo owner/repo --json number,state)
}

run_pr_view_json_help_value() {
  local calls_file="$1"
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       STUB_GH_CALLS="$calls_file" \
       env -u GH_TOKEN -u GITHUB_TOKEN "$GITHUB_SH" -C "$TMP_ROOT/repo" \
       pr-view --json --help)
}

run_pr_view_help_value() {
  local calls_file="$1" flag="$2"
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       STUB_GH_CALLS="$calls_file" \
       env -u GH_TOKEN -u GITHUB_TOKEN "$GITHUB_SH" -C "$TMP_ROOT/repo" \
       pr-view "$flag" --help)
}

without_timeout_utility() {
  command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "timeout" ]]; then
      return 1
    fi
    builtin command "$@"
  }
  export -f command
  "$@"
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unwanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

echo "=== github.sh pr-view ==="

stderr="$TMP_ROOT/no-pr.err"
set +e
output=$(run_pr_view STUB_PR_MODE=no_pr 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "1" "no PR exits nonzero like gh" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "no_pr" "no PR emits structured status" "$stderr"
assert_contains "$(jq -r .detail <<<"$output")" "no pull requests found" "no PR preserves gh detail"

stderr="$TMP_ROOT/auth-timeout.err"
set +e
output=$(run_pr_view STUB_AUTH_SLEEP=1 KENDEX_GITHUB_AUTH_TIMEOUT=0.2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "124" "auth preflight timeout exits 124" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "auth_timeout" "auth timeout emits structured status" "$stderr"

stderr="$TMP_ROOT/auth-timeout-no-utility.err"
set +e
output=$(without_timeout_utility run_pr_view \
  STUB_AUTH_SLEEP=1 KENDEX_GITHUB_AUTH_TIMEOUT=0.2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "124" "auth timeout works without the timeout utility" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "auth_timeout" \
  "no-utility auth timeout emits structured status" "$stderr"

stderr="$TMP_ROOT/auth-leading-zero.err"
set +e
output=$(without_timeout_utility run_pr_view \
  KENDEX_GITHUB_AUTH_TIMEOUT=08 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "auth timeout accepts a leading-zero decimal" "$stderr"
assert_eq "$(jq -r .number <<<"$output")" "42" \
  "leading-zero auth bound reaches gh" "$stderr"

stderr="$TMP_ROOT/api-user-auth-timeout.err"
set +e
output=$(run_pr_view GH_TOKEN=ghs_VALIDBOT123 STUB_API_USER_SLEEP=1 KENDEX_GITHUB_AUTH_TIMEOUT=0.2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "124" "env-token auth preflight timeout exits 124" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "auth_timeout" "env-token auth timeout emits structured status" "$stderr"

stderr="$TMP_ROOT/stale-keyring.err"
set +e
output=$(run_pr_view GH_TOKEN=ghs_VALIDBOT123 STUB_AUTH_STATUS_FAIL=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "valid selected token ignores stale keyring status" "$stderr"
assert_eq "$(jq -r .number <<<"$output")" "42" "valid selected token preserves gh JSON" "$stderr"

stderr="$TMP_ROOT/pr-view-timeout.err"
set +e
output=$(run_pr_view STUB_PR_MODE=hang KENDEX_GITHUB_PR_VIEW_TIMEOUT=0.2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "124" "gh pr view timeout exits 124" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "gh_timeout" "gh timeout emits structured status" "$stderr"

stderr="$TMP_ROOT/pr-view-timeout-no-utility.err"
set +e
output=$(without_timeout_utility run_pr_view \
  STUB_PR_MODE=hang KENDEX_GITHUB_PR_VIEW_TIMEOUT=0.2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "124" "gh pr view timeout works without the timeout utility" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "gh_timeout" \
  "no-utility gh timeout emits structured status" "$stderr"

stderr="$TMP_ROOT/pr-view-leading-zero.err"
set +e
output=$(without_timeout_utility run_pr_view \
  KENDEX_GITHUB_PR_VIEW_TIMEOUT=09 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "gh timeout accepts a leading-zero decimal" "$stderr"
assert_eq "$(jq -r .number <<<"$output")" "42" \
  "leading-zero gh bound returns PR JSON" "$stderr"

# A bound outside the grammar the help advertises. The runner refuses it with
# 125 having run nothing, so without a mapping here the caller reads a
# configuration typo as a GitHub auth failure or as gh itself failing — the
# one surface an operator debugging their own setting actually sees. Every
# name the loop checks is driven, because a name dropped from it would fail
# exactly this way again.
for bound in KENDEX_GITHUB_AUTH_TIMEOUT KENDEX_GITHUB_OP_TIMEOUT \
  KENDEX_GITHUB_PR_VIEW_TIMEOUT; do
  stderr="$TMP_ROOT/bad-bound-$bound.err"
  calls="$TMP_ROOT/bad-bound-$bound.calls"
  : >"$calls"
  set +e
  output=$(run_pr_view "$bound=2.55" STUB_GH_CALLS="$calls" 2>"$stderr")
  rc=$?
  set -e
  assert_eq "$rc" "2" "an unreadable $bound exits 2" "$stderr"
  assert_eq "$(jq -r .status <<<"$output")" "bad_timeout" \
    "an unreadable $bound emits the configuration status" "$stderr"
  assert_contains "$(jq -r .error <<<"$output")" "$bound" \
    "the refusal names $bound" "$stderr"
  assert_eq "$(jq -r .detail <<<"$output")" "2.55" \
    "the refusal carries the value it rejected for $bound" "$stderr"
  assert_eq "$(wc -c <"$calls")" "0" \
    "an unreadable $bound reaches no gh call" "$stderr"
done

rm -f "$TMP_ROOT/op.calls"
stderr="$TMP_ROOT/inherited-gh-token-op.err"
set +e
output=$(run_pr_view GH_TOKEN=op://vault/github/user STUB_AUTH_OK=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "inherited op GH_TOKEN falls back to keyring" "$stderr"
assert_eq "$(jq -r .number <<<"$output")" "42" "inherited op GH_TOKEN preserves gh JSON" "$stderr"
assert_eq "$(wc -l <"$TMP_ROOT/op.calls")" "1" "inherited op GH_TOKEN attempts op once" "$stderr"

rm -f "$TMP_ROOT/op.calls"
stderr="$TMP_ROOT/inherited-github-token-op.err"
set +e
output=$(run_pr_view GITHUB_TOKEN=op://vault/github/user STUB_AUTH_OK=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "inherited op GITHUB_TOKEN falls back to keyring" "$stderr"
assert_eq "$(jq -r .number <<<"$output")" "42" "inherited op GITHUB_TOKEN preserves gh JSON" "$stderr"
assert_eq "$(wc -l <"$TMP_ROOT/op.calls")" "1" "inherited op GITHUB_TOKEN attempts op once" "$stderr"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_BOT_TOKEN=op://vault/item/field
ENVEOF

stderr="$TMP_ROOT/op-leading-zero.err"
set +e
output=$(without_timeout_utility run_pr_view \
  STUB_TOKEN_ONLY=1 STUB_OP_MODE=ok KENDEX_GITHUB_OP_TIMEOUT=08 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "op timeout accepts a leading-zero decimal" "$stderr"
assert_eq "$(jq -r .number <<<"$output")" "42" \
  "leading-zero op bound reaches gh" "$stderr"

stderr="$TMP_ROOT/op-fail.err"
set +e
output=$(run_pr_view STUB_AUTH_OK=0 STUB_OP_MODE=fail 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "3" "token resolution failure exits auth code" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "token_resolution_failed" "token failure emits structured status" "$stderr"

stderr="$TMP_ROOT/op-timeout.err"
set +e
output=$(run_pr_view STUB_AUTH_OK=0 STUB_OP_MODE=slow KENDEX_GITHUB_OP_TIMEOUT=0.2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "3" "token resolution timeout exits auth code" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "token_resolution_timeout" "token timeout emits structured status" "$stderr"

stderr="$TMP_ROOT/op-timeout-no-utility.err"
set +e
output=$(without_timeout_utility run_pr_view \
  STUB_AUTH_OK=0 STUB_OP_MODE=slow KENDEX_GITHUB_OP_TIMEOUT=0.2 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "3" "op timeout works without the timeout utility" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "token_resolution_timeout" \
  "no-utility op timeout emits structured status" "$stderr"

rm -f "$TMP_ROOT/repo/.env.local"

stderr="$TMP_ROOT/success.err"
set +e
output=$(run_pr_view 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "successful pr-view exits 0" "$stderr"
assert_eq "$(jq -r .number <<<"$output")" "42" "successful pr-view preserves gh JSON" "$stderr"

calls="$TMP_ROOT/pr-view-passthrough.calls"
: >"$calls"
stderr="$TMP_ROOT/pr-view-passthrough.err"
set +e
output=$(run_pr_view_passthrough "$calls" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "pr-view accepts passthrough arguments" "$stderr"
assert_contains "$(cat "$calls")" "pr view 42 --web extra-position" \
  "pr-view forwards unknown flags and extra positionals"

calls="$TMP_ROOT/pr-view-no-pr-passthrough.calls"
: >"$calls"
stderr="$TMP_ROOT/pr-view-no-pr-passthrough.err"
set +e
output=$(run_pr_view_no_pr_passthrough "$calls" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "pr-view accepts option values without a PR number" "$stderr"
assert_contains "$(cat "$calls")" "pr view --repo owner/repo --json number,state" \
  "pr-view preserves no-PR option-value order"

calls="$TMP_ROOT/pr-view-json-help-value.calls"
: >"$calls"
stderr="$TMP_ROOT/pr-view-json-help-value.err"
set +e
output=$(run_pr_view_json_help_value "$calls" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "pr-view accepts a help-shaped JSON field value" "$stderr"
assert_contains "$(cat "$calls")" "pr view --json --help" \
  "pr-view keeps the JSON field value with its option"

for flag in --template --jq --repo -t -q -R; do
  calls="$TMP_ROOT/pr-view-help-value-${flag#-}.calls"
  : >"$calls"
  stderr="$TMP_ROOT/pr-view-help-value-${flag#-}.err"
  set +e
  output=$(run_pr_view_help_value "$calls" "$flag" 2>"$stderr")
  rc=$?
  set -e
  assert_eq "$rc" "0" "pr-view accepts --help as the $flag value" "$stderr"
  assert_contains "$(cat "$calls")" "pr view $flag --help" \
    "pr-view forwards $flag with its help-shaped value"
done

echo
echo "=== github.sh pr-view --format rejection ==="

# pr-view advertises only --json FIELDS; --format must be rejected by the
# wrapper with a clean error, never forwarded to `gh pr view` (which would emit
# gh's own "unknown flag: --format").
calls="$TMP_ROOT/gh-format-safe.calls"
: >"$calls"
stderr="$TMP_ROOT/format-safe.err"
set +e
output=$(run_pr_view_format safe "$calls" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "2" "pr-view --format=safe exits nonzero (wrapper rejects)" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "unsupported_flag" "pr-view --format=safe emits structured status" "$stderr"
assert_contains "$(cat "$stderr")" "does not support --format" "pr-view --format=safe clean wrapper error"
assert_contains "$(cat "$stderr")" "pr-data" "pr-view --format=safe points to pr-data"
assert_not_contains "$(cat "$stderr")" "unknown flag" "pr-view --format=safe suppresses gh unknown flag"
assert_not_contains "$(cat "$calls")" "--format" "pr-view --format=safe never forwards --format to gh"

calls="$TMP_ROOT/gh-format-raw.calls"
: >"$calls"
stderr="$TMP_ROOT/format-raw.err"
set +e
output=$(run_pr_view_format raw "$calls" 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "2" "pr-view --format=raw exits nonzero (wrapper rejects)" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "unsupported_flag" "pr-view --format=raw emits structured status" "$stderr"
assert_contains "$(cat "$stderr")" "does not support --format" "pr-view --format=raw clean wrapper error"
assert_not_contains "$(cat "$stderr")" "unknown flag" "pr-view --format=raw suppresses gh unknown flag"
assert_not_contains "$(cat "$calls")" "--format" "pr-view --format=raw never forwards --format to gh"

echo
echo "=== github.sh --help no longer advertises --format globally ==="

help_out="$("$GITHUB_SH" --help)"
assert_contains "$help_out" "command-specific" "root help marks --format as command-specific"
assert_not_contains "$help_out" "--format=safe    Flat, normalized structure (DEFAULT)" "root help drops global --format=safe block"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
