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

_auth_ok() {
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ "$tok" == op://* ]]; then
    return 1
  fi
  [[ "${STUB_AUTH_OK:-1}" == "1" ]]
}

case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      if [[ "${STUB_AUTH_SLEEP:-0}" == "1" ]]; then
        sleep 5
      fi
      if _auth_ok; then
        echo "Logged in"
        exit 0
      fi
      echo "gh auth failed" >&2
      exit 1
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
          sleep 5
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
    sleep 5
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
output=$(run_pr_view STUB_AUTH_SLEEP=1 VSTACK_GITHUB_AUTH_TIMEOUT=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "124" "auth preflight timeout exits 124" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "auth_timeout" "auth timeout emits structured status" "$stderr"

stderr="$TMP_ROOT/pr-view-timeout.err"
set +e
output=$(run_pr_view STUB_PR_MODE=hang VSTACK_GITHUB_PR_VIEW_TIMEOUT=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "124" "gh pr view timeout exits 124" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "gh_timeout" "gh timeout emits structured status" "$stderr"

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

stderr="$TMP_ROOT/op-fail.err"
set +e
output=$(run_pr_view STUB_AUTH_OK=0 STUB_OP_MODE=fail 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "3" "token resolution failure exits auth code" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "token_resolution_failed" "token failure emits structured status" "$stderr"

stderr="$TMP_ROOT/op-timeout.err"
set +e
output=$(run_pr_view STUB_AUTH_OK=0 STUB_OP_MODE=slow VSTACK_GITHUB_OP_TIMEOUT=1 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "3" "token resolution timeout exits auth code" "$stderr"
assert_eq "$(jq -r .status <<<"$output")" "token_resolution_timeout" "token timeout emits structured status" "$stderr"

rm -f "$TMP_ROOT/repo/.env.local"

stderr="$TMP_ROOT/success.err"
set +e
output=$(run_pr_view 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "successful pr-view exits 0" "$stderr"
assert_eq "$(jq -r .number <<<"$output")" "42" "successful pr-view preserves gh JSON" "$stderr"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
