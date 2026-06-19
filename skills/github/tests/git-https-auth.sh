#!/usr/bin/env bash
# Regression tests for GitHub SSH remote HTTPS fallback helper.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
GIT_HELPER="$REPO_ROOT/skills/github/scripts/git-https-auth"
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
    printf '  FAIL  %s\n        unexpected substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

run_helper() {
  PATH="$TMP_ROOT/bin:$PATH" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    "$GIT_HELPER" "$@"
}

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/repos"

cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      [[ "${STUB_GH_AUTH_OK:-1}" == "1" ]] || { echo "not logged in" >&2; exit 1; }
      echo "Logged in"
      exit 0
    fi
    if [[ "${2:-}" == "git-credential" ]]; then
      exit 0
    fi
    ;;
  api)
    if [[ "${2:-}" == "user" ]]; then
      [[ "${STUB_GH_AUTH_OK:-1}" == "1" ]] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "test-user"
      exit 0
    fi
    ;;
esac

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  printf 'base\n' >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m base
}

echo "=== git-https-auth ==="

ssh_repo="$TMP_ROOT/repos/ssh"
make_repo "$ssh_repo"
git -C "$ssh_repo" remote add origin git@github.com:owner/repo.git

helpers="$(run_helper -C "$ssh_repo" config --get-all credential.helper || true)"
assert_contains "$helpers" "!gh auth git-credential" "GitHub SSH remote installs gh credential helper"

rewrites="$(run_helper -C "$ssh_repo" config --get-all url.https://github.com/.insteadOf || true)"
assert_contains "$rewrites" "git@github.com:" "GitHub SSH scp syntax rewrites to HTTPS"
assert_contains "$rewrites" "ssh://git@github.com/" "GitHub SSH URL syntax rewrites to HTTPS"

alias_repo="$TMP_ROOT/repos/alias"
make_repo "$alias_repo"
git -C "$alias_repo" remote add vg-claude git@github-vg-claude:owner/repo.git
alias_rewrites="$(run_helper -C "$alias_repo" config --get-all url.https://github.com/.insteadOf || true)"
assert_contains "$alias_rewrites" "git@github-vg-claude:" "GitHub SSH host aliases rewrite to HTTPS"

persisted="$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$ssh_repo" config --get-all url.https://github.com/.insteadOf || true)"
assert_eq "$persisted" "" "fallback does not persist url rewrite config"

https_repo="$TMP_ROOT/repos/https"
make_repo "$https_repo"
git -C "$https_repo" remote add origin https://github.com/owner/repo.git
https_rewrites="$(run_helper -C "$https_repo" config --get-all url.https://github.com/.insteadOf || true)"
assert_eq "$https_rewrites" "" "HTTPS remotes stay on normal git path"

local_repo="$TMP_ROOT/repos/local"
make_repo "$local_repo"
git -C "$local_repo" remote add origin "$TMP_ROOT/repos/origin.git"
local_helpers="$(run_helper -C "$local_repo" config --get-all credential.helper || true)"
assert_not_contains "$local_helpers" "!gh auth git-credential" "non-GitHub remotes do not get helper config"

disabled="$(VSTACK_GITHUB_GIT_HTTPS_FALLBACK=never run_helper -C "$ssh_repo" config --get-all credential.helper || true)"
assert_not_contains "$disabled" "!gh auth git-credential" "fallback can be disabled"

unauthenticated="$(STUB_GH_AUTH_OK=0 run_helper -C "$ssh_repo" config --get-all credential.helper || true)"
assert_not_contains "$unauthenticated" "!gh auth git-credential" "invalid gh auth leaves SSH path unchanged"

explicit="$(
  source "$REPO_ROOT/skills/github/scripts/lib/gh-auth.sh"
  if vstack_github_git_should_use_https_fallback ls-remote git@github.com:owner/repo.git; then
    printf 'yes'
  else
    printf 'no'
  fi
)"
assert_eq "$explicit" "yes" "explicit GitHub SSH URL enables fallback"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
