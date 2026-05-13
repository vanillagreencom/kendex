#!/usr/bin/env bash
# Regression tests for orchestration/scripts/ci-wait.
# Verifies the stale-GH_TOKEN sanitizer from lib/gh-auth.sh kicks in before
# the first `gh` call (vstack#19).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
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

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin"
ln -s "$REPO_ROOT/skills/orchestration" "$TMP_ROOT/repo/.agents/skills/orchestration"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

# Fake gh: succeeds for auth status only when no env tokens are present;
# the same gate is applied to `pr checks` so a stale GH_TOKEN that the
# sanitizer fails to clear would surface as an HTTP 401 like the real bug.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
        echo "GH_TOKEN invalid" >&2
        exit 1
      fi
      echo "Logged in"
      exit 0
    fi
    ;;
  repo)
    if [[ "${2:-}" == "view" ]]; then
      # ci-wait calls: gh repo view --json nameWithOwner -q .nameWithOwner
      echo "owner/repo"
      exit 0
    fi
    ;;
  pr)
    if [[ "${2:-}" == "view" ]]; then
      # ci-wait calls: gh pr view N --repo R --json mergeStateStatus --jq '.mergeStateStatus'
      echo "CLEAN"
      exit 0
    fi
    if [[ "${2:-}" == "checks" ]]; then
      if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
        echo "HTTP 401: Bad credentials" >&2
        exit 1
      fi
      echo '[{"name":"build","state":"SUCCESS"}]'
      exit 0
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

run_wait() {
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" "$@" .agents/skills/orchestration/scripts/ci-wait 1 1 30)
}

echo "=== ci-wait auth handling ==="

# Case 1: bad GH_TOKEN inherited from caller, keyring works once unset.
stderr="$TMP_ROOT/case1.err"
output=$(run_wait env GH_TOKEN=bad-token 2>"$stderr")
assert_contains "$output" "CI passed" "bad GH_TOKEN sanitized; ci-wait reaches CI passed"
assert_contains "$(cat "$stderr")" "unsetting them" "stale-token warning emitted to stderr"

# Case 2: no env tokens — sanitizer must stay silent.
stderr="$TMP_ROOT/case2.err"
output=$(run_wait env -u GH_TOKEN -u GITHUB_TOKEN 2>"$stderr")
assert_contains "$output" "CI passed" "keyring auth works without env tokens"
assert_not_contains "$(cat "$stderr")" "unsetting them" "sanitizer silent when no env tokens set"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
