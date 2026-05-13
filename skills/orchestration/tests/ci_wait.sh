#!/usr/bin/env bash
# Regression tests for orchestration/scripts/ci-wait auth ladder.
#
# Covers vstack#19 plus the follow-up review:
#   1. stale GH_TOKEN + working keyring  -> sanitizer unsets, ci-wait passes
#   2. no env tokens + working keyring   -> no warning, ci-wait passes
#   3. stale GH_TOKEN + broken keyring + no .env.local bot token
#                                        -> exit 3 with "no working" diagnostic
#   4. stale GH_TOKEN + broken keyring + valid .env.local GH_BOT_TOKEN
#                                        -> bot-token fallback recovers
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

dump_stderr() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  printf '        stderr:\n'
  sed 's/^/          /' "$file"
}

assert_eq() {
  local got="$1" want="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    dump_stderr "$stderr_file"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unwanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin"
ln -s "$REPO_ROOT/skills/orchestration" "$TMP_ROOT/repo/.agents/skills/orchestration"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

# Parametrized `gh` stub.
#   _stub_auth_ok returns 0 iff the current invocation should succeed.
#     GH_TOKEN/GITHUB_TOKEN set    -> ok iff value matches STUB_GH_VALID_TOKEN
#     no env tokens                 -> ok iff STUB_GH_DENY_KEYRING != 1
#   All API endpoints (auth status, repo view, pr view, pr checks) gate on
#   _stub_auth_ok so a stale token surfaces as HTTP 401 the same way the
#   real `gh` does.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

_stub_auth_ok() {
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$tok" ]]; then
    [[ -n "${STUB_GH_VALID_TOKEN:-}" && "$tok" == "$STUB_GH_VALID_TOKEN" ]] && return 0
    return 1
  fi
  [[ "${STUB_GH_DENY_KEYRING:-0}" == "1" ]] && return 1
  return 0
}

case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      if _stub_auth_ok; then
        echo "Logged in"
        exit 0
      fi
      echo "auth failed" >&2
      exit 1
    fi
    ;;
  repo)
    if [[ "${2:-}" == "view" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "owner/repo"
      exit 0
    fi
    ;;
  pr)
    if [[ "${2:-}" == "view" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "CLEAN"
      exit 0
    fi
    if [[ "${2:-}" == "checks" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo '[{"name":"build","state":"SUCCESS"}]'
      exit 0
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

# Run ci-wait via the .agents symlink, exactly how it's invoked in
# production. `env "$@"` injects test-controlled env tokens / stub flags.
run_wait() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env "$@" .agents/skills/orchestration/scripts/ci-wait 1 1 30)
}

echo "=== ci-wait auth handling ==="

# Case 1: stale GH_TOKEN inherited from caller; keyring works once unset.
stderr="$TMP_ROOT/case1.err"
set +e
output=$(run_wait GH_TOKEN=bad-token 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case1: stale GH_TOKEN sanitized, ci-wait exits 0" "$stderr"
assert_contains "$output" "CI passed" "case1: ci-wait reaches CI passed"
assert_contains "$(cat "$stderr")" "unsetting them" "case1: stale-token warning on stderr"

# Case 2: no env tokens; keyring works directly.
stderr="$TMP_ROOT/case2.err"
set +e
output=$(run_wait 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case2: keyring works without env tokens" "$stderr"
assert_contains "$output" "CI passed" "case2: ci-wait reaches CI passed"
assert_not_contains "$(cat "$stderr")" "unsetting them" "case2: sanitizer silent when no env tokens" "$stderr"

# Case 3: stale GH_TOKEN + keyring denied + no .env.local bot token.
rm -f "$TMP_ROOT/repo/.env.local"
stderr="$TMP_ROOT/case3.err"
set +e
output=$(run_wait GH_TOKEN=bad-token STUB_GH_DENY_KEYRING=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "3" "case3: no working auth path -> exit 3" "$stderr"
assert_contains "$(cat "$stderr")" "no working GitHub auth path" "case3: clear diagnostic on stderr"

# Case 4: stale GH_TOKEN + keyring denied + valid .env.local GH_BOT_TOKEN.
cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
export GH_BOT_TOKEN=ghs_VALIDBOT123
ENVEOF
stderr="$TMP_ROOT/case4.err"
set +e
output=$(run_wait GH_TOKEN=bad-token STUB_GH_DENY_KEYRING=1 STUB_GH_VALID_TOKEN=ghs_VALIDBOT123 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "case4: .env.local GH_BOT_TOKEN recovers" "$stderr"
assert_contains "$output" "CI passed" "case4: ci-wait reaches CI passed via bot-token fallback"
rm -f "$TMP_ROOT/repo/.env.local"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
